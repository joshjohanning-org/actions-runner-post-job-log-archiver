#!/usr/bin/env bash
# =============================================================================
# post-job.sh - GitHub Actions Runner Post-Job Hook (Log Archiver)
# =============================================================================
# This script runs after each workflow job on a self-hosted runner, BEFORE the
# runner cleans up temporary files. It archives the step execution logs that
# the runner writes to $RUNNER_TEMP so they are preserved locally.
#
# Set via: ACTIONS_RUNNER_HOOK_JOB_COMPLETED=/path/to/hooks/post-job.sh
#
# Configuration (environment variables):
#   LOG_ARCHIVE_DIR             - Base directory for archived logs
#                                 Default: /var/log/actions-runner-logs
#   LOG_ARCHIVE_USE_API_FALLBACK - Fall back to GitHub API if no local logs
#                                 Default: true
#   LOG_ARCHIVE_RETENTION_DAYS  - Delete archives older than N days (0=disable)
#                                 Default: 90
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
LOG_ARCHIVE_DIR="${LOG_ARCHIVE_DIR:-/var/log/actions-runner-logs}"
LOG_ARCHIVE_USE_API_FALLBACK="${LOG_ARCHIVE_USE_API_FALLBACK:-true}"
LOG_ARCHIVE_RETENTION_DAYS="${LOG_ARCHIVE_RETENTION_DAYS:-90}"

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
log()  { echo "[post-job-hook] $(date -u '+%Y-%m-%dT%H:%M:%SZ') $*"; }
warn() { echo "[post-job-hook] $(date -u '+%Y-%m-%dT%H:%M:%SZ') WARNING: $*" >&2; }
err()  { echo "[post-job-hook] $(date -u '+%Y-%m-%dT%H:%M:%SZ') ERROR: $*" >&2; }

