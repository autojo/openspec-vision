# Proposal

## Why

The first external review of this repository exposed two failures in the Goose
ACP runner. Two concurrent `session/request_permission` calls overwrote a single
pending slot: one request was never answered, the turn stayed `working`, and
`boss answer` reported no pending request. Separately, `policy = "allow"` picked
Goose's `allow_always` option, which wrote a global `shell` grant into
`~/.config/goose/permission.yaml`. From then on Goose never asked again, so the
boss deny list was bypassed and the write-permission path was never exercised.

Both failures are trust failures: the Explorer believes the runner is enforcing
the configured policy, while in practice a stuck turn or a persistent global
grant decides what runs. Fixing this is a prerequisite for using Goose for any
further apply.

## What Changes

- Queue pending permission requests by `tool_call_id`; keep a list, answer a
  specific request, and cancel every queued request on interrupt or finish.
- Automatic allows answer Goose's `allow_once` option, never `allow_always`.
  An Explorer `allow_always` answer becomes an apply-scoped grant in the
  supervisor and is also sent to Goose as `allow_once`, so it cannot leak into
  the global Goose profile.
- Run the ACP child with a per-apply `XDG_CONFIG_HOME` and `XDG_DATA_HOME`:
  symlink `config.yaml`, `secrets.yaml` and provider state, own a boss-generated
  `permission.yaml` with an empty `always_allow`, and remove the profile when the
  apply finishes. Doctor probes use a temporary profile and leave no sessions.
- Validate the effective permission store in `boss doctor` and report
  `weakened` instead of `enforced` when a global `always_allow` for
  `shell`/`write`/`edit` would bypass the supervisor.
- Record `tool_call_id` and `request_id` in permission transcript and event
  entries so a stranded request is diagnosable.
- Extend the fake ACP agent with two concurrent requests and cover queueing,
  answer-by-id, cancel-all, `allow_once` selection and profile isolation.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `acp-runner`: permission policy, blocked state and answer, doctor validation,
  transcript identity, and a new isolated-agent-state requirement.

## Impact

- `runtime/lib/boss_acp.py` (queue, decision, profile spawn, transcript),
  `runtime/bin/boss-run.sh` (`answer`, interrupt/finish), `runtime/bin/boss-status.sh`,
  `runtime/bin/boss-doctor.sh`, `runtime/bin/boss-apply.sh` (state fields),
  `tests/run.sh`, `README.md`, `vision/SKILL.md`.
- No dependency changes. No change to native runners.
- Existing applies are not migrated; the state file gains additive fields.
- The global `shell` entry that already exists in `~/.config/goose/permission.yaml`
  is local operator state and must be removed separately; this change prevents
  new leaks but does not rewrite the user's Goose profile.
