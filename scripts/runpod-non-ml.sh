#!/bin/bash
# runpod-non-ml.sh
# End-to-end runtime tracker for human-only reproducibility evaluation on RunPod.
# Connects directly to a RunPod pod over SSH and records the full session locally.
#
# Prerequisites (local): ssh, script
# Prerequisites (RunPod): pod image with Python available directly
#
# Usage:
#   bash runpod-non-ml.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/../.env" ]; then
  set -a
  source "$SCRIPT_DIR/../.env"
  set +a
fi
LOG_DIR="$SCRIPT_DIR/../logs"
mkdir -p "$LOG_DIR"

ts() { date +%Y-%m-%dT%H:%M:%S; }

START_EPOCH=""
MASTER_LOG=""
CONDITION=""
SESSION_ID=""
ENV_JSON=""
RUNPOD_GATEWAY_MODE=""
RCT_DIR="${RUNPOD_RCT_DIR:-/opt/rct}"

RUNPOD_USER="${RUNPOD_USER:-root}"
RUNPOD_HOST="${RUNPOD_SSH_HOST:-ssh.runpod.io}"
RUNPOD_PORT="${RUNPOD_SSH_PORT:-22}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/lambda_key}"
SSH_ARGS=(-i "$SSH_KEY" -p "$RUNPOD_PORT" -o StrictHostKeyChecking=no)

[ -z "$RUNPOD_USER" ] && echo "ERROR: RUNPOD_USER not set in .env" && exit 1
[ "$RUNPOD_HOST" = "ssh.runpod.io" ] && RUNPOD_GATEWAY_MODE="1"

ssh_remote() {
  local stdout_file stderr_file status
  stdout_file=$(mktemp)
  stderr_file=$(mktemp)
  if ssh "${SSH_ARGS[@]}" "${RUNPOD_USER}@${RUNPOD_HOST}" "$@" >"$stdout_file" 2>"$stderr_file"; then
    status=0
  else
    status=$?
  fi
  sed "/^Error: Your SSH client doesn't support PTY$/d" "$stdout_file"
  sed "/^Error: Your SSH client doesn't support PTY$/d" "$stderr_file" >&2
  rm -f "$stdout_file" "$stderr_file"
  return $status
}

remote_python() {
  ssh_remote "python3 -"
}

write_sidecar() {
  local status="$1"
  local duration="$2"
  local start_time=""
  [ -n "$START_EPOCH" ] && start_time=$(date -r $START_EPOCH +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -d @$START_EPOCH +%Y-%m-%dT%H:%M:%S)
  remote_python 2>/dev/null << PYEOF || true
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
  'provider': 'runpod',
  'runpod_host': '$RUNPOD_HOST',
  'runpod_port': '$RUNPOD_PORT',
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

echo "==== RunPod Non-ML Evaluation (SSH) ===="

echo "[$(ts)] >> Testing SSH connection to ${RUNPOD_USER}@${RUNPOD_HOST}:${RUNPOD_PORT}..."
if ! ssh_remote "echo 'SSH OK'" 2>/dev/null; then
  echo "[$(ts)] ERROR: Could not connect. Check your host, port, username, and SSH key path."
  exit 1
fi
echo "[$(ts)]    Connected."

if [ -n "$RUNPOD_GATEWAY_MODE" ]; then
  echo "[$(ts)] >> RunPod gateway mode detected (ssh.runpod.io)."
fi

echo "[$(ts)] >> Verifying Python on RunPod..."
if ! ssh_remote "command -v python3 >/dev/null 2>&1"; then
  echo "[$(ts)] ERROR: python3 not found on RunPod pod."
  exit 1
fi

echo "[$(ts)] >> Verifying Docent helper scripts in image..."
if ! ssh_remote "test -f '$RCT_DIR/upload_non_ml_to_docent.py'"; then
  echo "[$(ts)] ERROR: $RCT_DIR/upload_non_ml_to_docent.py not found on RunPod pod."
  echo "[$(ts)]        Rebuild and redeploy the RunPod image after baking docent/ into it."
  exit 1
fi

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
echo "RunPod    : ${RUNPOD_USER}@${RUNPOD_HOST}:${RUNPOD_PORT}"
echo "Target    : direct pod shell"
echo "Session ID: $SESSION_ID"
echo "Log       : $MASTER_LOG"
echo "============================================================"

echo "[$(ts)] >> Capturing environment info..."
ENV_JSON=$(remote_python 2>/dev/null << 'PYEOF'
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

echo "You will be dropped into the RunPod shell directly."
echo "Do your work, then type 'exit' to stop timing."
read -p "Press ENTER to START..."

SESSION_TMP=$(mktemp)
START_EPOCH=$(date +%s)
echo "[$(ts)] START [paper=$PAPER_NAME] [researcher=$RESEARCHER] [condition=$CONDITION]" | tee -a "$MASTER_LOG"

DOCENT_API_KEY_Q=$(printf '%q' "$DOCENT_API_KEY")
script -q "$SESSION_TMP" \
  ssh "${SSH_ARGS[@]}" -t "${RUNPOD_USER}@${RUNPOD_HOST}" \
  "DOCENT_API_KEY=$DOCENT_API_KEY_Q exec /bin/bash -l" || true

END_EPOCH=$(date +%s)
DURATION=$(( END_EPOCH - START_EPOCH ))
echo "[$(ts)] END | duration=${DURATION}s" | tee -a "$MASTER_LOG"

{
  echo ""
  echo "--- SESSION RECORDING ---"
  python3 - "$SESSION_TMP" << 'PYEOF'
import sys, re
raw = open(sys.argv[1], 'rb').read().decode('utf-8', errors='replace')
clean = re.sub(r'\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)', '', raw)
clean = re.sub(r'\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])', '', clean)
clean = re.sub(r'[\x00-\x08\x0b-\x1f\x7f]', '', clean)
clean = re.sub(r'\d+;[^\n]*?[@:][^\n]*?[\$#] ', '', clean)
print(clean, end='')
PYEOF
} >> "$MASTER_LOG"
rm -f "$SESSION_TMP"

write_sidecar "complete" "$DURATION"

echo ""
echo "[$(ts)] Session complete."
echo "   Log : $MASTER_LOG"

echo ""
read -p "Upload session to Docent? [y/N]: " UPLOAD
if [[ "$UPLOAD" =~ ^[Yy]$ ]]; then
  if [ -z "$DOCENT_API_KEY" ]; then
    read -p "DOCENT_API_KEY not set. Enter API key: " DOCENT_API_KEY
    export DOCENT_API_KEY
  fi
  COLLECTION="${DOCENT_COLLECTION:-non-ml-reproducibility}"

  ssh_remote "export DOCENT_API_KEY='$DOCENT_API_KEY'; python3 '$RCT_DIR/upload_non_ml_to_docent.py' \
    --master-log '$MASTER_LOG' \
    --collection-name '$COLLECTION'" && echo "[$(ts)] Upload complete." || echo "[$(ts)] ERROR: Upload failed."
fi

echo ""
echo "[$(ts)] >> RunPod session finished. No remote container teardown step is needed."
