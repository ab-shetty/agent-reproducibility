#!/bin/bash
# lambda-ml.sh
# End-to-end runtime tracker for AI-assisted (Codex) reproducibility evaluation on Lambda GPU.
# Codex logs its own JSONL rollouts; this script handles timing and Lambda connection.
#
# Prerequisites (local): ssh
# Prerequisites (Lambda): Docker with NVIDIA runtime (standard on Lambda GPU instances)
#
# Usage:
#   bash lambda-ml.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/../.env" ]; then
  set -a
  source "$SCRIPT_DIR/../.env"
  set +a
fi
LOG_DIR="$SCRIPT_DIR/../logs"
DOCKER_IMAGE="ashetty21/ml-gpu:latest"
CONTAINER_NAME="rct-ml-eval"
mkdir -p "$LOG_DIR"

ts() { date +%Y-%m-%dT%H:%M:%S; }

START_EPOCH=""
MASTER_LOG=""
CONDITION=""
SESSION_ID=""
ENV_JSON=""

write_sidecar() {
  local status="$1"
  local duration="$2"
  local start_time=""
  [ -n "$START_EPOCH" ] && start_time=$(date -r $START_EPOCH +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -d @$START_EPOCH +%Y-%m-%dT%H:%M:%S)
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "${LAMBDA_USER}@${LAMBDA_HOST}" \
    "sudo docker exec -i $CONTAINER_NAME python3 -" 2>/dev/null << PYEOF || true
import json
data = {
  'paper': '$PAPER_NAME',
  'researcher': '$RESEARCHER',
  'condition': '$CONDITION',
  'session_id': '$SESSION_ID',
  'start_time': '$start_time',
  'end_time': '$(ts)',
  'duration_seconds': $duration,
  'status': '$status',
  'lambda_host': '$LAMBDA_HOST',
  'env': $ENV_JSON,
}
with open('/tmp/session_meta.json', 'w') as f:
    json.dump(data, f, indent=2)
PYEOF
}

cleanup() {
  if [ -n "$START_EPOCH" ] && [ -n "$MASTER_LOG" ] && ! grep -q "\] END" "$MASTER_LOG" 2>/dev/null; then
    local partial_duration=$(( $(date +%s) - START_EPOCH ))
    echo "[$(ts)] INTERRUPTED | partial duration=${partial_duration}s" | tee -a "$MASTER_LOG"
    write_sidecar "interrupted" "$partial_duration"
    echo ""
    echo "Session interrupted. Log saved:"
    echo "   Master log  : $MASTER_LOG"
  fi
}
trap cleanup EXIT

# ── Connection details ────────────────────────────────────────────────────────

echo "==== Lambda ML Evaluation ===="
LAMBDA_USER="${LAMBDA_USER:-ubuntu}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/lambda_key}"

[ -z "$LAMBDA_HOST" ] && echo "ERROR: LAMBDA_HOST not set in .env" && exit 1

SSH_CMD="ssh -i $SSH_KEY -o StrictHostKeyChecking=no ${LAMBDA_USER}@${LAMBDA_HOST}"
DOCKER="sudo docker"

# ── Verify SSH ────────────────────────────────────────────────────────────────

echo "[$(ts)] >> Testing SSH connection to ${LAMBDA_USER}@${LAMBDA_HOST}..."
if ! $SSH_CMD "echo 'SSH OK'" 2>/dev/null; then
  echo "[$(ts)] ERROR: Could not connect. Check your IP, username, and SSH key path."
  exit 1
fi
echo "[$(ts)]    Connected."

# ── Pull image and start container ───────────────────────────────────────────

echo "[$(ts)] >> Checking Docker on Lambda..."
$SSH_CMD "$DOCKER image inspect $DOCKER_IMAGE > /dev/null 2>&1 || (echo 'Pulling image...' && $DOCKER pull $DOCKER_IMAGE)"

# Sync docent folder to Lambda working directory
echo "[$(ts)] >> Syncing docent/ to Lambda..."
$SSH_CMD "mkdir -p ~/docent"
scp -i "$SSH_KEY" -o StrictHostKeyChecking=no \
  "$SCRIPT_DIR/../docent/"*.py "${LAMBDA_USER}@${LAMBDA_HOST}:~/docent/"

