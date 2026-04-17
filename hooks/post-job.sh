#!/usr/bin/env bash
# =============================================================================
# post-job.sh - GitHub Actions Runner Post-Job Hook (Log Archiver)
# =============================================================================
# This script runs after each workflow job on a self-hosted runner, BEFORE the
# runner cleans up temporary files. It captures the raw runtime logs from
# _diag/pages/ (the same content shown in "View raw logs" in the GitHub UI)
# and archives them locally.
#
# Key discovery: The runner writes step stdout/stderr to _diag/pages/*.log
# (NOT _temp). These are the actual "View raw logs" files. They are uploaded
# to GitHub as log "pages" and may be cleaned up between jobs.
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
JOB_START_EPOCH=0
if [[ -f "${START_TIME_FILE}" ]]; then
  JOB_START="$(cat "${START_TIME_FILE}")"
  JOB_END="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  if command -v date &>/dev/null; then
    if date --version &>/dev/null 2>&1; then
      # GNU date
      JOB_START_EPOCH=$(date -d "${JOB_START}" '+%s' 2>/dev/null || echo 0)
      END_EPOCH=$(date -d "${JOB_END}" '+%s' 2>/dev/null || echo 0)
    else
      # BSD/macOS date
      JOB_START_EPOCH=$(date -j -f '%Y-%m-%dT%H:%M:%SZ' "${JOB_START}" '+%s' 2>/dev/null || echo 0)
      END_EPOCH=$(date -j -f '%Y-%m-%dT%H:%M:%SZ' "${JOB_END}" '+%s' 2>/dev/null || echo 0)
    fi
    if [[ ${JOB_START_EPOCH} -gt 0 && ${END_EPOCH} -gt 0 ]]; then
      JOB_DURATION="$(( END_EPOCH - JOB_START_EPOCH ))s"
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
# Resolve the runner root and _diag/pages/ directory
# ---------------------------------------------------------------------------
# The runner root is typically the parent of _work. We can derive it from
# RUNNER_TEMP (which is _work/_temp) by going up two levels, or from
# AGENT_TOOLSDIRECTORY, or by looking for _diag relative to the script.
RUNNER_ROOT=""

# Strategy 1: derive from RUNNER_TEMP (_work/_temp -> runner root is ../..)
if [[ -n "${RUNNER_TEMP_DIR}" ]]; then
  CANDIDATE="$(cd "${RUNNER_TEMP_DIR}/../.." 2>/dev/null && pwd)"
  if [[ -d "${CANDIDATE}/_diag/pages" ]]; then
    RUNNER_ROOT="${CANDIDATE}"
  fi
fi

