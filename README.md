# vision

Two skills from one checkout:

- **`vision`** plans a very large software project feature by feature and then
  runs the resulting work autonomously as ordered version missions. Use it for
  a large project (roughly 20-50 changes), a vision, feature map and milestone
  plan, or several ordered version missions.
- **`boss`** runs one existing OpenSpec change or a small ad-hoc batch from a
  central Explorer session, without a planning phase. Use it to dispatch,
  review, fix or finish a single change or a handful of changes, including
  changes inside a mission.

Both use the same run procedure: the block between `<!-- shared:run:begin -->`
and `<!-- shared:run:end -->` in `vision/SKILL.md` is copied byte for byte into
`boss/SKILL.md`, and `tests/run.sh` fails if the two drift apart.

The vision skill has two phases:

- **PLAN** (optional, interactive) – a kickoff fixes the vision, goal,
  non-goals, constraints, domains and milestone criteria. Each feature is
  explored in depth, then its change is created immediately with all four
  artifacts (proposal, specs, design, tasks) and assigned provisionally to a
  milestone. Progress lives in `openspec/vision.md` and is resumable.
- **RUN** (core, autonomous) – the boss loop: `boss mission next` → `dispatch`
  → wake → `boss review` → `retrigger`/`finish` → `reconcile` → next, for
  missions v1 → v2 → v3. A single change can be run without a plan.

The plan is stored in three places:

- `openspec/vision.md` – vision, feature map, milestone table, plan status.
- `openspec/missions/<version>.md` – one boss mission per version, with its
  charter and change list.
- `openspec/changes/<feature>/` – the change for each feature.

The skill uses the `openspec` and `boss` CLIs directly and does not load any
other skill. `vision/SKILL.md` is unchanged by the vendoring: the command names
and the boss loop are the same.

## Install

One command installs everything:

```bash
./install.sh
```

The installer needs these programs on `PATH`:

- `bash`
- `jq`
- `python3` 3.11 or newer (for `tomllib`)
- `openspec`
- `herdr`

It also installs into `~/.local/bin`, so keep that directory on `PATH` (for
example `export PATH="$HOME/.local/bin:$PATH"`).

A single run installs, as regular copies and never as symbolic links:

- the `vision` skill into `~/.config/opencode/skills/vision/` and
  `~/.claude/skills/vision/`, and the bundled `boss` skill into
  `~/.config/opencode/skills/boss/` and `~/.claude/skills/boss/`;
- the bundled runtime from `runtime/bin/` into `~/.local/bin`, with executable
  mode: `boss`, `boss-lib.sh`, `boss-waiter` and the command modules
  `boss-apply.sh`, `boss-status.sh`, `boss-review.sh`, `boss-run.sh`,
  `boss-doctor.sh`, `boss-mission.sh`;
- the 17 opencode `boss-*.md` wrappers into `~/.config/opencode/commands/` and
  the 17 Claude wrappers into `~/.claude/commands/boss/`;
- the Herdr integration for `opencode` and `claude`.

Any existing symlink at an installed path is replaced by a regular file. Only
the named files are touched: other executables in `~/.local/bin` and unrelated
files in the command directories are left in place. The install is idempotent,
so running it again produces the same result.

The boss skill directory is marked with `.vision-managed`; only a marked
directory is replaced on a later run. A real boss directory without the marker
is reported and left untouched. `--no-boss-skill` installs vision only and
leaves every boss skill path alone; `--force-boss-skill` replaces a boss
directory this installer does not own.

Runtime scripts are replaced atomically (temporary file plus rename), and the
installer reports running `boss-waiter` processes without signalling or
restarting them. A waiter keeps its loaded code until it exits; new dispatches
start a waiter with the new code. Re-arm explicitly only if you intend to
replace a running waiter.

This is a copy-only install: after pulling an update, re-run `./install.sh` to
refresh the installed files. No separate `boss-mode` installation is needed at
runtime.

The installer writes two markers next to the binaries: `.boss-runtime-commit`
(the commit the copy came from) and `.boss-runtime-origin` (`vision-skill`).
`boss --version` prints both, so an installed runtime can be traced back to its
source. If another installer had written `~/.local/bin/boss` before, the run
says so instead of replacing it silently - the older standalone checkout uses
the same paths, and exactly one of the two may own them.

Run `./install.sh --uninstall` to remove the installed skills, runtime binaries
and command wrappers. Both owned skills are removed; a boss directory this
installer does not own is reported and left in place. The configuration in
`~/.config/openspec-boss` and the state in `~/.local/state/openspec-boss` are
kept, so existing projects and settings keep working. `./install.sh --help`
shows usage.

## Migrating from the old boss skill

This repository now ships its own `boss` skill, so a separate `boss-mode` skill
checkout is no longer needed. By default `./install.sh` installs it next to the
vision skill and removes an old `boss` skill symlink at either global skill
path. A real boss directory without the ownership marker — for example a
hand-copied skill — is reported and left untouched; re-run with
`--force-boss-skill` to replace it. Use `--no-boss-skill` to install the vision
skill alone.

The `boss` CLI and its slash-command wrappers such as `/boss-dispatch` keep
working; only the old `boss` skill is replaced. Migrate in this order:

1. Install both skills:

   ```bash
   ./install.sh
   ```

   This copies its own runtime and wrappers and replaces an old `boss` skill
   symlink. Check the installer output for anything it reported and left in
   place.

2. Only after that, if you no longer need the separate repository, purge the
   old `boss-mode` installation. Install from this repository *before* purging
   `boss-mode`, so there is no window without a working runtime. The install
   replaces `~/.local/bin/boss` and the wrappers with its own copies.

