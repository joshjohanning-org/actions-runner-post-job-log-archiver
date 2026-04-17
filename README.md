# Actions Runner Post-Job Log Archiver

Archive GitHub Actions workflow job logs from self-hosted runners **before the runner deletes them**. Uses the runner's built-in job lifecycle hooks with a background file watcher to capture the raw step-execution logs — the exact content you see in "View raw logs" in the GitHub UI.

## The Problem

When a GitHub Actions job runs on a **self-hosted runner**, the runner writes each step's stdout/stderr to temporary log files in `_diag/pages/`. After uploading each step's log to GitHub, the runner **immediately deletes** the local file. By the time the job finishes, every step's log file is already gone from disk.

This means:

- There is **no local copy** of workflow logs on the runner machine after a job completes
- If GitHub log retention expires or logs are deleted, they are **permanently gone**
- Compliance, auditing, or debugging scenarios that require durable local log storage have no source
- Centralized log aggregation (Splunk, ELK, Datadog, etc.) has nothing to ship

> **Common misconception:** Logs are NOT in `_work/_temp/` (`$RUNNER_TEMP`). That directory only contains step shell scripts and `event.json`. The actual "View raw logs" content lives in `_diag/pages/`.

## How It Works

### The Challenge

A simple post-job hook cannot read the logs because they are already deleted. Here's why:

The runner writes each step's output to `_diag/pages/{timelineId}_{recordId}_{page}.log`. As soon as the step completes and the log page is uploaded to GitHub, the runner calls `File.Delete()` on the source file ([`Logging.cs` line 142](https://github.com/actions/runner/blob/main/src/Runner.Common/Logging.cs) passes `deleteSource: true` → [`JobServerQueue.cs` lines 911–915](https://github.com/actions/runner/blob/main/src/Runner.Common/JobServerQueue.cs) deletes the file). This happens **per-step**, not per-job — so by the time a post-job hook runs, all prior steps' page files are gone.

### The Solution: Two-Hook Architecture

This project uses **two runner hooks** working together:

```
┌─────────────┐     ┌──────────────────────────────────────────────┐     ┌──────────────┐
│  pre-job.sh │     │              Job Execution                   │     │ post-job.sh  │
│             │     │                                              │     │              │
│ Start       │     │  Step 1 → write page → upload → DELETE       │     │ Stop watcher │
│ background  │────▶│  Step 2 → write page → upload → DELETE       │────▶│ Collect logs  │
│ page        │     │  Step 3 → write page → upload → DELETE       │     │ Build index   │
│ watcher     │     │  ...                                         │     │ Label steps   │
│ (250ms poll)│     │                                              │     │ Write metadata│
└─────────────┘     └──────────────────────────────────────────────┘     └──────────────┘
       │                              ▲                                         │
       │         ┌────────────────────┘                                         │
       │         │  Watcher copies files                                        │
       ▼         │  before runner deletes them                                  ▼
  ┌──────────────────────────────┐                              ┌─────────────────────────┐
  │  Staging Directory           │                              │  Archive Directory       │
  │  ($RUNNER_TEMP/              │  ─────────────────────────▶  │  /var/log/actions-runner/ │
  │   .log_pages_staging/)       │      post-job collects       │   org/repo/runId/job/    │
  └──────────────────────────────┘                              └─────────────────────────┘
```

| Hook | Script | When It Runs | What It Does |
|---|---|---|---|
| `ACTIONS_RUNNER_HOOK_JOB_STARTED` | `pre-job.sh` | Before the first step | Starts a background process that polls `_diag/pages/` every 250ms, copying new `.log` files to a staging directory before the runner deletes them |
| `ACTIONS_RUNNER_HOOK_JOB_COMPLETED` | `post-job.sh` | After the last step, before cleanup | Stops the watcher, collects staged files, labels each step, builds an index, writes metadata, and manages retention |

