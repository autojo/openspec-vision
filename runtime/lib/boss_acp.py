#!/usr/bin/env python3
"""boss-acp -- ACP supervisor for one boss apply.

The supervisor owns the ACP child and one turn at a time. It is started
detached by 'boss dispatch' and reads everything it needs from the apply state
file, so a retrigger, answer, interrupt or resume can reach it through the
per-apply Unix control socket without a second state machine.

Usage:
  boss_acp.py <state-file>
  boss_acp.py --probe <command> [--cwd DIR] [--model M] [--mode MODE]
              [--timeout S] [--profile-temp]
"""

from __future__ import annotations

import argparse
import asyncio
import fnmatch
import hashlib
import json
import os
import shlex
import shutil
import signal
import sys
import tempfile
import time

PROTOCOL_VERSION = 1

# Tools that must always reach the supervisor instead of being pre-approved by
# an agent-level permission store. Kept in both the user and the smart-approve
# section of the generated permission.yaml.
PERMISSION_ASK_TOOLS = (
    "shell",
    "write",
    "edit",
    "read_image",
    "extensionmanager__manage_extensions",
)


def now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S%z")


def log(message: str) -> None:
    line = f"{now_iso()} {message}\n"
    path = os.environ.get("BOSS_LOG_FILE", "")
    if path:
        try:
            with open(path, "a", encoding="utf-8") as handle:
                handle.write(line)
            return
        except OSError:
            pass
    sys.stderr.write(line)
    sys.stderr.flush()


def pid_alive(pid) -> bool:
    try:
        os.kill(int(pid), 0)
        return True
    except (TypeError, ValueError, ProcessLookupError, PermissionError):
        return False


def boss_state_dir() -> str:
    return os.environ.get(
        "BOSS_STATE_DIR",
        os.path.join(os.path.expanduser("~"), ".local", "state", "openspec-boss"),
    )


def user_config_home() -> str:
    return os.environ.get("XDG_CONFIG_HOME") or os.path.join(
        os.path.expanduser("~"), ".config"
    )


def user_data_home() -> str:
    return os.environ.get("XDG_DATA_HOME") or os.path.join(
        os.path.expanduser("~"), ".local", "share"
    )


def profile_root_for(state_path: str) -> str:
    """The per-apply agent profile root; the same state path always maps to the
    same root, so a supervisor restart reuses it."""
    key = hashlib.sha1(
        ("profile:" + os.path.abspath(state_path)).encode("utf-8")
    ).hexdigest()
    return os.path.join(boss_state_dir(), "acp", "profile-" + key)


def write_permission_store(path: str) -> None:
    lines = []
    for section in ("user", "smart_approve"):
        lines.append(f"{section}:")
        lines.append("  always_allow: []")
        lines.append("  never_allow: []")
        lines.append("  ask_before:")
        for tool in PERMISSION_ASK_TOOLS:
            lines.append(f"    - {tool}")
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")
    os.replace(tmp, path)


def link_entries(source: str, target: str, skip=()) -> None:
    if not os.path.isdir(source):
        return
    os.makedirs(target, exist_ok=True)
    for name in sorted(os.listdir(source)):
        if name in skip or name.endswith(".lock"):
            continue
        src = os.path.join(source, name)
        dst = os.path.join(target, name)
        if os.path.lexists(dst):
            continue
        os.symlink(src, dst)
        log(f"acp profile: linked {dst} -> {src}")


def build_agent_profile(root: str) -> str:
    """Create a boss-owned Goose profile below root and return it.

    Provider configuration and secrets are linked read-through, so the user's
    own setup keeps working. The permission store is generated here and never
    links the user's store, so no global grant can bypass the supervisor.
    """
    config_goose = os.path.join(root, "config", "goose")
    data_goose = os.path.join(root, "data", "goose")
    os.makedirs(config_goose, exist_ok=True)
    os.makedirs(os.path.join(data_goose, "sessions"), exist_ok=True)
    link_entries(
        os.path.join(user_config_home(), "goose"),
        config_goose,
        skip=("permission.yaml", "sessions", "logs"),
    )
    link_entries(
        os.path.join(user_data_home(), "goose"),
        data_goose,
        skip=("sessions",),
    )
    permission_path = os.path.join(config_goose, "permission.yaml")
    if not os.path.exists(permission_path):
        write_permission_store(permission_path)
        log(f"acp profile: wrote boss-owned permission store {permission_path}")
    return root


class AcpError(Exception):
    def __init__(self, code: str, message: str = "", data=None):
        super().__init__(message or code)
        self.code = code
        self.message = message or code
        self.data = data


class StateFile:
    """Atomic read-modify-write of the apply state with the bash lock."""

    def __init__(self, path: str):
        self.path = path
        self.state_dir = boss_state_dir()
        key = hashlib.sha1(os.path.abspath(path).encode("utf-8")).hexdigest()
        self.lock_dir = os.path.join(self.state_dir, "locks", key + ".lock")

    def read(self):
        with open(self.path, encoding="utf-8") as handle:
            return json.load(handle)

    def _holder_pid(self):
        try:
            with open(os.path.join(self.lock_dir, "pid"), encoding="utf-8") as handle:
                return handle.read().strip()
        except OSError:
            return ""

    def _lock_age(self) -> int:
        try:
            return int(time.time() - os.stat(self.lock_dir).st_mtime)
        except OSError:
            return 0

    def _acquire(self, timeout: float = 5.0) -> bool:
        deadline = time.time() + timeout
        while True:
            try:
                os.makedirs(self.lock_dir)
                try:
                    with open(os.path.join(self.lock_dir, "pid"), "w", encoding="utf-8") as handle:
                        handle.write(str(os.getpid()))
                except OSError:
                    pass
                return True
            except FileExistsError:
                holder = self._holder_pid()
                if (holder and not pid_alive(holder)) or self._lock_age() >= 60:
                    shutil.rmtree(self.lock_dir, ignore_errors=True)
                    continue
                if time.time() >= deadline:
                    return False
                time.sleep(0.05)

    def _release(self) -> None:
        holder = self._holder_pid()
        if holder == "" or holder == str(os.getpid()):
            shutil.rmtree(self.lock_dir, ignore_errors=True)

    def update(self, mutate) -> None:
        acquired = self._acquire()
        if not acquired:
            log("warning: state lock busy; updating without it")
        try:
            data = self.read()
            mutate(data)
            tmp = self.path + ".acp.tmp"
            with open(tmp, "w", encoding="utf-8") as handle:
                json.dump(data, handle, separators=(",", ":"))
                handle.write("\n")
            os.replace(tmp, self.path)
        finally:
            if acquired:
                self._release()

    def get(self, *keys, default=None):
        data = self.read()
        current = data
        for key in keys:
            if not isinstance(current, dict) or key not in current:
                return default
            current = current[key]
        return current


def option_id(option) -> str:
    return str(option.get("optionId") or option.get("id") or "")


