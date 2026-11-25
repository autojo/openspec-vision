#!/usr/bin/env python3
"""boss-model -- read-only model and usage adapters for the boss runtime.

The ACP supervisor reads the model and effort from the agent's own session
configuration before the first prompt (see boss_acp.py). A native agent has no
such channel: its model is only visible in the record the agent writes while it
works. This module reads that record after the first answer and reports what it
found, without ever starting or prompting an agent itself.

Usage:
  boss_model.py native-confirm --runner <json> --state <state-file|-> \
      [--since <iso>] [--session-id <id>] [--claude-dir <dir>] [--json]

Output is one compact JSON object on stdout:
  {status, source, model, effort, seen, cost_usd, tokens, message}

status is one of:
  confirmed     a record named the declared model (and effort when declared)
  mismatch      a record named another model or effort
  unverifiable  no readable record, an unknown format or an unsupported kind

The adapters are read-only. They never send a prompt and never write the
agent's store.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import re
import subprocess
import sys
import time


def result(status: str, **fields) -> dict:
    base = {
        "status": status,
        "source": None,
        "model": None,
        "effort": None,
        "seen": [],
        "cost_usd": None,
        "tokens": None,
        "message": "",
    }
    base.update(fields)
    return base


def epoch_of_iso(value: str) -> float | None:
    if not value:
        return None
    try:
        return time.mktime(time.strptime(value[:19], "%Y-%m-%dT%H:%M:%S"))
    except (ValueError, OverflowError):
        return None


def read_runner(path: str, raw: str = "") -> dict:
    if raw:
        try:
            data = json.loads(raw)
            return data if isinstance(data, dict) else {}
        except json.JSONDecodeError:
            return {}
    if not path or path == "-":
        return {}
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, json.JSONDecodeError):
        return {}


def read_state(path: str) -> dict:
    return read_runner(path)


def model_name(value) -> str | None:
    if value is None:
        return None
    if isinstance(value, str):
        return value.strip() or None
    if isinstance(value, dict):
        for key in ("id", "modelID", "modelId", "model", "name"):
            if value.get(key):
                return str(value[key])
    return None


def is_synthetic(record: dict) -> bool:
    if record.get("isSynthetic") is True or record.get("synthetic") is True:
        return True
    kind = str(record.get("type") or "").lower()
    if kind in ("summary", "system"):
        return True
    message = record.get("message")
    if isinstance(message, dict):
        if message.get("model") == "<synthetic>":
            return True
        if message.get("isSynthetic") is True:
            return True
        content = message.get("content")
        if isinstance(content, str) and "<synthetic>" in content:
            return True
    text = json.dumps(record)
    return "<synthetic>" in text


def token_total(usage: dict) -> int | None:
    if not isinstance(usage, dict):
        return None
    total = 0
    found = False
    for key in (
        "input_tokens",
        "output_tokens",
        "cache_creation_input_tokens",
        "cache_read_input_tokens",
        "inputTokens",
        "outputTokens",
        "input",
        "output",
        "total",
    ):
        value = usage.get(key)
        if isinstance(value, (int, float)):
            total += int(value)
            found = True
    return total if found else None


def claude_candidates(root: str, since: float | None) -> list[str]:
    files: list[tuple[float, str]] = []
    for path in glob.iglob(os.path.join(root, "**", "*.jsonl"), recursive=True):
        try:
            mtime = os.path.getmtime(path)
        except OSError:
            continue
        if since is not None and mtime + 1 < since:
            continue
        files.append((mtime, path))
    files.sort(reverse=True)
    return [path for _, path in files]


def read_claude_record(root: str, since: float | None) -> dict:
    """Read the newest Claude transcript that names a model.

    A transcript records the model per assistant message. A long session can
    contain a secondary model and `<synthetic>` entries; synthetic entries are
    ignored, the most frequent remaining model is the main model and every
    other model is reported as seen.
    """
    if not root or not os.path.isdir(root):
        return result("unverifiable", message=f"no Claude transcript directory at {root or '~/.claude/projects'}")
    for path in claude_candidates(root, since):
        counts: dict[str, int] = {}
        order: list[str] = []
        tokens = 0
        has_tokens = False
        try:
            with open(path, encoding="utf-8", errors="replace") as handle:
                for line in handle:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        record = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if not isinstance(record, dict) or is_synthetic(record):
                        continue
                    message = record.get("message")
                    name = None
                    if isinstance(message, dict):
                        name = model_name(message.get("model"))
                    if not name:
                        name = model_name(record.get("model"))
                    if not name:
                        continue
                    counts[name] = counts.get(name, 0) + 1
                    if name not in order:
                        order.append(name)
                    usage = {}
                    if isinstance(message, dict):
                        usage = message.get("usage") or {}
                    elif isinstance(record.get("usage"), dict):
                        usage = record["usage"]
                    total = token_total(usage)
                    if total is not None:
                        tokens += total
                        has_tokens = True
        except OSError as exc:
            return result("unverifiable", message=f"cannot read {path}: {exc}")
        if not counts:
            continue
        main = max(order, key=lambda name: counts.get(name, 0))
        return result(
            "confirmed",
            source="claude_transcript",
            model=main,
            seen=order,
            tokens=tokens if has_tokens else None,
            message=f"read {sum(counts.values())} model entries from {path}",
        )
    return result("unverifiable", source="claude_transcript", message="no Claude transcript with a model entry")


def opencode_session(session_id: str, timeout: float = 20.0) -> dict | None:
    try:
        proc = subprocess.run(
            ["opencode", "api", "get", f"/api/session/{session_id}"],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if proc.returncode != 0 or not proc.stdout.strip():
        return None
    try:
        data = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return None
    if isinstance(data, dict) and isinstance(data.get("result"), dict):
        data = data["result"]
    return data if isinstance(data, dict) else None


def read_opencode_record(session_id: str) -> dict:
    if not session_id:
        return result("unverifiable", source="opencode_session", message="no OpenCode session id is known for the apply")
    data = opencode_session(session_id)
    if data is None:
        return result("unverifiable", source="opencode_session", message=f"opencode api returned no session {session_id}")
    info = data.get("session") if isinstance(data.get("session"), dict) else data
    if isinstance(info.get("info"), dict):
        info = info["info"]
    model = model_name(info.get("model"))
    if not model:
        for key in ("modelID", "model_id", "modelId"):
            model = model_name(info.get(key))
            if model:
                break
    seen: list[str] = []
    for key in ("models", "seen", "children", "child_sessions"):
        value = info.get(key)
        if isinstance(value, list):
            for entry in value:
                name = model_name(entry)
                if name and name not in seen:
                    seen.append(name)
    if model and model not in seen:
        seen.insert(0, model)
    usage = info.get("usage") if isinstance(info.get("usage"), dict) else {}
    tokens = token_total(info.get("tokens") or usage)
    cost = None
    for key in ("cost", "cost_usd", "costUSD", "total_cost"):
        value = info.get(key)
        if isinstance(value, (int, float)):
            cost = float(value)
            break
    if cost is None:
        for key in ("cost", "cost_usd", "costUSD"):
            value = usage.get(key)
            if isinstance(value, (int, float)):
                cost = float(value)
                break
    effort = info.get("variant") or usage.get("variant")
    if not model:
        return result("unverifiable", source="opencode_session", message="the OpenCode session record names no model")
    return result(
        "confirmed",
        source="opencode_session",
        model=model,
        effort=str(effort) if effort else None,
        seen=seen,
        cost_usd=cost,
        tokens=tokens,
        message=f"read OpenCode session {session_id}",
    )


def confirm(declared: str | None, effort_declared: str | None, record: dict) -> dict:
    status = str(record.get("status") or "unverifiable")
    if status != "confirmed" or not declared:
        return record
    model = record.get("model")
    effort = record.get("effort")
    if model != declared:
        record["status"] = "mismatch"
        record["message"] = f"declared model {declared!r}, the session record names {model!r}"
        return record
    if effort_declared and effort and effort != effort_declared:
        record["status"] = "mismatch"
        record["message"] = f"declared effort {effort_declared!r}, the session record names {effort!r}"
        return record
    record["status"] = "confirmed"
    record["message"] = f"the session record names {model}"
    return record


def cmd_native_confirm(args) -> int:
    runner = read_runner(args.runner, args.runner_json)
    state = read_state(args.state)
    model_obj = state.get("model") if isinstance(state.get("model"), dict) else {}
    declared = model_obj.get("declared") or (state.get("acp") or {}).get("model")
    effort_declared = model_obj.get("effort_declared")
    if not declared:
        declared = runner.get("model")
    since = epoch_of_iso(args.since) if args.since else None
    if since is None:
        since = epoch_of_iso(str(state.get("started_at") or ""))
    start = runner.get("start") or "herdr"
    kind = runner.get("kind") or ("" if start == "acp" else start)
    if start == "acp":
        out = result("unverifiable", message="the ACP transport confirms in the supervisor, not in a session record")
    elif kind == "claude":
        root = args.claude_dir or os.environ.get("BOSS_CLAUDE_PROJECTS_DIR") or os.path.join(
            os.path.expanduser("~"), ".claude", "projects"
        )
        out = read_claude_record(root, since)
        out = confirm(declared, effort_declared, out)
    elif kind == "opencode":
        session_id = (
            args.session_id
            or state.get("session_id")
            or state.get("native_session_id")
            or state.get("opencode_session_id")
            or ""
        )
        out = read_opencode_record(str(session_id))
        # The OpenCode session API is a detection path only: it can show that
        # another model ran, but it cannot make a declaration true or false in
        # advance, so a matching record stays "confirmed" only for quota models.
        out = confirm(declared, effort_declared, out)
    else:
        out = result("unverifiable", message=f"no session-record adapter for kind {kind or 'unknown'}")
    json.dump(out, sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="boss model adapters")
    sub = parser.add_subparsers(dest="command", required=True)
    native = sub.add_parser("native-confirm", help="read the model from a native session record")
    native.add_argument("--runner", default="")
    native.add_argument("--runner-json", default="")
    native.add_argument("--state", default="")
    native.add_argument("--since", default="")
    native.add_argument("--session-id", default="")
    native.add_argument("--claude-dir", default="")
    native.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    if args.command == "native-confirm":
        return cmd_native_confirm(args)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
