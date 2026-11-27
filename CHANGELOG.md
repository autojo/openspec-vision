# Changelog

## 1.4.2

### Added

- `boss finish --discard` secures the apply branch as
  `park/<change>-<timestamp>`, then removes the worktree, the `boss/<change>`
  branch and the state. A later dispatch of the change starts clean instead of
  continuing on the unmerged branch. It cannot be combined with
  `--keep-worktree` or `--no-merge`.

### Fixed

- `boss doctor --fix` removes an apply state whose worktree directory and
  recorded branch are both gone, and reports it under
  `removed stale apply states`. Previously only `worktree_state` warned and the
  change stayed undispatchable until the state file was removed by hand.
- `boss doctor` never runs `openspec init`. It reports the command instead,
  because init writes project files (`AGENTS.md`, tool config) and must not be
  a side effect of a check.

## 1.4.1

### Fixed

- A fresh worktree dispatch no longer closes the root tab of the workspace it
  just created. Closing the last tab removed the workspace, so the following
  `herdr tab create` failed with `workspace_not_found`; a retried dispatch then
  allocated a new workspace number on every attempt. Stale tabs are cleaned
  only when an apply state already exists, and the workspace is re-resolved
  after a cleanup that may have removed it.
- A trial record stays valid when `<command> --version` prefixes the version
  (`opencode v2.4.1`) while the ACP handshake reported the bare `2.4.1`. The
  comparison now uses the version token instead of the presentation.

## 1.4.0

### Added

- ACP protocol lines are bounded by `BOSS_ACP_LINE_LIMIT` (default
  `67108864`, 64 MiB) at the supervisor and in the doctor probe. A longer line
  is skipped, reported once with its size and reading continues; a skipped
  response ends the turn as `transport_lost` instead of waiting for the timeout.
- A reader that stops now fails the open request, runs its close handler once
  and ends the turn as `transport_lost` with `acp.transport_lost_reason`, even
  while the child keeps running. The wake says whether the child and the reader
  are alive and names `boss retrigger` as the recovery.
- `boss retrigger` after a lost end stops a child that still runs, resumes the
  recorded session when the agent offers `session/load`, otherwise opens a new
  session in the same worktree. Uncommitted files are kept and the command is
  never refused with `turn_active`.
- `boss status` and the stall wake report `acp.child_alive`,
  `acp.reader_alive`, the last activity and its age. `stalled` alone no longer
  reads as a failed apply.
- Doctor: an OpenCode memory plugin in the effective configuration is a warning
  that names the plugin and the per-runner way to leave it out.
- `boss review` prints the executed test count when the output carries one and
  flags `0 tests executed` as an empty gate. The count is `quality.tests.executed`
  with `quality.tests.zero` in JSON.
- The shared run block of the boss and vision skills carries evidence,
  coordination and reporting rules: a gate without an executed count is not run,
  a "nothing changed" claim needs a control that can fail, every test that opens
  a changed screen runs, an undocumented destructive option needs a disposable
  trial, nobody is sent into a resource a running operation uses, and reports
  separate measurement from inference.

### Changed

- `boss finish` cancels the open prompt first, then closes the session and the
  child within `BOSS_ACP_SHUTDOWN_BUDGET_S` (default `15` seconds). It works
  with an unanswered prompt, tolerates an already removed state file and leaves
  no supervisor, socket or heartbeat file behind.

## 1.3.0

### Added

- Model selection: a runner declares `model` (native and ACP) and optional
  `effort`, and every dispatch pins one model. `[models]` records provider,
  billing class (`free`, `metered`, `quota`), per-apply limits, expected ids and
  allowed helper models; `[model_policy]`, `[model_roles]` and
  `[model_providers]` add the unpinned policy, role-to-runner mapping and the
  project's allowed providers.
- Confirmation: the ACP supervisor sets the model, then the effort (category
  `thought_level`), reads both back from the returned configuration and sends no
  prompt until they match. It repeats the check before every prompt and after
  `session/load`. A later `config_option_update` that deviates is a mismatch.
- Native confirmation: after the first answer the waiter reads the model from
  the `claude` transcript (ignoring synthetic entries) or the OpenCode session
  API and records `confirmed`, `mismatch` or `unverifiable`.
