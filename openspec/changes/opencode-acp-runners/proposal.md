# Proposal

## Why

Goose is still the documented ACP agent and the active runtime, tests and local
runner config carry Goose-specific profile, permission and fixture code. The
operator wants OpenCode ACP as the only apply transport, several OpenCode runners
with different models, and `opencode-deepseek` as the default. The current
`build_agent_profile` creates a Goose profile even for an OpenCode command, so
OpenCode runners have to disable isolation manually. The active skill and README
still teach Goose.

## What Changes

- Make `opencode acp` the documented and configured apply transport. Keep the
  native `opencode` runner only for `boss session`.
- Use the simple OpenCode configuration model: `isolate = false`, the user's
  global `~/.config/opencode`/`~/.local/share/opencode`, and the generated ACP
  policy. Do not create a Goose profile or read/write Goose's permission store.
- Add several named OpenCode ACP runners, each with its own `model`, `effort`,
  `mode = ""`, `policy` and optional `deny`; make `opencode-deepseek` the default.
- Remove Goose from the active runtime, doctor messages, tests/fixtures, README,
  `vision/SKILL.md`, `boss/SKILL.md` and the local `boss.toml`. Archived changes
  are not rewritten.
- Reuse the merged model-selection support for runner model/effort, roles,
  catalog and trials. The operator's local catalog/roles/default entries remain
  an operator task.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `acp-runner`: replace the Goose-only isolated profile and permission-store
  requirements with OpenCode ACP profile/permission requirements; keep the
  generic transport, lifecycle, queue, resume and turn checks.

## Impact

- `runtime/lib/boss_acp.py` (remove the Goose profile builder and Goose
  permission paths), `runtime/bin/boss-lib.sh`, `runtime/bin/boss`,
  `runtime/bin/boss-doctor.sh`, `tests/run.sh` (fake agent and ~100 Goose
  references), `README.md`, `vision/SKILL.md`, `boss/SKILL.md`.
- Local `~/.config/openspec-boss/boss.toml`: remove `goose`/`goose-review`, add
  OpenCode runners and set the default. Not a repository file.
- No archived change is edited and no Goose history is rewritten.
- No new dependency; OpenCode ACP is already installed and used.
