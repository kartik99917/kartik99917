#!/usr/bin/env bash
set -euo pipefail

readonly MAINTENANCE_PREFIX="chore(maintenance):"
readonly METRICS_FILE=".github/maintenance/repository-metrics.json"
readonly CHECKSUMS_FILE=".github/maintenance/asset-checksums.txt"
readonly HEARTBEAT_FILE=".github/maintenance/heartbeat.log"
readonly ROTATION_FILE=".github/maintenance/rotation.txt"
readonly RUN_HISTORY_FILE=".github/maintenance/run-history.jsonl"
readonly LINK_REPORT_FILE=".github/maintenance/link-report.md"

log() {
  printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"
}

retry() {
  local attempts=$1
  shift
  local n=1
  until "$@"; do
    if (( n >= attempts )); then
      log "ERROR: command failed after ${attempts} attempts: $*"
      return 1
    fi
    local sleep_seconds=$(( n * 3 ))
    log "WARN: command failed (attempt ${n}/${attempts}), retrying in ${sleep_seconds}s: $*"
    sleep "${sleep_seconds}"
    n=$((n + 1))
  done
}

today_utc() {
  date -u +'%Y-%m-%d'
}

day_seed() {
  # Deterministic per-day seed for stable target count selection.
  local yyyy_mm_dd
  yyyy_mm_dd="$(today_utc)"
  printf '%s' "${yyyy_mm_dd//-/}"
}

