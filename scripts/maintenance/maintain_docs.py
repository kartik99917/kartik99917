#!/usr/bin/env python3
"""Deterministic documentation maintenance for Markdown files."""

from __future__ import annotations

import argparse
import re
from dataclasses import dataclass
from os.path import relpath
from pathlib import Path
from typing import Iterable


REPO_ROOT = Path(".").resolve()
LINK_RE = re.compile(r"(!?\[[^\]]*\]\(([^)]+)\))")
HTML_LINK_RE = re.compile(r"((?:href|src)=[\"'])([^\"']+)([\"'])", re.IGNORECASE)
TOC_START = "<!-- AUTO-TOC:START -->"
TOC_END = "<!-- AUTO-TOC:END -->"
INDEX_START = "<!-- AUTO-INDEX:START -->"
INDEX_END = "<!-- AUTO-INDEX:END -->"


@dataclass
class Result:
    changed_files: set[Path]
    updates: list[str]

    def merge(self, other: "Result") -> None:
        self.changed_files.update(other.changed_files)
        self.updates.extend(other.updates)


def iter_markdown_files() -> list[Path]:
    files: set[Path] = set()
    for entry in [REPO_ROOT / "README.md", REPO_ROOT / "docs", REPO_ROOT / ".github"]:
        if entry.is_file() and entry.suffix.lower() == ".md":
            files.add(entry)
        elif entry.is_dir():
            files.update(p for p in entry.rglob("*.md") if ".git" not in p.parts)
    return sorted(files)


def clean_target(raw_target: str) -> str:
    target = raw_target.strip()
    if target.startswith("<") and target.endswith(">"):
        target = target[1:-1].strip()
    if " " in target:
        target = target.split(" ", 1)[0]
    return target


def is_external(target: str) -> bool:
    lowered = target.lower()
    return lowered.startswith(("http://", "https://", "mailto:", "tel:", "data:", "javascript:"))


def split_anchor(target: str) -> tuple[str, str]:
    if "#" in target:
        base, anchor = target.split("#", 1)
        return base, f"#{anchor}"
    return target, ""


def find_candidate(base: str, source: Path) -> str | None:
    if not base:
        return None

    requested = Path(base)
    name = requested.name.lower()
    suffix = requested.suffix.lower()

    matches: list[Path] = []
    for file in REPO_ROOT.rglob("*"):
        if not file.is_file() or ".git" in file.parts:
            continue
        if file.name.lower() != name:
            continue
        if suffix and file.suffix.lower() != suffix:
            continue
        matches.append(file)

    if len(matches) != 1:
        return None

    return Path(relpath(matches[0], source.parent.resolve())).as_posix()


def resolve_target(source: Path, target: str) -> tuple[bool, str | None]:
    base, anchor = split_anchor(target)
    if not base:
        return True, None

    if base.startswith("/"):
        candidate = (REPO_ROOT / base.lstrip("/")).resolve()
    else:
        candidate = (source.parent / base).resolve()

    if candidate.exists():
        return True, None

    replacement = find_candidate(base, source)
    if not replacement:
        return False, None

    return True, f"{replacement}{anchor}"


def maintain_links(markdown_file: Path) -> Result:
    text = markdown_file.read_text(encoding="utf-8")
    changed = False
    updates: list[str] = []

    def replace_md(match: re.Match[str]) -> str:
        nonlocal changed
        full, raw_target = match.group(1), match.group(2)
        cleaned = clean_target(raw_target)
        if not cleaned or is_external(cleaned) or cleaned.startswith("#"):
            return full

        valid, replacement = resolve_target(markdown_file, cleaned)
        if valid and replacement:
            changed = True
            updates.append(f"{markdown_file}: fixed link target '{cleaned}' -> '{replacement}'")
            return full.replace(raw_target, raw_target.replace(cleaned, replacement, 1), 1)
        return full

    def replace_html(match: re.Match[str]) -> str:
        nonlocal changed
        prefix, target, suffix = match.groups()
        cleaned = clean_target(target)
        if not cleaned or is_external(cleaned) or cleaned.startswith("#"):
            return match.group(0)

        valid, replacement = resolve_target(markdown_file, cleaned)
        if valid and replacement:
            changed = True
            updates.append(f"{markdown_file}: fixed HTML target '{cleaned}' -> '{replacement}'")
            return f"{prefix}{replacement}{suffix}"
        return match.group(0)

    updated = LINK_RE.sub(replace_md, text)
    updated = HTML_LINK_RE.sub(replace_html, updated)

    if changed and updated != text:
        markdown_file.write_text(updated, encoding="utf-8")
        return Result(changed_files={markdown_file}, updates=updates)
    return Result(changed_files=set(), updates=[])


