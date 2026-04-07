#!/bin/bash
# lambda-non-ml.sh
# End-to-end runtime tracker for human-only reproducibility evaluation on Lambda.
# Connects to the non-ML Docker container on a Lambda instance and records the full session locally.
#
# Prerequisites (local): ssh, script
# Prerequisites (Lambda): Docker installed and running
#
# Usage:
#   bash lambda-non-ml.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/../.env" ]; then
  set -a
  source "$SCRIPT_DIR/../.env"
  set +a
fi
LOG_DIR="$SCRIPT_DIR/../logs"
DOCKER_IMAGE="ashetty21/non-ml:latest"
CONTAINER_NAME="rct-eval"
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
    echo "   $MASTER_LOG"
  fi
}
trap cleanup EXIT

# ── Connection details ────────────────────────────────────────────────────────

echo "==== Lambda Non-ML Evaluation ===="
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

# Sync docent scripts to Lambda so they're accessible via volume mount
echo "[$(ts)] >> Syncing docent/ to Lambda..."
$SSH_CMD "mkdir -p ~/rct"
scp -i "$SSH_KEY" -o StrictHostKeyChecking=no \
  "$SCRIPT_DIR/../docent/"*.py "${LAMBDA_USER}@${LAMBDA_HOST}:~/rct/"

RUNNING=$($SSH_CMD "$DOCKER ps --filter name=^/${CONTAINER_NAME}$ --format '{{.Names}}'" 2>/dev/null)
if [ -z "$RUNNING" ]; then
  echo "[$(ts)] >> Starting container '$CONTAINER_NAME' on Lambda..."
  $SSH_CMD "$DOCKER run -dit --name $CONTAINER_NAME -v \$(pwd):/home/researcher/work $DOCKER_IMAGE /bin/bash"
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

CONDITION="manual"
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

# ── Run session ───────────────────────────────────────────────────────────────

echo "You will be dropped into the Docker container on Lambda."
echo "Do your work, then type 'exit' to stop timing."
read -p "Press ENTER to START..."

SESSION_TMP=$(mktemp)
START_EPOCH=$(date +%s)
echo "[$(ts)] START [paper=$PAPER_NAME] [researcher=$RESEARCHER] [condition=$CONDITION]" | tee -a "$MASTER_LOG"

script -q "$SESSION_TMP" \
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no \
  -t "${LAMBDA_USER}@${LAMBDA_HOST}" \
  "exec $DOCKER exec -it $CONTAINER_NAME /bin/bash" || true

END_EPOCH=$(date +%s)
DURATION=$(( END_EPOCH - START_EPOCH ))
echo "[$(ts)] END | duration=${DURATION}s" | tee -a "$MASTER_LOG"

# Append cleaned session recording to master log
{
  echo ""
  echo "--- SESSION RECORDING ---"
  python3 - "$SESSION_TMP" << 'PYEOF'
import sys, re
raw = open(sys.argv[1], 'rb').read().decode('utf-8', errors='replace')
# Strip OSC sequences (window titles, colour changes): ESC ] ... BEL/ST
clean = re.sub(r'\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)', '', raw)
# Strip CSI and other two/three-char escape sequences
clean = re.sub(r'\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])', '', clean)
# Strip remaining control characters except newline and tab
clean = re.sub(r'[\x00-\x08\x0b-\x1f\x7f]', '', clean)
# Clean up duplicate prompt fragments (title bar remnants like "0;user@host: ~")
clean = re.sub(r'\d+;[^\n]*?[@:][^\n]*?[\$#] ', '', clean)
print(clean, end='')
PYEOF
} >> "$MASTER_LOG"
rm -f "$SESSION_TMP"

# ── Write sidecar JSON into container ────────────────────────────────────────

write_sidecar "complete" "$DURATION"

echo ""
echo "[$(ts)] Session complete."
echo "   Log : $MASTER_LOG"

# ── Optional Docent upload ────────────────────────────────────────────────────

echo ""
read -p "Upload session to Docent? [y/N]: " UPLOAD
if [[ "$UPLOAD" =~ ^[Yy]$ ]]; then
  if [ -z "$DOCENT_API_KEY" ]; then
    read -p "DOCENT_API_KEY not set. Enter API key: " DOCENT_API_KEY
    export DOCENT_API_KEY
  fi
  COLLECTION="${DOCENT_COLLECTION:-non-ml-reproducibility}"

  # Copy master log to Lambda so it's accessible via volume mount in container
  REMOTE_LOG="~/$(basename $MASTER_LOG)"
  scp -i "$SSH_KEY" -o StrictHostKeyChecking=no "$MASTER_LOG" "${LAMBDA_USER}@${LAMBDA_HOST}:$REMOTE_LOG"

  $SSH_CMD "$DOCKER exec -e DOCENT_API_KEY=$DOCENT_API_KEY $CONTAINER_NAME \
    python3 work/rct/upload_non_ml_to_docent.py \
    --master-log work/$(basename $MASTER_LOG) \
    --collection-name $COLLECTION" && echo "[$(ts)] Upload complete." || echo "[$(ts)] ERROR: Upload failed."
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
