# Proposal

## Why

The ACP runner reports state that does not match its process tree. In the
external review, `boss status` (the aggregate view) showed `waiter: DEAD` while
the supervisor and `goose acp` were alive; the detail view showed `waiter_alive:
true`. The same run exposed one pending permission at a time, no runner name in
the status JSON, and `last_update` reduced to a single streamed token (".").
A turn also had no timeout: after the permission hang the apply stayed `working`
for six minutes until it was interrupted by hand.

These are not cosmetic defects. They make a stuck apply look healthy, hide
which runner/model/mode is active, and leave no bounded failure path.

## What Changes

- Make the aggregate `boss status` derive ACP liveness from
  `acp.supervisor_pid` the same way the detail view does.
- Add `runner`, `acp.model`, `acp.mode` and `pending_permissions[]` to the
  status JSON; keep `pending_permission` as a compatibility alias for the first
  entry.
- Keep `last_update` on the last message text or tool activity instead of the
  final token/whitespace chunk.
- Add a configurable turn timeout (`BOSS_ACP_TURN_TIMEOUT_S`, non-zero default)
  and a stall watchdog that wakes the Explorer when a `working` turn has made no
  transcript progress for `BOSS_ACP_STALL_S`.
- Debounce `blocked` wakes: one wake per `working -> blocked` transition, not one
  per concurrent permission request.
- Cover the status fields, timeout, stall and wake dedupe in the fake-ACP suite.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `acp-runner`: transcript and status, turn completion and wake, state/slots and
  liveness, plus a new turn-timeout requirement.

## Impact

- `runtime/lib/boss_acp.py`, `runtime/bin/boss-status.sh`,
  `runtime/bin/boss-run.sh`, `runtime/bin/boss-apply.sh` (state defaults),
  `tests/run.sh`, `README.md`, `vision/SKILL.md`.
- Additive JSON fields; existing consumers of `pending_permission` keep working.
- The timeout and stall defaults must stay above the longest expected command
  (the full suite currently takes about eight minutes), so they are configurable
  and documented.
