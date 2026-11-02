# Design

## Context

The fake-ACP suite covers the queue and the allow-once selection, but a real
Goose session under `policy = "ask"` is the only way to confirm that Goose
actually emits two concurrent `session/request_permission` messages and that the
installed supervisor keeps both pending. The normal `goose` runner is used
(`policy = "ask"`, `smart_approve`, isolated profile), not `goose-review`.

## Goals / Non-Goals

**Goals**

- Two real concurrent requests are visible as two `pending_permissions`.
- Answering one by tool-call id leaves the other pending.
- An `allow_always` answer becomes an apply grant, is sent as `allow_once`,
  and a repeated identical command does not prompt again.
- `boss interrupt` cancels two real pending requests and ends the turn.

**Non-Goals**

- A product change or a spec delta.
- A performance or model-quality test.
- Testing a filesystem sandbox; the agent still has the user's OS rights.

## Decisions

1. The tasks ask Goose to issue two separate shell tool calls in one turn. The
   commands are distinct (`sleep 3; printf 'alpha\n'` and
   `sleep 3; printf 'beta\n'`) and are not combined into one shell command.
2. The Explorer answers the first request with `allow_once --tool-call <id>`,
   verifies that the second id is still pending, then answers the second.
3. For allow-always the exact command is `echo smoke-allow-always`; the first
   request is answered with `allow_always`, the second identical command must run
   without a new permission. The Explorer also checks that the global
   `~/.config/goose/permission.yaml` is unchanged.
4. The interrupt pair is `sleep 30; printf 'gamma\n'` and
   `sleep 30; printf 'delta\n'`; once both are pending the Explorer calls
   `boss interrupt` and verifies that both are answered as cancelled and the
   stop reason is `cancelled`.
5. The Explorer, not the worker, writes the final report if the interrupt ends
   the turn before the worker's report task.

## Risks / Trade-offs

- **Goose issues the calls sequentially** -> the queue scenario is inconclusive;
  record it and retry with a more explicit instruction rather than claiming a
  pass.
- **A command is auto-approved by smart_approve** -> record the observed
  decision; the queue test needs an actual request.
- **The worker finishes before the interrupt pair** -> the task order puts the
  interrupt pair last; the Explorer can still run it manually.
- **A grant matches a wrapped command** -> use the exact `echo` command without
  a `cd` prefix so the apply grant matches.
