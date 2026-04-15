#!/bin/bash
# finish-session.sh — Stops the session timer, writes sidecar metadata,
# and handles Docent upload for all conditions (manual, codex, claude-code).
#
# Intended to be run as a command: `finish-session`

set -e

if [ -z "$RCT_START_EPOCH" ]; then
    echo "ERROR: No active session found."
    echo "       The session is started automatically when you first connect."
    echo "       If the pod was restarted, session state was lost."
    exit 1
fi

RCT_DIR="/opt/rct"

ts() { date +%Y-%m-%dT%H:%M:%S; }

END_EPOCH=$(date +%s)
DURATION=$(( END_EPOCH - RCT_START_EPOCH ))

echo "[$(ts)] END | duration=${DURATION}s" | tee -a "$RCT_MASTER_LOG"

# ── Append session recording for manual runs ────────────────
if [ "$CONDITION" = "manual" ] && [ -n "$RCT_SESSION_REC" ] && [ -f "$RCT_SESSION_REC" ]; then
    {
        echo ""
        echo "--- SESSION RECORDING ---"
        cat "$RCT_SESSION_REC"
    } >> "$RCT_MASTER_LOG"
fi

# ── Write sidecar metadata ───────────────────────────────────
START_TIME=$(date -d @$RCT_START_EPOCH +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -r $RCT_START_EPOCH +%Y-%m-%dT%H:%M:%S 2>/dev/null || echo "")

python3 - <<PYEOF
import json
data = {
    'paper': '$PAPER_NAME',
    'researcher': '$RESEARCHER',
    'condition': '$CONDITION',
    'session_id': '$RCT_SESSION_ID',
    'start_time': '$START_TIME',
    'end_time': '$(ts)',
    'duration_seconds': $DURATION,
    'status': 'complete',
    'provider': 'runpod',
    'env': $RCT_ENV_JSON,
}
with open('/tmp/session_meta.json', 'w') as f:
    json.dump(data, f, indent=2)
PYEOF

echo ""
echo "Session complete. Duration: ${DURATION}s"
echo "Log: $RCT_MASTER_LOG"

# ── Docent upload ─────────────────────────────────────────────
if [ -z "$DOCENT_API_KEY" ]; then
    echo ""
    echo "DOCENT_API_KEY not set — skipping upload."
    echo "To upload later, set DOCENT_API_KEY and run the appropriate upload script manually:"
    echo "  python3 $RCT_DIR/upload_non_ml_to_docent.py --master-log $RCT_MASTER_LOG --collection-name $DOCENT_COLLECTION"
    exit 0
fi

echo ""
read -p "Upload session to Docent? [y/N]: " UPLOAD
if [[ ! "$UPLOAD" =~ ^[Yy]$ ]]; then
    echo "Skipping upload."
    exit 0
fi

COLLECTION="${DOCENT_COLLECTION:-berkeley-pilot}"

if [ "$CONDITION" = "ai-assisted" ]; then
    UPLOADED=0

    # ── Try Codex rollouts ────────────────────────────────────
    CODEX_JSONL=$(python3 -c "
from pathlib import Path
import os
root = Path(os.path.expanduser('~')) / '.codex' / 'sessions'
if root.exists():
    files = sorted(root.rglob('rollout-*.jsonl'), key=lambda p: p.stat().st_mtime)
    if files: print(files[-1])
" 2>/dev/null)

    if [ -n "$CODEX_JSONL" ]; then
        echo "Found Codex rollout: $CODEX_JSONL"
        python3 "$RCT_DIR/upload_codex_to_docent.py" \
            --path "$CODEX_JSONL" \
            --collection-name "$COLLECTION" \
            --meta-sidecar /tmp/session_meta.json \
            && UPLOADED=$((UPLOADED + 1))
    fi

    # ── Try Claude Code conversations ─────────────────────────
    CC_JSONL=$(python3 -c "
from pathlib import Path
import os
root = Path(os.path.expanduser('~')) / '.claude' / 'projects'
if root.exists():
    files = sorted(root.rglob('*.jsonl'), key=lambda p: p.stat().st_mtime)
    # Filter out non-conversation files
    files = [f for f in files if not f.name.startswith('.')]
    if files: print(files[-1])
" 2>/dev/null)

    if [ -n "$CC_JSONL" ]; then
        echo "Found Claude Code conversation: $CC_JSONL"
        python3 "$RCT_DIR/upload_claude_code_to_docent.py" \
            --path "$CC_JSONL" \
            --collection-name "$COLLECTION" \
            && UPLOADED=$((UPLOADED + 1))
    fi

    if [ "$UPLOADED" -eq 0 ]; then
        echo "No AI agent rollouts found (checked ~/.codex/sessions and ~/.claude/projects)."
        echo "You can upload manually later if needed."
    else
        echo "[$(ts)] Uploaded $UPLOADED rollout(s) to '$COLLECTION'."
    fi

else
    # ── Manual (non-ML) session upload ────────────────────────
    python3 "$RCT_DIR/upload_non_ml_to_docent.py" \
        --master-log "$RCT_MASTER_LOG" \
        --collection-name "$COLLECTION" \
        && echo "[$(ts)] Upload complete." \
        || echo "[$(ts)] ERROR: Upload failed."
fi

# ── Clean up session state ────────────────────────────────────
rm -f /tmp/.rct_session_started
echo ""
echo "Session finished. Pod is still running — you can start a new session or stop the pod."
