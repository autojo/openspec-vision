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

# Requests of one permission burst arrive in separate messages. A blocked wake
# waits this long so its text can name every request that opened the same
# transition, instead of only the first one.
BLOCKED_WAKE_COALESCE_S = 0.25

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


def append_private(path: str, text: str) -> None:
    """Append text to a file only the operator may read.

    A supervisor log and an ACP transcript carry full commands and tool output,
    so both are created with mode 0600. The mode is applied after open, which
    also repairs a file created world-readable by an older version on its next
    append.
    """
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    try:
        os.fchmod(fd, 0o600)
    except OSError:
        pass
    with os.fdopen(fd, "a", encoding="utf-8") as handle:
        handle.write(text)


def log(message: str) -> None:
    line = f"{now_iso()} {message}\n"
    path = os.environ.get("BOSS_LOG_FILE", "")
    if path:
        try:
            append_private(path, line)
            return
        except OSError:
            pass
    sys.stderr.write(line)
    sys.stderr.flush()


def env_seconds(name: str, default: float) -> float:
    raw = os.environ.get(name)
    if raw is None or str(raw).strip() == "":
        return float(default)
    try:
        return float(raw)
    except (TypeError, ValueError):
        log(f"warning: {name}={raw!r} is not a number; using {default}")
        return float(default)


def turn_timeout():
    """Seconds a turn may wait for the prompt response; None disables it."""
    value = env_seconds("BOSS_ACP_TURN_TIMEOUT_S", 7200)
    return value if value > 0 else None


def stall_interval() -> float:
    """Seconds without transcript progress after which a turn is stalled."""
    value = env_seconds("BOSS_ACP_STALL_S", 1800)
    return value if value > 0 else 0.0


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


def config_option(config_options, config_id: str = "", category: str = ""):
    """Find a config option by id or by its ACP category."""
    for option in config_options or []:
        if not isinstance(option, dict):
            continue
        if config_id and str(option.get("id")) == config_id:
            return option
        if category and str(option.get("category") or "").lower() == category.lower():
            return option
    return None


def values_of(option):
    values = []
    for entry in (option or {}).get("options") or []:
        if isinstance(entry, dict):
            values.append(str(entry.get("value") or entry.get("name") or ""))
        else:
            values.append(str(entry))
    return values


def usage_fields(usage):
    """Cost and token counts of one usage snapshot; absent values stay None."""
    if not isinstance(usage, dict):
        return None, None
    cost = None
    for key in ("cost", "cost_usd", "costUSD", "total_cost"):
        value = usage.get(key)
        if isinstance(value, (int, float)):
            cost = float(value)
            break
    total = 0
    found = False
    for key in (
        "inputTokens",
        "outputTokens",
        "input_tokens",
        "output_tokens",
        "cache_creation_input_tokens",
        "cache_read_input_tokens",
        "total",
    ):
        value = usage.get(key)
        if isinstance(value, (int, float)):
            total += int(value)
            found = True
    return cost, (total if found else None)


LAST_UPDATE_MAX_CHARS = 200


def summarize_text(text: str) -> str:
    """Collapse whitespace and truncate; empty text yields ''."""
    return " ".join(str(text).split())[:LAST_UPDATE_MAX_CHARS]


