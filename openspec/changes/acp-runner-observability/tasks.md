# Tasks

## 1. Status

- [x] 1.1 Extract the effective-waiter helper (ACP supervisor pid vs native
      `waiter_pid`) and use it in the aggregate `boss status` view.
- [x] 1.2 Add `runner`, `acp.model`, `acp.mode` and `pending_permissions[]` to
      the status JSON; keep `pending_permission` as the first entry.
- [x] 1.3 Render the pending count and ids in the aggregate and blocked views;
      keep the existing single-request output readable.
- [x] 1.4 Keep `last_update` on the last message text or tool activity, ignore
      usage-only and whitespace-only chunks, and truncate the value.

## 2. Turn bounds

- [x] 2.1 Default `BOSS_ACP_TURN_TIMEOUT_S` to a non-zero value, keep `0` as an
      explicit disable, and record `turn_timeout` as the stop reason.
- [x] 2.2 Add `BOSS_ACP_STALL_S` with a progress timestamp updated by every
      transcript entry; a working turn without progress wakes once with
      `stalled` and the last activity.
- [x] 2.3 Reset the stall timestamp and the sent flag on new activity, and
      exclude the blocked phase from stall detection.

## 3. Wake dedupe

- [x] 3.1 Send one blocked wake per `working -> blocked` transition and include
      the number of pending requests; clear the flag when the last request is
      answered.
- [x] 3.2 Keep the inbox/event path unchanged so a single wake still reaches the
      dispatcher.

## 4. Tests

- [x] 4.1 Cover the aggregate view reporting an alive ACP supervisor as alive.
- [x] 4.2 Cover the new JSON fields, the `pending_permission` alias and the
      last-update value.
- [x] 4.3 Cover turn timeout, stall wake, progress reset and a long command
      that keeps emitting progress updates.
- [x] 4.4 Cover one wake for two concurrent requests.

## 5. Documentation and verification

- [x] 5.1 Document the new status fields, the two timeout variables and the
      wake behaviour in `README.md` and `vision/SKILL.md`.
- [x] 5.2 Run the full suite and the static, manifest, wrapper and OpenSpec
      gates; verify all green.
- [x] 5.3 Verify the worktree contains no change outside the planned files and
      record the gate results for the Explorer.

## Workflow follow-up

- Keep the default turn timeout above the configured test budget, and raise it
  for a project with a longer suite rather than disabling it.
