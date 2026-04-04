#!/usr/bin/env python3
"""Upload a Codex CLI rollout JSONL file to a Docent collection.

Usage:
    python upload_codex_to_docent.py --path /path/to/rollout.jsonl --collection-name my-collection

The script will reuse an existing collection with the given name, or create one if it doesn't exist.
DOCENT_API_KEY must be set in the environment.
"""
from __future__ import annotations

import argparse
import json
import os
from collections import Counter
from pathlib import Path

from docent import Docent
from docent.data_models import AgentRun, Transcript
from docent.data_models.chat import (
    AssistantMessage,
    SystemMessage,
    ToolCall,
    ToolMessage,
    UserMessage,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Upload a Codex CLI rollout JSONL to Docent.")
    parser.add_argument("--path", type=Path, required=True, help="Path to the rollout .jsonl file.")
    parser.add_argument("--collection-name", required=True, help="Docent collection name to upload into (created if absent).")
    parser.add_argument("--dry-run", action="store_true", help="Convert and validate without uploading.")
    parser.add_argument("--tag", help="Custom tag to attach to the run metadata.")
    return parser.parse_args()


def _attach_tool_call(messages: list, tc: ToolCall, timestamp: str | None = None) -> None:
    if messages and isinstance(messages[-1], AssistantMessage):
        messages[-1].tool_calls = (messages[-1].tool_calls or []) + [tc]
    else:
        meta = {"timestamp": timestamp} if timestamp else None
        messages.append(AssistantMessage(content="[tool call]", tool_calls=[tc], metadata=meta))


def convert(path: Path, tag: str | None = None) -> AgentRun:
    records = [json.loads(l) for l in path.open()]

    # --- Extract metadata from source ---
    session_meta = next((r["payload"] for r in records if r.get("type") == "session_meta"), {})
    turn_contexts = [r["payload"] for r in records if r.get("type") == "turn_context"]
    first_turn = turn_contexts[0] if turn_contexts else {}

    ri_types = Counter(
        r["payload"].get("type")
        for r in records
        if r.get("type") == "response_item" and isinstance(r.get("payload"), dict)
    )
    step_count = ri_types.get("function_call", 0) + ri_types.get("web_search_call", 0)

    # --- Build transcript ---
    messages: list = []
    tool_name_by_call_id: dict[str, str] = {}
    pending_web_searches: list[str] = []

    for i, rec in enumerate(records):
        rtype = rec.get("type")
        payload = rec.get("payload")
        if not isinstance(payload, dict):
            continue
        ptype = payload.get("type")
        ts = rec.get("timestamp")
        meta = {"timestamp": ts} if ts else None

        if rtype == "response_item" and ptype == "message":
            role = payload.get("role")
            raw_content = payload.get("content", "")
            if isinstance(raw_content, list):
                text = "\n".join(
                    b.get("text", "") for b in raw_content
                    if b.get("type") in ("input_text", "output_text", "text")
                )
            else:
                text = str(raw_content)

            if role == "developer":
                messages.append(SystemMessage(content=text, metadata=meta))
            elif role == "user":
                messages.append(UserMessage(content=text, metadata=meta))
            elif role == "assistant":
                messages.append(AssistantMessage(content=text, metadata=meta))

        elif rtype == "response_item" and ptype == "reasoning":
            pass  # encrypted — omitted

        elif rtype == "response_item" and ptype == "function_call":
            call_id = payload.get("call_id") or f"call-line-{i}"
            name = payload.get("name", "unknown_tool")
            tool_name_by_call_id[call_id] = name
            try:
                args = json.loads(payload.get("arguments", "{}"))
                if not isinstance(args, dict):
                    args = {"value": args}
            except json.JSONDecodeError:
                args = {"raw_arguments": payload.get("arguments", "")}
            _attach_tool_call(messages, ToolCall(id=call_id, function=name, arguments=args, type="function"), timestamp=ts)

        elif rtype == "response_item" and ptype == "function_call_output":
            call_id = payload.get("call_id") or f"tool-out-line-{i}"
            content = payload.get("output", "")
            if not isinstance(content, str):
                content = json.dumps(content)
            messages.append(ToolMessage(
                content=content,
                tool_call_id=call_id,
                function=tool_name_by_call_id.get(call_id),
                metadata=meta,
            ))

        elif rtype == "response_item" and ptype == "web_search_call":
            synthetic_id = f"web-search-line-{i}"
            pending_web_searches.append(synthetic_id)
            _attach_tool_call(messages, ToolCall(
                id=synthetic_id,
                function="web_search",
                arguments={"status": payload.get("status"), "action": payload.get("action", {})},
                type="function",
            ), timestamp=ts)

        elif rtype == "event_msg" and ptype == "web_search_end":
            real_id = payload.get("call_id")
            synthetic_id = pending_web_searches.pop(0) if pending_web_searches else real_id
            messages.append(ToolMessage(
                content=json.dumps({"query": payload.get("query"), "action": payload.get("action")}),
                tool_call_id=real_id or synthetic_id,
                function="web_search",
                metadata=meta,
            ))
        # All other event_msg types are operational metadata — omitted

    run_id = session_meta.get("id", path.stem)
    run_name = path.stem

    return AgentRun(
        id=run_id,
        name=run_name,
        description="Codex CLI rollout imported from JSONL.",
        transcripts=[Transcript(messages=messages)],
        metadata={
            "source_format": "codex_cli_rollout_jsonl",
            "source_path": str(path),
            "agent_name": "codex-cli",
            "model": first_turn.get("model"),
            "run_id": run_id,
            "message_count": len(messages),
            "step_count": step_count,
            "cli_version": session_meta.get("cli_version"),
            "approval_policy": first_turn.get("approval_policy"),
            **({"tag": tag} if tag is not None else {}),
        },
    )


def resolve_collection(client: Docent, name: str) -> str:
    for col in client.list_collections():
        if col.get("name") == name:
            print(f"Reusing existing collection '{name}': {col['id']}")
            return col["id"]
    cid = client.create_collection(name=name, description="Codex CLI rollout imports")
    print(f"Created new collection '{name}': {cid}")
    return cid


def main() -> None:
    args = parse_args()

    if not args.path.exists():
        raise SystemExit(f"File not found: {args.path}")

    print(f"Converting {args.path.name}...")
    agent_run = convert(args.path, tag=args.tag)
    msgs = agent_run.transcripts[0].messages
    print(f"  {len(msgs)} messages, {agent_run.metadata['step_count']} tool steps")
    print(f"  model: {agent_run.metadata['model']}")

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
