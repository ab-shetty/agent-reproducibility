# agent-reproducibility

## Running the ML-GPU Docker Image

```bash
 docker run --gpus all -it -v $(pwd):/home/researcher/work ashetty21/ml-gpu:latest
```

### Installing Codex

```bash
sudo npm i -g @openai/codex
```

### Running Codex

```bash
codex --dangerously-bypass-approvals-and-sandbox
```

## Uploading Codex Runs to Docent

Use `docent/upload_codex_to_docent.py` to upload a Codex rollout JSONL to a Docent collection.

**Prerequisites:** Set `DOCENT_API_KEY` in your environment.

**Running the upload script directly:**

```bash
python docent/upload_codex_to_docent.py \
  --path <path to rollout .jsonl> \
  --collection-name "berkeley-pilot" \
  --tag "<TOPIC>"
```

**Asking Codex to find and upload a run by topic:**

```
Using the script at <path to upload_codex_to_docent.py>,
find the rollout JSONL file for the conversation about <TOPIC>,
then run:

  python <path to upload_codex_to_docent.py> \
    --path <found file> \
    --collection-name "berkeley-pilot" \
    --tag "<TOPIC>"
```

The script will reuse an existing collection with the given name, or create one if it doesn't exist. Use `--dry-run` to validate without uploading.

---

## Non-ML and ML Session Setup

### Prerequisites

- SSH key for Lambda instances at `~/.ssh/lambda_key`
- A running Lambda instance (GPU for ML condition, CPU for non-ML)
- Docent API key

### SSH Key Setup

```bash
# Generate a key if you don't have one
ssh-keygen -t ed25519 -f ~/.ssh/lambda_key

# Add the public key to your Lambda instance via the Lambda dashboard
cat ~/.ssh/lambda_key.pub
```

### Environment Setup

Copy `.env.example` to `.env` and fill in your values:

```bash
cp .env.example .env
```

```env
LAMBDA_HOST=<your Lambda instance IP>
LAMBDA_USER=ubuntu
SSH_KEY=~/.ssh/lambda_key
DOCENT_API_KEY=<your Docent API key>
PAPER_NAME="<exact paper title>"
RESEARCHER="<your name>"
MODE=gpu          # gpu or cpu
DOCENT_COLLECTION=berkeley-pilot
```

---

## Running a Session

### AI-Assisted Condition (ML / Codex)

```bash
bash scripts/lambda-ml.sh
```

The script will:
1. Connect to Lambda and start the GPU Docker container
2. Install `docent-python` in the container
3. Capture environment info (CPU, RAM, GPU, Python)
4. Drop you into the container — install and run Codex:
   ```bash
   sudo npm i -g @openai/codex
   codex --dangerously-bypass-approvals-and-sandbox
   ```
5. On exit: record timing, write sidecar to `/tmp/session_meta.json` in container
6. Prompt to upload all Codex rollouts from the session to Docent
7. Prompt to stop and remove the container

### Manual Condition (Non-ML)

```bash
bash scripts/lambda-non-ml.sh
```

The script will:
1. Connect to Lambda and start the CPU Docker container
2. Install `docent-python` in the container
3. Capture environment info
4. Drop you into the container — do your work, type `exit` when done
5. On exit: record timing, append cleaned terminal recording to log, write sidecar
6. Prompt to upload session to Docent
7. Prompt to stop and remove the container

---

## Logs

All logs are saved locally to `logs/` (gitignored).

| File | Description |
|------|-------------|
| `<paper>_<researcher>_<condition>_<session_id>.log` | Master log — env info, timing, and (non-ML only) full session recording |
| `/tmp/session_meta.json` (in container) | Sidecar JSON — structured metadata for Docent upload |

### Log filename format

```
PAPER_NAME_RESEARCHER_CONDITION_YYYYMMDD_HHMMSS.log
```

Example:
```
LLaVA_Derrick_Chan-Sew_ai-assisted_20260406_183433.log
LLaVA_Derrick_Chan-Sew_manual_20260406_183433.log
```

### Sidecar JSON fields

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
  "lambda_host": "...",
  "env": {
    "cpu": "...",
    "ram": "...",
    "gpu": "...",
    "python": "...",
    "r": "..."
  }
}
```