def transcript_activity_text(record: dict) -> str:
    """A short human summary of a transcript entry, for the stall wake.

    Permission, usage and housekeeping entries carry no progress worth
    reporting, so they only refresh the timestamp.
    """
    kind = str(record.get("type") or "")
    if kind == "message":
        return summarize_text(record.get("text") or "")
    if kind in ("tool_call", "tool_call_update"):
        title = str(record.get("title") or record.get("tool_call_id") or "tool")
        status = record.get("status") or "requested"
        return f"tool {title} ({status})"
    if kind == "stop":
        return f"turn ended ({record.get('stop_reason') or 'unknown'})"
    return ""


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
        model_obj = data.get("model") if isinstance(data.get("model"), dict) else {}
        self.model_state = dict(model_obj)
        self.model_wanted = self.acp.get("model") or self.model_state.get("declared") or None
        self.effort_wanted = self.acp.get("effort") or self.model_state.get("effort_declared") or None
        self.billing = self.model_state.get("billing")
        self.limit_usd = self.model_state.get("limit_usd")
        self.limit_tokens = self.model_state.get("limit_tokens")
        self.cost_total = self.model_state.get("cost_usd")
        self.tokens_total = self.model_state.get("tokens")
        if not isinstance(self.cost_total, (int, float)):
            self.cost_total = None
        if not isinstance(self.tokens_total, (int, float)):
            self.tokens_total = None
        self.turn_usage = None
        self.force_cost_limit = False
        self.limit_stopped = False
        self.limit_warning_sent = bool(self.model_state.get("warning_80"))
        self.model_deviation_reported = False
        self.deviation_this_turn = False
        self.cost_limit_wake_sent = False
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
        # Stall detection: the timestamp of the last transcript entry, the
        # text that entry carried, and whether the current working phase has
        # already woken the boss about a stall.
        self.last_activity = time.monotonic()
        self.last_activity_text = ""
        self.stall_wake_sent = False
        self.stalled = bool(self.acp.get("stalled"))
        # Blocked wakes are debounced per working -> blocked transition.
        self.blocked_wake_sent = False
        # Streamed message chunks with the same message id are joined, so
        # last_update describes the message instead of its final token.
        self.message_texts: dict[str, str] = {}
        self.stall_task = None

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
        if phase == "working":
            # A new working phase starts the stall window now: activity that
            # happened before a blocked phase must not count as progress.
            self.mark_activity()

    def mark_activity(self, text: str = "") -> None:
        """Record transcript progress and clear a stall that was reported.

        Called for every transcript entry, so a stalled working turn recovers
        as soon as the agent is active again.
        """
        self.last_activity = time.monotonic()
        if text:
            self.last_activity_text = summarize_text(text)
        self.stall_wake_sent = False
        if self.stalled:
            self.stalled = False
            self.acp_set(stalled=False, stalled_at=None)

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
        # Every transcript entry is progress for the stall watchdog.
        self.mark_activity(transcript_activity_text(record))
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
                    append_private(
                        self.transcript,
                        json.dumps({"t": now_iso(), "type": "transcript_rotated"}) + "\n",
                    )
            except FileNotFoundError:
                pass
            append_private(
                self.transcript, json.dumps(record, separators=(",", ":")) + "\n"
            )
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
        agent_info = result.get("agentInfo") or {}
        self.acp_set(
            load_session=self.load_session,
            protocol=result.get("protocolVersion"),
            agent_name=agent_info.get("name"),
            agent_version=agent_info.get("version"),
        )
        self.event(
            "acp_started",
            {
                "protocol": result.get("protocolVersion"),
                "load_session": self.load_session,
                "agent": (result.get("agentInfo") or {}).get("name"),
            },
        )
        return result

    def model_update(self, **fields) -> None:
        """Merge fields into the apply state's .model object."""
        def mutate(data):
            model = data.setdefault("model", {})
            model.update(fields)
        self.state.update(mutate)
        self.model_state.update(fields)

    def remember_seen(self, *names) -> list:
        seen = list(self.model_state.get("seen") or [])
        for name in names:
            if name and name not in seen:
                seen.append(name)
        return seen

    async def set_config_option(self, config_id: str, value: str) -> dict:
        result = await self.client.request(
            "session/set_config_option",
            {"sessionId": self.session_id, "configId": config_id, "value": value},
            timeout=30,
        )
        options = result.get("configOptions")
        if options is not None:
            self.config_options = options or []
        return result

    def current_value(self, config_id: str = "", category: str = ""):
        option = config_option(self.config_options, config_id, category)
        if option is None:
            return None
        return option.get("currentValue")

    async def confirm_config(self, after_load: bool = False) -> None:
        """Set model, then effort, then read both back before any prompt.

        An unpinned runner has no declared model; the agent's own default is
        recorded as the session's current value but never as a confirmed
        choice. A pinned runner gets an error when the agent does not offer the
        value or reports another one after accepting it.
        """
        model = self.model_wanted
        # The mode is independent of the model and is checked for an unpinned
        # runner too, so a wrong mode cannot slip through on a default model.
        if self.mode_wanted:
            ids = offered_modes(self.modes)
            if not ids:
                raise AcpError(
                    "mode_not_offered",
                    f"the agent does not advertise session modes; requested '{self.mode_wanted}'",
                )
            if self.mode_wanted not in ids:
                raise AcpError(
                    "mode_not_offered",
                    f"mode '{self.mode_wanted}' is not offered; available: {', '.join(ids) or '(none)'}",
                )
            await self.client.request(
                "session/set_mode",
                {"sessionId": self.session_id, "modeId": self.mode_wanted},
                timeout=30,
            )

        if not model:
            current = self.current_value("model")
            self.acp_set(model=current or None)
            seen = self.remember_seen(current)
            self.model_update(
                status="unpinned", confirmed=None, effort_confirmed=None,
                source="acp_config", checked_at=now_iso(), seen=seen,
            )
            return

        model_option = config_option(self.config_options, "model")
        values = values_of(model_option) if model_option is not None else None
        if model_option is None:
            code = "model_mismatch" if after_load else "model_not_offered"
            reason = (
                "the loaded session advertises no model config option"
                if after_load
                else "the agent does not advertise a model config option"
            )
            self.model_update(status="mismatch", checked_at=now_iso())
            raise AcpError(code, f"{reason}; requested '{model}'", {"declared": model})
        if model not in values:
            self.model_update(status="mismatch", checked_at=now_iso())
            raise AcpError(
                "model_not_offered",
                f"model '{model}' is not offered; available: {', '.join(values) or '(none)'}",
                {"declared": model, "available": values},
            )
        await self.set_config_option("model", model)

        # Effort goes after the model because the offered levels depend on the
        # selected model. OpenCode advertises it under the category
        # 'thought_level'; the option id itself may differ.
        effort_option = config_option(self.config_options, category="thought_level")
        if effort_option is None:
            effort_option = config_option(self.config_options, "effort")
        if self.effort_wanted:
            if effort_option is None:
                self.model_update(status="mismatch", checked_at=now_iso())
                raise AcpError(
                    "effort_not_offered",
                    f"the agent advertises no thought-level config option; requested '{self.effort_wanted}'",
                    {"declared": self.effort_wanted},
                )
            effort_values = values_of(effort_option)
            if self.effort_wanted not in effort_values:
                self.model_update(status="mismatch", checked_at=now_iso())
                raise AcpError(
                    "effort_not_offered",
                    f"effort '{self.effort_wanted}' is not offered for model '{model}'; available: {', '.join(effort_values) or '(none)'}",
                    {"declared": self.effort_wanted, "available": effort_values},
                )
            await self.set_config_option(str(effort_option.get("id")), self.effort_wanted)

        model_confirmed = self.current_value("model")
        effort_option = config_option(self.config_options, category="thought_level")
        if effort_option is None:
            effort_option = config_option(self.config_options, "effort")
        effort_confirmed = None
        if self.effort_wanted and effort_option is not None:
            effort_confirmed = effort_option.get("currentValue")
        if model_confirmed != model:
            self.model_update(status="mismatch", checked_at=now_iso())
            raise AcpError(
                "model_mismatch",
                f"declared model '{model}' but the configuration reports '{model_confirmed}'",
                {"declared": model, "confirmed": model_confirmed},
            )
        if self.effort_wanted and effort_confirmed != self.effort_wanted:
            self.model_update(status="mismatch", checked_at=now_iso())
            raise AcpError(
                "model_mismatch",
                f"declared effort '{self.effort_wanted}' but the configuration reports '{effort_confirmed}'",
                {"declared": self.effort_wanted, "confirmed": effort_confirmed},
            )

        self.acp_set(model=model)
        seen = self.remember_seen(model)
        self.model_update(
            declared=model,
            effort_declared=self.effort_wanted,
            confirmed=model_confirmed,
            effort_confirmed=effort_confirmed,
            status="confirmed",
            source="acp_config",
            checked_at=now_iso(),
            seen=seen,
        )

    async def apply_config(self, payload: dict, strict: bool = True, after_load: bool = False) -> None:
        config_options = payload.get("configOptions")
        if config_options is not None:
            self.config_options = config_options or []
        modes = payload.get("modes")
        if modes is not None:
            self.modes = modes or {}

        await self.confirm_config(after_load=after_load)

        mode = self.mode_wanted
        if not mode and isinstance(self.modes, dict):
            mode = self.modes.get("currentModeId")
        self.acp_set(mode=mode or None)
        self.event(
            "acp_config",
            {
                "model": self.model_wanted or None,
                "effort": self.effort_wanted or None,
                "confirmed": self.model_state.get("confirmed"),
                "mode": mode or None,
                "policy": self.policy,
            },
        )

    async def guard_model(self) -> None:
        """Repeat the confirmation before every further prompt.

        A deviation is recorded and woken once; the prompt is not sent.
        """
        try:
            await self.confirm_config()
        except AcpError as exc:
            if exc.code in ("model_mismatch", "model_not_offered", "effort_not_offered"):
                self.model_update(
                    status="mismatch",
                    checked_at=now_iso(),
                    error=exc.message,
                )
                self.event("acp_model_mismatch", {"code": exc.code, "message": exc.message})
                if not self.model_deviation_reported:
                    self.model_deviation_reported = True
                    await self.wake(
                        "settled",
                        "mismatch",
                        f"Apply {self.change} in {self.project}: model mismatch before the next prompt "
                        f"({exc.message}). The declared model is kept and no prompt was sent. "
                        f"Next step: boss status {self.change}",
                    )
            raise

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
        # A resumed session is checked as strictly as a new one, even when the
        # load returns no config options: a model that cannot be confirmed must
        # never be prompted.
        await self.apply_config(result, after_load=True)

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
            # Streaming splits one message into chunks; join them per message
            # id so last_update describes the message, not its final token.
            key = str(message_id or "")
            if key:
                self.message_texts[key] = self.message_texts.get(key, "") + text
                summary = self.message_texts[key]
            else:
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
            self.turn_usage = usage
            self.acp_set(usage=usage)
            self.transcript_append({"type": "usage", "usage": usage})
            # Usage is reported separately; keep last_update for the last
            # message or tool activity.
            summary = None
            await self.maybe_enforce_limit()
        elif kind in ("current_mode_update", "config_option_update"):
            if kind == "current_mode_update":
                self.acp_set(mode=update.get("currentModeId") or update.get("modeId"))
            else:
                await self.check_config_deviation(update.get("configOptions") or [])
            self.transcript_append({"type": kind, "update": update})
            summary = None
        else:
            self.transcript_append({"type": "update", "update": update})
            summary = None
        # A whitespace-only chunk and a usage-only update carry no progress
        # worth reporting: keep the previous last_update instead of a token.
        text = summarize_text(summary or "")
        if text:
            self.acp_set(last_update=text)

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
        if not items:
            # The blocked transition is over; the next request may wake again.
            self.blocked_wake_sent = False
        # pending_permission stays as an alias for readers from before the
        # queue; it always names the first still-unanswered request.
        self.acp_set(
            pending_permissions=items,
            pending_permission=(items[0] if items else None),
        )

    def pending_ids(self) -> list:
        return list(self.pending.keys())

    def schedule_blocked_wake(self) -> None:
        """Wake the boss once for one working -> blocked transition.

        The requests of one burst arrive as separate messages; a short
        coalescing delay lets the wake text name all of them instead of only
        the first one that happened to open the transition.
        """
        task = asyncio.create_task(self.send_blocked_wake())
        self.wake_tasks.add(task)
        task.add_done_callback(self.wake_tasks.discard)

    async def send_blocked_wake(self) -> None:
        await asyncio.sleep(BLOCKED_WAKE_COALESCE_S)
        if not self.pending or self.stop_event.is_set():
            # Answered, cancelled or shut down before the wake was due: no
            # stale 'blocked' wake for a transition that is already over.
            return
        items = self.pending_list()
        options = sorted(
            {
                str(option.get("optionId"))
                for item in items
                for option in item.get("options") or []
                if option.get("optionId")
            }
        )
        if len(items) == 1:
            only = items[0]
            title = only.get("title") or "permission request"
            command = only.get("command")
            detail = f"{title} -- {command}" if command else title
            summary = f"blocked on an ACP permission request ({detail})"
            tool_hint = f"--tool-call {only.get('tool_call_id')}"
        else:
            summary = (
                f"blocked on {len(items)} ACP permission requests ("
                + "; ".join(
                    f"{item.get('tool_call_id')}: {item.get('title') or 'permission request'}"
                    for item in items
                )
                + ")"
            )
            tool_hint = "--tool-call <id>"
        await self.wake(
            "blocked",
            "blocked",
            f"Apply {self.change} in {self.project}: {summary}. "
            f"Options: {', '.join(options) or '(none)'}. "
            f"Next step: boss answer {self.change} <option> {tool_hint} "
            f"(or boss interrupt {self.change})",
        )

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
        was_empty = not self.pending
        self.pending[tool_call_id] = entry
        self.persist_pending()
        # One working -> blocked transition wakes the boss once, however many
        # requests arrive before the first answer.
        transition = was_empty and not self.blocked_wake_sent
        if transition:
            self.blocked_wake_sent = True
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
        if transition:
            self.schedule_blocked_wake()
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

    # ------------------------------------------------------ model and cost ---
    def usage_totals(self) -> tuple:
        """Committed totals plus the current turn's latest usage snapshot."""
        cost = self.cost_total
        tokens = self.tokens_total
        if self.turn_usage is not None:
            snapshot_cost, snapshot_tokens = usage_fields(self.turn_usage)
            if snapshot_cost is not None:
                cost = (cost or 0.0) + snapshot_cost
            if snapshot_tokens is not None:
                tokens = (tokens or 0) + snapshot_tokens
        return cost, tokens

    def limit_exceeded(self) -> bool:
        cost, tokens = self.usage_totals()
        if isinstance(self.limit_usd, (int, float)) and cost is not None and cost >= self.limit_usd:
            return True
        if isinstance(self.limit_tokens, (int, float)) and tokens is not None and tokens >= self.limit_tokens:
            return True
        return False

    def warning_text(self) -> str:
        cost, tokens = self.usage_totals()
        parts = []
        if isinstance(self.limit_usd, (int, float)) and cost is not None and cost >= 0.8 * self.limit_usd:
            parts.append(f"cost {cost:.2f} USD of {self.limit_usd:.2f} USD")
        if isinstance(self.limit_tokens, (int, float)) and tokens is not None and tokens >= 0.8 * self.limit_tokens:
            parts.append(f"{tokens} tokens of {self.limit_tokens}")
        return ", ".join(parts)

    def record_usage(self, usage) -> None:
        if usage:
            cost, tokens = usage_fields(usage)
            if cost is not None:
                self.cost_total = (self.cost_total or 0.0) + cost
            if tokens is not None:
                self.tokens_total = (self.tokens_total or 0) + tokens
        self.turn_usage = None
        fields = {"cost_usd": self.cost_total, "tokens": self.tokens_total, "usage_at": now_iso()}
        warning = self.warning_text()
        if warning and not self.limit_warning_sent:
            self.limit_warning_sent = True
            fields["warning_80"] = True
            fields["warning"] = warning
            self.event(
                "acp_cost_warning",
                {
                    "cost_usd": self.cost_total,
                    "tokens": self.tokens_total,
                    "limit_usd": self.limit_usd,
                    "limit_tokens": self.limit_tokens,
                },
            )
        self.model_update(**fields)

    def limit_description(self) -> str:
        cost, tokens = self.usage_totals()
        used = []
        if cost is not None:
            used.append(f"cost {cost:.2f} USD")
        if tokens is not None:
            used.append(f"{tokens} tokens")
        limits = []
        if isinstance(self.limit_usd, (int, float)):
            limits.append(f"{self.limit_usd:.2f} USD")
        if isinstance(self.limit_tokens, (int, float)):
            limits.append(f"{self.limit_tokens} tokens")
        return (
            f"used {', '.join(used) or 'unknown'}; limit {', '.join(limits) or 'none'}"
        )

    async def maybe_enforce_limit(self) -> None:
        warning = self.warning_text()
        if warning and not self.limit_warning_sent:
            self.limit_warning_sent = True
            self.model_update(warning_80=True, warning=warning)
            self.event(
                "acp_cost_warning",
                {
                    "cost_usd": self.cost_total,
                    "tokens": self.tokens_total,
                    "limit_usd": self.limit_usd,
                    "limit_tokens": self.limit_tokens,
                },
            )
        if not self.limit_exceeded() or self.limit_stopped:
            return
        self.limit_stopped = True
        self.force_cost_limit = True
        self.model_update(stop_reason="cost_limit", stop_at=now_iso())
        self.event(
            "acp_cost_limit",
            {
                "cost_usd": self.cost_total,
                "tokens": self.tokens_total,
                "limit_usd": self.limit_usd,
                "limit_tokens": self.limit_tokens,
            },
        )
        self.transcript_append({"type": "cost_limit", "usage": self.turn_usage or {}})
        if self.turn_task is not None and not self.turn_task.done() and self.session_id:
            try:
                await self.client.notify("session/cancel", {"sessionId": self.session_id})
            except Exception as exc:  # best effort; the turn timeout still bounds it
                log(f"warning: cannot cancel a turn past its cost limit: {exc!r}")

    async def check_config_deviation(self, config_options) -> None:
        """A later config_option_update that deviates is a mismatch, not a fix.

        The declared values stay in the state; the actual values are recorded
        separately and the turn is cancelled. One wake per apply.
        """
        if self.model_state.get("status") != "confirmed":
            return
        actual_model = None
        actual_effort = None
        for option in config_options or []:
            if not isinstance(option, dict):
                continue
            oid = str(option.get("id") or "")
            category = str(option.get("category") or "").lower()
            value = option.get("currentValue")
            if oid == "model":
                actual_model = value
            elif category == "thought_level" or oid == "effort":
                actual_effort = value
        model_dev = bool(
            self.model_wanted and actual_model is not None and actual_model != self.model_wanted
        )
        effort_dev = bool(
            self.effort_wanted
            and actual_effort is not None
            and actual_effort != self.effort_wanted
        )
        if not model_dev and not effort_dev:
            return
        seen = self.remember_seen(actual_model, actual_effort)
        self.model_update(
            status="mismatch",
            checked_at=now_iso(),
            actual=actual_model,
            actual_effort=actual_effort,
            seen=seen,
        )
        self.event(
            "acp_model_mismatch",
            {
                "declared": self.model_wanted,
                "confirmed": actual_model,
                "effort_declared": self.effort_wanted,
                "effort_confirmed": actual_effort,
            },
        )
        if self.model_deviation_reported:
            return
        self.model_deviation_reported = True
        self.deviation_this_turn = True
        detail = []
        if model_dev:
            detail.append(f"declared model '{self.model_wanted}' but the agent reports '{actual_model}'")
        if effort_dev:
            detail.append(f"declared effort '{self.effort_wanted}' but the agent reports '{actual_effort}'")
        self.wake_background(
            "settled",
            "mismatch",
            f"Apply {self.change} in {self.project}: model mismatch during the run "
            f"({'; '.join(detail)}). The turn was cancelled, the declared model is kept. "
            f"Next step: boss status {self.change}",
        )
        task = asyncio.create_task(self.cancel_turn())
        self.wake_tasks.add(task)
        task.add_done_callback(self.wake_tasks.discard)

    # --------------------------------------------------------------- turns ---
    async def run_turn(self, text: str) -> str:
        self.message_texts.clear()
        self.stall_wake_sent = False
        self.turn_usage = None
        self.force_cost_limit = False
        self.deviation_this_turn = False
        self.set_phase("working", "working")

        # No prompt is sent until model and effort are confirmed again. A
        # retrigger or resume therefore cannot drift silently.
        try:
            await self.guard_model()
        except AcpError as exc:
            self.acp_set(last_stop_reason="model_mismatch")
            self.set_phase("idle", "mismatch")
            self.event("acp_stop", {"stop_reason": "model_mismatch", "code": exc.code})
            self.transcript_append(
                {"type": "stop", "stop_reason": "model_mismatch", "message": exc.message}
            )
            return "model_mismatch"

        # A limit that was already reached (a resumed apply) is a hard stop:
        # no further prompt is sent. The first stop wakes once.
        if self.limit_exceeded():
            self.limit_stopped = True
            self.force_cost_limit = True
            self.model_update(stop_reason="cost_limit", stop_at=now_iso())
            if not self.cost_limit_wake_sent:
                self.cost_limit_wake_sent = True
                await self.wake(
                    "settled",
                    "cost_limit",
                    f"Apply {self.change} in {self.project}: cost_limit ({self.limit_description()}). "
                    f"Next step: boss status {self.change}",
                )
            self.acp_set(last_stop_reason="cost_limit")
            self.set_phase("idle", "cost_limit")
            return "cost_limit"

        self.event("acp_prompt", {"text": text[:2000]})
        self.transcript_append({"type": "prompt", "text": text[:4000]})
        timeout = turn_timeout()
        self.turn_task = asyncio.create_task(
            self.client.request(
                "session/prompt",
                {"sessionId": self.session_id, "prompt": [{"type": "text", "text": text}]},
                timeout=timeout,
            )
        )
        stop_reason = "unknown"
        usage = None
        try:
            result = await self.turn_task
            stop_reason = str(result.get("stopReason") or "unknown")
            # The turn's usage_update may carry cost that the prompt result
            # omits; merge both, with the final result fields winning.
            merged = dict(self.turn_usage or {})
            merged.update(result.get("usage") or {})
            usage = merged or None
            if usage:
                self.usage = usage
                self.acp_set(usage=usage)
        except asyncio.TimeoutError:
            # Bounded failure path: the wait ends here even if the agent keeps
            # working. Tell the child to cancel so it does not run a second
            # turn behind our back, then record the reason.
            stop_reason = "turn_timeout"
            log(f"acp: turn timed out after {timeout}s; sending session/cancel")
            self.event("acp_timeout", {"timeout_s": timeout})
            if self.session_id:
                try:
                    await self.client.notify("session/cancel", {"sessionId": self.session_id})
                except Exception as exc:
                    log(f"warning: cannot cancel a timed-out turn: {exc!r}")
        except AcpError as exc:
            stop_reason = "failed"
            self.acp_set(error=exc.message)
            log(f"acp: prompt failed: {exc.message}")
        finally:
            self.turn_task = None

        if usage is None:
            usage = self.turn_usage
        self.record_usage(usage)
        await self.maybe_enforce_limit()
        if self.force_cost_limit:
            stop_reason = "cost_limit"
        self.acp_set(last_stop_reason=stop_reason)
        self.event(
            "acp_stop",
            {
                "stop_reason": stop_reason,
                "usage": self.usage,
                "cost_usd": self.cost_total,
                "tokens": self.tokens_total,
            },
        )
        self.transcript_append({"type": "stop", "stop_reason": stop_reason, "usage": self.usage})
        last_state = "idle" if stop_reason in ("end_turn", "unknown") else stop_reason
        self.set_phase("idle", last_state)
        if self.deviation_this_turn:
            # The deviation handler already cancelled the turn and woke once.
            self.acp_set(last_stop_reason="model_mismatch")
            self.set_phase("idle", "mismatch")
            return "model_mismatch"
        if self.stop_event.is_set():
            # Finish or a stop signal: the Explorer initiated the end, so no
            # wake is needed (and none should delay shutdown).
            return stop_reason
        if stop_reason == "end_turn":
            message = "idle (ACP turn ended, stopReason end_turn)"
        elif stop_reason == "cancelled":
            message = "cancelled (ACP turn ended, stopReason cancelled)"
        elif stop_reason == "cost_limit":
            message = f"cost_limit ({self.limit_description()})"
        elif stop_reason == "turn_timeout":
            message = (
                "turn_timeout (ACP turn did not answer within "
                f"BOSS_ACP_TURN_TIMEOUT_S={int(timeout or 0)}s)"
            )
        else:
            message = f"{stop_reason} (ACP turn ended, stopReason {stop_reason})"
        if stop_reason == "cost_limit":
            self.cost_limit_wake_sent = True
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
                    "last_update": self.acp.get("last_update"),
                    "stalled": bool(self.stalled),
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

    async def stall_watchdog(self) -> None:
        """Wake the boss once when a working turn stops making progress.

        The heartbeat only proves the supervisor is alive, so the check is
        based on transcript activity. A blocked turn waits for the Explorer by
        design and is never a stall; a turn that becomes active again clears
        the reported stall so a later silence can be reported again.
        """
        stall = stall_interval()
        if stall <= 0:
            log("acp: stall detection disabled (BOSS_ACP_STALL_S=0)")
            return
        interval = min(30.0, max(0.2, stall / 2.0))
        while not self.stop_event.is_set():
            try:
                await asyncio.wait_for(self.stop_event.wait(), interval)
                return
            except asyncio.TimeoutError:
                pass
            if self.phase != "working" or self.stall_wake_sent:
                continue
            age = time.monotonic() - self.last_activity
            if age < stall:
                continue
            last = self.last_activity_text or "no transcript activity"
            self.stall_wake_sent = True
            self.stalled = True
            self.acp_set(stalled=True, stalled_at=now_iso())
            self.event(
                "acp_stall",
                {"age_s": int(age), "stall_s": int(stall), "last_activity": last},
            )
            log(f"acp: turn stalled ({int(age)}s without progress): {last}")
            await self.wake(
                "stalled",
                "stalled",
                f"Apply {self.change} in {self.project}: stalled (no transcript progress for "
                f"{int(age)}s, last activity: {last}). "
                f"Next step: boss status {self.change} (or boss interrupt {self.change})",
            )

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
            stalled=False,
            stalled_at=None,
        )
        self.message_texts.clear()
        self.blocked_wake_sent = False
        self.stalled = False
        self.set_phase("starting", "starting")
        self.heartbeat_task = asyncio.create_task(self.heartbeat())
        self.stall_task = asyncio.create_task(self.stall_watchdog())
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
            self.acp_set(error=detail, error_code=exc.code)
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
        for task in (self.heartbeat_task, self.stall_task):
            if task is None:
                continue
            task.cancel()
            try:
                await task
            except (asyncio.CancelledError, Exception):
                pass
        self.event("acp_exit", {"reason": "closed", "stop_reason": self.acp.get("last_stop_reason")})
        self.acp_set(
            phase="closed",
            supervisor_pid=None,
            pending_permission=None,
            pending_permissions=[],
            stalled=False,
        )
        self.closed_event.set()
        log("acp: supervisor stopped")


