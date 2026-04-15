#!/bin/bash
# start-session.sh — Auto-invoked on first interactive terminal connection.
# Reads env vars (set via RunPod template or prompted interactively),
# captures system info, starts timer/logging, and sets up finish-session.
#
# This script is sourced from .bashrc, so it runs in the user's shell context.

# ── Guard: only run once per pod lifecycle ───────────────────
GUARD="/tmp/.rct_session_started"
if [ -f "$GUARD" ]; then
    return 0 2>/dev/null || exit 0
fi

LOG_DIR="/workspace/logs"
RCT_DIR="/opt/rct"
mkdir -p "$LOG_DIR"

ts() { date +%Y-%m-%dT%H:%M:%S; }

echo ""
echo "==== Reproducibility Evaluation Session ===="
echo ""

# ── Prompt for required env vars if not set via RunPod template ──
if [ -z "$PAPER_NAME" ]; then
    read -p "Enter Paper Name (exact title): " PAPER_NAME
    export PAPER_NAME
fi
if [ -z "$RESEARCHER" ]; then
    read -p "Enter Researcher Name: " RESEARCHER
    export RESEARCHER
fi
if [ -z "$CONDITION" ]; then
    echo "Select condition:"
    echo "  1) manual"
    echo "  2) ai-assisted"
    read -p "Choice [1/2]: " COND_CHOICE
    case "$COND_CHOICE" in
      1) CONDITION="manual" ;;
      2) CONDITION="ai-assisted" ;;
      *) echo "ERROR: Invalid choice. Enter 1 or 2." ; return 1 2>/dev/null || exit 1 ;;
    esac
    export CONDITION
fi
if [ -z "$DOCENT_API_KEY" ]; then
    read -p "DOCENT_API_KEY (leave blank to skip upload later): " DOCENT_API_KEY
    export DOCENT_API_KEY
fi
if [ -z "$DOCENT_COLLECTION" ]; then
    export DOCENT_COLLECTION="berkeley-pilot"
fi

# ── Session identifiers ─────────────────────────────────────
export RCT_SESSION_ID=$(date +%Y%m%d_%H%M%S)
SAFE_PAPER=$(echo "$PAPER_NAME" | tr ' ' '_' | tr -cd '[:alnum:]_-')
SAFE_RESEARCHER=$(echo "$RESEARCHER" | tr ' ' '_' | tr -cd '[:alnum:]_-')
export RCT_MASTER_LOG="$LOG_DIR/${SAFE_PAPER}_${SAFE_RESEARCHER}_${CONDITION}_${RCT_SESSION_ID}.log"

# ── Capture environment info ─────────────────────────────────
export RCT_ENV_JSON=$(python3 -c "
import json, subprocess
def run(cmd):
    try: return subprocess.check_output(cmd, shell=True, text=True, stderr=subprocess.DEVNULL).strip()
    except: return ''
print(json.dumps({
    'cpu':    run(\"grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs\"),
    'ram':    run(\"free -h | awk '/^Mem:/{print \\\$2}'\"),
    'gpu':    run('nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader 2>/dev/null'),
    'python': run('python3 --version'),
    'r':      run('R --version 2>/dev/null | head -1'),
}))
" 2>/dev/null)

echo ""
echo "============================================================"
echo "Paper     : $PAPER_NAME"
echo "Researcher: $RESEARCHER"
echo "Condition : $CONDITION"
echo "Session ID: $RCT_SESSION_ID"
echo "Log       : $RCT_MASTER_LOG"
echo "============================================================"

{
  echo "[$(ts)] ENV INFO"
  echo "$RCT_ENV_JSON" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for k,v in d.items(): print(f'  {k}: {v}')
" 2>/dev/null || echo "$RCT_ENV_JSON"
} | tee "$RCT_MASTER_LOG"

# ── Start timer ──────────────────────────────────────────────
export RCT_START_EPOCH=$(date +%s)
echo "[$(ts)] START [paper=$PAPER_NAME] [researcher=$RESEARCHER] [condition=$CONDITION]" | tee -a "$RCT_MASTER_LOG"
echo ""

if [ "$CONDITION" = "ai-assisted" ]; then
    echo "Hints:"
    echo "  codex --dangerously-bypass-approvals-and-sandbox"
    echo ""
fi

echo "Type 'finish-session' when done to stop timing and upload to Docent."
echo ""

touch "$GUARD"

# ── Log CLI commands for manual sessions ────────────────────
if [ "$CONDITION" = "manual" ]; then
    export RCT_SESSION_REC="/tmp/session_recording_${RCT_SESSION_ID}.txt"
    _rct_log_cmd() {
        local cmd
        cmd=$(history 1 | sed 's/^ *[0-9]* *//')
        echo "$(date +%Y-%m-%dT%H:%M:%S) \$ $cmd" >> "$RCT_SESSION_REC"
    }
    PROMPT_COMMAND="_rct_log_cmd${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
fi
