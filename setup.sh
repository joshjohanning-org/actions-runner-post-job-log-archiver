#!/usr/bin/env bash
# =============================================================================
# setup.sh - Install the post-job log archiver hooks on a self-hosted runner
# =============================================================================
# Usage:
#   sudo ./setup.sh /path/to/actions-runner
#
# This script:
#   1. Copies the hook scripts to the runner directory
#   2. Adds the hook environment variables to the runner's .env file
#   3. Creates the log archive directory
#   4. Shows how to restart the runner service
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
DEFAULT_ARCHIVE_DIR="/var/log/actions-runner-logs"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
if [[ $# -lt 1 ]]; then
  echo "Usage: sudo $0 <runner-directory> [archive-directory]"
  echo ""
  echo "Arguments:"
  echo "  runner-directory   Path to the GitHub Actions runner installation"
  echo "                     (e.g., /opt/actions-runner or ~/actions-runner)"
  echo "  archive-directory  Where to store archived logs (optional)"
  echo "                     Default: ${DEFAULT_ARCHIVE_DIR}"
  exit 1
fi

RUNNER_DIR="$(cd "$1" && pwd)"
ARCHIVE_DIR="${2:-${DEFAULT_ARCHIVE_DIR}}"

# ---------------------------------------------------------------------------
# Validate runner directory
# ---------------------------------------------------------------------------
if [[ ! -f "${RUNNER_DIR}/run.sh" ]]; then
  error "'${RUNNER_DIR}' does not look like a GitHub Actions runner directory."
  error "Expected to find run.sh in the runner directory."
  exit 1
fi

info "Runner directory : ${RUNNER_DIR}"
info "Archive directory: ${ARCHIVE_DIR}"
info "Hook source      : ${SCRIPT_DIR}/hooks/"
echo ""

# ---------------------------------------------------------------------------
# Step 1: Copy hook scripts
# ---------------------------------------------------------------------------
info "Step 1: Copying hook scripts ..."

HOOKS_DEST="${RUNNER_DIR}/hooks"
mkdir -p "${HOOKS_DEST}"
cp -v "${SCRIPT_DIR}/hooks/pre-job.sh"  "${HOOKS_DEST}/pre-job.sh"
cp -v "${SCRIPT_DIR}/hooks/post-job.sh" "${HOOKS_DEST}/post-job.sh"
chmod +x "${HOOKS_DEST}/pre-job.sh"
chmod +x "${HOOKS_DEST}/post-job.sh"

info "Hook scripts installed to ${HOOKS_DEST}"
echo ""

# ---------------------------------------------------------------------------
# Step 2: Configure the runner's .env file
# ---------------------------------------------------------------------------
info "Step 2: Configuring runner environment ..."

ENV_FILE="${RUNNER_DIR}/.env"

# Create .env if it doesn't exist
touch "${ENV_FILE}"

# Helper to add or update a variable in the .env file
add_env_var() {
  local key="$1"
  local value="$2"

  if grep -q "^${key}=" "${ENV_FILE}" 2>/dev/null; then
    warn "${key} already set in ${ENV_FILE} - updating"
    sed -i.bak "s|^${key}=.*|${key}=${value}|" "${ENV_FILE}"
    rm -f "${ENV_FILE}.bak"
  else
    echo "${key}=${value}" >> "${ENV_FILE}"
  fi
  info "  ${key}=${value}"
}

add_env_var "ACTIONS_RUNNER_HOOK_JOB_STARTED"   "${HOOKS_DEST}/pre-job.sh"
add_env_var "ACTIONS_RUNNER_HOOK_JOB_COMPLETED" "${HOOKS_DEST}/post-job.sh"
add_env_var "LOG_ARCHIVE_DIR"                   "${ARCHIVE_DIR}"

echo ""

# ---------------------------------------------------------------------------
# Step 3: Create the archive directory
# ---------------------------------------------------------------------------
info "Step 3: Creating archive directory ..."

mkdir -p "${ARCHIVE_DIR}"

# Try to determine the runner service user
RUNNER_USER=""
SVC_FILE="${RUNNER_DIR}/.service"
if [[ -f "${SVC_FILE}" ]]; then
  SVC_NAME="$(cat "${SVC_FILE}")"
  if command -v systemctl &>/dev/null; then
    RUNNER_USER=$(systemctl show "${SVC_NAME}" -p User --value 2>/dev/null || true)
  fi
fi

# Fall back to directory owner
if [[ -z "${RUNNER_USER}" ]]; then
  RUNNER_USER=$(stat -c '%U' "${RUNNER_DIR}" 2>/dev/null || stat -f '%Su' "${RUNNER_DIR}" 2>/dev/null || echo "")
fi

if [[ -n "${RUNNER_USER}" ]]; then
  chown -R "${RUNNER_USER}" "${ARCHIVE_DIR}" 2>/dev/null || warn "Could not chown archive directory to ${RUNNER_USER}"
  info "Archive directory owned by: ${RUNNER_USER}"
fi

chmod 755 "${ARCHIVE_DIR}"
info "Archive directory created: ${ARCHIVE_DIR}"
echo ""

# ---------------------------------------------------------------------------
# Step 4: Show restart instructions
# ---------------------------------------------------------------------------
info "Step 4: Restart the runner service to apply changes"
echo ""

if [[ -f "${SVC_FILE:-}" ]] && command -v systemctl &>/dev/null; then
  SVC_NAME="$(cat "${RUNNER_DIR}/.service")"
  echo "  sudo systemctl restart ${SVC_NAME}"
  echo ""
  read -rp "Restart the runner service now? [y/N] " REPLY
  if [[ "${REPLY}" =~ ^[Yy]$ ]]; then
    systemctl restart "${SVC_NAME}"
    info "Service '${SVC_NAME}' restarted successfully"
  else
    warn "Remember to restart the runner service manually"
  fi
else
  echo "  If running as a systemd service:"
  echo "    sudo systemctl restart actions.runner.<org>.<runner-name>.service"
  echo ""
  echo "  If running interactively, stop and re-run:"
  echo "    cd ${RUNNER_DIR} && ./run.sh"
fi

echo ""
info "========================================"
info "  Setup complete!"
info "========================================"
info ""
info "Archived logs will be saved to:"
info "  ${ARCHIVE_DIR}/{owner}/{repo}/{run_id}_attempt{N}/{job_name}/"
info ""
info "To customize, set these variables in ${ENV_FILE}:"
info "  LOG_ARCHIVE_DIR=${ARCHIVE_DIR}"
info "  LOG_ARCHIVE_USE_API_FALLBACK=true"
info "  LOG_ARCHIVE_RETENTION_DAYS=90"
