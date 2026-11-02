# Proposal

## Why

Goose cannot be started as a Herdr-native agent: `herdr agent start` has no
goose kind, so it cannot join the boss's pane-based runner model. Goose does
expose an ACP server (`goose acp`) with structured turns, tool calls,
permission requests, cancellation and session loading. That is enough to run a
Goose worker as a boss-managed headless apply, with an exact `blocked` state and
a permission boundary the runtime can enforce - neither of which a TUI hook
bridge can provide.

## What Changes

- Add an `acp` runner transport to the boss runtime. Dispatch starts a detached
  supervisor that owns a `goose acp` child and speaks ACP over stdio.
- Drive the session lifecycle: `initialize`, `session/new` with the worktree as
  `cwd`, `session/prompt`, `session/cancel`, `session/load` and `session/close`.
- Select model and mode per runner through `session/set_config_option`
  (`model`) and `session/set_mode` (`auto`, `approve`, `smart_approve`,
  `chat`).
- Bridge permissions: answer `session/request_permission` from the runner's
  deny policy; leave unresolved requests pending and report `blocked`. The
  Explorer answers through `boss answer`.
- Replace the Herdr agent wait for this runner with the prompt response
  (`stopReason`). The supervisor writes the same state and wake events, so
  slots, status and missions keep working.
- Make `boss interrupt` send `session/cancel` and confirm the `cancelled` stop
  reason.
- Persist the session id and use `session/load` to replay a session after a
  supervisor restart.
- Stream `session/update` into the apply transcript. The runner hosts no TUI
  and receives no keystrokes.
- Extend the runner configuration with `start = "acp"`, `command`, optional
  `model`, `mode`, `deny` and `apply`; the doctor validates the command and a
  real ACP handshake.
- Make the apply prompt independent of Goose slash commands. Goose slash
  commands are recipes only, so the prompt references the OpenSpec apply
  instructions or an installed skill.
- Document the transport and cover it with tests, including a fake ACP agent.

## Capabilities

### New Capabilities

- `acp-runner`: the boss can run an ACP-speaking agent as a managed apply, with
  session lifecycle, model and mode selection, permission policy,
  blocked/answer, cancel, resume, transcript, state and wake integration.

### Modified Capabilities

None. The worktree isolation, hard concurrency limit and lock requirements are
transport-neutral; the supervisor becomes the running apply and the existing
Herdr tab only shows the transcript.

## Impact

- Runtime: a new bundled `boss-acp` supervisor (Python 3.11+, already a hard
  prerequisite) plus runner resolution, start, state, wake, interrupt, answer,
  finish, status and doctor changes in the boss modules.
- Apply state: adds transport, session id, model, mode, pending permission,
  transcript path and last stop reason.
- Configuration: new optional runner fields. Existing Herdr and Claude runners
  are unchanged.
- Documentation: README, skill runner tables and VENDOR record.
- Tests: a fake ACP peer that exercises prompts, permissions, cancel, load and
  close without a real model.
- Out of scope: a Goose TUI runner, an ACP bridge that renders an interactive
  terminal UI, and any change to the existing OpenCode/Herdr runner.