- Apply state, dispatch result, `boss status` (text and JSON, single and
  aggregate), wake text and `boss review` carry a `model` object with declared
  and confirmed values, source, provider, billing, cost and tokens. An old
  state reads as `unknown`.
- Cost limits: reported use is summed across prompts; at 80 percent a warning is
  recorded, at the limit the turn is cancelled with `cost_limit` and the boss is
  woken once. Unknown cost stays `unknown`, never zero.
- `boss model list`, `boss model check` (handshake only, no prompt) and
  `boss model trial` (one fixed prompt in an empty temporary directory, only
  with `--confirm-spend` or a charter amount) with regenerated wrappers.
- Doctor: unpinned runners and the mission changes that use them, catalog,
  limit, provider, trial and helper-model checks, and a probe that uses the same
  profile kind a dispatch uses. A non-isolated probe closes and deletes its
  session or reports the one that remains.
- New error codes: `model_unpinned`, `model_uncataloged`, `model_not_offered`,
  `effort_not_offered`, `model_mismatch`, `model_confirmation_late`,
  `model_fallback_configured`, `model_limit_missing`, `model_untried`,
  `provider_not_allowed`, plus the extended `invalid_runner_model`; stop reason
  `cost_limit`.
- Skills: task roles resolve to `runner:` bullets, a second review uses another
  vendor, the charter has a Runner Policy table and the shared RUN block reacts
  to every model error. The boss and vision run blocks stay byte-identical.

### Changed

- A metered model is only dispatched through a transport that confirms before
  the first prompt (ACP); a native metered runner is refused with
  `model_confirmation_late`. A model without a catalog entry, a metered model
  without a limit and a provider not allowed for the project are refused before
  a tab, worktree or state exists. Under `unpinned = "warn"` they start with a
  visible warning instead; `strict` refuses them.
- A runner that declares `model` and also passes `--model`/`--effort` in `args`
  is refused with `invalid_runner_model`; `--fallback-model` is refused with
  `model_fallback_configured`.
- `boss doctor` probes an ACP runner in the user's own profile when
  `isolate = false` (instead of a temporary profile), so a model a dispatch can
  select is not reported as missing.

### Migration

Follow the design's Migration Plan in this order:

1. Answer the open design questions and adjust the specs when an answer differs
   from the recommendation.
2. Install this runtime with `[model_policy] unpinned = "warn"`; nothing that
   runs today stops.
3. Add `[models]`, `[model_roles]` and `[model_providers]`, and move a native
   `--model` from `args` to the runner's `model` field (and `--effort` to
   `effort`).
4. Run `boss doctor` until no unpinned runner is in use, run the authorized
   trials, then switch to `unpinned = "strict"`.

Rollback: set `warn` or remove the new tables; old states and missions stay
readable.

## 1.2.0

### Added

- The ACP runner transport (`start = "acp"`): `boss dispatch` starts the
  detached `boss-acp` supervisor, which owns a `<command> acp` child and drives
  the session (`initialize`, `session/new`, `session/prompt`, `session/cancel`,
  `session/load`, `session/close`). It applies the configured model and mode,
  enforces the deny/ask permission policy, records a pending permission and a
  `blocked` state, streams `session/update` into a JSONL transcript, treats the
  prompt response as the turn boundary, and wakes the boss through the same
  inbox/event path as the native waiter.
- `boss answer` selects an offered ACP permission option, `boss interrupt`
  sends `session/cancel` (with a bounded `cancel_unconfirmed` result), and
  `boss resume` reloads a crashed session when the agent advertises
  `session/load`.
- `boss doctor` validates a configured ACP runner with a real handshake and
  names the offered models and modes.
- The ACP apply prompt is CLI-based (`openspec instructions apply --change
  <change> --json`) and never assumes a slash command.
- A fake ACP agent in the regression suite covers dispatch, permissions,
  cancel, resume, slots, locks, doctor and the end-to-end workflow without a
  model or network.

### Changed

- Apply state gains a `transport` field (`herdr` for old and native applies)
  and an `acp` object; old state files stay readable.