# Strategy 2: script is in <runner_root>/hooks/
if [[ -z "${RUNNER_ROOT}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  CANDIDATE="$(cd "${SCRIPT_DIR}/.." 2>/dev/null && pwd)"
  if [[ -d "${CANDIDATE}/_diag/pages" ]]; then
    RUNNER_ROOT="${CANDIDATE}"
  fi
fi

# Strategy 3: check common locations
if [[ -z "${RUNNER_ROOT}" ]]; then
  for CANDIDATE in "/home/runner/actions-runner" "/opt/actions-runner" "/actions-runner"; do
    if [[ -d "${CANDIDATE}/_diag/pages" ]]; then
      RUNNER_ROOT="${CANDIDATE}"
      break
    fi
  done
fi

PAGES_DIR="${RUNNER_ROOT:+${RUNNER_ROOT}/_diag/pages}"
DIAG_DIR="${RUNNER_ROOT:+${RUNNER_ROOT}/_diag}"

# ---------------------------------------------------------------------------
# PRIMARY: Copy raw runtime logs from _diag/pages/
# ---------------------------------------------------------------------------
# The runner writes step stdout/stderr output to _diag/pages/ as log "page"
# files. These are the EXACT content of "View raw logs" in the GitHub UI.
# File naming: {timelineId}_{recordId}_{pageNumber}.log
#
# We identify which files belong to THIS job by comparing modification times
# against the pre-job start time recorded by pre-job.sh. Files modified after
# the job started belong to the current job.
# ---------------------------------------------------------------------------
PAGES_LOG_COUNT=0

if [[ -n "${PAGES_DIR}" && -d "${PAGES_DIR}" ]]; then
  log "Scanning for runtime log pages in ${PAGES_DIR} ..."

  mkdir -p "${ARCHIVE_PATH}/raw_logs"

  while IFS= read -r -d '' pagefile; do
    # Filter by modification time if we have a start epoch
    if [[ ${JOB_START_EPOCH} -gt 0 ]]; then
      if date --version &>/dev/null 2>&1; then
        FILE_EPOCH=$(stat -c '%Y' "${pagefile}" 2>/dev/null || echo 0)
      else
        FILE_EPOCH=$(stat -f '%m' "${pagefile}" 2>/dev/null || echo 0)
      fi
      # Allow a 5-second grace period before the recorded start time
      if [[ ${FILE_EPOCH} -lt $((JOB_START_EPOCH - 5)) ]]; then
        continue
      fi
    fi

    BASENAME="$(basename "${pagefile}")"
    # Only copy non-empty files
    if [[ -s "${pagefile}" ]]; then
      cp -a "${pagefile}" "${ARCHIVE_PATH}/raw_logs/${BASENAME}" 2>/dev/null \
        && PAGES_LOG_COUNT=$((PAGES_LOG_COUNT + 1))
    fi
  done < <(find "${PAGES_DIR}" -type f -name '*.log' -print0 2>/dev/null)

  log "Copied ${PAGES_LOG_COUNT} runtime log page(s) from _diag/pages/"

  # Also create a single combined raw log file, sorted by timestamp
  if [[ ${PAGES_LOG_COUNT} -gt 0 ]]; then
    sort "${ARCHIVE_PATH}/raw_logs/"*.log > "${ARCHIVE_PATH}/combined_raw_log.log" 2>/dev/null \
      && log "Created combined_raw_log.log" \
      || warn "Failed to create combined log"
  fi
else
  warn "Could not locate _diag/pages/ directory (RUNNER_ROOT=${RUNNER_ROOT:-not found})"
fi

# ---------------------------------------------------------------------------
# SECONDARY: Copy step scripts and metadata from RUNNER_TEMP
# ---------------------------------------------------------------------------
TEMP_LOG_COUNT=0

if [[ -n "${RUNNER_TEMP_DIR}" && -d "${RUNNER_TEMP_DIR}" ]]; then
  log "Scanning for step scripts in ${RUNNER_TEMP_DIR} ..."

  while IFS= read -r -d '' logfile; do
    REL_PATH="${logfile#"${RUNNER_TEMP_DIR}"/}"
    DEST_DIR="${ARCHIVE_PATH}/runner_temp/$(dirname "${REL_PATH}")"
    mkdir -p "${DEST_DIR}"
    cp -a "${logfile}" "${DEST_DIR}/" 2>/dev/null && TEMP_LOG_COUNT=$((TEMP_LOG_COUNT + 1))
  done < <(find "${RUNNER_TEMP_DIR}" -type f \( -name '*.txt' -o -name '*.log' -o -name '*.json' -o -name '*.cmd' -o -name '*.sh' \) -print0 2>/dev/null)

  log "Copied ${TEMP_LOG_COUNT} file(s) from runner temp directory"
fi

# ---------------------------------------------------------------------------
# TERTIARY: Copy Worker diagnostic log for this job
# ---------------------------------------------------------------------------
WORKER_LOG_COUNT=0
if [[ -n "${DIAG_DIR}" && -d "${DIAG_DIR}" ]]; then
  # The Worker log for the current job is the most recently modified one
  LATEST_WORKER_LOG="$(ls -t "${DIAG_DIR}"/Worker_*.log 2>/dev/null | head -1)"
  if [[ -n "${LATEST_WORKER_LOG}" && -f "${LATEST_WORKER_LOG}" ]]; then
    cp -a "${LATEST_WORKER_LOG}" "${ARCHIVE_PATH}/" 2>/dev/null \
      && WORKER_LOG_COUNT=1 \
      && log "Copied worker diagnostic log: $(basename "${LATEST_WORKER_LOG}")"
  fi
fi

TOTAL_COUNT=$((PAGES_LOG_COUNT + TEMP_LOG_COUNT + WORKER_LOG_COUNT))

# ---------------------------------------------------------------------------
# API fallback: download logs via GitHub API if no local files found
# ---------------------------------------------------------------------------
if [[ ${TOTAL_COUNT} -eq 0 && "${LOG_ARCHIVE_USE_API_FALLBACK}" == "true" ]]; then
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
  "runner_root": "${RUNNER_ROOT:-not found}",
  "pages_dir": "${PAGES_DIR:-not found}",
  "raw_log_pages_copied": ${PAGES_LOG_COUNT},
  "temp_files_copied": ${TEMP_LOG_COUNT},
  "worker_log_copied": ${WORKER_LOG_COUNT},
  "total_files_copied": ${TOTAL_COUNT},
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
log "Post-job hook complete. Archived ${TOTAL_COUNT} file(s) to ${ARCHIVE_PATH}"
log "  Raw log pages: ${PAGES_LOG_COUNT}, Temp files: ${TEMP_LOG_COUNT}, Worker logs: ${WORKER_LOG_COUNT}"