target_tasks_for_today() {
  local seed
  seed="$(day_seed)"
  echo $(( (10#${seed} % 4) + 3 ))
}

completed_tasks_today() {
  local start_of_day
  start_of_day="$(date -u +'%Y-%m-%dT00:00:00Z')"
  git log --since="${start_of_day}" --pretty=%s --grep="^${MAINTENANCE_PREFIX}" | wc -l | tr -d ' '
}

remaining_windows_today() {
  local hour
  hour="$(date -u +'%H')"
  echo $(( 24 - 10#${hour} ))
}

should_run_this_window() {
  local target completed remaining tasks_left windows_left threshold roll

  if [[ "${MAINTENANCE_FORCE_RUN:-0}" == "1" ]]; then
    log "MAINTENANCE_FORCE_RUN=1 set; forcing execution for this window."
    return 0
  fi

  target="$(target_tasks_for_today)"
  completed="$(completed_tasks_today)"

  if (( completed >= target )); then
    log "Daily target already met (${completed}/${target}); skipping."
    return 1
  fi

  tasks_left=$(( target - completed ))
  windows_left="$(remaining_windows_today)"
  if (( windows_left < 1 )); then
    windows_left=1
  fi

  # Use integer probability in basis points to avoid floating point issues.
  threshold=$(( (tasks_left * 10000 + windows_left - 1) / windows_left ))
  if (( threshold > 10000 )); then
    threshold=10000
  fi

  roll=$(( RANDOM % 10000 + 1 ))
  log "Decision context: target=${target}, completed=${completed}, tasks_left=${tasks_left}, windows_left=${windows_left}, threshold=${threshold}, roll=${roll}"

  if (( roll <= threshold )); then
    return 0
  fi
  return 1
}

ensure_maintenance_dir() {
  mkdir -p .github/maintenance
}

task_update_metrics() {
  local file_count gif_count readme_lines total_size_bytes
  file_count="$(find . -type f ! -path './.git/*' | wc -l | tr -d ' ')"
  gif_count="$(find . -maxdepth 1 -type f -name '*.gif' | wc -l | tr -d ' ')"
  readme_lines="$(wc -l < README.md | tr -d ' ')"
  total_size_bytes="$(du -sb . --exclude=.git | awk '{print $1}')"

  cat > "${METRICS_FILE}" <<EOF
{
  "generated_at_utc": "$(date -u +'%Y-%m-%dT%H:%M:%SZ')",
  "file_count": ${file_count},
  "gif_count": ${gif_count},
  "readme_lines": ${readme_lines},
  "repository_size_bytes": ${total_size_bytes}
}
EOF
}

task_refresh_asset_checksums() {
  {
    echo "# Auto-generated asset checksums"
    echo "# Updated: $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    for asset in *.gif; do
      if [[ -f "${asset}" ]]; then
        sha256sum "${asset}"
      fi
    done
  } > "${CHECKSUMS_FILE}"
}

task_append_heartbeat() {
  touch "${HEARTBEAT_FILE}"
  printf '%s run_id=%s ref=%s\n' \
    "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
    "${GITHUB_RUN_ID:-local}" \
    "${GITHUB_REF_NAME:-unknown}" >> "${HEARTBEAT_FILE}"

  # Keep only the most recent 120 entries.
  tail -n 120 "${HEARTBEAT_FILE}" > "${HEARTBEAT_FILE}.tmp"
  mv "${HEARTBEAT_FILE}.tmp" "${HEARTBEAT_FILE}"
}

task_rotate_focus_topic() {
  local -a topics=(
    "README quality audit"
    "Asset integrity verification"
    "Workflow reliability check"
    "Metadata freshness review"
    "Link health monitoring"
    "Automation observability pass"
  )

  local current next i
  current=""
  if [[ -f "${ROTATION_FILE}" ]]; then
    current="$(head -n 1 "${ROTATION_FILE}")"
  fi

  next="${topics[0]}"
  for i in "${!topics[@]}"; do
    if [[ "${topics[$i]}" == "${current}" ]]; then
      next="${topics[$(( (i + 1) % ${#topics[@]} ))]}"
      break
    fi
  done

  printf '%s\n' "${next}" > "${ROTATION_FILE}"
}

task_log_run_history() {
  printf '{"timestamp":"%s","run_id":"%s","branch":"%s","repository":"%s"}\n' \
    "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
    "${GITHUB_RUN_ID:-local}" \
    "${GITHUB_REF_NAME:-unknown}" \
    "${GITHUB_REPOSITORY:-unknown}" >> "${RUN_HISTORY_FILE}"

  tail -n 200 "${RUN_HISTORY_FILE}" > "${RUN_HISTORY_FILE}.tmp"
  mv "${RUN_HISTORY_FILE}.tmp" "${RUN_HISTORY_FILE}"
}

task_link_health_report() {
  local readme_has_http readme_has_svg
  readme_has_http="no"
  readme_has_svg="no"

  if grep -Eq 'https?://' README.md; then
    readme_has_http="yes"
  fi
  if grep -Eq '<img|!\[' README.md; then
    readme_has_svg="yes"
  fi

  cat > "${LINK_REPORT_FILE}" <<EOF
# Link Health Report

Generated at: $(date -u +'%Y-%m-%dT%H:%M:%SZ')

- README contains URL references: ${readme_has_http}
- README contains image references: ${readme_has_svg}
EOF
}

choose_task() {
  local -a tasks=(
    "task_update_metrics"
    "task_refresh_asset_checksums"
    "task_append_heartbeat"
    "task_rotate_focus_topic"
    "task_log_run_history"
    "task_link_health_report"
  )

  local index=$(( RANDOM % ${#tasks[@]} ))
  echo "${tasks[$index]}"
}

commit_if_changed() {
  local task_name commit_message
  task_name="$1"

  if git diff --quiet -- .github/maintenance; then
    log "No effective repository changes detected after ${task_name}; nothing to commit."
    return 0
  fi

  git add .github/maintenance

  if git diff --cached --quiet; then
    log "Staged content is empty after ${task_name}; skipping commit."
    return 0
  fi

  commit_message="${MAINTENANCE_PREFIX} ${task_name} [skip ci]"

  local last_subject
  last_subject="$(git log -1 --pretty=%s || true)"
  if [[ "${last_subject}" == "${commit_message}" ]]; then
    log "Last commit already has the same subject; avoiding duplicate commit."
    return 0
  fi

  if [[ "${MAINTENANCE_DRY_RUN:-0}" == "1" ]]; then
    log "MAINTENANCE_DRY_RUN=1 set; skipping commit and push."
    return 0
  fi

  git commit -m "${commit_message}"
  retry 3 git push origin "HEAD:${GITHUB_REF_NAME}"
  log "Committed and pushed maintenance update: ${commit_message}"
}

main() {
  log "Starting daily maintenance workflow."

  if ! should_run_this_window; then
    log "This run is intentionally skipped to distribute maintenance throughout the day."
    exit 0
  fi

  ensure_maintenance_dir

  local selected_task
  selected_task="$(choose_task)"
  log "Selected maintenance task: ${selected_task}"

  retry 3 "${selected_task}"
  commit_if_changed "${selected_task}"

  log "Maintenance workflow completed successfully."
}

main "$@"
