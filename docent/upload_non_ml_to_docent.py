#!/usr/bin/env python3
"""Upload a non-ML CLI session log to a Docent collection.

Reads the master log (and optionally the session log) produced by lambda-non-ml.sh
and uploads them as an AgentRun to Docent.

Usage:
    python upload_non_ml_to_docent.py --master-log logs/paper_alice_manual_20260406.log
    python upload_non_ml_to_docent.py --master-log logs/paper_alice_manual_20260406.log \
                                       --session-log logs/paper_alice_manual_20260406_session.log \
                                       --collection-name "my-study"

DOCENT_API_KEY must be set in the environment.
"""
from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

from docent import Docent
from docent.data_models import AgentRun, Transcript
from docent.data_models.chat import UserMessage, AssistantMessage


def strip_ansi(text: str) -> str:
    return re.sub(r"\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])", "", text)


def parse_master_log(path: Path) -> dict:
    meta = {"paper": "", "researcher": "", "condition": "",
            "start_time": None, "end_time": None, "duration_s": None,
            "env_info": [], "status": "complete", "session_recording": None}

    in_env = False
    in_recording = False
    recording_lines = []

    with open(path) as f:
        for line in f:
            line = line.rstrip()
            if line == "--- SESSION RECORDING ---":
                in_recording = True
                in_env = False
                continue
            if in_recording:
                recording_lines.append(line)
                continue
            if "] ENV INFO" in line:
                in_env = True
                continue
            if in_env:
                if line.startswith("[") and "] " in line and not line.startswith("[---"):
                    in_env = False
                else:
                    meta["env_info"].append(line)
                    continue
            if "] START " in line:
                m = re.match(r"\[(.+?)\]", line)
                if m:
                    meta["start_time"] = m.group(1)
                for field in ["paper", "researcher", "condition"]:
                    fm = re.search(rf"\[{field}=([^\]]+)\]", line)
                    if fm:
                        meta[field] = fm.group(1)
            elif "] END " in line:
                m = re.match(r"\[(.+?)\]", line)
                if m:
                    meta["end_time"] = m.group(1)
                dm = re.search(r"duration=(\d+)s", line)
                if dm:
                    meta["duration_s"] = int(dm.group(1))
            elif "] INTERRUPTED" in line:
                meta["status"] = "interrupted"
                dm = re.search(r"duration=(\d+)s", line)
                if dm:
                    meta["duration_s"] = int(dm.group(1))

    if recording_lines:
        meta["session_recording"] = "\n".join(recording_lines).strip()

    return meta


def parse_recording_into_messages(recording: str) -> list:
    """Parse cleaned script recording into UserMessage/AssistantMessage pairs.

    Each prompt line (user@host:path# cmd) becomes a UserMessage.
    Any output between prompts becomes an AssistantMessage.
    Stops before finish-session output.
    """
    messages = []
    # Match prompt: optional (env) user@host:path[#$] command
    prompt_re = re.compile(r'^(?:\([^)]+\)\s+)?\S+@\S+:[^#\$]*[#\$]\s*(.*)')

    current_cmd = None
    output_lines = []

    for line in recording.splitlines():
        m = prompt_re.match(line)
        if m:
            # Flush previous command + output
            if current_cmd is not None:
                if current_cmd.strip() == 'finish-session':
                    break
                if current_cmd.strip():
                    messages.append(UserMessage(content=current_cmd.strip()))
                    output = '\n'.join(output_lines).strip()
                    if output:
                        messages.append(AssistantMessage(content=output))
            current_cmd = m.group(1)
            output_lines = []
        elif current_cmd is not None:
            output_lines.append(line)

    # Handle last command
    if current_cmd and current_cmd.strip() and current_cmd.strip() != 'finish-session':
        messages.append(UserMessage(content=current_cmd.strip()))
        output = '\n'.join(output_lines).strip()
        if output:
            messages.append(AssistantMessage(content=output))

    return messages


def build_agent_run(meta: dict, master_log: Path) -> AgentRun:
    messages = [UserMessage(content=f"Reproduce the paper: {meta['paper']}")]
    recording = meta.get("session_recording")
    if recording:
        cmd_messages = parse_recording_into_messages(recording)
        messages.extend(cmd_messages)

    # Count user commands (UserMessages minus the initial prompt)
    cli_count = sum(1 for m in messages if isinstance(m, UserMessage)) - 1

    return AgentRun(
        name=master_log.stem,
        description=f"Non-ML manual reproducibility session for: {meta['paper']}",
        transcripts=[Transcript(messages=messages)],
        metadata={
            "paper": meta["paper"] or "none",
            "researcher": meta["researcher"] or "none",
            "condition": meta["condition"] or "none",
            "status": meta["status"],
            "start_time": meta["start_time"] or "none",
            "end_time": meta["end_time"] or "none",
            "duration_seconds": meta["duration_s"],
            "message_count": len(messages),
            "step_count": cli_count,
            "agent_name": "human",
            "model": "none",
            "env_info": "\n".join(meta["env_info"]).strip() or "none",
            "source_log": str(master_log),
        },
    )


def resolve_collection(client: Docent, name: str) -> str:
    for col in client.list_collections():
        if col.get("name") == name:
            print(f"Reusing existing collection '{name}': {col['id']}")
            return col["id"]
    cid = client.create_collection(name=name, description="Non-ML reproducibility sessions")
    print(f"Created new collection '{name}': {cid}")
    return cid


def main() -> None:
    parser = argparse.ArgumentParser(description="Upload non-ML session log to Docent.")
    parser.add_argument("--master-log", required=True, type=Path)
    parser.add_argument("--collection-name", default="non-ml-reproducibility")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    master_log = args.master_log.expanduser()
    if not master_log.exists():
        raise SystemExit(f"Master log not found: {master_log}")

    meta = parse_master_log(master_log)

    agent_run = build_agent_run(meta, master_log)

    print(f"Paper     : {meta['paper']}")
    print(f"Researcher: {meta['researcher']}")
    print(f"Duration  : {meta['duration_s']}s")
    print(f"Status    : {meta['status']}")
    print(f"Env info  : {'yes' if meta['env_info'] else 'no'}")
    recording = meta.get("session_recording")
    cmd_count = sum(1 for m in agent_run.transcripts[0].messages if isinstance(m, UserMessage)) - 1
    print(f"Recording : {'yes' if recording else 'no'} ({cmd_count} CLI commands)")

    if args.dry_run:
        print("Dry run — skipping upload.")
        return

    if not os.environ.get("DOCENT_API_KEY"):
        raise SystemExit("DOCENT_API_KEY is not set.")

    client = Docent()
    collection_id = resolve_collection(client, args.collection_name)
    client.add_agent_runs(collection_id, [agent_run], wait=True)
    print(f"Uploaded. View at: {client.frontend_url}/collection/{collection_id}")


if __name__ == "__main__":
    main()
