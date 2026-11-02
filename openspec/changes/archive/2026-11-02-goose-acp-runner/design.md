# Design

## Context

The boss runtime starts every worker through `herdr agent start`, then waits on
Herdr agent state (`idle`/`working`/`blocked`) and reads the pane for status.
That model works for Herdr-native kinds (OpenCode, Claude) but not for Goose,
which Herdr does not recognize as an agent.

A protocol probe against `goose acp` (Goose 1.57, ACP `agent-client-protocol`
2.2.0) established the relevant behavior:

| Probe | Result |
| --- | --- |
| `initialize` | protocol 1, `loadSession: true`, session `list`/`delete`/`close` |
| `session/new` | returns `sessionId`, `modes` (`auto`, `approve`, `smart_approve`, `chat`) and `configOptions` (`provider`, `mode`, `model`, `thinking_effort`) |
| model switch | `session/set_config_option {configId: "model"}` switches immediately and emits `config_option_update` |
| tools | loaded from the Goose config without `--with-builtin` |
| `approve` mode | one `session/request_permission` per write/shell call, with `rawInput` and four options |
| reject | the command did not run and the turn continued |
| `session/cancel` | `stopReason: "cancelled"` during generation and during a running shell tool |
| `session/load` | replay of 11 updates, then a normal response |
| turn end | `session/prompt` returns `stopReason` plus token usage; `usage_update` carries cost |

The runtime already requires Python 3.11+ and already speaks JSON-RPC over a
Unix socket for Herdr (`herdr_raw`). A supervisor in Python adds no dependency
and fits the existing state/event model.

## Goals / Non-Goals

**Goals**

- Add an ACP transport without changing the behavior of Herdr-native runners.
- Make the ACP turn the unit of waiting, so completion, cancellation and
  blocking are explicit instead of inferred from a screen.
- Put the permission decision in the runtime's policy, with a path to ask the
  Explorer.
- Keep one apply state model, one event log and the existing slots/locks.

**Non-Goals**

- Rendering an interactive terminal UI for the ACP agent.
- Replacing the Herdr integration for OpenCode or Claude.
- Running ACP agents on a remote machine (`goose serve`).
- Making the worktree a sandbox; it remains isolation, not a security boundary.

## Decisions

### 1. An explicit transport field, not an implicit kind

A runner gains `start = "herdr" | "acp"` (default `herdr`). `kind` stays the
Herdr kind and is ignored by the ACP path. A runner with `start = "acp"` also
declares `command` and may declare `model`, `mode`, `deny` and `apply`.

*Why:* inferring "ACP" from an unknown `kind` would make a typo start a
different transport. An explicit field keeps the native path byte-for-byte
unchanged and makes `boss doctor` able to validate the right thing.

*Alternative rejected:* a `kind = "goose"` that Herdr would have to learn. Herdr
has no such kind, and its state would still be screen-based.

### 2. A detached supervisor owns the ACP child and the turn

`boss dispatch` writes the apply state and starts a detached `boss-acp`
supervisor. The supervisor spawns `<command> acp`, speaks newline-delimited
JSON-RPC on stdio, sends the apply prompt, handles updates and permissions, and
writes the same events and wake messages as `boss-waiter`.

*Why:* the ACP child's stdio belongs to one process. A detached owner survives
the Explorer's turn, keeps the session alive for `boss answer` and
`boss interrupt`, and can resume after the Explorer restarts.

*Alternative rejected:* making the Explorer session the ACP client. The Explorer
turn ends; the child would die with it. It also couples the model session to the
apply lifetime.

### 3. The prompt response is the turn boundary

The supervisor waits for the `session/prompt` response and records
`stopReason` (`end_turn`, `cancelled`, `max_tokens`, `refusal`, ...). The apply
becomes ready only on that response, not on a pane state.

*Why:* it removes polling, readiness races and the ambiguity between "idle" and
"done". The response also carries token usage.

*Trade-off:* the supervisor must distinguish a long turn from a hung agent. It
uses a configurable turn timeout and records a `turn_timeout` state instead of
waking as if the turn had ended.