3. Check each project for project-local copies of the `boss` skill and remove
   the listed links:

   ```bash
   find . -type l -path '*/skills/boss' -print
   ```

4. Start a new session so both tools pick up the new skill set.

5. Keep using `/boss-dispatch` and the `boss` CLI as before.

Configuration (`~/.config/openspec-boss`) and state
(`~/.local/state/openspec-boss`) are not removed by `--uninstall`. A `--purge`
for them is a separate, later change.

## Usage

Ask for a large project to be planned ("plan this project feature by feature"),
or ask to run or continue the plan. That selects the `vision` skill. For a
single existing change or a small ad-hoc batch, ask to dispatch, review or
finish it without a plan; that selects the `boss` skill.

Planning assumes the target project uses OpenSpec. If it does not, the skill
asks before initializing anything.

## Missions with human tasks

A mission change can contain work that only a human can do (a device, an
account, a purchase, a multi-week test). Mark such a task in `tasks.md` with
`[Nutzer]` or `[human]`; the list is configurable in `boss.toml`:

```toml
[missions]
human_markers = ["[Nutzer]", "[human]"]
# Agent implements and tests; proof comes from outside (Mac build, real data).
external_verify_markers = ["[Mac]", "[Daten]"]
```

An external task is still agent work: the apply prompt tells the agent to
implement and run local tests now, leave the checkbox open until the external
proof exists, and not stop merely because of the marker. `boss park` accepts a
change when only human or external tasks remain and lists both kinds in the
handoff; `boss status` and `boss mission status` report `human_open`,
`external_open`, `agent_open`, `human_tasks` and `external_tasks`.

When only marked tasks remain open, park the change instead of retriggering it:

```bash
boss park <change> --project <name|path> --note "what the human must do"
```

Parking closes the apply tab, releases the workspace, keeps the state and event
log, and writes the human tasks and their acceptance criteria to the inbox and
journal. `boss status` and `boss mission status` then show `waiting_human`.
After the human made progress, either check the tasks off in `tasks.md` or run:

```bash
boss resume <change> --project <name|path> --note "what was reported"
```

`resume` clears the park and starts a fresh dispatch when no apply is live.

Mission changes may declare dependencies on their `## Changes` bullets:

```markdown
- data-pipeline (after: spike-api)
- data-pipeline (after: spike-api; human-ok: spike-api)
```

`after:` requires the prerequisite to be `done`. `human-ok:` allows a
prerequisite that is still `waiting_human`, for changes that can run without the
human's result. A bullet without an annotation keeps the existing document
order. When nothing is startable but parked changes remain, `boss mission next`
returns `waiting_human` with a bundled handoff instead of an error; that is the
normal end of a mission that waits for a human.

## Runners per change

A mission can start each change with a different runner. Add an optional
`runner:` annotation to the same `## Changes` bullet as `after:` and
`human-ok:`:

```markdown
- spike-api (runner: claude-opus)
- data-pipeline (after: local-store; human-ok: local-store; runner: opencode)
- coding-change
```

`boss mission next` uses the named runner; without an annotation it uses
`default` from `boss.toml`. An unknown runner name returns `unknown_runner` with
the configured names and starts nothing. `boss mission status` shows the
effective runner for every change and in `dependencies`; `boss doctor` warns
about unknown mission runners. `boss resume` keeps the runner recorded by the
original dispatch; `boss retrigger` continues the same agent and apply command.

Runner names must exist under `[runners]` in `~/.config/openspec-boss/boss.toml`.
The fields of a runner entry:

| Field | Meaning |
| --- | --- |
| `kind` | Herdr agent kind for the default `start = "herdr"` |
| `start` | transport: `herdr` (default) or `acp` |
| `command` | ACP only: the agent command; boss starts `<command> acp` |
| `model` | ACP only: session model, applied before the first prompt |
| `mode` | ACP only: session mode; default `smart_approve` |
| `policy` | ACP only: `allow` (default) or `ask` for an unmatched permission |
| `isolate` | ACP only: `true` (default) runs the agent with a per-apply profile; `false` uses the user's global agent profile |
| `deny` | command/path/title globs an apply never needs (default: force-push, mirror-push, `git push --delete`, `git filter-branch`, `git filter-repo`) |
| `apply` | native: the prompt template with `{change}`; ACP: optional extra instructions (a slash-command template is ignored) |
| `args`, `env` | native only: extra agent start arguments and environment entries; an ACP runner ignores them and is configured with `command`, `model`, `mode`, `policy`, `deny` and `apply` instead |
| `commit` | `explorer` (default) or `agent` |
| `interrupt_keys` | native: keys for `boss interrupt` |
| `ready`, `ready_regex`, `ready_timeout_ms` | native: readiness marker and timeout |
| `dialog_match`, `dialog_keys` | native: a first-run dialog to answer |
| `yield` | custom turn-end instruction (an empty string disables it) |

An unknown `start` value is rejected with `invalid_runner_start`; an ACP
runner without `command` is rejected with `acp_command_missing`. Both fail
before a tab, worktree or state file is created.

The assignment rule used by the vision skill:

| Change content | Runner |
| --- | --- |
| research, legal text, evaluation | `claude-sonnet` |
| licenses, regulatory/legal, privacy, other expensive mistakes | `claude-opus` |
| primarily code | `default` (here `opencode`) |
| apply-only work that suits an ACP agent | `goose` (`start = "acp"`; permissions come from its `policy` and `mode`) |

