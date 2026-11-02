# Design

## Context

See `proposal.md` - Why. The current supervisor keeps one `permission_future`
and one `permission_request`. `handle_permission` creates a future per request
and assigns it to those fields, so a second request replaces the first; the first
future is never resolved and the turn waits forever. `control_answer` answers
whatever is in the single field, and `boss answer` refuses when the state has no
pending object.

`decide()` also returns `allow` for read/search/think and for `policy = "allow"`,
and `pick_option(options, "allow")` returns the first option whose kind starts
with `allow`. Goose offers `allow_always` before `allow_once`, so every automatic
allow becomes a persistent Goose grant. Goose writes that grant to
`~/.config/goose/permission.yaml`; the file is shared by every project and every
manual Goose session.

The ACP child is spawned with `os.environ.copy()` and the user's home, so there
is no per-apply agent state.

## Goals / Non-Goals

**Goals**

- Make concurrent permission requests independent and answerable.
- Keep every permission decision inside the apply.
- Make the agent's permission store boss-owned and disposable.
- Make a weakened policy visible in the doctor.

**Non-Goals**

- A full sandbox for the agent. The charter remains the prompt-level boundary.
- Rewriting the user's existing Goose profile or session history.
- A content review of Goose's smart-approve classifier.
- Native runner changes.

## Decisions

### 1. Queue pending permissions by tool-call id

`Supervisor` keeps `self.pending: dict[str, PendingPermission]`. A pending entry
holds the JSON-RPC request id, the offered options, the recorded options, the
tool title/command, and its own future. `handle_permission` inserts the entry
and sets `blocked` only on the first insertion. `resolve_pending(payload,
tool_call_id)` resolves exactly that entry; `resolve_all(payload)` is used by
interrupt, finish and shutdown. An orphaned request is therefore impossible.

The state carries `acp.pending_permissions` (a list) and keeps
`acp.pending_permission` as the first entry for older readers. `status` lists
all entries. The control protocol adds an optional `tool_call_id` to the
`answer` command; `boss answer` exposes it as `--tool-call <id>` (and accepts
the id as a second positional argument for convenience). With one pending
request the option alone still works; with several, an answer without an id
returns `ambiguous_pending` and names the ids.

*Alternative rejected:* a queue of futures without ids. It would answer in
arrival order, which is not what the Explorer sees and not stable when two
requests arrive together.

### 2. Automatic allow is allow-once; allow-always is apply-scoped

Add `pick_option_once(options)` that prefers `kind == "allow_once"` (then a
name containing "once"). Automatic decisions use it. If the agent offers no
allow-once option, the request stays pending even when the profile is isolated;
an automatic decision never sends `allow_always`. The supervisor logs why, so
the runner fails closed.

When the Explorer chooses an option whose kind is `allow_always`, the
supervisor stores an apply-scoped grant (tool title/kind/command pattern) in
`acp.apply_allows` and answers Goose with `allow_once`. Every later matching
request is auto-allowed for the rest of the apply. Nothing is written to the
agent's global permission store. The CLI keeps the familiar `allow_always` option id; its meaning is now
"for this apply".

*Alternative rejected:* remove `allow_always` from the offered options. The
option comes from the agent; filtering it would confuse the Explorer and the
agent's own state machine.

### 3. Per-apply agent profile

The supervisor creates `$BOSS_STATE_DIR/acp/<apply-hash>/` with:

```text
config/goose/
  config.yaml       -> symlink to the user's config.yaml (if present)
  secrets.yaml      -> symlink (if present)
  <provider-dirs>   -> symlink (chatgpt_codex, gemini_oauth, ...)
  permission.yaml   -> generated, boss-owned
data/goose/
  sessions/         -> private session database
  apps/             -> symlink to the user's apps state (if present)
  model_catalog/    -> symlink (if present)
```

The child gets `XDG_CONFIG_HOME=<root>/config` and
`XDG_DATA_HOME=<root>/data` in its environment. The generated `permission.yaml`
has empty `always_allow` and `never_allow` lists in both the `user` and
`smart_approve` sections, and lists `shell`, `write`, `edit`, `read_image` and
`extensionmanager__manage_extensions` under both `ask_before` lists, so Goose
asks and the supervisor sees every request in either mode. If a listed user
file is missing, it is skipped; Goose then starts with its defaults, which is
still isolated.

The profile survives a supervisor restart (same answer to `resume`). `boss
finish` removes it together with the apply state. A failed apply keeps it until
finish so the Explorer can inspect and resume. Doctor probes use a temporary
profile and delete it in `finally`.

*Alternative rejected:* set only `HOME`. It would hide too much (git config,
provider CLI state) and break unrelated tools.

*Alternative rejected:* copy `config.yaml` and `secrets.yaml`. Provider token
refresh writes through the file; a symlink keeps the user's setup working.

### 4. Doctor reports the effective policy

`policy_check` for ACP returns `enforced` only when the runner is isolated or the
effective global permission store has no `always_allow` for shell, write or
edit. Otherwise it returns `weakened`, names the entry, and points at the
profile flag. The doctor also reports whether isolation is active. It reads
`permission.yaml` read-only; it never edits the user's store.

*Alternative rejected:* have the doctor silently delete the global entry. That
is the user's configuration and may be intentional for manual sessions.

### 5. Transcript identity

`transcript_append` for permission and permission-answered entries includes
`tool_call_id` and `request_id`. The event log already carries the tool-call id;
the request id is added. This is what made the stranded request hard to see.

## Risks / Trade-offs

- **Symlink farm breaks a provider** -> keep the profile generation small,
  log every link, and let a runner set `isolate = false` as an escape hatch.
- **Per-apply session history is lost on finish** -> that is the point; the
  apply transcript remains under `openspec/reviews` or the transcript path.
- **Disk growth from per-apply data** -> remove on finish; a failed apply is
  removed by the next finish or `boss doctor --fix` can report it.
- **Manual `allow_always` no longer grants globally** -> document the change;
  a user who wants a global grant edits Goose's own config.
- **Existing global `shell` entry keeps bypassing the policy until removed** ->
  the doctor reports `weakened`; the operator cleanup is a separate task.
- **Queue state is a new schema** -> additive fields; older readers keep
  `pending_permission`; no migration for finished applies.

## Migration Plan

No data migration. On dispatch, a new profile root is created. On finish, it is
removed. Existing state files gain `pending_permissions` and `apply_allows` on
the first write; `pending_permission` remains as an alias. The operator removes
the already-written `shell` entry from `~/.config/goose/permission.yaml` before
the next non-isolated Goose run.

## Open Questions

- Should isolation be the default for every ACP runner or opt-in per runner?
  The design assumes default-on with `isolate = false` as an escape hatch.
- Should a `--keep` finish preserve the profile for debugging, or should the
  transcript be the only retained evidence? The design removes it with the
  worktree.