### 4. Permissions are a policy, not a prompt

On `session/request_permission` the supervisor applies, in order:

1. `deny` rules (command, path or title) → select a `reject_*` option.
2. `allow` rules / read-only tools → select an `allow_*` option.
3. otherwise, if the runner's policy is `ask` → keep the request pending,
   report `blocked` and wake the boss.
4. otherwise → allow by default (documented and configurable).

`boss answer` selects one of the offered options. `boss interrupt` answers every
pending request with `cancelled` before sending `session/cancel`.

*Why:* the agent's `toolCall.kind` is `other` and `name` is empty in the probe;
matching must use `rawInput.command`, `rawInput.path` and `title`. A policy
keyed on `kind` alone would miss the shell and write calls.

*Default:* `smart_approve` for new ACP runners, so not every write asks; `auto`
is opt-in. The deny list remains the hard boundary; `ask` is for unknown
commands, not for routine edits.

### 5. Model and mode are session configuration

Before the first prompt the supervisor reads `session/new`'s `configOptions` and
`modes`, applies the runner's `model` and `mode`, and fails the dispatch if a
configured value is not offered, naming the available values.

*Why:* the probe showed the switch is immediate and emits
`config_option_update`. No process restart, no environment juggling. It also
makes the model visible in status.

### 6. Resume is explicit and never silent

The state stores the ACP session id, model, mode and worktree. After a
supervisor crash, `boss resume` starts a new supervisor that calls
`session/load` when the agent advertises `loadSession`, replays updates into the
transcript, and re-applies model/mode. If loading is unsupported, the apply is
marked unresumable and the Explorer is offered a retrigger instead of a second
session silently editing the same worktree.

*Why:* a fresh session would lose the conversation and could repeat work. A
silent fallback is worse than a clear failure.

### 7. Transcript is data, status is state

`session/update` notifications are appended to a JSONL transcript and rendered
as concise text lines (assistant chunks, tool titles, status changes, usage).
`boss status` reads the state file and the transcript tail; it does not read a
terminal.

*Why:* ACP is the source of truth. A pane may show the transcript for a human,
but no behavior depends on screen contents.

### 8. Slots, liveness and the display-only tab

The apply state records `transport`, `supervisor_pid` and `session_id`.
`open_apply_count` counts an ACP apply while its supervisor is alive; a dead
supervisor frees the slot and triggers a wake. Locks remain keyed by project and
change and are unchanged.

The apply still creates its Herdr tab and workspace for the worktree, but the
tab runs a transcript tail, not an agent. No Herdr agent name or state is used
for waiting, prompting or interrupting.

*Why:* the worktree requirement says every worktree apply runs in its own Herdr
workspace, and the tab gives the Explorer a live view. Liveness still follows
the supervisor pid, because there is no Herdr agent to ask.

*Alternative rejected:* dropping the tab and relaxing the worktree requirement.
That would remove the only live view and turn a transport addition into a
rewrite of the worktree contract.

### 9. Apply prompt is CLI-based

The ACP apply prompt asks the agent to run
`openspec instructions apply --change <change> --json` and follow the returned
instructions, then appends the existing charter, lessons, external-verification
and commit-policy blocks. It does not use `/opsx-apply`.

*Why:* Goose slash commands are recipes; `/opsx-apply` is not one. The CLI
instruction is available to any agent and does not depend on a project-specific
skill directory that Goose does not read.

### 10. A fake ACP peer makes the runtime testable

The regression suite ships a small Python fake that implements `initialize`,
`session/new`, `session/prompt`, `session/update`, `session/request_permission`,
`session/cancel`, `session/load` and `session/close`. Tests point an ACP runner
at it and exercise dispatch, model/mode, allow/reject/ask, cancel, load, slots
and doctor without a model or network.

## Architecture

