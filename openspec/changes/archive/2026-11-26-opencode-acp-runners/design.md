# Design

## Context

See proposal.md. The supervisor is generic ACP, but `build_agent_profile()` in
`runtime/lib/boss_acp.py` creates `config/goose`/`data/goose`, writes a Goose
`permission.yaml`, and sets `XDG_*`; `acp_permission_store_path()` and the doctor
policy read the Goose store. `opencode-deepseek` already exists as
`start = "acp"`, `command = "opencode"`, `model = "deepseek/deepseek-flash"`,
`mode = ""`, `isolate = false`. The merged model-selection work supplies
`model`/`effort` per runner, the catalog, roles and limits.

## Goals / Non-Goals

**Goals**

- OpenCode ACP is the apply transport and the default.
- Several OpenCode runners with distinct models/efforts can coexist.
- The active runtime/docs/tests/config no longer teach or require Goose.

**Non-Goals**

- Per-apply OpenCode config isolation. The simple solution is global OpenCode
  config with `isolate = false`; a profile adapter is a later change.
- Rewriting archived changes or Git history.
- Automatic model routing or provider account management.

## Decisions

### 1. OpenCode global profile, no Goose profile

An OpenCode ACP runner runs with the user's global OpenCode config and data.
`isolate = true` is rejected for an OpenCode command. The supervisor does not
create `config/goose`, does not set XDG paths to a Goose profile, and does not
write a Goose permission store. The ACP `policy`/`deny` remains the gate for
requests OpenCode actually sends; the global `opencode.jsonc` permission setting
is documented as the outer boundary.

### 2. Multiple runners, one model each

Each runner entry is one model/effort pair. Example:

```toml
default = "opencode-deepseek"

[runners.opencode-deepseek]
start = "acp"
command = "opencode"
model = "deepseek/deepseek-flash"
effort = "high"
mode = ""
isolate = false
policy = "allow"
commit = "explorer"

[runners.opencode-openai]
start = "acp"
command = "opencode"
model = "openai/gpt-6.2-sol"
effort = "high"
mode = ""
isolate = false
policy = "ask"
commit = "explorer"
```

The native `opencode` runner stays for `boss session`; it is not used for
applies. `boss model list|check|trial` and the catalog/roles from the merged
model-selection change are the onboarding path.

### 3. Remove Goose code rather than keep a compatibility layer

Delete `build_agent_profile`, the Goose permission-store reader and the Goose
doctor policy. Keep the generic ACP supervisor, queue, grants, turn timeout,
stall detection, resume and transcript. Rename test fixtures from `fake-goose`
to `fake-opencode` and keep the ACP protocol fake generic.

### 4. Doctor checks the OpenCode boundary

For an OpenCode ACP runner the doctor validates the command, handshake, model and
effort, and reports the effective OpenCode permission configuration. It must not
read `~/.config/goose/permission.yaml`. A broad `"permission": "allow"` in
`opencode.jsonc` is reported as the actual boundary, not as an ACP enforcement.

### 5. Documentation and skill

Replace the Goose ACP section and examples with `opencode acp`, `mode = ""`,
`isolate = false`, model/effort and multiple runner names. The shared RUN block
in both skill copies stays byte-identical. The vision runner-assignment table
uses `opencode-*` ACP runners for applies and native `opencode` for sessions.

## Risks / Trade-offs

- **No per-apply OpenCode isolation** -> the global `opencode.jsonc` and its
  permission setting apply. This is the accepted simple solution; a profile
  adapter is a follow-up.
- **ACP deny sees only requests** -> OpenCode may auto-approve tools. Document
  the global permission boundary and keep the charter.
- **Large mechanical test rename** -> keep the ACP fake protocol generic and
  change only the runner name/command fixtures.
- **Existing Goose runner states** -> old states remain readable; new dispatches
  use OpenCode runners.

## Migration Plan

1. Add the OpenCode runner entries and set the default; remove `goose` and
   `goose-review`.
2. Install the resulting runtime.
3. Run `boss doctor` and `boss model list`; check that no active runner is
   Goose.
4. Run the full suite and the ACP smoke test.

## Open Questions

None for the simple solution; OpenCode profile isolation is explicitly out of
scope.