def pick_option(options, want: str):
    """Pick an allow/reject option by ACP kind, then by name."""
    for option in options:
        kind = str(option.get("kind") or "").lower()
        if want == "allow" and kind.startswith("allow"):
            return option
        if want == "reject" and kind.startswith("reject"):
            return option
    for option in options:
        name = str(option.get("name") or "").lower()
        if want == "allow" and ("allow" in name or "approve" in name or "yes" in name):
            return option
        if want == "reject" and ("reject" in name or "deny" in name or "no" in name):
            return option
    return None


def pick_option_once(options):
    """Pick an allow-once option. Never falls back to allow_always: an automatic
    decision must not create a persistent agent-level grant."""
    for option in options:
        if str(option.get("kind") or "").lower() == "allow_once":
            return option
    for option in options:
        name = str(option.get("name") or "").lower()
        if "once" in name and ("allow" in name or "approve" in name or "yes" in name):
            return option
    return None


def option_is_allow_always(option) -> bool:
    if not isinstance(option, dict):
        return False
    kind = str(option.get("kind") or "").lower()
    oid = option_id(option).lower()
    return kind == "allow_always" or "always" in oid


def offered_values(config_options, config_id: str):
    for option in config_options or []:
        if str(option.get("id")) != config_id:
            continue
        values = []
        for entry in option.get("options") or []:
            if isinstance(entry, dict):
                values.append(str(entry.get("value") or entry.get("name") or ""))
            else:
                values.append(str(entry))
        return values
    return None


def offered_modes(modes):
    if not isinstance(modes, dict):
        return []
    available = modes.get("availableModes") or modes.get("available") or []
    result = []
    for entry in available:
        if isinstance(entry, dict):
            result.append(str(entry.get("id") or entry.get("name") or ""))
        else:
            result.append(str(entry))
    return result