# ---------------------------------------------------------------------------
# Error trap - ensure we always log failures but never block the runner
# ---------------------------------------------------------------------------
cleanup() {
  local exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    err "Post-job hook exited with code ${exit_code}. The runner will continue normally."
  fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Gather context from runner-injected environment variables
# ---------------------------------------------------------------------------
REPO="${GITHUB_REPOSITORY:-unknown/unknown}"
REPO_NAME="${REPO##*/}"
RUN_ID="${GITHUB_RUN_ID:-0}"
RUN_NUMBER="${GITHUB_RUN_NUMBER:-0}"
RUN_ATTEMPT="${GITHUB_RUN_ATTEMPT:-1}"
WORKFLOW="${GITHUB_WORKFLOW:-unknown}"
JOB_NAME="${GITHUB_JOB:-unknown}"
ACTOR="${GITHUB_ACTOR:-unknown}"
REF="${GITHUB_REF:-unknown}"
SHA="${GITHUB_SHA:-unknown}"
EVENT="${GITHUB_EVENT_NAME:-unknown}"
RUNNER_NAME_VAL="${RUNNER_NAME:-unknown}"
RUNNER_OS_VAL="${RUNNER_OS:-unknown}"
RUNNER_TEMP_DIR="${RUNNER_TEMP:-}"
GITHUB_API_URL_VAL="${GITHUB_API_URL:-https://api.github.com}"
GITHUB_SERVER="${GITHUB_SERVER_URL:-https://github.com}"

# Sanitize the job name for use as a directory name
SAFE_JOB_NAME="$(echo "${JOB_NAME}" | sed 's/[^a-zA-Z0-9._-]/_/g')"

log "Post-job hook activated"
log "Repository : ${REPO}"
log "Workflow   : ${WORKFLOW}"
log "Job        : ${JOB_NAME}"
log "Run ID     : ${RUN_ID} (attempt ${RUN_ATTEMPT})"
log "Runner     : ${RUNNER_NAME_VAL} (${RUNNER_OS_VAL})"

# ---------------------------------------------------------------------------
# Compute job duration if pre-job hook recorded a start time
# ---------------------------------------------------------------------------
JOB_DURATION="unknown"
START_TIME_FILE="${RUNNER_TEMP_DIR:-.}/.job_start_time"
if [[ -f "${START_TIME_FILE}" ]]; then
  JOB_START="$(cat "${START_TIME_FILE}")"
  JOB_END="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  if command -v date &>/dev/null; then
    if date --version &>/dev/null 2>&1; then
      # GNU date
      START_EPOCH=$(date -d "${JOB_START}" '+%s' 2>/dev/null || echo 0)
      END_EPOCH=$(date -d "${JOB_END}" '+%s' 2>/dev/null || echo 0)
    else
      # BSD/macOS date
      START_EPOCH=$(date -j -f '%Y-%m-%dT%H:%M:%SZ' "${JOB_START}" '+%s' 2>/dev/null || echo 0)
      END_EPOCH=$(date -j -f '%Y-%m-%dT%H:%M:%SZ' "${JOB_END}" '+%s' 2>/dev/null || echo 0)
    fi
    if [[ ${START_EPOCH} -gt 0 && ${END_EPOCH} -gt 0 ]]; then
      JOB_DURATION="$(( END_EPOCH - START_EPOCH ))s"
    fi
  fi
else
  JOB_START="unknown"
  JOB_END="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  warn "No start-time file found at ${START_TIME_FILE}. Is pre-job.sh configured?"
fi

# ---------------------------------------------------------------------------
# Create the archive directory
# ---------------------------------------------------------------------------
ARCHIVE_PATH="${LOG_ARCHIVE_DIR}/${REPO}/${RUN_ID}_attempt${RUN_ATTEMPT}/${SAFE_JOB_NAME}"
if ! mkdir -p "${ARCHIVE_PATH}"; then
  err "Failed to create archive directory: ${ARCHIVE_PATH}"
  exit 1
fi
log "Archive directory: ${ARCHIVE_PATH}"

# ---------------------------------------------------------------------------
# Copy local log files from RUNNER_TEMP
# ---------------------------------------------------------------------------
LOCAL_LOG_COUNT=0

if [[ -n "${RUNNER_TEMP_DIR}" && -d "${RUNNER_TEMP_DIR}" ]]; then
  log "Scanning for log files in ${RUNNER_TEMP_DIR} ..."

  # The runner stores step logs as files like:
  #   _runner_file_commands/  (set-output, etc.)
  #   _github_workflow/       (composite action internals)
  #   *.txt files             (step execution logs)
  # We copy everything interesting.

  while IFS= read -r -d '' logfile; do
    REL_PATH="${logfile#"${RUNNER_TEMP_DIR}"/}"
    DEST_DIR="${ARCHIVE_PATH}/runner_temp/$(dirname "${REL_PATH}")"
    mkdir -p "${DEST_DIR}"
    cp -a "${logfile}" "${DEST_DIR}/" 2>/dev/null && LOCAL_LOG_COUNT=$((LOCAL_LOG_COUNT + 1))
  done < <(find "${RUNNER_TEMP_DIR}" -type f \( -name '*.txt' -o -name '*.log' -o -name '*.json' -o -name '*.cmd' -o -name '*.sh' \) -print0 2>/dev/null)

  log "Copied ${LOCAL_LOG_COUNT} file(s) from runner temp directory"
else
  warn "RUNNER_TEMP is not set or directory does not exist"
fi

# ---------------------------------------------------------------------------
# API fallback: download logs via GitHub API if no local files found
# ---------------------------------------------------------------------------
if [[ ${LOCAL_LOG_COUNT} -eq 0 && "${LOG_ARCHIVE_USE_API_FALLBACK}" == "true" ]]; then
  log "No local log files found. Attempting API fallback ..."

  API_LOG_ZIP="${ARCHIVE_PATH}/run_logs.zip"
  API_ENDPOINT="${GITHUB_API_URL_VAL}/repos/${REPO}/actions/runs/${RUN_ID}/attempts/${RUN_ATTEMPT}/logs"
  DOWNLOADED=false

  # Try using the GitHub CLI first (uses built-in auth)
  if command -v gh &>/dev/null; then
    log "Downloading logs via 'gh api' ..."
    if gh api "repos/${REPO}/actions/runs/${RUN_ID}/attempts/${RUN_ATTEMPT}/logs" > "${API_LOG_ZIP}" 2>/dev/null; then
      DOWNLOADED=true
      log "Downloaded run logs via GitHub CLI"
    else
      warn "gh api download failed; trying curl ..."
    fi
  fi

  # Fall back to curl with ACTIONS_RUNTIME_TOKEN or GITHUB_TOKEN
  if [[ "${DOWNLOADED}" != "true" ]]; then
    TOKEN="${ACTIONS_RUNTIME_TOKEN:-${GITHUB_TOKEN:-}}"
    if [[ -n "${TOKEN}" ]]; then
      log "Downloading logs via curl ..."
      HTTP_CODE=$(curl -sS -w '%{http_code}' -o "${API_LOG_ZIP}" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        -L "${API_ENDPOINT}" 2>/dev/null || echo "000")

      if [[ "${HTTP_CODE}" == "200" ]]; then
        DOWNLOADED=true
        log "Downloaded run logs via curl (HTTP ${HTTP_CODE})"
      else
        warn "curl download failed with HTTP ${HTTP_CODE}"
        rm -f "${API_LOG_ZIP}"
      fi
    else
      warn "No authentication token available for API fallback"
    fi
  fi

  # Unzip if we got the archive
  if [[ "${DOWNLOADED}" == "true" && -f "${API_LOG_ZIP}" ]]; then
    if command -v unzip &>/dev/null; then
      unzip -qo "${API_LOG_ZIP}" -d "${ARCHIVE_PATH}/api_logs/" 2>/dev/null || warn "Failed to unzip API logs"
      rm -f "${API_LOG_ZIP}"
      log "Extracted API logs to ${ARCHIVE_PATH}/api_logs/"
    else
      log "unzip not available; keeping raw zip at ${API_LOG_ZIP}"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Write metadata.json
# ---------------------------------------------------------------------------
METADATA_FILE="${ARCHIVE_PATH}/metadata.json"
cat > "${METADATA_FILE}" <<METADATA_EOF
{
  "repository": "${REPO}",
  "repository_name": "${REPO_NAME}",
  "workflow": "${WORKFLOW}",
  "job_name": "${JOB_NAME}",
  "run_id": ${RUN_ID},
  "run_number": ${RUN_NUMBER},
  "run_attempt": ${RUN_ATTEMPT},
  "actor": "${ACTOR}",
  "ref": "${REF}",
  "sha": "${SHA}",
  "event": "${EVENT}",
  "runner_name": "${RUNNER_NAME_VAL}",
  "runner_os": "${RUNNER_OS_VAL}",
  "job_started_at": "${JOB_START}",
  "job_completed_at": "${JOB_END}",
  "job_duration": "${JOB_DURATION}",
  "local_log_files_copied": ${LOCAL_LOG_COUNT},
  "archive_path": "${ARCHIVE_PATH}",
  "server_url": "${GITHUB_SERVER}",
  "run_url": "${GITHUB_SERVER}/${REPO}/actions/runs/${RUN_ID}/attempts/${RUN_ATTEMPT}",
  "archived_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}
METADATA_EOF
log "Wrote metadata to ${METADATA_FILE}"

# ---------------------------------------------------------------------------
# Retention: clean up old archives
# ---------------------------------------------------------------------------
if [[ "${LOG_ARCHIVE_RETENTION_DAYS}" -gt 0 ]]; then
  log "Cleaning up archives older than ${LOG_ARCHIVE_RETENTION_DAYS} days ..."
  DELETED_COUNT=0

  while IFS= read -r -d '' old_dir; do
    rm -rf "${old_dir}"
    DELETED_COUNT=$((DELETED_COUNT + 1))
  done < <(find "${LOG_ARCHIVE_DIR}" -mindepth 3 -maxdepth 3 -type d -mtime "+${LOG_ARCHIVE_RETENTION_DAYS}" -print0 2>/dev/null)

  if [[ ${DELETED_COUNT} -gt 0 ]]; then
    log "Deleted ${DELETED_COUNT} archive(s) older than ${LOG_ARCHIVE_RETENTION_DAYS} days"
  fi

  # Remove empty parent directories left behind
  find "${LOG_ARCHIVE_DIR}" -mindepth 1 -type d -empty -delete 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
log "Post-job hook complete. Archived ${LOCAL_LOG_COUNT} local log file(s) to ${ARCHIVE_PATH}"
