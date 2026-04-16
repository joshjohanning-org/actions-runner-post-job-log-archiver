#!/usr/bin/env bash
# =============================================================================
# pre-job.sh - GitHub Actions Runner Pre-Job Hook
# =============================================================================
# This script runs before each workflow job on a self-hosted runner.
# It records the job start time so the post-job hook can calculate duration,
# and logs that the hook system is active.
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
START_TIME_FILE="${RUNNER_TEMP:-.}/.job_start_time"
date -u '+%Y-%m-%dT%H:%M:%SZ' > "${START_TIME_FILE}"
log "Recorded job start time to ${START_TIME_FILE}"

log "Pre-job hook complete"