def slugify_heading(heading: str) -> str:
    slug = heading.strip().lower()
    slug = re.sub(r"[`*_~]", "", slug)
    slug = re.sub(r"[^a-z0-9\-\s]", "", slug)
    slug = re.sub(r"\s+", "-", slug)
    slug = re.sub(r"-+", "-", slug).strip("-")
    return slug


def extract_headings(text: str) -> list[tuple[int, str]]:
    headings: list[tuple[int, str]] = []
    in_fence = False
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("```"):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        if not stripped.startswith("#"):
            continue
        level = len(stripped) - len(stripped.lstrip("#"))
        title = stripped[level:].strip()
        if not title:
            continue
        headings.append((level, title))
    return headings


def replace_between_markers(text: str, start_marker: str, end_marker: str, content: str) -> str:
    block_re = re.compile(
        rf"({re.escape(start_marker)}\\n)(.*?)(\\n{re.escape(end_marker)})",
        re.DOTALL,
    )
    return block_re.sub(rf"\\1{content}\\3", text)


def regenerate_toc(markdown_file: Path) -> Result:
    text = markdown_file.read_text(encoding="utf-8")
    if TOC_START not in text or TOC_END not in text:
        return Result(changed_files=set(), updates=[])

    headings = extract_headings(text)
    toc_lines: list[str] = []
    for level, title in headings:
        if level == 1:
            continue
        slug = slugify_heading(title)
        if not slug:
            continue
        indent = "  " * max(level - 2, 0)
        toc_lines.append(f"{indent}- [{title}](#{slug})")

    new_body = "\n".join(toc_lines) if toc_lines else "- No sections detected"
    updated = replace_between_markers(text, TOC_START, TOC_END, new_body)

    if updated != text:
        markdown_file.write_text(updated, encoding="utf-8")
        return Result(changed_files={markdown_file}, updates=[f"{markdown_file}: regenerated TOC block"])
    return Result(changed_files=set(), updates=[])


def first_heading(path: Path) -> str:
    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if stripped.startswith("#"):
            return stripped.lstrip("#").strip() or path.stem
    return path.stem


def regenerate_index(markdown_file: Path, all_docs: Iterable[Path]) -> Result:
    text = markdown_file.read_text(encoding="utf-8")
    if INDEX_START not in text or INDEX_END not in text:
        return Result(changed_files=set(), updates=[])

    source_dir = markdown_file.parent
    entries: list[str] = []
    for doc in sorted(all_docs):
        if doc == markdown_file:
            continue
        if doc.parent != source_dir and source_dir not in doc.parents:
            continue
        rel = doc.relative_to(source_dir).as_posix()
        entries.append(f"- [{first_heading(doc)}]({rel})")

    body = "\n".join(entries) if entries else "- No documents found"
    updated = replace_between_markers(text, INDEX_START, INDEX_END, body)

    if updated != text:
        markdown_file.write_text(updated, encoding="utf-8")
        return Result(changed_files={markdown_file}, updates=[f"{markdown_file}: regenerated index block"])
    return Result(changed_files=set(), updates=[])


def run(task: str) -> Result:
    docs = iter_markdown_files()
    result = Result(changed_files=set(), updates=[])

    if task in {"links", "all"}:
        for doc in docs:
            result.merge(maintain_links(doc))

    if task in {"generated", "all"}:
        for doc in docs:
            result.merge(regenerate_toc(doc))
            result.merge(regenerate_index(doc, docs))

    return result


def main() -> int:
    parser = argparse.ArgumentParser(description="Maintain documentation files deterministically.")
    parser.add_argument("--task", choices=["links", "generated", "all"], default="all")
    parser.add_argument("--write", action="store_true", help="No-op flag for interface compatibility.")
    args = parser.parse_args()

    result = run(args.task)

    print(f"[docs-maintenance] task={args.task}")
    if result.updates:
        for entry in result.updates:
            print(f"[docs-maintenance] {entry}")
    else:
        print("[docs-maintenance] no changes required")
    print(f"[docs-maintenance] changed_files={len(result.changed_files)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