```
boss dispatch --runner <acp-runner>
  |
  +-- resolve runner, worktree, state (transport=acp)
  +-- write apply state, events
  +-- create the Herdr tab (transcript tail, no agent)
  +-- spawn detached boss-acp <state-file>
        |
        +-- <command> acp          (stdio JSON-RPC)
        +-- initialize
        +-- session/new {cwd: <apply root>}
        +-- set_config_option {model} / set_mode {mode}
        +-- session/prompt {apply prompt}
        |     |
        |     +-- session/update  --> transcript + events
        |     +-- request_permission --> policy / pending (blocked)
        +-- prompt response {stopReason} --> event + wake
        +-- control socket  <-- boss answer / interrupt / finish
        +-- session/close on finish
```

State machine of one apply:

```
dispatch --> starting --> working --> idle (end_turn) --review--> finished
                 |           |  ^
                 |           v  |
                 |        blocked (pending permission)
                 |           |
                 +--------> cancelled (interrupt)
                 |
                 +--------> failed / turn_timeout / unresumable
```

## Data Model

The apply state adds:

```json
{
  "transport": "acp",
  "acp": {
    "command": "goose",
    "session_id": "...",
    "model": "...",
    "mode": "smart_approve",
    "supervisor_pid": 12345,
    "control_socket": "...",
    "transcript": "...",
    "last_stop_reason": "end_turn",
    "pending_permission": {
      "tool_call_id": "...",
      "title": "shell · ...",
      "raw_input": {"command": "..."},
      "options": ["allow_once", "reject_once"]
    }
  }
}
```

Event types: `acp_started`, `acp_session`, `acp_config`, `acp_prompt`,
`acp_permission`, `acp_permission_answered`, `acp_stop`, `acp_cancel`,
`acp_load`, `acp_exit`.

## Control Channel

The supervisor listens on a per-apply Unix socket in the state directory. The
boss CLI sends small JSON commands (`answer`, `cancel`, `finish`, `status`) and
reads one JSON response. The supervisor also writes a heartbeat timestamp.

*Alternative rejected:* a command file polled by the supervisor. It is portable
but adds latency and a second state machine for permission answers; the runtime
already requires a Unix socket for Herdr.

## Risks / Trade-offs

- **Permission noise** → default `smart_approve`, allow read-only tools, deny
  rules for destructive commands; make `ask` explicit.
- **Agent ignores cancel** → the supervisor waits a bounded time for the
  `cancelled` response, then records `cancel_unconfirmed` and wakes the boss.
- **Transcript grows without bound** → append-only JSONL with a size cap and
  rotation per apply; status reads only the tail.
- **`session/load` replay duplicates updates** → deduplicate by `messageId`
  and `toolCallId` when replaying, and mark the transcript boundary.
- **Crash between permission and answer** → the pending request is persisted;
  a restarted supervisor replays it only if the session can be loaded,
  otherwise the apply is marked unresumable.
- **Two transports increase maintenance** → the native path is untouched; the
  ACP path is isolated behind `start = "acp"` and one supervisor module.
- **No TUI for the human** → the transcript is the visibility surface; the
  Explorer can `boss status` and read the log. This is the chosen trade-off.
- **Provider/auth failure at `session/new`** → the supervisor records the error,
  sends a wake and leaves a clear message; no worktree changes are assumed.
- **Goose ACP changes across versions** → the doctor checks the handshake and
  the advertised model/mode; a probe test guards the expected shapes.

## Migration Plan

1. Add the transport and the supervisor disabled by default (no runner uses it).
2. Document the new runner fields and add one example configuration.
3. Run the fake-ACP suite in CI on Linux and macOS.
4. Enable a Goose runner explicitly in `boss.toml`; the existing runners keep
   their behavior and state files.
5. Rollback: remove or disable the ACP runner; existing applies and runners are
   unaffected. A running ACP apply is finished or interrupted before rollback.

## Open Questions

- Whether to expose `session/list` in `boss status` for abandoned sessions, or
  rely on `boss doctor` for cleanup.
- Whether the transcript should be one file per turn or per apply; the state
  only needs the path and the last offset.
- Whether `ask` should be per tool kind or only per command/path pattern; the
  first implementation can use the deny list plus a default.
