#!/usr/bin/env python3
"""Repository health maintenance tasks with deterministic, safe updates."""

from __future__ import annotations

import argparse
import json
import subprocess
from dataclasses import dataclass
from pathlib import Path


REPO_ROOT = Path(".").resolve()
METADATA_FILE = REPO_ROOT / ".github" / "repository-metadata.json"
TEXT_SUFFIXES = {
    ".md",
    ".txt",
    ".py",
    ".sh",
    ".json",
    ".yml",
    ".yaml",
    ".toml",
    ".ini",
    ".cfg",
    ".gitignore",
    ".gitattributes",
}


@dataclass
class Result:
    changed_files: set[Path]
    updates: list[str]


def tracked_files() -> list[Path]:
    output = subprocess.check_output(["git", "ls-files"], text=True, cwd=REPO_ROOT)
    files: list[Path] = []
    for line in output.splitlines():
        if not line:
            continue
        path = REPO_ROOT / line
        if path.is_file():
            files.append(path)
    return files


def is_text_candidate(path: Path) -> bool:
    if path.name in {"README"}:
        return True
    if path.suffix.lower() in TEXT_SUFFIXES:
        return True
    return path.name.startswith(".") and path.suffix.lower() in {"", ".txt", ".md", ".yml", ".yaml"}


def normalize_text_file(path: Path) -> str | None:
    try:
        original = path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        return None

    lines = original.splitlines()
    normalized = "\n".join(line.rstrip() for line in lines)
    if original.endswith("\n") or original == "":
        normalized = f"{normalized}\n" if normalized else ""
    elif normalized:
        normalized = f"{normalized}\n"

    while normalized.endswith("\n\n\n"):
        normalized = normalized[:-1]

    if normalized != original:
        path.write_text(normalized, encoding="utf-8")
        return f"{path.relative_to(REPO_ROOT).as_posix()}: normalized whitespace and EOF newlines"
    return None


def task_formatting() -> Result:
    changed: set[Path] = set()
    updates: list[str] = []

    for file in tracked_files():
        if not is_text_candidate(file):
            continue
        update = normalize_text_file(file)
        if update:
            changed.add(file)
            updates.append(update)

    return Result(changed_files=changed, updates=updates)


def build_metadata() -> dict[str, object]:
    docs = sorted(
        p.relative_to(REPO_ROOT).as_posix()
        for p in REPO_ROOT.rglob("*.md")
        if ".git" not in p.parts
    )
    scripts_dir = REPO_ROOT / "scripts" / "maintenance"
    scripts = sorted(
        p.relative_to(REPO_ROOT).as_posix()
        for p in scripts_dir.glob("*")
        if p.is_file()
    )

    return {
        "schema_version": 1,
        "maintenance": {
            "automated": True,
            "scope": [
                "stale generated files",
                "formatting",
                "broken documentation references",
                "repository metadata",
                "dependency metadata",
                "generated indexes",
                "lint-fixable issues",
            ],
            "scripts": scripts,
        },
        "documentation": {
            "markdown_files": docs,
            "count": len(docs),
        },
    }


def task_metadata() -> Result:
    METADATA_FILE.parent.mkdir(parents=True, exist_ok=True)
    new_content = json.dumps(build_metadata(), indent=2, sort_keys=True) + "\n"
    old_content = METADATA_FILE.read_text(encoding="utf-8") if METADATA_FILE.exists() else ""

    if new_content == old_content:
        return Result(changed_files=set(), updates=[])

    METADATA_FILE.write_text(new_content, encoding="utf-8")
    return Result(changed_files={METADATA_FILE}, updates=[f"{METADATA_FILE.relative_to(REPO_ROOT).as_posix()}: refreshed deterministic repository metadata"])


def task_dependencies() -> Result:
    updates: list[str] = []
    changed: set[Path] = set()

    package_json = REPO_ROOT / "package.json"
    package_lock = REPO_ROOT / "package-lock.json"

    if package_json.exists() and package_lock.exists():
        subprocess.check_call(
            [
                "npm",
                "install",
                "--package-lock-only",
                "--ignore-scripts",
                "--no-audit",
                "--no-fund",
            ],
            cwd=REPO_ROOT,
        )
        updates.append("package-lock.json: regenerated safely using npm --package-lock-only")
        changed.add(package_lock)
    else:
        updates.append("No supported dependency metadata files found; skipped")

    return Result(changed_files=changed, updates=updates)


def run(task: str) -> Result:
    if task == "formatting":
        return task_formatting()
    if task == "metadata":
        return task_metadata()
    if task == "dependencies":
        return task_dependencies()
    raise ValueError(f"Unsupported task: {task}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Maintain repository health deterministically.")
    parser.add_argument("--task", choices=["formatting", "metadata", "dependencies"], required=True)
    args = parser.parse_args()

    result = run(args.task)
    print(f"[repo-health] task={args.task}")
    if result.updates:
        for entry in result.updates:
            print(f"[repo-health] {entry}")
    else:
        print("[repo-health] no changes required")
    print(f"[repo-health] changed_files={len(result.changed_files)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
