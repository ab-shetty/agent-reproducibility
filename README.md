# agent-reproducibility

Infrastructure for a reproducibility RCT — researchers attempt to reproduce ML and non-ML papers under two conditions: **AI-assisted** (using Codex) vs. **manual** (human only). Sessions are timed, logged, and uploaded to [Docent](https://docent.dev) for analysis.

## Quick Start

1. Deploy a RunPod pod from the appropriate template (see below).
2. SSH into the pod — session setup starts automatically on first connect.
3. Do your work (and if AI-assisted, use Codex).
4. Run `finish-session` to stop the timer and upload to Docent.

## RunPod Templates

### ML / GPU (AI-assisted condition)

**Template:** [Deploy ML template](https://console.runpod.io/deploy?template=jo8klw71d0&ref=bd37kdkt)

- Image: `ashetty21/ml-gpu:latest` — CUDA 12.1, PyTorch, HuggingFace, conda, Python 3.11
- Disk: 40GB container + 40GB volume
- Includes Codex CLI

### Non-ML (manual condition)

**Template:** [Deploy Non-ML template](https://console.runpod.io/deploy?template=071bthitdg&ref=bd37kdkt)

- Image: `ashetty21/non-ml:latest` — Python 3.11, R 4.x, stats/data packages
- Disk: 20GB container

## Session Workflow

### 1. Connect to the pod

SSH into the RunPod pod. On first interactive login, `start-session.sh` runs automatically and prompts for:

- **Paper Name** (exact title)
- **Researcher Name**
- **Condition** (`manual` or `ai-assisted`)
- **DOCENT_API_KEY** (leave blank to skip upload)

These can also be set as environment variables in the RunPod template to skip the prompts.

The script captures environment info (CPU, RAM, GPU, Python, R), starts the timer, and begins logging to `/workspace/logs/`.

### 2. Do your work

For AI-assisted sessions:
```bash
codex --dangerously-bypass-approvals-and-sandbox
```

For manual sessions, just work normally.

### 3. Finish the session

```bash
finish-session
```

This command:
1. Stops the timer and records duration
2. Writes sidecar metadata to `/tmp/session_meta.json`
3. Auto-detects Codex rollouts from `~/.codex/sessions/`
4. Prompts to upload to Docent

## Logs

All logs are saved to `/workspace/logs/` on the pod.

### Log filename format

```
PAPER_NAME_RESEARCHER_CONDITION_YYYYMMDD_HHMMSS.log
```

Example:
```
LLaVA_Derrick_Chan-Sew_ai-assisted_20260406_183433.log
```

### Sidecar JSON

Written to `/tmp/session_meta.json` on the pod:

```json
{
  "paper": "...",
  "researcher": "...",
  "condition": "ai-assisted | manual",
  "session_id": "...",
  "start_time": "...",
  "end_time": "...",
  "duration_seconds": 0,
  "status": "complete | interrupted",
  "provider": "runpod",
  "env": {
    "cpu": "...",
    "ram": "...",
    "gpu": "...",
    "python": "...",
    "r": "..."
  }
}
```

## Docent Upload Scripts

Upload scripts live in `docent/` and are baked into the Docker images at `/opt/rct/`:

| Script | What it uploads |
|--------|----------------|
| `upload_codex_to_docent.py` | Codex CLI rollout JSONL (`~/.codex/sessions/`) |
| `upload_non_ml_to_docent.py` | Master log with embedded session recording |

`finish-session` calls these automatically. To upload manually:

```bash
# Codex rollout
python3 /opt/rct/upload_codex_to_docent.py \
  --path <rollout.jsonl> \
  --collection-name "berkeley-pilot" \
  --meta-sidecar /tmp/session_meta.json

# Manual session
python3 /opt/rct/upload_non_ml_to_docent.py \
  --master-log <master.log> \
  --collection-name "berkeley-pilot"
```

All scripts support `--dry-run` to validate without uploading.

## Workspace

Do your research work under `/workspace` on the pod — files there survive pod restarts if you have persistent volume storage attached.