> 📖 **Reference:** [Runner Job Hooks ADR (actions/runner#1751)](https://github.com/actions/runner/blob/main/docs/adrs/1751-runner-job-hooks.md)

### How the Page Watcher Works

1. **Pre-job hook** starts a background bash process that runs in a polling loop
2. Every 250ms, the watcher checks `_diag/pages/` for `.log` files
3. When a file appears (or grows), it's copied to a staging directory under `$RUNNER_TEMP`
4. The runner then uploads and deletes the original — but the copy is safe in staging
5. The watcher PID is saved so the post-job hook can stop it cleanly

### Step Identification

Each raw log page file uses opaque GUIDs as filenames (e.g., `c8a322dc_a18726f9_1.log`). The post-job hook parses `##[group]` markers inside each file to extract the human-readable step name (e.g., `actions/checkout@v4`) and produces both:

- **`steps/`** — Labeled copies like `04_actions_checkout_v4.log`
- **`index.json`** — Machine-readable manifest mapping each file to its step name, order, and size

## Archive Structure

Each job produces a self-contained archive directory:

```
$LOG_ARCHIVE_DIR/
└── owner/repo-name/
    └── 12345678_attempt1/
        └── build/                        # Job name
            ├── index.json                # Step manifest (name, order, record ID, sizes)
            ├── metadata.json             # Job context (repo, actor, duration, etc.)
            ├── combined_raw_log.log      # All steps merged, sorted by timestamp
            ├── steps/                    # Human-readable step logs
            │   ├── 01_Set_up_job.log
            │   ├── 02_actions_checkout_v4.log
            │   ├── 03_Run_tests.log
            │   └── 04_Post_actions_checkout_v4.log
            ├── raw_logs/                 # Original GUID-named page files
            │   ├── {timelineId}_{recordId}_1.log
            │   └── ...
            ├── runner_temp/              # Step scripts and event.json from $RUNNER_TEMP
            │   ├── abc123.sh
            │   └── _github_workflow/
            │       └── event.json
            └── Worker_*.log              # Runner diagnostic log (internal details)
```

### `index.json`

```json
[
  {
    "order": 1,
    "step_name": "actions/checkout@v4",
    "record_id": "a18726f9-7649-4255-98ec-9f52dacfb6d2",
    "page": 1,
    "original_file": "c8a322dc_a18726f9_1.log",
    "labeled_file": "01_actions_checkout_v4.log",
    "lines": 80,
    "bytes": 6566
  }
]
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
  "raw_log_pages_copied": 7,
  "temp_files_copied": 5,
  "total_files_copied": 13,
  "run_url": "https://github.com/owner/repo-name/actions/runs/12345678/attempts/1",
  "archived_at": "2024-01-15T10:35:23Z"
}
```

### What Each File Contains

| File | Contents | Use Case |
|---|---|---|
| `steps/*.log` | Per-step output with human-readable names | Quick browsing, "which step failed?" |
| `raw_logs/*.log` | Same content, GUID filenames | Correlation with runner internals |
| `combined_raw_log.log` | All steps merged by timestamp | Full job timeline in one file |
| `index.json` | Step manifest with names, sizes, order | Programmatic access / dashboards |
| `metadata.json` | Job context (repo, actor, SHA, duration) | Audit trail / log aggregation metadata |
| `runner_temp/*.sh` | The actual shell scripts the runner generated for each `run:` step | Debugging "what script did GitHub actually run?" |
| `runner_temp/event.json` | The webhook event payload that triggered the workflow | Debugging trigger context |
| `Worker_*.log` | Runner internal diagnostic log | Deep debugging (contains internal runner details) |

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

   > **Important:** The runner must be restarted after any `.env` changes. The hooks are loaded at runner startup, not per-job.

## Configuration

All configuration is done through environment variables in the runner's `.env` file:

| Variable | Default | Description |
|---|---|---|
| `LOG_ARCHIVE_DIR` | `/var/log/actions-runner-logs` | Base directory for archived logs |
| `LOG_ARCHIVE_USE_API_FALLBACK` | `true` | If the page watcher fails to capture logs, fall back to downloading via the GitHub API |
| `LOG_ARCHIVE_RETENTION_DAYS` | `90` | Automatically delete archived logs older than this many days. Set to `0` to disable cleanup |

### API Fallback

If neither the page watcher nor direct `_diag/pages/` scanning finds any log files (e.g., the watcher failed to start, or an edge case), the post-job hook can fall back to downloading logs via the GitHub API. This uses:

1. **`gh` CLI** (preferred) — uses the runner's existing GitHub CLI authentication
2. **`curl`** with `ACTIONS_RUNTIME_TOKEN` or `GITHUB_TOKEN` — direct API call

The API returns a zip archive of the run's logs, which is extracted into an `api_logs/` subdirectory.

> **Note:** The API fallback only captures the logs that have been uploaded to GitHub, not the raw `_diag/pages/` content. For most jobs, these are equivalent. The page watcher approach is preferred because it runs locally with no network dependency.

## Shipping Logs to External Storage

The hooks archive logs to the local filesystem. From there, you can ship them to any centralized system:

### Log Aggregation / SIEM

- **Filebeat / Logstash:** Point at the archive directory, use `metadata.json` for structured fields
- **Fluentd / Fluent Bit:** `tail` input plugin on the archive directory
- **Splunk Universal Forwarder:** Monitor the archive directory, index `index.json` for step metadata
- **Datadog Agent:** File-based log collection with custom parsing

### Cloud Object Storage

- **AWS S3:** Cron job or post-job hook extension using `aws s3 cp`
- **Azure Blob Storage:** `az storage blob upload-batch`
- **Google Cloud Storage:** `gsutil cp`

### Custom Post-Processing

The `post-job.sh` script is designed to be extended. Add your own upload/shipping logic at the end of the script, after the archive is written. The `metadata.json` and `index.json` files provide all the context needed for downstream systems.

> **Note:** `actions/upload-artifact` **cannot** be used from a post-job hook. The hook runs outside the Actions step execution context — there is no access to the Actions runtime services (which use internal gRPC, not the public REST API). Use direct API calls or CLI tools instead.

## Testing

A sample workflow is included at `.github/workflows/test-hook.yml`. It runs on a `self-hosted` runner and produces output from echo commands, loops, curl, and system info to verify log capture.

Trigger it manually:

```bash
gh workflow run test-hook.yml
```

Then check the archive directory on your runner:

```bash
# List the archived files
find /var/log/actions-runner-logs/ -type f | head -20

# View the step index
cat /var/log/actions-runner-logs/<owner>/<repo>/<run_id>_attempt1/<job>/index.json

# View a specific step's output
cat /var/log/actions-runner-logs/<owner>/<repo>/<run_id>_attempt1/<job>/steps/02_actions_checkout_v4.log

# View job metadata
cat /var/log/actions-runner-logs/<owner>/<repo>/<run_id>_attempt1/<job>/metadata.json
```

## How It Works — Technical Deep Dive

This section explains the runner internals that necessitate the background watcher approach.

### Where Do "View Raw Logs" Actually Live?

| Location | What's There | Survives Job? |
|---|---|---|
| `_work/_temp/` (`$RUNNER_TEMP`) | Step `.sh` scripts, `event.json`, `.gitconfig` | ❌ Cleaned up after job |
| `_diag/pages/` | **Raw step stdout/stderr** — the "View raw logs" content | ❌ Deleted **per-step** after upload |
| `_diag/Worker_*.log` | Runner internal diagnostic log | ✅ Persists across jobs |

### Why a Simple Post-Job Hook Doesn't Work

```
Step 1 starts
  → Runner writes stdout to _diag/pages/{timeline}_{record1}_1.log
Step 1 ends
  → Runner uploads page to GitHub
  → Runner calls File.Delete() on the page file           ← GONE
Step 2 starts
  → Runner writes stdout to _diag/pages/{timeline}_{record2}_1.log
Step 2 ends
  → Runner uploads page → File.Delete()                   ← GONE
...
Post-job hook runs
  → _diag/pages/ is EMPTY (all page files already deleted)
```

Source: [`Logging.cs`](https://github.com/actions/runner/blob/main/src/Runner.Common/Logging.cs) calls `QueueFileUpload(timelineId, recordId, ..., _dataFileName, deleteSource: true)` → [`JobServerQueue.cs`](https://github.com/actions/runner/blob/main/src/Runner.Common/JobServerQueue.cs) processes the upload and calls `File.Delete(file.Path)`.

### Why the Background Watcher Works

```
pre-job.sh starts watcher (polls every 250ms)
  ↓
Step 1 writes page file
  → Watcher copies it to staging          ← SAVED
  → Runner uploads and deletes original
Step 2 writes page file
  → Watcher copies it to staging          ← SAVED
  → Runner uploads and deletes original
...
post-job.sh runs
  → Stops watcher
  → Collects ALL step logs from staging   ← COMPLETE
  → Labels steps, builds index, writes metadata
```

### Runner Hook Execution Order

From [`JobRunner.cs`](https://github.com/actions/runner/blob/main/src/Runner.Worker/JobRunner.cs):

1. **Pre-job hook** fires (`ACTIONS_RUNNER_HOOK_JOB_STARTED`)
2. Job steps execute (pages written and deleted per-step)
3. **Post-job hook** fires (`ACTIONS_RUNNER_HOOK_JOB_COMPLETED`)
4. `FinalizeJob()` — evaluates outputs, uploads diagnostic logs
5. `CompleteJobAsync()` → `ShutdownQueue()` (flushes pending uploads) → `CleanupTempDirectory()` (wipes `_temp`)

### Security Note

The raw log page files are **safe** — the runner's secret masking is applied before writing to disk (tokens, passwords, etc. appear as `***`). However, the `Worker_*.log` diagnostic file contains internal runner details (full job message payload) and should be treated as sensitive.

## Alternative Approaches

### Webhook + API Approach

Instead of capturing logs at the runner, you can capture them after upload to GitHub:

1. Configure a **repository or organization webhook** for the `workflow_job` event
2. When a job completes, the webhook fires with the `run_id`
3. A server-side handler calls the [Download workflow run logs](https://docs.github.com/en/rest/actions/workflow-runs#download-workflow-run-logs) API endpoint
4. Store the downloaded zip archive

OSS examples of this approach:

- [`expert-services/beaver`](https://github.com/expert-services/beaver) — Probot/JS, webhook-driven, streams to Event Hub or PostgreSQL
- [`timorthi/export-workflow-logs`](https://github.com/timorthi/export-workflow-logs) — Go GitHub Action using `workflow_run` trigger, ships to S3/Azure/GCS
- [`kuhlman-labs/workflow-archiver-bot`](https://github.com/kuhlman-labs/workflow-archiver-bot) — Go standalone service, webhook listener, Azure Blob Storage

### Trade-offs

| | Post-Job Hook + Watcher (this project) | Webhook + API |
|---|---|---|
| **Where it runs** | On the runner machine | On a separate server |
| **Network dependency** | None (local file copy) | Requires GitHub API access |
| **Log availability** | Immediate (captured during execution) | After upload to GitHub completes |
| **Captures all output** | ✅ Raw page files exactly as written | ⚠️ Only what GitHub processed & uploaded |
| **Setup complexity** | Per-runner `.env` change + hook scripts | Webhook endpoint + server + auth |
| **Infrastructure** | Nothing beyond the runner | Requires hosting a webhook listener |
| **GHES / GHEC support** | ✅ Works everywhere | ✅ Works everywhere |
| **Per-step files** | ✅ Individual files per step | ❌ Single zip per job |
| **Fault tolerance** | Logs saved even if GitHub upload fails | ❌ Requires successful upload first |

## Troubleshooting

### Hooks are not running

- Verify the `.env` file contains **both** `ACTIONS_RUNNER_HOOK_JOB_STARTED` and `ACTIONS_RUNNER_HOOK_JOB_COMPLETED`
- **Restart the runner** after editing `.env` — hooks are loaded at startup
- Check that the hook scripts are executable: `chmod +x hooks/*.sh`
- The runner must be version **2.300.0+** for hook support
- Verify paths are **absolute** (e.g., `/opt/actions-runner/hooks/pre-job.sh`, not `./hooks/pre-job.sh`)

### Page watcher not capturing logs

- Ensure `pre-job.sh` is configured via `ACTIONS_RUNNER_HOOK_JOB_STARTED` (the watcher starts here)
- Check that `_diag/pages/` exists under the runner root — the script resolves it from `$RUNNER_TEMP`
- Look for `[pre-job-hook] Started page watcher` in the runner output to confirm it started
- If the runner root can't be found, the watcher won't start — check the hook output for warnings

### Empty or missing step logs

- If `steps/` directory is empty but `raw_logs/` has files, the `##[group]` marker parsing may have failed for those steps — check the raw log content
- Steps that produce no output may not generate a page file at all

### Permission denied on archive directory

- Ensure the runner service user owns the archive directory
- Check: `ls -la /var/log/actions-runner-logs/`
- Fix: `sudo chown -R <runner-user> /var/log/actions-runner-logs/`

### Archive directory growing too large

- Set `LOG_ARCHIVE_RETENTION_DAYS` to automatically clean up old archives
- Monitor disk usage: `du -sh /var/log/actions-runner-logs/`
- Consider shipping logs to external storage and reducing local retention

### Hook script errors

- The post-job hook uses `set -euo pipefail` with an error `trap`
- Errors are logged but **will not block** the runner from proceeding
- Runner diagnostic logs in `_diag/Worker_*.log` show hook execution details

## Requirements

- GitHub Actions Runner **v2.300.0** or later
- Bash (available on all supported runner OS versions)
- Standard Unix utilities: `find`, `cp`, `mkdir`, `date`, `stat`, `sort`, `wc`, `sed`, `grep`
- Optional: `gh` CLI or `curl` (for API fallback)
- Optional: `unzip` (for extracting API-downloaded log archives)

> **Note:** This project currently supports Linux and macOS runners. Windows/PowerShell support is not yet implemented.

## License

MIT