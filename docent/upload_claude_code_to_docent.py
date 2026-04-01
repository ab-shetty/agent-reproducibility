#!/usr/bin/env python3
"""Upload a Claude Code conversation JSONL file to a Docent collection.

Claude Code stores conversations as JSONL files under:
    ~/.claude/projects/<project-hash>/<session-id>.jsonl

Usage:
    python upload_claude_code_to_docent.py --path ~/.claude/projects/-content/<session-id>.jsonl --collection-name my-collection

    # Or auto-detect the most recent conversation in a project directory:
    python upload_claude_code_to_docent.py --latest --collection-name my-collection

The script will reuse an existing collection with the given name, or create one if it doesn't exist.
DOCENT_API_KEY must be set in the environment.
"""
from __future__ import annotations

import argparse
import json
import os
from collections import defaultdict
from pathlib import Path

from docent import Docent
from docent.data_models import AgentRun, Transcript
from docent.data_models.chat import (
    AssistantMessage,
    ToolCall,
    ToolMessage,
    UserMessage,
)

# Claude Code project directory for the current working directory
DEFAULT_PROJECT_DIR = Path.home() / ".claude" / "projects" / "-content"

# Anthropic pricing for estimated_cost (per million tokens)
_PRICE_INPUT = 3.0
_PRICE_OUTPUT = 15.0
_PRICE_CACHE_WRITE = 3.75
_PRICE_CACHE_READ = 0.30


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Upload a Claude Code conversation JSONL to Docent.")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--path", type=Path, help="Path to the conversation .jsonl file.")
    group.add_argument("--latest", action="store_true", help="Auto-detect the most recently modified conversation in ~/.claude/projects/-content/.")
    parser.add_argument("--collection-name", required=True, help="Docent collection name to upload into (created if absent).")
    parser.add_argument("--dry-run", action="store_true", help="Convert and validate without uploading.")
    return parser.parse_args()


def find_latest_conversation(project_dir: Path) -> Path:
    """Return the most recently modified top-level conversation JSONL in the project dir."""
    candidates = [
        p for p in project_dir.glob("*.jsonl")
        if not p.name.startswith(".")
    ]
    if not candidates:
        raise SystemExit(f"No conversation JSONL files found in {project_dir}")
    return max(candidates, key=lambda p: p.stat().st_mtime)


def _estimate_cost(usage: dict) -> float:
    """Estimate USD cost from aggregated token usage for Claude models."""
    return round(
        (
            usage.get("input_tokens", 0) * _PRICE_INPUT
            + usage.get("cache_creation_input_tokens", 0) * _PRICE_CACHE_WRITE
            + usage.get("cache_read_input_tokens", 0) * _PRICE_CACHE_READ
            + usage.get("output_tokens", 0) * _PRICE_OUTPUT
        ) / 1_000_000,
        4,
    )