RUNNING=$($SSH_CMD "$DOCKER ps --filter name=^/${CONTAINER_NAME}$ --format '{{.Names}}'" 2>/dev/null)
if [ -z "$RUNNING" ]; then
  MODE="${MODE:-gpu}"
  if [ "$MODE" = "gpu" ]; then
    echo "[$(ts)] >> Starting GPU container '$CONTAINER_NAME' on Lambda..."
    $SSH_CMD "$DOCKER run -dit --gpus all --name $CONTAINER_NAME -v ~/docent:/home/researcher/rct $DOCKER_IMAGE /bin/bash"
  else
    echo "[$(ts)] >> Starting CPU container '$CONTAINER_NAME' on Lambda..."
    $SSH_CMD "$DOCKER run -dit --name $CONTAINER_NAME -v ~/docent:/home/researcher/rct $DOCKER_IMAGE /bin/bash"
  fi
  echo "[$(ts)]    Container started."
else
  echo "[$(ts)]    Container '$CONTAINER_NAME' already running."
fi
echo "[$(ts)] >> Installing docent in container..."
$SSH_CMD "$DOCKER exec $CONTAINER_NAME pip install -q docent-python"

# ── Session metadata ──────────────────────────────────────────────────────────

echo ""
[ -z "$PAPER_NAME" ] && read -p "Enter Paper Name (exact title): " PAPER_NAME
[ -z "$RESEARCHER" ] && read -p "Enter Researcher Name: " RESEARCHER

CONDITION="ai-assisted"
SAFE_PAPER=$(echo "$PAPER_NAME" | tr ' ' '_' | tr -cd '[:alnum:]_-')
SAFE_RESEARCHER=$(echo "$RESEARCHER" | tr ' ' '_' | tr -cd '[:alnum:]_-')
SESSION_ID=$(date +%Y%m%d_%H%M%S)
MASTER_LOG="$LOG_DIR/${SAFE_PAPER}_${SAFE_RESEARCHER}_${CONDITION}_${SESSION_ID}.log"

echo ""
echo "============================================================"
echo "Paper     : $PAPER_NAME"
echo "Researcher: $RESEARCHER"
echo "Condition : $CONDITION"
echo "Lambda    : ${LAMBDA_USER}@${LAMBDA_HOST}"
echo "Container : $CONTAINER_NAME"
echo "Session ID: $SESSION_ID"
echo "Log       : $MASTER_LOG"
echo "============================================================"

# ── Capture environment info ──────────────────────────────────────────────────

echo "[$(ts)] >> Capturing environment info from container..."
ENV_JSON=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "${LAMBDA_USER}@${LAMBDA_HOST}" \
  "sudo docker exec -i $CONTAINER_NAME python3 -" 2>/dev/null << 'PYEOF'
import json, subprocess
def run(cmd):
    try: return subprocess.check_output(cmd, shell=True, text=True, stderr=subprocess.DEVNULL).strip()
    except: return ''
print(json.dumps({
    'cpu':    run("grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs"),
    'ram':    run("free -h | awk '/^Mem:/{print $2}'"),
    'gpu':    run('nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader 2>/dev/null'),
    'python': run('python3 --version'),
    'r':      run('R --version 2>/dev/null | head -1'),
}))
PYEOF
)

{
  echo "[$(ts)] ENV INFO"
  echo "$ENV_JSON" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for k,v in d.items(): print(f'  {k}: {v}')
" 2>/dev/null || echo "$ENV_JSON"
} | tee -a "$MASTER_LOG"
echo ""

# ── Docent setup ─────────────────────────────────────────────────────────────

if [ -z "$DOCENT_API_KEY" ]; then
  read -p "DOCENT_API_KEY (leave blank to skip Docent upload): " DOCENT_API_KEY
fi

# ── Run session ───────────────────────────────────────────────────────────────

echo ""
echo "Once inside the container, run:"
echo "  sudo npm i -g @openai/codex"
echo "  codex --dangerously-bypass-approvals-and-sandbox"
echo ""
echo "Type 'exit' to leave the container and stop timing."
read -p "Press ENTER to START..."

