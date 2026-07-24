#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
readonly DOC_SCRIPT="${SCRIPT_DIR}/maintain_docs.py"
readonly BOT_NAME="github-actions[bot]"
readonly BOT_EMAIL="41898282+github-actions[bot]@users.noreply.github.com"

log() {
  printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"
}

retry() {
  local attempts="$1"
  shift
  local n=1
  until "$@"; do
    if (( n >= attempts )); then
      log "ERROR: command failed after ${attempts} attempts: $*"
      return 1
    fi
    local backoff=$(( n * 5 ))
    log "WARN: attempt ${n}/${attempts} failed; retrying in ${backoff}s: $*"
    sleep "${backoff}"
    n=$((n + 1))
  done
}

commit_task_if_changed() {
  local commit_message="$1"

  if git diff --quiet; then
    log "No documentation updates for task: ${commit_message}"
    return 0
  fi

  git add -A
  if git diff --cached --quiet; then
    log "No staged updates after add for task: ${commit_message}"
    return 0
  fi

  local last_subject
  last_subject="$(git log -1 --pretty=%s 2>/dev/null || true)"
  if [[ "${last_subject}" == "${commit_message}" ]]; then
    log "Skipping duplicate commit subject: ${commit_message}"
    git reset --quiet
    return 0
  fi

  git commit -m "${commit_message}"
  retry 3 git push origin "HEAD:${GITHUB_REF_NAME}"
  log "Committed and pushed: ${commit_message}"
}

main() {
  cd "${REPO_ROOT}"

  log "Starting documentation maintenance run"

  if [[ ! -f "${DOC_SCRIPT}" ]]; then
    log "ERROR: missing script ${DOC_SCRIPT}"
    exit 1
  fi

  git config user.name "${BOT_NAME}"
  git config user.email "${BOT_EMAIL}"

  retry 3 python3 "${DOC_SCRIPT}" --task links --write
  commit_task_if_changed "docs(maintenance): fix broken internal links and file references"

  retry 3 python3 "${DOC_SCRIPT}" --task generated --write
  commit_task_if_changed "docs(maintenance): refresh generated indexes and tables of contents"

  log "Documentation maintenance run complete"
}

main "$@"