def convert(path: Path) -> AgentRun:
    records = [json.loads(l) for l in path.open()]

    # --- Extract metadata from source ---
    session_id = next(
        (rec.get("sessionId") for rec in records if rec.get("sessionId")),
        path.stem,
    )
    first_user = next((r for r in records if r.get("type") == "user"), {})
    version = first_user.get("version")

    # Model: take from first assistant message that has one
    model = next(
        (r["message"].get("model") for r in records
         if r.get("type") == "assistant" and r.get("message", {}).get("model")),
        None,
    )

    # Aggregate token usage across all assistant turns
    usage: dict = defaultdict(int)
    for rec in records:
        if rec.get("type") == "assistant":
            for k, v in rec.get("message", {}).get("usage", {}).items():
                if isinstance(v, (int, float)):
                    usage[k] += v

    # --- Build transcript ---
    messages: list = []
    step_count = 0

    for rec in records:
        rtype = rec.get("type")
        if rtype not in ("user", "assistant"):
            continue  # file-history-snapshot, last-prompt — omit

        msg = rec.get("message", {})
        role = msg.get("role")
        content = msg.get("content", "")

        if role == "user":
            if isinstance(content, str):
                if content.strip():
                    messages.append(UserMessage(content=content))
            elif isinstance(content, list):
                tool_results = [b for b in content if b.get("type") == "tool_result"]
                text_blocks = [b for b in content if b.get("type") == "text"]

                for tr in tool_results:
                    tr_content = tr.get("content", "")
                    if isinstance(tr_content, list):
                        tr_content = "\n".join(
                            b.get("text", "") for b in tr_content if b.get("type") == "text"
                        )
                    elif not isinstance(tr_content, str):
                        tr_content = json.dumps(tr_content)
                    messages.append(ToolMessage(
                        content=tr_content,
                        tool_call_id=tr.get("tool_use_id"),
                        function=None,
                    ))

                if text_blocks:
                    text = "\n".join(b.get("text", "") for b in text_blocks).strip()
                    if text:
                        messages.append(UserMessage(content=text))

        elif role == "assistant":
            if isinstance(content, str):
                if content.strip():
                    messages.append(AssistantMessage(content=content))
            elif isinstance(content, list):
                text_parts = []
                tool_calls = []

                for b in content:
                    btype = b.get("type")
                    if btype == "text":
                        text_parts.append(b.get("text", ""))
                    elif btype == "tool_use":
                        step_count += 1
                        raw_input = b.get("input", "{}")
                        if isinstance(raw_input, str):
                            try:
                                args = json.loads(raw_input)
                                if not isinstance(args, dict):
                                    args = {"value": args}
                            except json.JSONDecodeError:
                                args = {"raw_input": raw_input}
                        else:
                            args = raw_input if isinstance(raw_input, dict) else {"value": raw_input}
                        tool_calls.append(ToolCall(
                            id=b.get("id", ""),
                            function=b.get("name", "unknown"),
                            arguments=args,
                            type="function",
                        ))
                    # thinking blocks — omit

                text = "\n".join(text_parts).strip() or ("[tool call]" if tool_calls else "")
                if text or tool_calls:
                    messages.append(AssistantMessage(
                        content=text,
                        tool_calls=tool_calls or None,
                    ))

    estimated_cost = _estimate_cost(usage) if usage else None

    return AgentRun(
        id=session_id,
        name=path.stem,
        description="Claude Code conversation imported from JSONL.",
        transcripts=[Transcript(messages=messages)],
        metadata={
            "source_format": "claude_code_jsonl",
            "source_path": str(path),
            "agent_name": "claude-code",
            "model": model,
            "run_id": session_id,
            "message_count": len(messages),
            "step_count": step_count,
            "version": version,
            **({"estimated_cost": estimated_cost} if estimated_cost is not None else {}),
            **({"token_usage": dict(usage)} if usage else {}),
        },
    )


def resolve_collection(client: Docent, name: str) -> str:
    for col in client.list_collections():
        if col.get("name") == name:
            print(f"Reusing existing collection '{name}': {col['id']}")
            return col["id"]
    cid = client.create_collection(name=name, description="Claude Code conversation imports")
    print(f"Created new collection '{name}': {cid}")
    return cid


def main() -> None:
    args = parse_args()

    if args.latest:
        path = find_latest_conversation(DEFAULT_PROJECT_DIR)
        print(f"Auto-detected: {path}")
    else:
        path = args.path.expanduser()

    if not path.exists():
        raise SystemExit(f"File not found: {path}")

    print(f"Converting {path.name}...")
    agent_run = convert(path)
    msgs = agent_run.transcripts[0].messages
    meta = agent_run.metadata
    print(f"  {len(msgs)} messages, {meta['step_count']} tool steps")
    print(f"  model: {meta.get('model')}")
    if meta.get("estimated_cost") is not None:
        print(f"  estimated cost: ${meta['estimated_cost']}")

    # Validate
    from docent.data_models.agent_run import AgentRunView
    _ = AgentRunView.from_agent_run(agent_run).to_text()
    print("  Validation: OK")

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