An ACP runner is apply-only. `boss session` rejects it with
`acp_session_unsupported`, because the session needs a Herdr-native agent to
attach to; there is no hidden native path. A change whose work needs an
interactive session therefore belongs to a native runner, while the ACP runner
takes the change as a normal detached apply with its transcript in the tab.

A mixed change uses the runner of its dominant part or is split into two
changes.

A later mission can wait for an earlier one with `start_after` in `## Plan`,
for example `start_after: v1 (waiting_human)`. `boss mission next` returns
`mission_waiting` until v1 is `done` or `waiting_human`; `mission status` shows
`start_after` and `start_after_state`.

Research and decision changes can hand recommendations to follow-up changes in
`openspec/recommendations.md`:

```markdown
| ID | Target | Decision | Note |
| --- | --- | --- | --- |
| R17 | export-tool | approved | adopt threshold 3 |
```

`boss reconcile <slug> --json` reports approved recommendations for
`next_change` that have no `recommendation-adopted` journal entry. Record an
adoption with
`boss journal --tag recommendation-adopted --change <target> "R17 ..."`.

External verification (build station, real data) uses the checklist in
`vision/references/external-review.md`: pull, build, test, osv-scanner, restore
tracked files, report. Record a pass with
`boss journal --tag external-pass --project <p> "<result>"`; a red pass goes
into `boss resume <change> --note "<log>"`. `boss mission status` shows
`external_open` and `external_tasks` per change.

A runner may set `commit = "explorer"` (default) or `commit = "agent"`.
Under `explorer` the apply prompt says not to commit; after a green review the
Explorer commits exactly the reviewed change paths with the apply's completion
message, then runs `boss finish` (which warns if the tree is still dirty).
Under `agent` the apply commits its tested work. `boss review` reports
`quality.git.commit_policy`; under `explorer` every commit since `base_head` is
listed under `friction.commit_policy_violations`, and foreign authors remain
under `quality.git.foreign_commits`.

The `boss mission start` skeleton includes `## Build Environment`,
`## External Review`, `## Marker Policy`, `## Commit Policy`, `## Runner Policy`
and `## Start` in addition to the original charter sections; fill them during
P5.

## Worktree applies

A change can run in an isolated git worktree instead of the project checkout.
The base stays clean while the apply edits, tests and commits in its own
worktree; `boss finish` merges the branch back and removes the worktree.

Choose the mode in `boss.toml`:

```toml
[missions]
worktrees = "auto"   # auto | always | never, default auto
```

`auto` keeps today's base-checkout behaviour in this change. `always` sends
every dispatch into a worktree. `--worktree` and `--no-worktree` override the
configured mode on `boss dispatch` and `boss mission next`:

```bash
boss dispatch <change> --project <name|path> --worktree
boss mission next <slug> --project <name|path> --worktree
boss dispatch <change> --project <name|path> --no-worktree
```

Before the first worktree dispatch, commit the planning artifacts on the base
branch. `boss plan commit` stages and commits only `openspec/vision.md`,
`openspec/missions/` and `openspec/changes/` with the message
`plan: <change> artifacts`; code paths are never added:

```bash
boss plan commit <change> --project <name|path>
```

The result is `committed` with the commit id and paths, or `clean` when the plan
paths already match `HEAD`. Worktree dispatch refuses an uncommitted plan with
`plan_uncommitted` and a dirty base outside `openspec/` with `base_dirty`,
naming the paths. Commit or stash those paths first.

The worktree lives outside the project tree at
`$BOSS_STATE_DIR/worktrees/<sha1(project)>/<change>`, on branch
`boss/<change>`, in its own Herdr workspace. The apply state stays keyed by the
base project and change and records `worktree`, `branch`,
`worktree_workspace`, `base_head`, `merge_state`, `merged`, `merge_test`,
`merge_test_at` and `merge_test_output` and `kept`. `boss status <change> --project <base>` and `boss review` find the
apply from the base and read git, tasks, validation and tests from the
worktree; the mission and plan stay in the base. A legacy state without these
fields keeps the base-checkout behaviour.

`boss finish` verifies the worktree, merges `boss/<change>` into the base
(`--ff-only` when the base is still at `base_head`, otherwise a `--no-ff`
merge), runs the configured or detected test command on the merged base, then
closes the tab, removes the worktree, deletes the branch and the state:

```bash
boss finish <change> --project <name|path>
```

