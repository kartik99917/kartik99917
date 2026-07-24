#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
readonly DOC_SCRIPT="${SCRIPT_DIR}/maintain_docs.py"
readonly HEALTH_SCRIPT="${SCRIPT_DIR}/maintain_repo_health.py"
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

run_task() {
  local label="$1"
  shift
  log "Running task: ${label}"
  retry 3 "$@"
}

validate_pending_changes() {
  local verify_cmd="$1"

  log "Validating pending changes"
  bash -n "${SCRIPT_DIR}/run-maintenance.sh"
  python3 -m py_compile "${DOC_SCRIPT}" "${HEALTH_SCRIPT}"

  git add -A
  log "Running idempotence pass: ${verify_cmd}"
  eval "${verify_cmd}"
  if ! git diff --quiet; then
    log "WARN: first idempotence pass made additional edits; restaging and verifying once more"
    git add -A
    eval "${verify_cmd}"
    if ! git diff --quiet; then
      log "ERROR: maintenance output remains non-deterministic after retry"
      exit 1
    fi
  fi

  git add -A
}

commit_task_if_changed() {
  local commit_message="$1"
  local verify_cmd="$2"

  if git diff --quiet; then
    log "No updates for task: ${commit_message}"
    return 0
  fi

  validate_pending_changes "${verify_cmd}"

  if git diff --cached --quiet; then
    log "No staged updates after validation for task: ${commit_message}"
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

  log "Starting repository health maintenance run"

  if [[ ! -f "${DOC_SCRIPT}" ]]; then
    log "ERROR: missing script ${DOC_SCRIPT}"
    exit 1
  fi

  if [[ ! -f "${HEALTH_SCRIPT}" ]]; then
    log "ERROR: missing script ${HEALTH_SCRIPT}"
    exit 1
  fi

  git config user.name "${BOT_NAME}"
  git config user.email "${BOT_EMAIL}"

  run_task "docs links" python3 "${DOC_SCRIPT}" --task links --write
  commit_task_if_changed \
    "docs(maintenance): fix broken internal links and file references" \
    "python3 '${DOC_SCRIPT}' --task links --write"

  run_task "docs generated indexes" python3 "${DOC_SCRIPT}" --task generated --write
  commit_task_if_changed \
    "docs(maintenance): refresh generated indexes and tables of contents" \
    "python3 '${DOC_SCRIPT}' --task generated --write"

  run_task "formatting normalization" python3 "${HEALTH_SCRIPT}" --task formatting
  commit_task_if_changed \
    "chore(maintenance): normalize whitespace and EOF formatting" \
    "python3 '${HEALTH_SCRIPT}' --task formatting"

  run_task "repository metadata refresh" python3 "${HEALTH_SCRIPT}" --task metadata
  commit_task_if_changed \
    "chore(maintenance): refresh repository metadata snapshot" \
    "python3 '${HEALTH_SCRIPT}' --task metadata"

  run_task "dependency metadata refresh" python3 "${HEALTH_SCRIPT}" --task dependencies
  commit_task_if_changed \
    "chore(deps): regenerate dependency metadata safely" \
    "python3 '${HEALTH_SCRIPT}' --task dependencies"

  log "Repository health maintenance run complete"
}

main "$@"