START_EPOCH=$(date +%s)
echo "[$(ts)] START [paper=$PAPER_NAME] [researcher=$RESEARCHER] [condition=$CONDITION]" | tee -a "$MASTER_LOG"

ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no \
  -t "${LAMBDA_USER}@${LAMBDA_HOST}" \
  "sudo docker exec -it -e DOCENT_API_KEY=$DOCENT_API_KEY $CONTAINER_NAME /bin/bash" || true

END_EPOCH=$(date +%s)
DURATION=$(( END_EPOCH - START_EPOCH ))
echo "[$(ts)] END | duration=${DURATION}s" | tee -a "$MASTER_LOG"

# ── Write sidecar JSON into container ────────────────────────────────────────

write_sidecar "complete" "$DURATION"

echo ""
echo "[$(ts)] Session complete."
echo "   Master log : $MASTER_LOG"

# ── Optional Docent upload ────────────────────────────────────────────────────

echo ""
read -p "Upload session to Docent? [y/N]: " UPLOAD
if [[ "$UPLOAD" =~ ^[Yy]$ ]]; then
  if [ -z "$DOCENT_API_KEY" ]; then
    read -p "DOCENT_API_KEY: " DOCENT_API_KEY
  fi
  COLLECTION="${DOCENT_COLLECTION:-ml-reproducibility}"

  # Pull sidecar from container
  LOCAL_SIDECAR="/tmp/${SESSION_ID}_meta.json"
  $SSH_CMD "$DOCKER cp $CONTAINER_NAME:/tmp/session_meta.json /tmp/${SESSION_ID}_meta.json"
  scp -i "$SSH_KEY" -o StrictHostKeyChecking=no \
    "${LAMBDA_USER}@${LAMBDA_HOST}:/tmp/${SESSION_ID}_meta.json" "$LOCAL_SIDECAR"

  # Find all JSONLs created during this session window
  START_FMT=$(date -u -r $START_EPOCH "+%Y-%m-%d %H:%M:%S" 2>/dev/null || date -u -d @$START_EPOCH "+%Y-%m-%d %H:%M:%S")
  END_FMT=$(date -u -r $END_EPOCH "+%Y-%m-%d %H:%M:%S" 2>/dev/null || date -u -d @$END_EPOCH "+%Y-%m-%d %H:%M:%S")
  JSONL_LIST=$($SSH_CMD "$DOCKER exec $CONTAINER_NAME bash -c \
    'find /home/researcher/.codex/sessions -name \"*.jsonl\" -newermt \"$START_FMT\" ! -newermt \"$END_FMT\" 2>/dev/null | sort'")

  if [ -z "$JSONL_LIST" ]; then
    echo "No Codex JSONL files found for this session window."
    rm -f "$LOCAL_SIDECAR"
  else
    echo "Found rollouts:"
    echo "$JSONL_LIST"
    echo ""
    UPLOADED=0
    while IFS= read -r JSONL_PATH; do
      $SSH_CMD "$DOCKER exec -e DOCENT_API_KEY=$DOCENT_API_KEY $CONTAINER_NAME \
        python3 rct/upload_codex_to_docent.py \
        --path $JSONL_PATH \
        --collection-name $COLLECTION \
        --meta-sidecar /tmp/session_meta.json"
      UPLOADED=$(( UPLOADED + 1 ))
    done <<< "$JSONL_LIST"
    echo "[$(ts)] Uploaded $UPLOADED rollout(s) to '$COLLECTION'."
  fi
fi

# ── Teardown ──────────────────────────────────────────────────────────────────

echo ""
read -p "Stop and remove the container on Lambda? [y/N]: " TEARDOWN
if [[ "$TEARDOWN" =~ ^[Yy]$ ]]; then
  $SSH_CMD "$DOCKER stop $CONTAINER_NAME && $DOCKER rm $CONTAINER_NAME" \
    && echo "[$(ts)] >> Container removed."
else
  echo "[$(ts)] >> Container left running as '$CONTAINER_NAME'."
fi