# ------------------------------------------------------------------ probe ---

async def probe(command: str, cwd: str, model, effort, mode, timeout: float, profile_temp: bool = False) -> dict:
    result = {
        "status": "ok",
        "command": command,
        "cwd": cwd,
        "protocol": None,
        "load_session": None,
        "agent_version": None,
        "models": [],
        "efforts": [],
        "modes": [],
        "session_left": False,
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
    closed = False
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
        result["agent_version"] = (init.get("agentInfo") or {}).get("version")
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
            else:
                set_result = await client.request(
                    "session/set_config_option",
                    {"sessionId": session_id, "configId": "model", "value": model},
                    timeout=timeout,
                )
                config_options = set_result.get("configOptions") or config_options
        effort_option = config_option(config_options, category="thought_level")
        if effort_option is None:
            effort_option = config_option(config_options, "effort")
        efforts = values_of(effort_option) if effort_option is not None else []
        result["efforts"] = efforts
        if result["status"] == "ok" and effort:
            if effort_option is None:
                result.update(
                    status="fail",
                    message=f"effort '{effort}' is not offered: the agent advertises no thought-level config option for model '{model or 'default'}'",
                )
            elif effort not in efforts:
                result.update(
                    status="fail",
                    message=f"effort '{effort}' is not offered for model '{model or 'default'}'; available: {', '.join(efforts) or '(none)'}",
                )
            else:
                await client.request(
                    "session/set_config_option",
                    {"sessionId": session_id, "configId": str(effort_option.get("id")), "value": effort},
                    timeout=timeout,
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
                closed = True
            except Exception:
                pass
        # A non-isolated probe uses the user's own agent store. Close the
        # session and delete it when the agent supports deletion; otherwise
        # report the empty session instead of hiding it.
        if session_id and not profile_temp:
            try:
                await client.request("session/delete", {"sessionId": session_id}, timeout=3)
            except Exception as exc:
                result["session_left"] = True
                note = f"an empty probe session {session_id} remains in the user's agent store"
                result["message"] = (result["message"] + "; " + note).strip("; ")
                log(f"acp probe: {note} ({exc})")
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
    parser.add_argument("--effort", default="")
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
                args.effort or None,
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