A merge conflict aborts the merge, sets `merge_state=conflict`, keeps the
worktree and state, and reports `merge_conflict` with the conflicting paths. A
red integration test keeps the state with `merged=true` and
`merge_state=test_failed`, reports `merge_test_failed`, and lets a later
`boss finish` retry the test after the fix on the base. A test that exceeds its
budget keeps the state with `merge_state=test_timeout`, reports
`merge_test_timeout`, and retries with a larger budget without merging again
(see [Test gate](#test-gate)); the base-checkout finish path runs the same gate.
`--keep-worktree`
merges and tests but keeps the worktree, branch and state (`kept=true`,
`merge_state=done`) for inspection; `--no-merge` closes the tab and keeps them
for a manual merge without recording a finish. A later `boss finish` cleans up
either kept path.

`boss park` keeps the worktree and branch for the human handoff. `boss resume`
reuses the same worktree and branch and starts a fresh agent there; `boss
retrigger` continues in the same worktree, or starts a new agent there when the
old one is gone. A missing worktree fails with `worktree_missing` instead of
silently using the base checkout. `boss doctor` reports a missing worktree
path, a `conflict`/`test_failed`/`test_timeout` state, an uncommitted change dir, orphaned
worktrees under the state root, a dirty base and an uncommitted plan.
`boss doctor --fix` removes only merged worktrees that belong to a kept or
finished state; unmerged worktrees are only reported.

## Test gate

`boss review` and `boss finish` run the project's test command with a persistent,
per-project budget. Configure it in `boss.toml`; the key is the registered
project name from `[projects]`:

```toml
[tests.shop]
command = "nice -n 10 taskset -c 0-2 npx vitest run"
timeout_s = 1800
```

`command` is optional: without it the detected command (`just test`,
`npm test`, `pytest`, `make test`, `./tests/run.sh`, `./scripts/test.sh`) runs
with the configured budget. The two repository conventions come last and only
when the file is executable, so a project manifest keeps precedence. The legacy
string form stays valid and means "this command, default budget":

```toml
[tests]
shop = "npm test"
```

The budget is resolved as:

1. `BOSS_REVIEW_TEST_TIMEOUT_S`, when it was explicitly set for this process;
2. `[tests.<project>].timeout_s`;
3. 300 seconds.

A configured value must be a positive integer number of seconds; zero,
negative and non-numeric values are rejected with `invalid_test_timeout`
naming the project. The budget is a hang guard, not a liveness check: raise it
for a suite that legitimately needs longer, and do not wrap the suite in an
outer `timeout` shorter than the budget.

`command` and `timeout_s` belong together. The budget must exceed the runtime of
the whole suite on this machine with margin: the suite is run inside the merge
step, and a budget below it turns a green change into `merge_state=test_timeout`
with the merge already applied. A suite that takes eight minutes needs a budget
well above 480 seconds; the safe form is to measure the suite once and set the
budget to roughly twice that. `[tests]` (the string form) cannot carry a budget
of its own and always uses the default 300 seconds, so use the table form for
anything slower.

A test that exceeds its budget is a `timeout`, not a red test. `boss review`
reports `quality.tests.result` as `pass`, `fail`, `timeout` or `not_run`
together with `timeout_s` and the log path. `boss finish` records
`merge_state=test_timeout` and `merge_test=timeout`, keeps the worktree and
state, and reports `merge_test_timeout` with the budget and log path. Raise the
budget and run `boss finish` again: the merge is skipped, only the test reruns,
and a green result finishes and cleans up as usual. A red test keeps
`merge_state=test_failed` and `merge_test_failed`.

Every review and finish test writes its output to a log under
`$BOSS_STATE_DIR/logs/` (the path is reported). On a timeout or failure the
apply state also keeps `merge_test_at` and `merge_test_output`
(`{path, tail}` with the last 40 lines). A timed-out apply counts as unfinished
for `[missions] max_parallel` and appears in `boss status` as
`merge: test_timeout (... test: timeout)`.

## Parallel missions

`[missions] max_parallel` (default `1`) is the hard cap on concurrently running
applies. Raise it in the project config or for one process:

```toml
[missions]
worktrees = "auto"
max_parallel = 2
```

```bash
BOSS_MAX_PARALLEL=2 boss mission next v1 --project shop
```

The limit is global and counts running applies across projects. A parked,
finished or merged/kept apply does not consume a slot; a `test_failed`,
`test_timeout` or `conflict` state does, because the change is unfinished. A
dispatch beyond the
limit returns `parallel_limit` with `current`, `max` and `slots_free` and starts
nothing. `BOSS_DISPATCH_MAX_APPLIES`, `BOSS_DISPATCH_MIN_FREE_MB` and
`BOSS_DISPATCH_MAX_LOAD` remain advisory resource warnings; a user who raises
`max_parallel` above `BOSS_DISPATCH_MAX_APPLIES` should raise that warning too.

Above one, every apply uses the worktree lifecycle: `worktrees = "auto"`
resolves to a worktree, and `--no-worktree` or `worktrees = "never"` is refused
with `worktree_required`. Commit the plan and keep the base clean first. A
limit of one keeps the existing serial base-checkout path.

### Locks

Declare what a change touches on its mission bullet:

```markdown
- feat-a (runner: opencode-flash; touches: src/auth, deps)
- feat-b (runner: opencode-flash; touches: none)
- feat-c (runner: opencode-flash)
```

`touches:` is a comma list of resource keys or path prefixes. Locks match
exactly (`deps`, `test-env`, `port:3000`, `db:shop`) or by path prefix when both
sides contain `/` (`src/auth` overlaps `src/auth/login`; a trailing slash is
ignored). A lock without `/` never prefix-matches a path. `touches: none`
declares that the change shares nothing; a missing annotation leaves the change
undeclared and exclusive, so it waits for every running or unmerged apply.

Locks are scoped to the base project in this version: `port:3000` serialises
applies in one project, not machine-wide. A manual dispatch outside a mission
uses `--touches`:

```bash
boss dispatch feat-a --project shop --touches "src/auth, deps"
boss dispatch docs-fix --project shop --touches none
```

`boss dispatch` and `boss mission next` check locks before creating a worktree
or tab and return `lock_conflict` with the holding change. Holders are running
applies, parked applies with a worktree, and `conflict`/`test_failed`/
`test_timeout` states. A merged green kept worktree holds no locks. Releasing a lock means merging or
finishing the holder; there is no manual release command.

### Filling slots

`boss mission next` skips changes that already have an apply state (the
documented check-off path for a parked change whose tasks are all checked stays
available), skips changes whose locks conflict, and returns `no_startable` with
the blocking holders when nothing else can start. The shared RUN procedure
fills free slots: it repeats `boss mission next` while the result is `started`
and stops on `parallel_limit`, `no_startable`, `waiting_human`,
`mission_complete` or a non-null `resource_warning`. Running applies continue in
every case. After a wake, review and finish or retrigger the finished change,
then refill. At limit one the procedure dispatches once and waits as before.

`boss mission status` shows `max_parallel`, `running`, `slots_used`,
`slots_free` and per-change `running`, `touches` and `declared`. `boss status`
adds `touches`, `declared` and `merge_state`.

### Overlap backstop

`boss review` compares the changed files of the current worktree with those of
the other running, parked and test-failed worktrees of the same project and
returns `overlaps: [{file, changes:[...]}]`. It does not merge, rebase or
resolve; the Explorer uses the report to order merges or retrigger. A stale
lock therefore cannot merge into the same file silently.

### Assignment in PLAN

The vision P4 pass writes `touches:` on every mission bullet: source paths or
directories the change will edit and shared resources (`deps`, `test-env`,
`port:<n>`, `db:<name>`). Use `touches: none` for an isolated change; omit the
annotation only while uncertain, which makes the change exclusive. `boss
doctor` warns for every mission change without a declaration when
`max_parallel > 1`, and reports the effective limit including the
`BOSS_MAX_PARALLEL` override.

## Reconcile gate

`boss reconcile <slug> --json` is read-only context. Before starting a change
after the mission has a finish or park boundary, record that the remaining plan
was checked:

```bash
boss reconcile <slug> --project <name|path> --done <change>
boss mission next <slug> --project <name|path> --dry-run
boss mission next <slug> --project <name|path>
```

`--done <change>` writes a mission-level `reconcile_done` marker for exactly
that change. `mission next` refuses with `reconcile_required` when the marker is
missing or older than the latest mission finish/park. `--dry-run` shows the
selected change, runner and reconcile state without claiming, starting an agent
or writing apply state. `--skip-reconcile` overrides the gate and records a
`reconcile_skipped` event plus a journal entry.

Before `dispatch` and `mission next` start an apply, boss runs
`openspec validate <change> --strict`. A red change returns `change_invalid`
with the validator output and starts nothing; fix the artifacts first.

Command results that are JSON go to stdout; logs, warnings and errors go to
stderr, so `boss park … | jq` and the other JSON commands stay parseable.
`boss status` and `boss doctor` without `--json` are explicitly text output.

Stop an apply deliberately with `boss interrupt <change>`; the runner's
`interrupt_keys` (default opencode `esc esc`, Claude `esc`) are sent, the event
log and journal record the interruption, and the next wake is reported as
`interrupted` instead of `done`/`idle`. `boss retrigger` clears the marker.

`boss wait --all` is scoped to the caller's project, or to its Herdr
workspace when no project is available; `--all-projects` performs the explicit
global pass. `boss doctor --fix` removes registry entries whose pane no longer
hosts an agent; moved living entries are only reported.

## Caller identity and wake routing

Before `claim`, `dispatch`, `mission next`, `retrigger`, `resume`, `park`,
`finish` or `answer` records a boss identity, boss verifies the caller. The pane
in `HERDR_PANE_ID` must be alive, belong to `HERDR_WORKSPACE_ID`, and have a cwd
related to the calling process. A missing `HERDR_WORKSPACE_ID` is rejected even
when the pane id is alive. Boss also compares the caller's agent session id
(environment or foreground `--session-id`/`--resume`) with the pane's Herdr
`agent_session`; a stale pane fails with `caller_pane_mismatch`, and a fork or
background session that inherited an old pane fails with
`caller_session_mismatch`. Both mismatches write nothing. The error names the
pane found by walking the process ancestry of the calling process, so the
likely real pane is visible.

The waiter watches the pane id, not the agent name. If `herdr agent wait` fails
but the pane still hosts an agent, it refreshes the name and keeps waiting; it
reports `lost` only after both `agent get` and `agent list` show no agent on
the pane.

Use an explicit target instead of editing environment variables by hand:

```bash
boss dispatch <change> --as <pane|agent>
boss retarget <change> --to <pane|agent>
boss claim --as <pane|agent> [--name <name>] [--force]
```

`boss retarget <change>` is state-only: it moves a running apply's dispatcher to
the verified caller or `--to` target, updates the dispatcher fields and records
a `retarget` event. It never claims, renames or writes a
`bosses/<workspace>.json` entry; without `--to` the target is the current pane.
`boss claim --as` is the separate registry repair. A claim that would rename a
pane already carrying a different living boss name registered in
`bosses/*.json` is refused with `boss_exists` unless `--force` is explicit; the
auto-claiming commands (`dispatch`, `session`, `retrigger`, `finish`, `answer`,
`park`, `resume`) never force. The claim result is honest: `already_claimed`
means nothing changed, `claimed` means a previously unnamed pane was registered,
and `renamed` means the pane name or registry value changed. Read-only commands
(`status`, `review`, `wait`, `doctor`) keep working with a stale environment.

A dispatch records the dispatcher name, pane, workspace, cwd and scope flags in
the apply state. Wake order stays dispatcher -> workspace boss ->
`BOSS_AGENT_NAME`. The dispatcher is woken only when it is alive and either in
the apply's workspace or explicitly recorded as cross-workspace
(`boss_cross_workspace`). Its recorded cwd must also be related to the apply
project, or it must be explicitly recorded as cross-project
(`boss_cross_project`). A workspace boss with a known unrelated cwd is treated
the same way. A verified dispatch from another workspace or project records the
corresponding flag and returns a warning. `boss status` and `boss review` show
the next wake target, skipped candidates with their reason, and the last
successful or failed wake.

If a session moved between Herdr panes, it inherits the old `HERDR_PANE_ID` and
`HERDR_WORKSPACE_ID`. Before this check, a dispatch from such a session recorded
the foreign pane as the dispatcher and the waiter woke a boss in another
project. The check now fails closed on that pattern. Legacy apply state is still
readable: an old same-workspace dispatcher without the new fields keeps
receiving the first wake, an old state without `boss_cwd` keeps the
workspace-only check, and an old cross-workspace or same-workspace
wrong-project dispatcher is skipped (the missing flags read as `false`) until
`boss retarget <change>` repairs it. In particular, an old same-workspace apply
whose recorded `boss_cwd` is unrelated to the apply project is skipped as
`cross_project`; retargeting to the correct pane records the right scope and
restores the wake. That fail-closed behavior is intentional; `boss doctor`
names affected applies and suggests the retarget.

## OpenCode V1 and V2

The boss runtime supports both OpenCode major versions and detects the
installed one with `opencode --version` before it starts an OpenCode runner.
The detected version and the permission mode are stored as
`opencode_version` and `permission_mode` in the dispatch/session JSON and in
the apply state; `boss status` shows them in text and JSON.

- **OpenCode V2** uses one shared background server. Boss adds the native
  `--auto` flag when the runner has no explicit `args` (or `args = []`) and does
  not set `OPENCODE_CONFIG_CONTENT`. A per-tab inline allow-all would be read
  by the shared server and could leak into unrelated sessions, so V2 must not
  rely on it.
- **OpenCode V1** keeps the existing behavior: without an explicit `env`,
  boss passes the inline `OPENCODE_CONFIG_CONTENT={"permission":"allow"}`
  default. Nothing changes for an existing V1 project.

Explicit runner configuration always wins. A non-empty `args` list is passed
as is, and an explicit `env` list prevents boss from adding any default. A
version that cannot be parsed produces a warning and keeps the conservative
V1/legacy path rather than assuming V2.

For V2, `boss doctor` reads the effective configuration with
`opencode debug config` and falls back to `opencode api get /api/config` when
that query fails. It warns about broad deny rules for shell, edit, read or
external-directory actions, and warns when an explicit OpenCode runner `args`
list omits `--auto`. If neither query works, the check is a warning that names
the failed query; it never claims success. For V1, doctor keeps the tab
environment check.

The installer runs `herdr integration status` after
`herdr integration install opencode` and requires the line
`opencode: current`. If the integration is missing or stale, the install fails
with a hint to update Herdr to a version that ships opencode integration v13
or newer. That turns a silent V2 agent-state failure into an install-time
error.

### Migrating an existing `boss.toml`

An existing OpenCode runner with `args = []` needs no edit: under V2 boss
automatically adds `--auto`, and under V1 it keeps the inline permission
default. To take full control, set a non-empty `args` list explicitly. If that
list omits `--auto` on V2, boss uses exactly the configured arguments and
`boss doctor` reports the missing auto mode as a warning. An explicit `env`
list likewise replaces the V1 default.

`--auto` is a per-invocation flag on the shared V2 server. If you need a
private server per apply instead, add `--standalone` to that runner's explicit
`args`; this is an explicit isolation option, not a default, because it starts
and manages a separate server process.

## ACP runner (Goose and other ACP agents)

Goose is not a Herdr-native agent kind, but it exposes an ACP server
(`goose acp`). A runner with `start = "acp"` is driven by the bundled
`boss-acp` supervisor over stdio: session lifecycle, model and mode selection,
permissions, cancellation, resume and a JSONL transcript. The apply tab still
exists for a human view, but it only tails the transcript and hosts no agent;
no behavior reads the pane.

An ACP runner is apply-only: `boss session` rejects it with
`acp_session_unsupported`. `command` names the agent binary that speaks ACP;
`args` and `env` are native-only and have no effect on an ACP child, while
`model`, `mode`, `policy`, `deny` and `apply` are the supported knobs.

```toml
[runners.goose]
start = "acp"
command = "goose"
model = "claude-sonnet"        # optional; must be offered by the agent
mode = "smart_approve"         # default; auto, approve, smart_approve, chat
policy = "allow"               # allow (default) or ask for unmatched requests
deny = ["git push --force*"]   # optional; defaults to the boss deny list
apply = "Follow the returned tasks."  # optional extra instructions
```

`boss dispatch <change> --runner goose ...` starts the supervisor detached. It
sends the apply prompt over ACP; the prompt runs
`openspec instructions apply --change <change> --json` and never depends on a
slash command. `session/update` notifications are appended to a JSONL
transcript and shown in the apply tab. `boss status` reads the state file and
the transcript tail, not the pane.

### Dispatch runs the installed runtime

A dispatch uses the installed runtime (`~/.local/bin/boss` and `boss-acp`), not
the repository branch the Explorer reads. A merged runtime change therefore has
no effect until it is installed:

```bash
./install.sh
boss --version                     # names the installed commit and origin
```

Before trusting the first ACP apply after such a change, check its state:
`acp.isolated` must be `true` and `acp.profile_root` must name the per-apply
profile (`boss status <change> --json`). Without them the dispatch came from an
older runtime and keeps the old behaviour, including world-readable
transcripts and no permission queueing. Re-run `./install.sh` and dispatch
again instead of debugging the change.

The status JSON names what drives the session and what it waits for:

| Field | Meaning |
| --- | --- |
| `runner` | the configured runner (`goose`); the aggregate row shows it too |
| `acp.model`, `acp.mode` | the model and mode applied to the session |
| `acp.last_update` | the last message text or tool activity (at most 200 characters). Streamed chunks are joined per message id; usage-only and whitespace-only chunks do not overwrite it |
| `pending_permissions` | every pending request with tool-call id, command and options |
| `pending_permission` | compatibility alias for the first entry; `null` when nothing is pending |
| `acp.stalled` | `true` while a working turn has made no progress and the boss has been woken about it |

The aggregate `boss status` derives liveness from the same process as the
per-apply view: for an ACP apply that is the supervisor pid, so a live
supervisor is never printed as `waiter: DEAD`. The aggregate row also names the
pending count and the pending tool-call ids.

Permissions are a policy, not a prompt: a command matching `deny` is rejected
before it runs, a read-only tool or an allowed request proceeds, and with
`policy = "ask"` an unmatched request stays pending. Every pending request is
queued independently by tool-call id, so concurrent requests are reported
together and answering one never discards another. The apply reports `blocked`
and `boss status` lists every pending tool call with its id, command and
offered options:

```bash
boss status <change>                                # all pending requests
boss answer <change> allow_once --tool-call <id>    # answer one request
boss answer <change> allow_once <id>                # same, positional form
boss interrupt <change>                             # cancel every pending request
```

With exactly one pending request the option alone is still enough; with more,
an answer without a tool-call id is refused with `ambiguous_pending` and names
the ids.

One blocked transition wakes the boss once, however many requests arrive
before the first answer: the wake names the number of pending requests and their
ids, and the flag clears when the last request is answered. A new blocked
transition wakes again.

### Turn bounds

An ACP turn is bounded twice, and both bounds are configurable:

- `BOSS_ACP_TURN_TIMEOUT_S` (default `7200`, two hours) is the longest a turn
  may wait for the prompt response. On expiry the supervisor sends
  `session/cancel`, records `turn_timeout` as the stop reason, ends the turn and
  wakes the boss. `0` disables the timeout explicitly.
- `BOSS_ACP_STALL_S` (default `1800`, thirty minutes) is the longest a `working`
  turn may go without transcript progress. The supervisor checks every
  `min(30 s, BOSS_ACP_STALL_S / 2)`; when the interval passes it wakes the boss
  once with state `stalled` and the last activity, and sets `acp.stalled`. Any
  new transcript entry clears the flag and restarts the timer, so a turn that
  recovers can be reported as stalled again later. A `blocked` turn waits for
  the Explorer and is never a stall. `0` disables the check.

The defaults sit above the longest expected command (the full suite takes about
eight minutes) so a normal `./tests/run.sh` is not a stall. A tool call that
keeps emitting `tool_call_update` is progress; a silent tool call is not, which
is why the stall interval, not the tool-execution time, is the measure. Raise
both values for a project with a longer run rather than disabling them.

An automatic allow always selects the agent's `allow_once` option and never
`allow_always`, so it cannot create a persistent agent-level grant. If the agent
offers no allow-once option, the request stays pending (fail closed) and the
supervisor logs why. An Explorer `allow_always` answer is recorded as an
apply-scoped grant in `acp.apply_allows`, sent to the agent as `allow_once`, and
kept for the rest of the apply; every matching request is auto-allowed. Nothing
is written to the agent's global permission store.

`allow_always` is an agent-level grant in the agent's own model: it applies to
every later session of that agent, not only to this apply. The runner therefore
never creates one and maps an Explorer's `allow_always` answer to the
apply-scoped `acp.apply_allows` above. A user who writes such an entry into
Goose's own `permission.yaml` gives it to every session; an isolated runner is
unaffected because its store is boss-owned and empty, while a non-isolated
runner is reported as `weakened` by `boss doctor`, which names the entry. The
grant only skips the prompt; only an OS sandbox or a separate user confines what
the shell can do.

`boss interrupt` sends `session/cancel` and never keystrokes; it records the
`cancelled` stop reason and cancels every queued request first. If the agent does
not confirm within `BOSS_ACP_CANCEL_TIMEOUT_S`, the state records
`cancel_unconfirmed` and the boss is woken. `boss finish` closes the session
(`session/close`), stops the supervisor and removes the per-apply profile.

### Isolated agent state

By default the ACP child runs with a per-apply profile below
`$BOSS_STATE_DIR/acp/profile-<hash>/`:

```text
config/goose/   config.yaml, secrets.yaml and provider state linked from the
                user's profile; permission.yaml generated and boss-owned
data/goose/     private sessions/, apps and model catalog linked read-through
```

`XDG_CONFIG_HOME` and `XDG_DATA_HOME` point at that root. The generated
`permission.yaml` has empty `always_allow`/`never_allow` lists in both the
`user` and `smart_approve` sections and lists `shell`, `write`, `edit`,
`read_image` and the extension manager under both `ask_before` lists, so Goose
asks and the supervisor sees every request. A supervisor restart reuses the
same profile; `boss finish` removes it together with the apply state.
`isolate = false` is the escape hatch and uses the user's global profile.

The profile isolates Goose's configuration, permission store and sessions. It
is **not a filesystem sandbox**: the shell, write and edit tools still run with
the user's OS permissions and reach every path that user can reach. Only an OS
sandbox (a container, a sandboxed unit) or a separate user confines them; the
worktree only keeps parallel applies out of each other's index.

### Transcript and log privacy

The transcript below `$BOSS_STATE_DIR/transcripts/` and the supervisor log
`$BOSS_STATE_DIR/logs/<change>-acp.log` are created with mode `0600`. Both hold
full commands, tool output and model text, so they are readable by the operator
only. The supervisor chmods the file on every append, so a transcript created
world-readable by an older runtime is corrected the next time it is written.

A transcript is retained until the operator removes it. `boss finish` deletes
the state file, the profile and the socket, but keeps the transcript: it is the
evidence for the finished apply and for a later audit. Rotation keeps one
previous file (`<transcript>.1`) with the same mode. A cleanup (a cron job or a
manual `rm`) is an operator decision; no retention policy is implemented.

### Doctor and the effective policy

`boss doctor` validates every configured ACP runner: the command is on `PATH`,
the handshake succeeds (`initialize` + `session/new`), and the configured model
and mode are offered (a mismatch names the available values). It also reports
the isolation state and the effective permission store. An ACP runner is skipped
by the Herdr integration and `kind` checks.

A runner is reported as `enforced` when its profile is isolated, or when a
non-isolated runner's global permission store has no `always_allow` entry for
`shell`, `write` or `edit`. If such an entry exists, the doctor reports
`weakened`, names the entry and points at the per-apply profile; it reads the
store read-only and never edits it. Doctor probes run with a temporary profile
and delete it afterwards, so a probe leaves no session or permission entry
behind.

The supervisor persists the session id, model, mode and last stop reason.
After a crash, `boss resume` calls `session/load` when the agent advertises it,
replays the updates into the transcript (duplicates are skipped by message and
tool-call id) and re-applies model and mode. Without `loadSession` the apply is
reported as `unresumable` and `boss retrigger` starts an explicit new session
instead of silently editing the same worktree twice. A dead supervisor frees
its concurrency slot and wakes the boss; the declared resource locks remain
until the apply is finished.

## Trust model and limits

The apply agents are the only place where the runtime deliberately hands over
control, so the boundaries are worth stating once:

- **Broad permissions by design.** An apply tab runs its agent with
  auto-approval (`OPENCODE_CONFIG_CONTENT` with allow for OpenCode V1,
  `--auto` for V2, `--permission-mode bypassPermissions` for Claude). The
  reason is the same in every case: a session that stops on a permission
  prompt is a session nobody wakes up, and the whole loop assumes nobody is
  watching.
- **The charter is the boundary.** What an apply may do (branches, pushes,
  destructive operations) is decided before the run in the mission charter and
  enforced by the agent reading the skill. That is a prompt-level boundary, not
  a sandbox.
- **The deny list is defence in depth.** Every apply additionally gets a small
  list of commands it never needs (`BOSS_POLICY_DENY_DEFAULT`: force-push,
  mirror-push, `git push --delete`, `git filter-branch`, `git filter-repo`).
  For a `claude` runner the dispatcher passes them as `--disallowedTools`. For
  OpenCode the agent reads the deny rules from its own configuration, so
  `boss doctor` and every dispatch result report a `policy` object: `enforced`,
  `verified`, `missing`, `unavailable` or `off`. A runner can tune the list with
  `deny = [...]` in its `[runners.<name>]` table; `deny = []` turns it off.
  The check never blocks a dispatch - it makes a weak configuration visible.
- **`boss review` runs the project's test command.** It executes what it
  detects (`just test`, `npm test`, `pytest`, `make test`, `./tests/run.sh`,
  `./scripts/test.sh`, the legacy `[tests]`
  string or `[tests.<project>].command`) with the resolved budget. That is code
  from the target repository, run with the user's rights, exactly as a developer
  would run it.
- **Worktrees isolate, they do not sandbox.** Parallel applies run in their own
  worktree and branch, which keeps two changes out of each other's index; it is
  not a security boundary either.

If you need a real boundary, run the apply agent in a container or on a
separate station (see `vision/references/external-review.md` for the review
pass on such a station).

## Repository layout

| Path | Purpose |
| --- | --- |
| `runtime/bin/boss` | entry point: config, runner resolution, dispatch table |
| `runtime/bin/boss-lib.sh` | shared helpers: paths, JSON, locks, policy, herdr |
| `runtime/bin/boss-apply.sh` | dispatch, claim, session, worktrees, readiness |
| `runtime/bin/boss-status.sh` | `status` |
| `runtime/bin/boss-review.sh` | `review` (tasks, validate, tests, git, friction) |
| `runtime/bin/boss-run.sh` | wait, inbox, journal, retrigger, finish, park, resume |
| `runtime/bin/boss-doctor.sh` | `doctor` |
| `runtime/bin/boss-mission.sh` | missions and `reconcile` |
| `runtime/bin/boss-waiter` | detached watcher for one apply |
| `runtime/bin/boss-acp` | wrapper that starts the ACP supervisor |
| `runtime/lib/boss_acp.py` | ACP session, permission, transcript and control supervisor |
| `scripts/gen-commands.sh` | generates the 34 command wrappers from `commands/commands.tsv` |
| `scripts/runtime-manifest.sh` | records/verifies the vendored runtime hashes |
| `scripts/check-generated.sh` | fails when the OpenSpec instruction files are stale |
| `tests/run.sh` | regression suite (stub herdr/openspec/opencode, temp HOME) |

Files under `.opencode/` and `.claude/commands/opsx/` are output of
`openspec update`, not hand-written; `scripts/check-generated.sh` fails when
they are stale. The `boss-*.md` wrappers are generated from
`commands/commands.tsv` - edit the table, run `scripts/gen-commands.sh`, and
check the result with `--check`.

The runtime in `runtime/bin/` is a vendored snapshot (see `runtime/VENDOR.md`);
`runtime/MANIFEST.sha256` records its hashes so a change is always deliberate.

## Language

Code, comments, messages and this README are English. The OpenSpec specs in
`openspec/specs/` were written in German and are kept that way as the historical
record; new or substantially rewritten specs should be English.

## Tests

Run the runtime test suite from the repository root:

```bash
./tests/run.sh
```

The tests use a temporary `HOME`, state directory and stub `herdr`/`openspec`
commands, so they do not touch a real workspace, a real apply or another
project.
