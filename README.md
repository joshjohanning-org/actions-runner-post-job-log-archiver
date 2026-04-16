# Actions Runner Post-Job Log Archiver

Archive GitHub Actions workflow job logs from self-hosted runners using the runner's built-in **post-job hook** mechanism.

## The Problem

When a GitHub Actions job runs on a **self-hosted runner**, the runner writes step execution logs (the same content you see in "View raw logs" on GitHub) to temporary files under `_work/_temp/`. After uploading them to GitHub, the runner **deletes these files**.

This means:

- There is no local copy of workflow logs on the runner machine
- If log retention is reduced or logs are deleted from GitHub, they're gone
- Compliance, auditing, or debugging scenarios may require durable local log storage
- Centralized log aggregation (e.g., Splunk, ELK, Datadog) needs a local source to ship from

## How It Works

The GitHub Actions runner supports **job lifecycle hooks** — scripts that run before and after every job:

| Environment Variable | When It Runs |
|---|---|
| `ACTIONS_RUNNER_HOOK_JOB_STARTED` | Before the job starts |
| `ACTIONS_RUNNER_HOOK_JOB_COMPLETED` | After the job completes, **before cleanup** |

The post-job hook (`ACTIONS_RUNNER_HOOK_JOB_COMPLETED`) fires while the temporary log files still exist on disk, giving us a window to copy them to a persistent location.

This project provides:

1. **`hooks/post-job.sh`** — Copies all log files from `$RUNNER_TEMP` to a structured archive directory, writes a `metadata.json` with job context, and optionally falls back to the GitHub API if no local files are found.
2. **`hooks/pre-job.sh`** — Records the job start time so the post-job hook can compute job duration.
3. **`setup.sh`** — Automated installation script.

