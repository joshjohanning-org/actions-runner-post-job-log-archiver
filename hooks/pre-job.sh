#!/usr/bin/env bash
# =============================================================================
# pre-job.sh - GitHub Actions Runner Pre-Job Hook
# =============================================================================
# This script runs before each workflow job on a self-hosted runner.
# It records the job start time and starts a background "page watcher" that
# copies raw log pages from _diag/pages/ before the runner deletes them.
#
# Why a watcher? The runner writes step stdout/stderr to _diag/pages/*.log
# and DELETES each file immediately after uploading it (deleteSource: true
# in Logging.cs → JobServerQueue.cs). By the time the post-job hook runs,
# every prior step's page files are gone. The watcher captures them in flight.
#
# Set via: ACTIONS_RUNNER_HOOK_JOB_STARTED=/path/to/hooks/pre-job.sh
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Logging helper
# ---------------------------------------------------------------------------
log() {
  echo "[pre-job-hook] $(date -u '+%Y-%m-%dT%H:%M:%SZ') $*"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
log "Pre-job hook activated"
log "Repository : ${GITHUB_REPOSITORY:-unknown}"
log "Workflow   : ${GITHUB_WORKFLOW:-unknown}"
log "Job        : ${GITHUB_JOB:-unknown}"
log "Run ID     : ${GITHUB_RUN_ID:-unknown}"
log "Runner     : ${RUNNER_NAME:-unknown}"

# Record job start time so the post-job hook can compute duration
RUNNER_TEMP_DIR="${RUNNER_TEMP:-.}"
START_TIME_FILE="${RUNNER_TEMP_DIR}/.job_start_time"
date -u '+%Y-%m-%dT%H:%M:%SZ' > "${START_TIME_FILE}"
log "Recorded job start time to ${START_TIME_FILE}"

# ---------------------------------------------------------------------------
# Resolve the runner root and _diag/pages/ directory
# ---------------------------------------------------------------------------
RUNNER_ROOT=""
if [[ -n "${RUNNER_TEMP_DIR}" ]]; then
  CANDIDATE="$(cd "${RUNNER_TEMP_DIR}/../.." 2>/dev/null && pwd)"
  if [[ -d "${CANDIDATE}/_diag/pages" ]]; then
    RUNNER_ROOT="${CANDIDATE}"
  fi
fi
if [[ -z "${RUNNER_ROOT}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  CANDIDATE="$(cd "${SCRIPT_DIR}/.." 2>/dev/null && pwd)"
  if [[ -d "${CANDIDATE}/_diag/pages" ]]; then
    RUNNER_ROOT="${CANDIDATE}"
  fi
fi

PAGES_DIR="${RUNNER_ROOT:+${RUNNER_ROOT}/_diag/pages}"

# ---------------------------------------------------------------------------
# Start the page watcher background process
# ---------------------------------------------------------------------------
# The watcher polls _diag/pages/ and copies any .log files to a staging
# directory before the runner deletes them after upload. It writes its PID
# to a file so the post-job hook can stop it.
# ---------------------------------------------------------------------------
STAGING_DIR="${RUNNER_TEMP_DIR}/.log_pages_staging"
WATCHER_PID_FILE="${RUNNER_TEMP_DIR}/.page_watcher.pid"

if [[ -n "${PAGES_DIR}" && -d "${PAGES_DIR}" ]]; then
  mkdir -p "${STAGING_DIR}"

  # Clean up any leftover staging from a prior job
  rm -f "${STAGING_DIR}"/*.log 2>/dev/null || true

  # The watcher script: poll every 250ms, copy new non-empty .log files
  (
    while true; do
      for f in "${PAGES_DIR}"/*.log; do
        [[ -f "$f" ]] || continue
        BASENAME="$(basename "$f")"
        # Only copy if file has content and we haven't already copied this version
        # Use file size as a simple change detector
        if [[ -s "$f" ]]; then
          CURRENT_SIZE=$(stat -f '%z' "$f" 2>/dev/null || stat -c '%s' "$f" 2>/dev/null || echo 0)
          STAGED="${STAGING_DIR}/${BASENAME}"
          if [[ -f "${STAGED}" ]]; then
            STAGED_SIZE=$(stat -f '%z' "${STAGED}" 2>/dev/null || stat -c '%s' "${STAGED}" 2>/dev/null || echo 0)
          else
            STAGED_SIZE=0
          fi
          # Copy if new or grown
          if [[ "${CURRENT_SIZE}" -gt "${STAGED_SIZE}" ]]; then
            cp -f "$f" "${STAGED}" 2>/dev/null || true
          fi
        fi
      done
      sleep 0.25
    done
  ) &
  WATCHER_PID=$!
  echo "${WATCHER_PID}" > "${WATCHER_PID_FILE}"
  log "Started page watcher (PID ${WATCHER_PID}), staging to ${STAGING_DIR}"
else
  log "WARNING: Could not locate _diag/pages/ - page watcher not started"
fi

log "Pre-job hook complete"