class AcpClient:
    """Newline-delimited JSON-RPC over the child's stdio."""

    def __init__(self, proc):
        self.proc = proc
        self.pending = {}
        self.next_id = 0
        self.closed = False
        self.on_request = None
        self.on_notification = None
        self.on_closed = None

    async def _write(self, obj) -> None:
        if self.proc.stdin is None:
            raise AcpError("child_exit", "the ACP child has no stdin")
        data = json.dumps(obj, separators=(",", ":")) + "\n"
        self.proc.stdin.write(data.encode("utf-8"))
        await self.proc.stdin.drain()

    async def reader_loop(self) -> None:
        while True:
            line = await self.proc.stdout.readline()
            if not line:
                break
            text = line.decode("utf-8", errors="replace").strip()
            if not text:
                continue
            try:
                message = json.loads(text)
            except json.JSONDecodeError:
                log(f"acp: malformed line from child: {text[:300]}")
                continue
            try:
                await self._dispatch(message)
            except Exception as exc:  # never let one message kill the reader
                log(f"acp: message handling failed: {exc!r}")
        self.closed = True
        for future in list(self.pending.values()):
            if not future.done():
                future.set_exception(AcpError("child_exit", "the ACP child exited"))
        self.pending.clear()
        if self.on_closed is not None:
            try:
                await self.on_closed()
            except Exception as exc:
                log(f"acp: close handler failed: {exc!r}")

    async def _dispatch(self, message) -> None:
        if "id" in message and ("result" in message or "error" in message):
            future = self.pending.pop(message.get("id"), None)
            if future is not None and not future.done():
                future.set_result(message)
            return
        if "method" in message and "id" in message:
            if self.on_request is not None:
                await self.on_request(message)
            return
        if "method" in message:
            if self.on_notification is not None:
                await self.on_notification(message)

    async def request(self, method: str, params: dict, timeout=None):
        self.next_id += 1
        request_id = self.next_id
        future = asyncio.get_running_loop().create_future()
        self.pending[request_id] = future
        await self._write({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})
        try:
            response = await asyncio.wait_for(future, timeout) if timeout else await future
        finally:
            self.pending.pop(request_id, None)
        if "error" in response:
            error = response.get("error") or {}
            raise AcpError(
                "rpc_error",
                str(error.get("message") or "ACP request failed"),
                error,
            )
        return response.get("result") or {}

    async def notify(self, method: str, params: dict) -> None:
        await self._write({"jsonrpc": "2.0", "method": method, "params": params})

    async def respond(self, request_id, result: dict) -> None:
        await self._write({"jsonrpc": "2.0", "id": request_id, "result": result})

    async def respond_error(self, request_id, code: int, message: str) -> None:
        await self._write(
            {"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}}
        )


class Supervisor:
    def __init__(self, state_path: str):
        self.state = StateFile(state_path)
        data = self.state.read()
        self.data = data
        self.acp = dict(data.get("acp") or {})
        self.change = str(data.get("change") or "")
        self.project = str(data.get("project") or "")
        self.root = str(self.acp.get("apply_root") or self.project)
        self.session_id = self.acp.get("session_id") or None
        self.config_options = []
        self.modes = {}
        self.model_wanted = self.acp.get("model") or None
        self.mode_wanted = self.acp.get("mode") or None
        self.policy = str(self.acp.get("policy") or "allow")
        self.deny = [str(rule) for rule in (self.acp.get("deny") or [])]
        self.transcript = str(self.acp.get("transcript") or "")
        self.socket_path = str(self.acp.get("control_socket") or "")
        self.events_file = str(self.acp.get("events_file") or "")
        self.boss_bin = str(self.acp.get("boss_bin") or "boss")
        self.heartbeat_file = str(self.acp.get("heartbeat_file") or "")
        self.load_session = self.acp.get("load_session")
        self.resume = bool(self.acp.get("resume"))
        self.phase = str(self.acp.get("phase") or "starting")
        raw_isolate = self.acp.get("isolated")
        if raw_isolate is None:
            raw_isolate = self.acp.get("isolate")
        self.isolated = True if raw_isolate is None else bool(raw_isolate)
        self.profile_root = str(self.acp.get("profile_root") or profile_root_for(state_path))
        self.usage = None
        # Pending permissions are independent and keyed by tool-call id. A
        # second request must never replace the first one's future.
        self.pending: dict[str, dict] = {}
        self.apply_allows = [dict(item) for item in (self.acp.get("apply_allows") or []) if isinstance(item, dict)]
        self.turn_task = None
        self.next_prompt = None
        self.control_event = asyncio.Event()
        self.stop_event = asyncio.Event()
        self.closed_event = asyncio.Event()
        self.client = None
        self.proc = None
        self.server = None
        self.heartbeat_task = None
        self.stderr_task = None
        self.stderr_tail = []
        self.replaying = False
        self.seed_message_ids = set()
        self.seed_tool_ids = set()
        self.started_prompt = False
        self.wake_tasks = set()

    # ------------------------------------------------------------- state ---
    def acp_set(self, **fields) -> None:
        def mutate(data):
            acp = data.setdefault("acp", {})
            acp.update(fields)

        self.state.update(mutate)
        self.acp.update(fields)
        if "phase" in fields:
            self.phase = str(fields["phase"])

    def set_phase(self, phase: str, last_state: str | None = None) -> None:
        fields = {"phase": phase}
        self.acp_set(**fields)

        def mutate(data):
            acp = data.setdefault("acp", {})
            acp["phase"] = phase
            if last_state is not None:
                data["last_state"] = last_state
                data["last_state_at"] = now_iso()

        self.state.update(mutate)
        self.phase = phase

    def event(self, name: str, extra: dict | None = None) -> None:
        if not self.events_file:
            return
        record = {"t": now_iso(), "event": name, "change": self.change, "project": self.project}
        if extra:
            record.update(extra)
        try:
            os.makedirs(os.path.dirname(self.events_file), exist_ok=True)
            with open(self.events_file, "a", encoding="utf-8") as handle:
                handle.write(json.dumps(record, separators=(",", ":")) + "\n")
        except OSError as exc:
            log(f"warning: cannot append event {name}: {exc}")

    def transcript_append(self, record: dict) -> None:
        if not self.transcript:
            return
        record = dict(record)
        record.setdefault("t", now_iso())
        try:
            os.makedirs(os.path.dirname(self.transcript), exist_ok=True)
            cap = int(os.environ.get("BOSS_ACP_TRANSCRIPT_MAX_BYTES", "8388608") or "8388608")
            try:
                if os.path.getsize(self.transcript) > cap:
                    os.replace(self.transcript, self.transcript + ".1")
                    with open(self.transcript, "a", encoding="utf-8") as handle:
                        handle.write(json.dumps({"t": now_iso(), "type": "transcript_rotated"}) + "\n")
            except FileNotFoundError:
                pass
            with open(self.transcript, "a", encoding="utf-8") as handle:
                handle.write(json.dumps(record, separators=(",", ":")) + "\n")
        except OSError as exc:
            log(f"warning: cannot append the transcript: {exc}")

    async def wake(self, event: str, state: str, text: str) -> None:
        try:
            proc = await asyncio.create_subprocess_exec(
                self.boss_bin,
                "acp-event",
                self.state.path,
                event,
                state,
                text,
                stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.DEVNULL,
            )
        except OSError as exc:
            log(f"warning: cannot run the wake path: {exc}")
            return
        try:
            await asyncio.wait_for(proc.wait(), 120)
        except asyncio.TimeoutError:
            proc.kill()
            log("warning: the wake path did not finish within 120s")

    def wake_background(self, event: str, state: str, text: str) -> None:
        """Wake without blocking the control flow.

        A permission request must not wait for the boss delivery: the answer
        can arrive through the control socket while the wake is still in the
        inbox/retry path. Keep a reference so the task is not collected.
        """
        task = asyncio.create_task(self.wake(event, state, text))
        self.wake_tasks.add(task)
        task.add_done_callback(self.wake_tasks.discard)

    # ---------------------------------------------------------- transport ---
    async def initialize(self, timeout: float = 60.0) -> dict:
        result = await self.client.request(
            "initialize",
            {
                "protocolVersion": PROTOCOL_VERSION,
                "clientCapabilities": {},
            },
            timeout=timeout,
        )
        self.load_session = bool(
            (result.get("agentCapabilities") or {}).get("loadSession")
        )
        self.acp_set(load_session=self.load_session, protocol=result.get("protocolVersion"))
        self.event(
            "acp_started",
            {
                "protocol": result.get("protocolVersion"),
                "load_session": self.load_session,
                "agent": (result.get("agentInfo") or {}).get("name"),
            },
        )
        return result

    async def apply_config(self, payload: dict, strict: bool = True) -> None:
        config_options = payload.get("configOptions")
        if config_options is not None:
            self.config_options = config_options or []
        modes = payload.get("modes")
        if modes is not None:
            self.modes = modes or {}

        if self.model_wanted:
            values = offered_values(self.config_options, "model")
            if values is None:
                if strict:
                    raise AcpError(
                        "model_not_offered",
                        f"the agent does not advertise a model config option; requested '{self.model_wanted}'",
                    )
            elif self.model_wanted not in values:
                raise AcpError(
                    "model_not_offered",
                    f"model '{self.model_wanted}' is not offered; available: {', '.join(values) or '(none)'}",
                )
            try:
                result = await self.client.request(
                    "session/set_config_option",
                    {
                        "sessionId": self.session_id,
                        "configId": "model",
                        "value": self.model_wanted,
                    },
                    timeout=30,
                )
                self.config_options = result.get("configOptions") or self.config_options
            except AcpError as exc:
                if strict:
                    raise
                log(f"warning: could not re-apply the model after load: {exc}")

        if self.mode_wanted:
            ids = offered_modes(self.modes)
            if not ids:
                if strict:
                    raise AcpError(
                        "mode_not_offered",
                        f"the agent does not advertise session modes; requested '{self.mode_wanted}'",
                    )
            elif self.mode_wanted not in ids:
                raise AcpError(
                    "mode_not_offered",
                    f"mode '{self.mode_wanted}' is not offered; available: {', '.join(ids) or '(none)'}",
                )
            try:
                await self.client.request(
                    "session/set_mode",
                    {"sessionId": self.session_id, "modeId": self.mode_wanted},
                    timeout=30,
                )
            except AcpError as exc:
                if strict:
                    raise
                log(f"warning: could not re-apply the mode after load: {exc}")

        model = self.model_wanted
        if not model:
            for option in self.config_options:
                if str(option.get("id")) == "model":
                    model = option.get("currentValue")
                    break
        mode = self.mode_wanted
        if not mode and isinstance(self.modes, dict):
            mode = self.modes.get("currentModeId")
        self.acp_set(model=model or None, mode=mode or None)
        self.event(
            "acp_config",
            {"model": model or None, "mode": mode or None, "policy": self.policy},
        )

    async def new_session(self) -> None:
        result = await self.client.request(
            "session/new", {"cwd": self.root, "mcpServers": []}, timeout=120
        )
        self.session_id = result.get("sessionId") or result.get("session_id")
        if not self.session_id:
            raise AcpError("session_new_failed", "session/new returned no session id")
        self.acp_set(session_id=self.session_id)
        self.event("acp_session", {"session_id": self.session_id, "cwd": self.root})
        await self.apply_config(result)

    async def load_session_into_client(self) -> None:
        if not self.load_session:
            raise AcpError(
                "load_unsupported",
                "the agent does not support session/load; use 'boss retrigger' for an explicit new session",
            )
        self.transcript_append(
            {"type": "boundary", "reason": "session_load", "session_id": self.session_id}
        )
        self.replaying = True
        try:
            result = await self.client.request(
                "session/load",
                {"sessionId": self.session_id, "cwd": self.root, "mcpServers": []},
                timeout=120,
            )
        finally:
            self.replaying = False
        self.event("acp_load", {"session_id": self.session_id})
        strict = bool(result.get("configOptions") or result.get("modes"))
        await self.apply_config(result, strict=strict)

    # ------------------------------------------------------- notifications ---
    def seed_seen_from_transcript(self) -> None:
        """Remember message and tool-call ids already in the transcript so a
        session/load replay does not duplicate them. Streaming inside one turn
        may emit several chunks with the same message id, so the replay phase
        is tracked separately from normal streaming."""
        if not self.transcript:
            return
        try:
            with open(self.transcript, encoding="utf-8") as handle:
                for line in handle:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        record = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if record.get("type") == "message" and record.get("message_id"):
                        self.seed_message_ids.add(str(record["message_id"]))
                    elif record.get("type") == "tool_call" and record.get("tool_call_id"):
                        self.seed_tool_ids.add(str(record["tool_call_id"]))
        except OSError as exc:
            log(f"warning: cannot read the transcript for dedup: {exc}")

    async def on_notification(self, message: dict) -> None:
        if message.get("method") != "session/update":
            return
        params = message.get("params") or {}
        update = params.get("update") or {}
        kind = str(update.get("sessionUpdate") or "")
        summary = None
        if kind in ("agent_message_chunk", "agent_thought_chunk"):
            message_id = update.get("messageId")
            if self.replaying and message_id and str(message_id) in self.seed_message_ids:
                return
            content = update.get("content") or {}
            text = str(content.get("text") or "")
            self.transcript_append(
                {"type": "message", "message_id": message_id, "text": text}
            )
            summary = text
        elif kind == "tool_call":
            tool_id = str(update.get("toolCallId") or "")
            if self.replaying and tool_id and tool_id in self.seed_tool_ids:
                return
            title = str(update.get("title") or tool_id or "tool")
            self.transcript_append(
                {
                    "type": "tool_call",
                    "tool_call_id": tool_id,
                    "title": title,
                    "kind": update.get("kind"),
                    "status": update.get("status"),
                    "raw_input": update.get("rawInput"),
                }
            )
            summary = f"tool {title} ({update.get('status') or 'requested'})"
        elif kind == "tool_call_update":
            tool_id = str(update.get("toolCallId") or "")
            if self.replaying and tool_id and tool_id in self.seed_tool_ids:
                return
            title = str(update.get("title") or tool_id or "tool")
            self.transcript_append(
                {
                    "type": "tool_call_update",
                    "tool_call_id": tool_id,
                    "title": update.get("title"),
                    "status": update.get("status"),
                }
            )
            summary = f"tool {title} ({update.get('status') or 'updated'})"
        elif kind == "usage_update":
            usage = update.get("usage") or {
                key: value for key, value in update.items() if key != "sessionUpdate"
            }
            self.usage = usage
            self.acp_set(usage=usage)
            self.transcript_append({"type": "usage", "usage": usage})
            # Usage is reported separately; keep last_update for the last
            # message or tool activity.
            summary = None
        elif kind in ("current_mode_update", "config_option_update"):
            if kind == "current_mode_update":
                self.acp_set(mode=update.get("currentModeId") or update.get("modeId"))
            else:
                for option in update.get("configOptions") or []:
                    if str(option.get("id")) == "model":
                        self.acp_set(model=option.get("currentValue"))
            self.transcript_append({"type": kind, "update": update})
            summary = kind
        else:
            self.transcript_append({"type": "update", "update": update})
            summary = None
        if summary:
            text = " ".join(str(summary).split())
            self.acp_set(last_update=text[:500])

    # ---------------------------------------------------------- permission ---
    def rule_matches(self, rule: str, tool: dict) -> bool:
        raw = tool.get("rawInput") or {}
        values = [
            str(raw.get("command") or ""),
            str(raw.get("path") or raw.get("file_path") or ""),
            str(tool.get("title") or ""),
        ]
        for value in values:
            if not value:
                continue
            if value == rule or rule in value:
                return True
            try:
                if fnmatch.fnmatchcase(value, rule):
                    return True
            except Exception:
                pass
        return False

    def decide(self, tool: dict) -> str:
        for rule in self.deny:
            if rule and self.rule_matches(rule, tool):
                return "reject"
        kind = str(tool.get("kind") or "").lower()
        if kind in ("read", "search", "fetch", "think"):
            return "allow"
        if self.policy == "ask":
            return "ask"
        return "allow"

    def permission_options(self, params: dict):
        options = params.get("options") or []
        result = []
        for option in options:
            if not isinstance(option, dict):
                continue
            result.append(
                {
                    "optionId": option_id(option),
                    "name": option.get("name"),
                    "kind": option.get("kind"),
                }
            )
        return result

    # -- apply-scoped allow-always grants -----------------------------------
    def grant_matches(self, grant: dict, tool: dict) -> bool:
        raw = tool.get("rawInput") or {}
        command = str(raw.get("command") or raw.get("path") or "")
        title = str(tool.get("title") or "")
        grant_command = str(grant.get("command") or "")
        grant_title = str(grant.get("title") or "")
        grant_kind = str(grant.get("kind") or "")
        kind = str(tool.get("kind") or "")
        if grant_kind and kind and grant_kind != kind:
            return False
        if grant_command:
            if command == grant_command:
                return True
            try:
                return bool(fnmatch.fnmatchcase(command, grant_command))
            except Exception:
                return False
        return bool(grant_title) and title == grant_title

    def find_apply_allow(self, tool: dict):
        for index, grant in enumerate(self.apply_allows):
            if self.grant_matches(grant, tool):
                return index
        return None

    def remember_apply_allow(self, tool: dict, title: str, command: str) -> None:
        raw = tool.get("rawInput") or {}
        grant = {
            "title": title,
            "kind": tool.get("kind"),
            "command": command or str(raw.get("path") or ""),
        }
        if grant not in self.apply_allows:
            self.apply_allows.append(grant)
            self.acp_set(apply_allows=self.apply_allows)

    # -- pending queue ------------------------------------------------------
    def pending_public(self, key: str, entry: dict) -> dict:
        return {
            "tool_call_id": key,
            "request_id": entry.get("request_id"),
            "title": entry.get("title"),
            "command": entry.get("command"),
            "raw_input": entry.get("raw_input"),
            "options": entry.get("recorded") or [],
        }

    def pending_list(self) -> list:
        return [self.pending_public(key, entry) for key, entry in self.pending.items()]

    def persist_pending(self) -> None:
        items = self.pending_list()
        # pending_permission stays as an alias for readers from before the
        # queue; it always names the first still-unanswered request.
        self.acp_set(
            pending_permissions=items,
            pending_permission=(items[0] if items else None),
        )

    def pending_ids(self) -> list:
        return list(self.pending.keys())

    async def on_request(self, message: dict) -> None:
        method = message.get("method")
        request_id = message.get("id")
        if method != "session/request_permission":
            await self.client.respond_error(request_id, -32601, f"unknown method {method}")
            return
        asyncio.create_task(self.handle_permission(request_id, message.get("params") or {}))

    async def handle_permission(self, request_id, params: dict) -> None:
        tool = params.get("toolCall") or {}
        options = params.get("options") or []
        recorded = self.permission_options(params)
        raw = tool.get("rawInput") or {}
        title = str(tool.get("title") or "permission request")
        command = str(raw.get("command") or raw.get("path") or "")
        description = f"{title} -- {command}" if command else title
        tool_call_id = str(tool.get("toolCallId") or f"request-{request_id}")
        decision = self.decide(tool)
        from_apply_allow = False
        grant_index = None
        if decision != "reject":
            grant_index = self.find_apply_allow(tool)
            if grant_index is not None:
                decision = "allow"
                from_apply_allow = True
        if decision == "reject":
            option = pick_option(options, "reject")
            await self.respond_permission(request_id, option)
            self.event(
                "acp_permission",
                {
                    "decision": "reject",
                    "title": title,
                    "command": command,
                    "tool_call_id": tool_call_id,
                    "request_id": request_id,
                },
            )
            self.transcript_append(
                {
                    "type": "permission",
                    "decision": "reject",
                    "title": title,
                    "command": command,
                    "tool_call_id": tool_call_id,
                    "request_id": request_id,
                }
            )
            return
        if decision == "allow":
            option = pick_option_once(options)
            if option is None:
                # Fail closed: without an allow-once option, an automatic
                # allow would have to write an agent-level grant.
                log(
                    "warning: permission request offers no allow-once option; "
                    "leaving it pending instead of granting allow-always"
                )
            else:
                await self.respond_permission(request_id, option)
                self.event(
                    "acp_permission",
                    {
                        "decision": "allow",
                        "title": title,
                        "command": command,
                        "tool_call_id": tool_call_id,
                        "request_id": request_id,
                        "apply_allow": from_apply_allow,
                    },
                )
                self.transcript_append(
                    {
                        "type": "permission",
                        "decision": "allow",
                        "title": title,
                        "command": command,
                        "tool_call_id": tool_call_id,
                        "request_id": request_id,
                    }
                )
                return

        # ask: the request stays open, the apply becomes blocked and the boss
        # decides through 'boss answer' (or 'boss interrupt'). Each request owns
        # its future, so a concurrent request cannot orphan it.
        future = asyncio.get_running_loop().create_future()
        entry = {
            "request_id": request_id,
            "options": options,
            "recorded": recorded,
            "tool_call_id": tool_call_id,
            "title": title,
            "command": command,
            "raw_input": raw,
            "tool": tool,
            "future": future,
        }
        self.pending[tool_call_id] = entry
        self.persist_pending()
        first = len(self.pending) == 1
        if first:
            self.set_phase("blocked", "blocked")
        self.event(
            "acp_permission",
            {
                "decision": "ask",
                "title": title,
                "command": command,
                "tool_call_id": tool_call_id,
                "request_id": request_id,
            },
        )
        self.transcript_append(
            {
                "type": "permission",
                "decision": "ask",
                "title": title,
                "command": command,
                "tool_call_id": tool_call_id,
                "request_id": request_id,
            }
        )
        if first:
            self.wake_background(
                "blocked",
                "blocked",
                f"Apply {self.change} in {self.project}: blocked on an ACP permission request ({description}). "
                f"Options: {', '.join(item['optionId'] for item in recorded) or '(none)'}. "
                f"Next step: boss answer {self.change} <option> --tool-call {tool_call_id} "
                f"(or boss interrupt {self.change})",
            )
        chosen = await future
        self.pending.pop(tool_call_id, None)
        self.persist_pending()
        if chosen and chosen.get("cancel"):
            option = pick_option(options, "reject")
            if option is not None:
                await self.respond_permission(request_id, option)
            else:
                await self.client.respond(request_id, {"outcome": {"outcome": "cancelled"}})
            self.event(
                "acp_permission_answered",
                {
                    "decision": "cancelled",
                    "title": title,
                    "tool_call_id": tool_call_id,
                    "request_id": request_id,
                },
            )
            self.transcript_append(
                {
                    "type": "permission_answered",
                    "decision": "cancelled",
                    "title": title,
                    "tool_call_id": tool_call_id,
                    "request_id": request_id,
                }
            )
        else:
            selected = (chosen or {}).get("option")
            option = None
            for candidate in options:
                if option_id(candidate) == selected:
                    option = candidate
                    break
            if option is None:
                option = pick_option(options, "reject")
            await self.respond_permission(request_id, option)
            self.event(
                "acp_permission_answered",
                {
                    "decision": "answer",
                    "option": selected,
                    "title": title,
                    "tool_call_id": tool_call_id,
                    "request_id": request_id,
                    "apply_allow": bool((chosen or {}).get("grant")),
                },
            )
            self.transcript_append(
                {
                    "type": "permission_answered",
                    "decision": "answer",
                    "option": selected,
                    "title": title,
                    "tool_call_id": tool_call_id,
                    "request_id": request_id,
                }
            )
        if not self.pending:
            self.set_phase("working", "working")

    async def respond_permission(self, request_id, option) -> None:
        if option is not None:
            await self.client.respond(
                request_id,
                {"outcome": {"outcome": "selected", "optionId": option_id(option)}},
            )
        else:
            await self.client.respond(request_id, {"outcome": {"outcome": "cancelled"}})

    def resolve_pending(self, payload: dict, tool_call_id=None) -> bool:
        if tool_call_id is not None:
            entry = self.pending.get(str(tool_call_id))
            if entry is None:
                return False
            future = entry.get("future")
            if future is not None and not future.done():
                future.set_result(payload)
                return True
            return False
        if len(self.pending) == 1:
            future = next(iter(self.pending.values())).get("future")
            if future is not None and not future.done():
                future.set_result(payload)
                return True
        return False

    def resolve_all(self, payload: dict) -> int:
        count = 0
        for entry in list(self.pending.values()):
            future = entry.get("future")
            if future is not None and not future.done():
                future.set_result(payload)
                count += 1
        return count

    # --------------------------------------------------------------- turns ---
    async def run_turn(self, text: str) -> str:
        self.set_phase("working", "working")
        self.event("acp_prompt", {"text": text[:2000]})
        self.transcript_append({"type": "prompt", "text": text[:4000]})
        timeout = None
        raw_timeout = os.environ.get("BOSS_ACP_TURN_TIMEOUT_S", "0")
        try:
            if int(raw_timeout) > 0:
                timeout = int(raw_timeout)
        except ValueError:
            timeout = None
        self.turn_task = asyncio.create_task(
            self.client.request(
                "session/prompt",
                {"sessionId": self.session_id, "prompt": [{"type": "text", "text": text}]},
                timeout=timeout,
            )
        )
        stop_reason = "unknown"
        try:
            result = await self.turn_task
            stop_reason = str(result.get("stopReason") or "unknown")
            usage = result.get("usage")
            if usage:
                self.usage = usage
                self.acp_set(usage=usage)
        except asyncio.TimeoutError:
            stop_reason = "turn_timeout"
        except AcpError as exc:
            stop_reason = "failed"
            self.acp_set(error=exc.message)
            log(f"acp: prompt failed: {exc.message}")
        finally:
            self.turn_task = None
        self.acp_set(last_stop_reason=stop_reason)
        self.event("acp_stop", {"stop_reason": stop_reason, "usage": self.usage})
        self.transcript_append({"type": "stop", "stop_reason": stop_reason, "usage": self.usage})
        last_state = "idle" if stop_reason in ("end_turn", "unknown") else stop_reason
        self.set_phase("idle", last_state)
        if self.stop_event.is_set():
            # Finish or a stop signal: the Explorer initiated the end, so no
            # wake is needed (and none should delay shutdown).
            return stop_reason
        if stop_reason == "end_turn":
            message = "idle (ACP turn ended, stopReason end_turn)"
        elif stop_reason == "cancelled":
            message = "cancelled (ACP turn ended, stopReason cancelled)"
        else:
            message = f"{stop_reason} (ACP turn ended, stopReason {stop_reason})"
        await self.wake(
            "settled",
            last_state,
            f"Apply {self.change} in {self.project}: {message}. Next step: boss status {self.change}",
        )
        return stop_reason

    async def cancel_turn(self) -> str:
        had_pending = bool(self.pending)
        if had_pending:
            self.resolve_all({"cancel": True})
        task = self.turn_task
        if task is None or task.done():
            return "cancelled" if had_pending else "idle"
        await self.client.notify("session/cancel", {"sessionId": self.session_id})
        self.event("acp_cancel", {"session_id": self.session_id})
        timeout = float(os.environ.get("BOSS_ACP_CANCEL_TIMEOUT_S", "15") or "15")
        try:
            await asyncio.wait_for(asyncio.shield(task), timeout)
        except asyncio.TimeoutError:
            self.acp_set(last_stop_reason="cancel_unconfirmed")
            self.set_phase("working", "cancel_unconfirmed")
            self.event("acp_cancel", {"session_id": self.session_id, "confirmed": False})
            await self.wake(
                "settled",
                "cancel_unconfirmed",
                f"Apply {self.change} in {self.project}: cancel_unconfirmed (the ACP agent did not answer "
                f"session/cancel within {int(timeout)}s). Next step: boss status {self.change}",
            )
            return "cancel_unconfirmed"
        except AcpError as exc:
            return f"error:{exc.code}"
        if had_pending:
            return "cancelled"
        if task.done() and not task.cancelled():
            try:
                result = task.result()
                return str(result.get("stopReason") or "cancelled")
            except Exception:
                pass
        return "cancelled"

    # -------------------------------------------------------------- control ---
    async def handle_control(self, reader, writer) -> None:
        response = {"ok": False, "error": "bad_request"}
        try:
            line = await reader.readline()
            command = json.loads(line.decode("utf-8", errors="replace"))
            action = str(command.get("command") or "")
            if action == "status":
                response = {
                    "ok": True,
                    "command": action,
                    "phase": self.phase,
                    "session_id": self.session_id,
                    "model": self.acp.get("model"),
                    "mode": self.acp.get("mode"),
                    "pending": bool(self.pending),
                    "pending_permissions": self.pending_list(),
                    "apply_allows": self.apply_allows,
                    "isolated": self.isolated,
                    "profile_root": self.profile_root if self.isolated else None,
                    "last_stop_reason": self.acp.get("last_stop_reason"),
                    "usage": self.usage,
                }
            elif action == "answer":
                response = await self.control_answer(command)
            elif action == "cancel":
                status = await self.cancel_turn()
                response = {"ok": True, "command": action, "status": status}
            elif action == "prompt":
                if self.turn_task is not None and not self.turn_task.done():
                    response = {"ok": False, "error": "turn_active"}
                else:
                    self.next_prompt = str(command.get("text") or "")
                    self.control_event.set()
                    response = {"ok": True, "command": action}
            elif action == "finish":
                response = {"ok": True, "command": action}
                await self.shutdown_from_control()
            else:
                response = {"ok": False, "error": f"unknown_command:{action}"}
        except Exception as exc:
            log(f"acp: control handling failed: {exc!r}")
            response = {"ok": False, "error": "control_failed", "message": str(exc)}
        try:
            writer.write((json.dumps(response) + "\n").encode("utf-8"))
            await writer.drain()
        except OSError:
            pass
        try:
            writer.close()
            await writer.wait_closed()
        except OSError:
            pass

    async def control_answer(self, command: dict) -> dict:
        if not self.pending:
            return {"ok": False, "error": "no_pending_permission"}
        wanted = str(command.get("option") or "")
        requested_id = command.get("tool_call_id") or command.get("toolCallId")
        requested_id = str(requested_id) if requested_id else ""
        if requested_id:
            entry = self.pending.get(requested_id)
            if entry is None:
                return {
                    "ok": False,
                    "error": "unknown_pending",
                    "pending": self.pending_ids(),
                }
        elif len(self.pending) > 1:
            return {
                "ok": False,
                "error": "ambiguous_pending",
                "pending": self.pending_ids(),
            }
        else:
            entry = next(iter(self.pending.values()))
        key = str(entry.get("tool_call_id"))
        recorded = entry.get("recorded") or []
        selected = None
        selected_option = None
        for item in recorded:
            if wanted == item.get("optionId") or wanted == str(item.get("name") or ""):
                selected = item.get("optionId")
                selected_option = item
                break
        if selected is None:
            return {
                "ok": False,
                "error": "unknown_option",
                "tool_call_id": key,
                "offered": [item.get("optionId") for item in recorded],
            }

        grant = False
        if option_is_allow_always(selected_option):
            once = pick_option_once(entry.get("options") or [])
            if once is not None:
                selected = option_id(once)
            elif not self.isolated:
                # A persistent agent-level grant could bypass the supervisor.
                # The request stays pending and the Explorer must choose an
                # allow-once option.
                return {
                    "ok": False,
                    "error": "no_allow_once",
                    "tool_call_id": key,
                    "message": "the agent offers no allow-once option; allow-always would become a persistent grant",
                }
            self.remember_apply_allow(
                entry.get("tool") or {},
                str(entry.get("title") or ""),
                str(entry.get("command") or ""),
            )
            grant = True
        self.resolve_pending({"option": selected, "grant": grant}, key)
        return {
            "ok": True,
            "command": "answer",
            "option": selected,
            "tool_call_id": key,
            "grant": grant,
        }

    async def shutdown_from_control(self) -> None:
        log("acp: finish requested by the control socket")
        self.stop_event.set()
        self.control_event.set()
        self.resolve_all({"cancel": True})
        if self.turn_task is not None and not self.turn_task.done() and self.session_id:
            try:
                await self.client.notify("session/cancel", {"sessionId": self.session_id})
            except Exception:
                pass
        try:
            await asyncio.wait_for(self.closed_event.wait(), 10)
        except asyncio.TimeoutError:
            log("warning: supervisor did not close in time; terminating the child")
            if self.proc is not None and self.proc.returncode is None:
                self.proc.terminate()

    def request_stop(self) -> None:
        """Signal handler path: no turn may keep the process alive."""
        log("acp: stop signal received")
        self.stop_event.set()
        self.control_event.set()
        self.resolve_all({"cancel": True})
        if self.proc is not None and self.proc.returncode is None:
            try:
                self.proc.terminate()
            except ProcessLookupError:
                pass

    # -------------------------------------------------------------- startup ---
    async def start_control_server(self) -> None:
        if not self.socket_path:
            raise AcpError("no_socket", "the apply state carries no control socket path")
        os.makedirs(os.path.dirname(self.socket_path), exist_ok=True)
        try:
            os.unlink(self.socket_path)
        except FileNotFoundError:
            pass
        self.server = await asyncio.start_unix_server(self.handle_control, path=self.socket_path)
        try:
            os.chmod(self.socket_path, 0o600)
        except OSError:
            pass

    async def heartbeat(self) -> None:
        interval = 5.0
        try:
            interval = float(os.environ.get("BOSS_ACP_HEARTBEAT_S", "5") or "5")
        except ValueError:
            pass
        while not self.stop_event.is_set():
            self.acp_set(heartbeat=now_iso())
            if self.heartbeat_file:
                try:
                    os.makedirs(os.path.dirname(self.heartbeat_file), exist_ok=True)
                    with open(self.heartbeat_file, "w", encoding="utf-8") as handle:
                        handle.write(now_iso() + "\n")
                except OSError:
                    pass
            try:
                await asyncio.wait_for(self.stop_event.wait(), max(interval, 1.0))
            except asyncio.TimeoutError:
                continue

    async def drain_stderr(self) -> None:
        while True:
            line = await self.proc.stderr.readline()
            if not line:
                return
            text = line.decode("utf-8", errors="replace").rstrip()
            if text:
                log(f"acp child stderr: {text}")
                self.stderr_tail.append(text)
                del self.stderr_tail[:-20]

    async def spawn_child(self) -> None:
        command = str(self.acp.get("command") or "").strip()
        if not command:
            raise AcpError("command_missing", "the apply state carries no ACP command")
        argv = shlex.split(command) + ["acp"]
        env = os.environ.copy()
        if self.isolated:
            try:
                build_agent_profile(self.profile_root)
            except OSError as exc:
                raise AcpError(
                    "profile_failed",
                    f"cannot create the per-apply agent profile {self.profile_root}: {exc}",
                )
            env["XDG_CONFIG_HOME"] = os.path.join(self.profile_root, "config")
            env["XDG_DATA_HOME"] = os.path.join(self.profile_root, "data")
        self.acp_set(
            isolated=self.isolated,
            profile_root=self.profile_root if self.isolated else None,
        )
        try:
            self.proc = await asyncio.create_subprocess_exec(
                *argv,
                cwd=self.root or None,
                env=env,
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
        except FileNotFoundError:
            raise AcpError("command_missing", f"the ACP command '{argv[0]}' was not found")
        except OSError as exc:
            raise AcpError("spawn_failed", f"cannot start '{argv[0]}': {exc}")
        self.client = AcpClient(self.proc)
        self.client.on_request = self.on_request
        self.client.on_notification = self.on_notification
        self.client.on_closed = self.child_closed
        asyncio.create_task(self.client.reader_loop())
        self.stderr_task = asyncio.create_task(self.drain_stderr())
        self.event(
            "acp_started_child",
            {
                "command": command,
                "pid": self.proc.pid,
                "cwd": self.root,
                "isolated": self.isolated,
                "profile_root": self.profile_root if self.isolated else None,
            },
        )
        self.transcript_append(
            {
                "type": "start",
                "command": command,
                "cwd": self.root,
                "pid": self.proc.pid,
                "isolated": self.isolated,
            }
        )

    async def child_closed(self) -> None:
        # No future may survive an unexpected child exit.
        self.resolve_all({"cancel": True})
        if not self.stop_event.is_set():
            self.event("acp_exit", {"reason": "child_exit"})
            self.acp_set(error="the ACP child exited unexpectedly")
            self.set_phase("failed", "failed")
            self.stop_event.set()
            self.control_event.set()

    # ----------------------------------------------------------------- run ---
    async def run(self) -> None:
        self.acp_set(
            supervisor_pid=os.getpid(),
            phase="starting",
            ready=False,
            error=None,
            dead_reported=False,
            pending_permission=None,
            pending_permissions=[],
            apply_allows=self.apply_allows,
            isolated=self.isolated,
            profile_root=self.profile_root if self.isolated else None,
        )
        self.set_phase("starting", "starting")
        self.heartbeat_task = asyncio.create_task(self.heartbeat())
        try:
            await self.start_control_server()
            await self.spawn_child()
            await self.initialize()
            if self.resume and self.session_id:
                self.seed_seen_from_transcript()
                await self.load_session_into_client()
                self.acp_set(ready=True)
                self.set_phase("idle", "idle")
                await self.wake(
                    "resumed",
                    "idle",
                    f"Apply {self.change} in {self.project}: idle (ACP session reloaded). "
                    f"Next step: boss status {self.change}",
                )
            else:
                await self.new_session()
                self.acp_set(ready=True)
                prompt = str(self.acp.get("prompt") or "")
                self.started_prompt = True
                await self.run_turn(prompt)
            log("acp: first turn done; entering the control loop")
            while not self.stop_event.is_set():
                self.control_event.clear()
                wait_stop = asyncio.create_task(self.stop_event.wait())
                wait_control = asyncio.create_task(self.control_event.wait())
                done, pending = await asyncio.wait(
                    {wait_stop, wait_control}, return_when=asyncio.FIRST_COMPLETED
                )
                for task in pending:
                    task.cancel()
                log(f"acp: control loop woke (stop={self.stop_event.is_set()})")
                if self.stop_event.is_set():
                    break
                text = self.next_prompt
                self.next_prompt = None
                if text is not None:
                    await self.run_turn(text)
        except asyncio.CancelledError:
            raise
        except AcpError as exc:
            log(f"acp: supervisor failed: {exc.code}: {exc.message}")
            detail = exc.message
            if self.stderr_tail:
                detail = f"{detail} (stderr: {' | '.join(self.stderr_tail[-3:])[:800]})"
            self.acp_set(error=detail)
            self.set_phase("failed", "failed")
            if self.acp.get("ready"):
                await self.wake(
                    "settled",
                    "failed",
                    f"Apply {self.change} in {self.project}: failed ({detail}). "
                    f"Next step: boss status {self.change}",
                )
        except Exception as exc:  # last resort: never die silently
            log(f"acp: supervisor crashed: {exc!r}")
            self.acp_set(error=f"supervisor crashed: {exc}")
            self.set_phase("failed", "failed")
        finally:
            await self.cleanup()

    async def cleanup(self) -> None:
        log("acp: cleanup started")
        if self.stop_event.is_set() is False:
            self.stop_event.set()
        self.resolve_all({"cancel": True})
        # Close the ACP session explicitly when one exists.
        if self.client is not None and self.session_id and not self.client.closed:
            try:
                log("acp: closing the session")
                await self.client.request(
                    "session/close", {"sessionId": self.session_id}, timeout=3
                )
                log("acp: session closed")
            except Exception as exc:
                log(f"acp: session close failed: {exc!r}")
        if self.proc is not None and self.proc.returncode is None:
            log("acp: terminating the child")
            try:
                self.proc.terminate()
            except ProcessLookupError:
                pass
            try:
                await asyncio.wait_for(self.proc.wait(), 5)
            except asyncio.TimeoutError:
                log("acp: child did not terminate; killing it")
                try:
                    self.proc.kill()
                except ProcessLookupError:
                    pass
                try:
                    await asyncio.wait_for(self.proc.wait(), 5)
                except asyncio.TimeoutError:
                    pass
        log("acp: child stopped")
        if self.server is not None:
            self.server.close()
        # Release the control handler that is waiting for this close before
        # waiting for the server: otherwise wait_closed() would wait on that
        # very handler (which is waiting on closed_event) for its full timeout.
        self.closed_event.set()
        if self.server is not None:
            try:
                await asyncio.wait_for(self.server.wait_closed(), 2)
            except (asyncio.TimeoutError, Exception):
                pass
        if self.socket_path:
            try:
                os.unlink(self.socket_path)
            except FileNotFoundError:
                pass
        if self.heartbeat_task is not None:
            self.heartbeat_task.cancel()
            try:
                await self.heartbeat_task
            except (asyncio.CancelledError, Exception):
                pass
        self.event("acp_exit", {"reason": "closed", "stop_reason": self.acp.get("last_stop_reason")})
        self.acp_set(
            phase="closed",
            supervisor_pid=None,
            pending_permission=None,
            pending_permissions=[],
        )
        self.closed_event.set()
        log("acp: supervisor stopped")


# ------------------------------------------------------------------ probe ---

async def probe(command: str, cwd: str, model, mode, timeout: float, profile_temp: bool = False) -> dict:
    result = {
        "status": "ok",
        "command": command,
        "cwd": cwd,
        "protocol": None,
        "load_session": None,
        "models": [],
        "modes": [],
        "message": "",
    }
    argv = shlex.split(command) + ["acp"]
    stderr_tail = []
    profile_root = None
    env = os.environ.copy()
    if profile_temp:
        profile_root = tempfile.mkdtemp(prefix="boss-acp-probe-")
        try:
            build_agent_profile(profile_root)
        except OSError as exc:
            shutil.rmtree(profile_root, ignore_errors=True)
            result.update(status="fail", message=f"cannot create the probe profile: {exc}")
            return result
        env["XDG_CONFIG_HOME"] = os.path.join(profile_root, "config")
        env["XDG_DATA_HOME"] = os.path.join(profile_root, "data")
    try:
        proc = await asyncio.create_subprocess_exec(
            *argv,
            cwd=cwd or None,
            env=env,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
    except FileNotFoundError:
        result.update(status="fail", message=f"command '{argv[0]}' not found")
        if profile_root:
            shutil.rmtree(profile_root, ignore_errors=True)
        return result
    except OSError as exc:
        result.update(status="fail", message=f"cannot start '{argv[0]}': {exc}")
        if profile_root:
            shutil.rmtree(profile_root, ignore_errors=True)
        return result
    client = AcpClient(proc)

    async def drain():
        while True:
            line = await proc.stderr.readline()
            if not line:
                return
            text = line.decode("utf-8", errors="replace").rstrip()
            if text:
                stderr_tail.append(text)
                del stderr_tail[:-10]

    reader = asyncio.create_task(client.reader_loop())
    err = asyncio.create_task(drain())
    session_id = None
    try:
        init = await client.request(
            "initialize",
            {
                "protocolVersion": PROTOCOL_VERSION,
                "clientCapabilities": {},
            },
            timeout=timeout,
        )
        result["protocol"] = init.get("protocolVersion")
        result["load_session"] = bool((init.get("agentCapabilities") or {}).get("loadSession"))
        session = await client.request(
            "session/new", {"cwd": cwd or os.getcwd(), "mcpServers": []}, timeout=timeout
        )
        session_id = session.get("sessionId") or session.get("session_id")
        config_options = session.get("configOptions") or []
        models = offered_values(config_options, "model")
        result["models"] = models or []
        modes = offered_modes(session.get("modes"))
        result["modes"] = modes
        if model:
            if models is None:
                result.update(
                    status="fail",
                    message=f"model '{model}' is not offered: the agent advertises no model config option",
                )
            elif model not in models:
                result.update(
                    status="fail",
                    message=f"model '{model}' is not offered; available: {', '.join(models) or '(none)'}",
                )
        if result["status"] == "ok" and mode:
            if not modes:
                result.update(
                    status="fail",
                    message=f"mode '{mode}' is not offered: the agent advertises no session modes",
                )
            elif mode not in modes:
                result.update(
                    status="fail",
                    message=f"mode '{mode}' is not offered; available: {', '.join(modes) or '(none)'}",
                )
    except AcpError as exc:
        detail = exc.message
        if stderr_tail:
            detail = f"{detail} (stderr: {' | '.join(stderr_tail[-3:])[:800]})"
        result.update(status="fail", message=detail)
    except asyncio.TimeoutError:
        result.update(status="fail", message=f"the ACP handshake timed out after {timeout}s")
    finally:
        if session_id:
            try:
                await client.request("session/close", {"sessionId": session_id}, timeout=3)
            except Exception:
                pass
        try:
            proc.terminate()
        except ProcessLookupError:
            pass
        try:
            await asyncio.wait_for(proc.wait(), 3)
        except asyncio.TimeoutError:
            try:
                proc.kill()
            except ProcessLookupError:
                pass
        for task in (reader, err):
            task.cancel()
        if profile_root:
            shutil.rmtree(profile_root, ignore_errors=True)
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description="boss-acp supervisor")
    parser.add_argument("state_file", nargs="?")
    parser.add_argument("--probe")
    parser.add_argument("--cwd", default="")
    parser.add_argument("--model", default="")
    parser.add_argument("--mode", default="")
    parser.add_argument("--timeout", type=float, default=20.0)
    parser.add_argument("--profile-temp", action="store_true")
    args = parser.parse_args()

    if args.probe:
        result = asyncio.run(
            probe(
                args.probe,
                args.cwd,
                args.model or None,
                args.mode or None,
                args.timeout,
                profile_temp=args.profile_temp,
            )
        )
        print(json.dumps(result))
        return 0 if result["status"] == "ok" else 1

    if not args.state_file or not os.path.isfile(args.state_file):
        sys.stderr.write("usage: boss_acp.py <state-file>\n")
        return 2

    supervisor = Supervisor(args.state_file)

    async def runner():
        loop = asyncio.get_running_loop()
        for sig in (signal.SIGTERM, signal.SIGINT):
            try:
                loop.add_signal_handler(sig, supervisor.request_stop)
            except (NotImplementedError, RuntimeError):
                pass
        await supervisor.run()

    try:
        asyncio.run(runner())
    except KeyboardInterrupt:
        return 130
    return 0


if __name__ == "__main__":
    sys.exit(main())