> 📖 **Reference:** [Runner Job Hooks ADR (actions/runner#1751)](https://github.com/actions/runner/blob/main/docs/adrs/1751-runner-job-hooks.md)

## Archived Log Structure

```
/var/log/actions-runner-logs/
└── owner/repo-name/
    └── 12345678_attempt1/
        └── build/
            ├── metadata.json
            ├── runner_temp/
            │   ├── step_abc123.txt
            │   ├── step_def456.txt
            │   └── _github_workflow/
            │       └── composite_step.txt
            └── api_logs/          # (only if API fallback was used)
                └── 0_build.txt
```

### `metadata.json`

```json
{
  "repository": "owner/repo-name",
  "workflow": "CI",
  "job_name": "build",
  "run_id": 12345678,
  "run_number": 42,
  "run_attempt": 1,
  "actor": "octocat",
  "ref": "refs/heads/main",
  "sha": "abc123...",
  "event": "push",
  "runner_name": "my-runner",
  "runner_os": "Linux",
  "job_started_at": "2024-01-15T10:30:00Z",
  "job_completed_at": "2024-01-15T10:35:22Z",
  "job_duration": "322s",
  "local_log_files_copied": 5,
  "run_url": "https://github.com/owner/repo-name/actions/runs/12345678/attempts/1",
  "archived_at": "2024-01-15T10:35:23Z"
}
```

## Installation

### Quick Setup (Recommended)

```bash
# Clone this repository on your runner machine
git clone https://github.com/joshjohanning-org/actions-runner-post-job-log-archiver.git
cd actions-runner-post-job-log-archiver

# Run the setup script (provide your runner installation path)
sudo ./setup.sh /opt/actions-runner
```

The setup script will:

1. Copy the hook scripts to your runner's `hooks/` directory
2. Add the required environment variables to the runner's `.env` file
3. Create the archive directory with proper ownership
4. Offer to restart the runner service

### Manual Setup

1. **Copy the hook scripts** to your runner machine:

   ```bash
   cp hooks/pre-job.sh  /opt/actions-runner/hooks/pre-job.sh
   cp hooks/post-job.sh /opt/actions-runner/hooks/post-job.sh
   chmod +x /opt/actions-runner/hooks/*.sh
   ```

2. **Add environment variables** to the runner's `.env` file (`/opt/actions-runner/.env`):

   ```env
   ACTIONS_RUNNER_HOOK_JOB_STARTED=/opt/actions-runner/hooks/pre-job.sh
   ACTIONS_RUNNER_HOOK_JOB_COMPLETED=/opt/actions-runner/hooks/post-job.sh
   LOG_ARCHIVE_DIR=/var/log/actions-runner-logs
   ```

3. **Create the archive directory:**

   ```bash
   sudo mkdir -p /var/log/actions-runner-logs
   sudo chown <runner-user> /var/log/actions-runner-logs
   ```

4. **Restart the runner service:**

   ```bash
   sudo systemctl restart actions.runner.<org>.<name>.service
   ```

## Configuration

All configuration is done through environment variables in the runner's `.env` file:

| Variable | Default | Description |
|---|---|---|
| `LOG_ARCHIVE_DIR` | `/var/log/actions-runner-logs` | Base directory for archived logs |
| `LOG_ARCHIVE_USE_API_FALLBACK` | `true` | If no local log files are found in `$RUNNER_TEMP`, attempt to download them via the GitHub API |
| `LOG_ARCHIVE_RETENTION_DAYS` | `90` | Automatically delete archived logs older than this many days. Set to `0` to disable cleanup |

### API Fallback

If the post-job hook finds no log files in `$RUNNER_TEMP` (which can happen in edge cases), it can fall back to downloading the logs through the GitHub API. This uses:

1. **`gh` CLI** (preferred) — uses the runner's existing GitHub CLI authentication
2. **`curl`** with `ACTIONS_RUNTIME_TOKEN` or `GITHUB_TOKEN` — direct API call

The API returns a zip archive of the run's logs, which is extracted into an `api_logs/` subdirectory.

## Testing

A sample workflow is included at `.github/workflows/test-hook.yml`. It runs on a `self-hosted` runner and produces multi-line output to verify log capture.

Trigger it manually:

```bash
gh workflow run test-hook.yml
```

Then check the archive directory on your runner:

```bash
ls -la /var/log/actions-runner-logs/
cat /var/log/actions-runner-logs/<owner>/<repo>/<run_id>_attempt1/<job>/metadata.json
```

## Integration with Log Aggregation

Once logs are archived locally, you can ship them to centralized logging systems:

- **Filebeat / Logstash:** Point at the archive directory, use the `metadata.json` for structured fields
- **Fluentd / Fluent Bit:** Use the `tail` input plugin on the archive directory
- **Splunk Universal Forwarder:** Monitor the archive directory
- **Datadog Agent:** Use the file log collection
- **AWS CloudWatch / S3:** Use a cron job or the CloudWatch agent to upload archives

## Alternative Approaches

The post-job hook approach captures logs **at the source** on the runner machine. An alternative approach is:

### Webhook + API Approach

1. Configure a **repository or organization webhook** for the `workflow_job` event
2. When a job completes, the webhook fires with the `run_id`
3. A server-side handler calls the [Download workflow run logs](https://docs.github.com/en/rest/actions/workflow-runs#download-workflow-run-logs) API endpoint
4. Store the downloaded zip archive

**Trade-offs:**

| | Post-Job Hook (this project) | Webhook + API |
|---|---|---|
| **Where it runs** | On the runner machine | On a separate server |
| **Network dependency** | None (local file copy) | Requires API access |
| **Log availability** | Immediate (before cleanup) | After upload to GitHub |
| **Setup complexity** | Per-runner `.env` change | Webhook endpoint + server |
| **GHES / GHEC support** | ✅ Works everywhere | ✅ Works everywhere |
| **Captures raw temp files** | ✅ Yes | ❌ Only uploaded logs |

## Troubleshooting

### Hooks are not running

- Verify the `.env` file contains the `ACTIONS_RUNNER_HOOK_JOB_*` variables
- Restart the runner service after editing `.env`
- Check that the hook scripts are executable: `chmod +x hooks/*.sh`
- The runner must be version **2.300.0+** for hook support

### No log files found in `RUNNER_TEMP`

- This can happen if the job failed very early (e.g., during checkout)
- Enable `LOG_ARCHIVE_USE_API_FALLBACK=true` to download logs via the API
- Check runner diagnostics: `_diag/` folder in the runner directory

### Permission denied on archive directory

- Ensure the runner service user owns the archive directory
- Check: `ls -la /var/log/actions-runner-logs/`
- Fix: `sudo chown -R <runner-user> /var/log/actions-runner-logs/`

### Archive directory growing too large

- Set `LOG_ARCHIVE_RETENTION_DAYS` to automatically clean up old archives
- Monitor disk usage: `du -sh /var/log/actions-runner-logs/`
- Consider shipping logs to external storage and reducing retention

### Hook script errors

- The post-job hook uses `set -euo pipefail` with an error `trap`
- Errors are logged but **will not block** the runner from proceeding
- Check the runner's Worker stdout/stderr for hook output
- Runner diagnostic logs in `_diag/Worker_*.log` will show hook execution

## Requirements

- GitHub Actions Runner **v2.300.0** or later
- Bash 4.0+ (available on all supported runner OS versions)
- `find`, `cp`, `mkdir`, `date` (standard Unix utilities)
- Optional: `gh` CLI or `curl` (for API fallback)
- Optional: `unzip` (for extracting API-downloaded log archives)

## License

MIT