- The runner start path is shared by dispatch, retrigger and session.

## 1.1.1

### Fixed

- The integration test (`[tests]` in the config, `merge_test` in the review)
  was skipped on macOS, where `timeout(1)` does not exist (coreutils installs it
  as `gtimeout`). The runtime now runs it through `run_with_deadline`, which
  uses `timeout`/`gtimeout` when present and a watchdog subshell otherwise, so
  the result is no longer a silent `not_run` on macOS.
- The regression suite failed on macOS: it called `timeout` directly and made a
  dummy waiter with `exec -a` (bash 4). It now uses the runtime's
  `run_with_deadline` through a `deadline` stub and a real script named
  `boss-waiter`, so the checks run on bash 3.2 as well.
- A project reached through a symlink was treated as a different project: the
  caller identity check compared the path a pane reports (as opened) with the
  physical path the process sees, and refused with `caller_pane_mismatch`. On
  macOS every TMPDIR is such a case, because `/var` and `/tmp` are symlinks.
  `boss_cwd_related` resolves both sides now, and the suite creates its TMP
  physically so its state-file arithmetic matches the runtime.

## 1.1.0

Correctness and hardening pass over the runtime, driven by a review of the
three checkouts (`openspec-herdr`, `boss-mode`, this one).

### Fixed

- A usage error produced invalid JSON when the offending argument contained a
  quote (`usage_error` now builds its output with jq, with an escaped fallback).
- `ensure_config` reported "generated config" even when the write failed; it now
  fails with `config_write` and removes the half-written file.
- The state file was updated read-modify-write without serialization; the
  waiter, `retrigger`, `finish` and `park` could drop each other's fields. All
  state writes now take a per-apply lock.
- Two bosses could pass the "already running" check and start the same change
  twice; dispatch is now serialized per change (`dispatch_busy`).
- `waiter_alive` matched any process whose arguments contained `boss-waiter`;
  it now matches the executable name.
- `now_ms` had one-second resolution even where the platform offers
  milliseconds.
- The OpenCode unknown-version warning test asserted on stderr, which the
  runtime no longer writes to.

### Added

- `boss --version` prints the runtime version and the commit it came from
  (`-dirty` for a checkout with uncommitted runtime changes).
- Deny policy: `BOSS_POLICY_DENY_DEFAULT` and `[runners.<name>] deny = [...]`.
  Claude runners get `--disallowedTools`; OpenCode runners are verified against
  their effective permission rules. Every dispatch result carries a `policy`
  object, `boss doctor` reports a `policy` check, and the run procedure says how
  to react. The boss session itself is exempt - its charter may grant a
  force-push of its own branch.
- `scripts/gen-commands.sh` generates the 34 command wrappers from
  `commands/commands.tsv`; `--check` fails on drift.
- `scripts/runtime-manifest.sh` records and verifies the vendored runtime hashes
  (`runtime/MANIFEST.sha256`).
- `scripts/check-generated.sh` fails when the OpenSpec instruction files are not
  what `openspec update` would write.
- CI: syntax, shellcheck, manifest, generator drift, and the regression suite on
  Linux and macOS (bash 3.2).

### Changed

- `bin/boss` is split into command modules (`boss-apply.sh`, `boss-status.sh`,
  `boss-review.sh`, `boss-run.sh`, `boss-doctor.sh`, `boss-mission.sh`); the
  worktree checks of `doctor` moved into their own function.
- The installer writes `.boss-runtime-commit` and `.boss-runtime-origin`, warns
  when it replaces a runtime it did not install, and installs the new modules.
- The regression suite writes runtime logs to a file instead of the test output,
  and works without GNU `sha1sum` (macOS). It also covers the installer's
  runtime file list, the `.boss-runtime-commit`/`.boss-runtime-origin` stamps,
  the "replacing the boss runtime" warning and the `--version` output of an
  installed copy.
- README: trust model, repository layout, language policy. `runtime/VENDOR.md`
  lists the local changes and how to update the snapshot.
- The skills' `metadata.version` is 1.1.0; the stale `embeddedFrom` date is
  replaced by a pointer to the shared run block.
