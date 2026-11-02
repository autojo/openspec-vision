# Design

## Context

See `proposal.md` - Why. Two code paths decide what status says. The per-apply
view (`boss-status.sh`, `status_one`) falls back to `acp.supervisor_pid` when
`waiter_pid` is empty. The aggregate view (`status_all`) reads `.waiter_pid`
only, so an ACP apply whose supervisor is alive is printed as `waiter: DEAD`.
The JSON has no `runner` field, one `pending_permission`, and `last_update` is
set from the last streamed chunk, which is often a single token.

`run_turn` reads `BOSS_ACP_TURN_TIMEOUT_S` with a default of `0`, so the prompt
request has no timeout. The heartbeat records liveness every five seconds but
does not compare activity. `handle_permission` wakes the boss for every
request, so two concurrent requests produce two wakes.

## Goals / Non-Goals

**Goals**

- Make status truthful about the process and the pending work.
- Bound a turn and surface a stalled one.
- One wake per blocked transition.

**Non-Goals**

- A full metrics system or a UI.
- Changing the ACP protocol.
- Changing permission queue semantics (delivered by `acp-permission-integrity`).

## Decisions

### 1. Reuse the detail liveness rule in the aggregate view

Extract a helper that returns the effective waiter pid for a state file: the
supervisor pid for ACP, `waiter_pid` for native. `status_all` uses it for
`waiter_alive` and for the printed pid. The detail view already does this; the
change removes the duplication rather than adding a second rule.

*Alternative rejected:* special-case ACP in the aggregate print. The JSON would
still be wrong.

### 2. Additive status fields

The status JSON gains:

- `runner`: the recorded runner name (also in the aggregate row);
- `acp.model` and `acp.mode`: already in the state, surfaced explicitly;
- `pending_permissions`: the full list, with `pending_permission` kept as the
  first entry;
- `acp.last_update`: a message or tool summary, not a token; truncated to 200
  characters and never set from `usage_update`.

The aggregate row gains the runner, the pending count and the pending
tool-call ids, so a blocked apply is visible without opening the detail view.

A reader that only understands `pending_permission` continues to work.

*Alternative rejected:* replace `pending_permission` with a list. It breaks the
existing status tests and any external reader for no gain.

### 3. Turn timeout and stall watchdog

`BOSS_ACP_TURN_TIMEOUT_S` keeps its name but defaults to `7200` (two hours)
instead of `0`. A value of `0` disables it explicitly. A timeout ends the turn
with `turn_timeout` and uses the existing wake path.

A separate `BOSS_ACP_STALL_S` defaults to `1800` (thirty minutes). The
supervisor records the timestamp of the last transcript activity; a watchdog
checks every 30 seconds while the phase is `working`. When the age exceeds the
threshold it wakes the boss once with state `stalled` and the last activity,
sets `acp.stalled`, and marks the wake as sent so it does not repeat. The phase
stays `working`: the turn is still running and may recover, so `blocked` (which
means "waiting for the Explorer") would be wrong. Any new transcript entry
resets the timestamp, the sent flag and `acp.stalled`, so a later silence can be
reported again. A tool call that is still running counts as activity only when
it emits `tool_call_update`; a long `./tests/run.sh` with no updates is
therefore not a false stall before 30 minutes.

*Alternative rejected:* derive the stall from the heartbeat file. The heartbeat
proves the supervisor is alive, not that the agent is making progress.

### 4. Wake dedupe

The supervisor keeps `blocked_wake_sent`. The first pending request in a
`working -> blocked` transition opens the wake and sets the flag; further
requests update the pending list without another wake. When the last pending
request is answered, the phase returns to `working` and the flag clears. The
wake text names the number of pending requests.

The requests of one burst arrive as separate messages, so the wake is held for
a short coalescing window (250 ms) and its text is built when it is sent. A
wake whose transition ended in the meantime is skipped instead of arriving as a
stale `blocked` event.

*Alternative rejected:* rely on the inbox to dedupe. The inbox is a delivery
queue, not a state machine; duplicate events still cost a wake and a prompt.

## Risks / Trade-offs

- **Timeout kills a legitimate long command** -> the default is two hours and
  the suite has a separate budget; the value is documented and configurable.
- **Stall false positive during a silent long tool** -> thirty minutes is above
  the current eight-minute suite; `tool_call_update` resets the timer.
- **New JSON fields confuse strict consumers** -> additive only; the existing
  keys keep their shape.
- **Wake dedupe hides a second request** -> the wake text includes the pending
  count and `boss status` lists every request; the Explorer can still answer
  each one.

## Migration Plan

No data migration. New state fields are written on the next transition. Existing
applies pick up the new defaults when the supervisor restarts. `BOSS_ACP_TURN_TIMEOUT_S=0`
preserves the old behaviour for an operator who wants it.

## Resolved Questions

- Is `stalled` a distinct apply state or `blocked`? Neither: the phase stays
  `working` (the turn is still running and may recover) and `acp.stalled` marks
  it. The wake uses state `stalled`, so the existing wake path delivers it.
- Is the stall watchdog disabled for `policy = "ask"` applies, where a pending
  permission is expected? No special case is needed: the watchdog only checks a
  `working` phase, so a `blocked` apply is never reported as stalled.
