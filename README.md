# agent-reproducibility

## Running the ML-GPU Docker Image

```bash
 docker run --gpus all -it -v $(pwd):/home/researcher/work ashetty21/ml-gpu:latest
```

## Running the Non-ML Docker Image

```bash
docker run -it -v $(pwd):/home/researcher/work ashetty21/non-ml:latest
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
- A running RunPod pod with SSH enabled if using the RunPod scripts
- For RunPod, launch the pod from the runtime image you want to work inside; the RunPod scripts connect directly to that pod and do not start nested Docker containers
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
RUNPOD_USER=<your RunPod SSH username>
RUNPOD_SSH_HOST=ssh.runpod.io
RUNPOD_SSH_PORT=22
SSH_KEY=~/.ssh/lambda_key
DOCENT_API_KEY=<your Docent API key>
PAPER_NAME="<exact paper title>"
RESEARCHER="<your name>"
ML_DOCKER_IMAGE=ashetty21/ml-gpu:latest
ML_CONTAINER_NAME=rct-ml-eval
NON_ML_DOCKER_IMAGE=ashetty21/non-ml:latest
NON_ML_CONTAINER_NAME=rct-eval
MODE=gpu          # gpu or cpu
DOCENT_COLLECTION=berkeley-pilot
```

`ML_DOCKER_IMAGE`, `ML_CONTAINER_NAME`, `NON_ML_DOCKER_IMAGE`, and `NON_ML_CONTAINER_NAME` are used by the Lambda scripts. The RunPod scripts connect directly into the pod you launched.

For RunPod, use the SSH endpoint form:

```bash
ssh 042llwqdpoddj3-644118db@ssh.runpod.io -i ~/.ssh/id_ed25519
```

That maps to:

```env
RUNPOD_USER=042llwqdpoddj3-644118db
RUNPOD_SSH_HOST=ssh.runpod.io
RUNPOD_SSH_PORT=22
SSH_KEY=~/.ssh/id_ed25519
```

### RunPod Setup

Create a template under `My Templates` for each runtime you want to launch:

1. In RunPod, open `My Templates`.
2. Create a new template.
3. Set the image to `ashetty21/ml-gpu:latest` for the ML/Codex condition, or `ashetty21/non-ml:latest` for the manual non-ML condition.
4. Enable SSH for the pod so RunPod provides the `ssh.runpod.io` connection form.
5. Launch a pod from that template.
6. Copy the pod's SSH username into `.env` as `RUNPOD_USER`.
7. Keep `RUNPOD_SSH_HOST=ssh.runpod.io` and `RUNPOD_SSH_PORT=22` unless RunPod shows a different SSH endpoint.

Recommended template split:

- `My Templates` -> `agent-repro-ml`: image `ashetty21/ml-gpu:latest`
- `My Templates` -> `agent-repro-non-ml`: image `ashetty21/non-ml:latest`

---

## Running a Session

### AI-Assisted Condition (ML / Codex)

```bash
bash scripts/lambda-ml.sh
```

Or on RunPod:

```bash
bash scripts/runpod-ml.sh
```

Use the `ssh.runpod.io` SSH endpoint here.

The RunPod script connects directly into the pod you launched, syncs the Docent helper scripts to `~/rct`, and runs the session there.

The script will:
1. Connect to RunPod over SSH/TCP
2. Sync `docent/` to `~/rct` on the pod and install `docent-python`
3. Capture environment info (CPU, RAM, GPU, Python)
4. Drop you into the pod shell — install and run Codex:
   ```bash
   sudo npm i -g @openai/codex
   codex --dangerously-bypass-approvals-and-sandbox
   ```
5. On exit: record timing and write sidecar metadata to `/tmp/session_meta.json` on the pod
6. Prompt to upload all Codex rollouts from the session to Docent

### Manual Condition (Non-ML)

```bash
bash scripts/lambda-non-ml.sh
```

Or on RunPod:

```bash
bash scripts/runpod-non-ml.sh
```

Use the `ssh.runpod.io` SSH endpoint here.

The RunPod script connects directly into the pod you launched, syncs the Docent helper scripts to `~/rct`, and runs the session there.

The script will:
1. Connect to RunPod over SSH/TCP
2. Sync `docent/` to `~/rct` on the pod and install `docent-python`
3. Capture environment info
4. Drop you into the pod shell — do your work, type `exit` when done
5. On exit: record timing, append cleaned terminal recording to log, write sidecar
6. Prompt to upload session to Docent

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
  "provider": "lambda | runpod",
  "lambda_host": "...",
  "runpod_host": "...",
  "runpod_port": "22",
  "env": {
    "cpu": "...",
    "ram": "...",
    "gpu": "...",
    "python": "...",
    "r": "..."
  }
}
```
