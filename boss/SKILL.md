---
name: boss
description: Runs one existing OpenSpec change or a small ad-hoc batch from a central Explorer session, without a planning phase – dispatch, wake, review, retrigger, park/resume, retarget, interrupt, finish and archive. Use when the user asks to dispatch, review, fix or finish a single change, or to run a handful of changes, including changes inside a mission. For a large project (roughly 20-50 changes), a vision, feature map, milestone plan or ordered version missions, use the vision skill instead.
allowed-tools: Bash(openspec:*), Bash(boss:*)
license: MIT
metadata:
  version: "1.0"
  sharedRun: "vision/SKILL.md (shared:run block)"
---

# Boss – run one change or a small batch

This skill is the run-only entry point: it drives one existing OpenSpec change,
or a small ad-hoc batch of changes, from a central Explorer session. It has no
PLAN phase.

- Missing artifacts are created directly with `openspec instructions` and
  checked with `openspec validate --strict`; no planning interview, vision or
  feature map is involved.
- A change inside a mission is selected with `boss mission next`, with the same
  gates and reconcile rule described below.
- A large project – roughly 20-50 changes, a vision, feature map, milestone
  plan or ordered version missions – belongs to the vision skill, not here.
- The procedure below is the same text the vision skill embeds. Editing it in
  one of the two files alone fails the drift test in `tests/run.sh`.

## Run procedure

<!-- shared:run:begin -->
### Run-only entry

The user may invoke this skill for a single existing change without a plan.
In that case skip PLAN and `openspec/vision.md` entirely:

1. Select the change (`openspec list --json`, or the name the user gave).
2. Check `openspec status --change "<name>" --json`; if required artifacts are
   missing, create them with `openspec instructions` and validate.
3. Ask the open design questions once, with a recommendation each, and wait for
   explicit approval. A pure error fix with one obvious solution needs no
   question – say in one sentence why nothing is open.
4. Run the single-change loop: dispatch, wake, review, fix or finish. No
   mission, no milestone, no final sort.

After the change is finished, stop and offer archiving.

### Mission order

Read the mission files (or `openspec/vision.md` when it exists) and process
missions in version order: **v1 -> v2 -> v3**. Never start a later version while
an earlier one has unfinished changes unless the mission docs explicitly say
they may run in parallel (they normally do not).

For each mission, the loop is:

```text
boss mission next -> dispatch -> wake -> review -> retrigger/finish -> reconcile -> next
```

### Session start

At the start of a RUN session, before the first dispatch:

```bash
boss inbox                         # recover a wake lost earlier
boss wait --all                    # scoped to this project/workspace; --all-projects for all
boss doctor --project <name|path>  # read-only preflight; --fix only safe repairs
```

Then check the mission charter with `boss mission status <slug> --project <p>`.
If it reports `charter_open`, do not dispatch: resolve the charter first, and
only then continue.

### OpenCode V1 and V2

Boss detects the installed OpenCode major version and selects the runner mode:

- **V2** runs one shared background server. Boss adds the native `--auto` flag
  when the runner's `args` is absent or empty and does not set
  `OPENCODE_CONFIG_CONTENT`. Never tell an operator to patch a per-tab
  environment on V2: the shared server reads it, so it cannot scope permissions
  to one apply tab.
- **V1** keeps the existing inline permission default when the runner has no
  explicit `env`. Its behavior is unchanged.

Explicit `args` and `env` always win. The dispatch/session JSON and apply state
carry `opencode_version` and `permission_mode` (`auto` on V2, `inline` on V1 or
an unknown version); `boss status` shows both. An unknown version warns and
keeps the legacy V1 path instead of assuming V2.

For V2 troubleshooting, `boss doctor` is the source of truth about
permissions: it reads the effective config with `opencode debug config` (falling
back to `opencode api get /api/config`) and names broad shell/edit/read/
external-directory deny rules or a runner whose explicit `args` omit `--auto`.
If an apply starts but Herdr cannot report its state, run
`herdr integration status` and require `opencode: current`; the installer needs
opencode integration v13 or newer. Re-run `./install.sh` after updating Herdr.

### The mission loop

1. **Reconcile before each dispatch.** After a change finished or was parked
   (and before the next `boss mission next`), run:

   ```bash
   boss reconcile <slug> --project <name|path> --json
   boss mission next <slug> --project <name|path> --dry-run
   ```

   Read the assembled context (charter, remaining changes, backlog, inbox,
   journal) and the dry-run result. Actually read the affected code and the
   applied result. Sharpen the remaining proposals/specs/tasks that no longer
   hold – with `openspec instructions` and `openspec validate`, never by
   editing project source. Then record the handshake for exactly the change the
   dry run selected:

   ```bash
   boss reconcile <slug> --project <name|path> --done <change>
   ```

   `mission next` returns `reconcile_required` when the marker is missing or
   older than the latest mission finish/park. `--skip-reconcile` bypasses it
   only with an explicit reason and writes a journal entry. The pass asks no
   questions: when a charter assumption broke, write a
   `[charter-assumption-broken]` entry with `boss journal` and continue in the
   most conservative in-grant path.

2. **Start the next change.**

   ```bash
   boss mission next <slug> --project <name|path>
   ```

   React to the result:
   - `charter_open` -> stop this mission, fix the charter, report; do not
     dispatch.
   - `mission_complete` -> continue with the next version.
   - `waiting_human` -> report the bundled handoff (each parked change with
     its open human tasks and acceptance criteria) and end this mission. Do not
     report `mission_complete` and do not wait.
   - The runner comes from the change's `runner:` bullet; do not override it
     with a manual dispatch. An `unknown_runner` error means the name is not in
     `[runners]`, not that the default should be used.
   - `change_not_ready` -> create the missing artifacts named by the result
     with `openspec instructions` (proposal, specs, design, tasks), validate,
     then call `next` again.
   - `change_invalid` -> fix the validator finding in the change artifacts with
     `openspec instructions`, run `openspec validate --strict`, then call
     `next` again.
   - `executer_busy` -> an apply is already running; end your turn and wait for
     the wake. Do not poll.
   - dispatched -> end your turn. The waiter wakes you when the apply settles;
     never poll `boss status`.

3. **On wake: review.** The wake prompt carries the change, the project, the
   state (`done` or `idle`) and the apply's last output. Run `boss inbox`
   first. Then:

   ```bash
   boss review <change> --project <name|path> --json
   ```

   Run the review checks in the embedded procedure below. A green diff and
   checked-off tasks are not enough; verify external claims, runtime state and
   any verification that was deferred to "later" or "by a human".

4. **Fix or finish.**
   - Problems: update proposal/specs/design/tasks in the target project with
     the OpenSpec instructions and validate, then
     `boss retrigger <change> --project <p> --note "<what to fix>"`. A fix that
     changes the design goes through one explicit clarification round first;
     a pure review fix does not.
   - Only marked human tasks left: `boss park <change> --project <p> --note
     "<what the human must do>"`, then journal the handoff and continue with
     the changes that do not depend on it. Do not retrigger, do not use
     `finish --force`, and do not call the change finished.
   - Green: `boss finish <change> --project <p>` and record a durable lesson
     with `--lesson` when the review verified one.
   - Blocked: read the visible dialog; accept a consent/permission dialog;
     otherwise choose the conservative, reversible option, journal it, and
     continue. If no safe choice exists, `boss finish <change> --force`,
     journal the open question, and turn the remaining tasks into a follow-up
     change.

5. **Repeat.** After `finish` or `park`, run `boss mission next` for the
   mission's next change (step 1/2 above). After `mission_complete`, move to
   the next version. After `waiting_human`, hand the bundle to the human and
   end the mission; resume it later with `boss resume` or checked-off tasks.
   After the last version, report completion or handoff and offer archiving.

### Worktree applies

An isolated apply runs in a git worktree outside the project tree, on branch
`boss/<change>`, in its own Herdr workspace. Choose the mode with
`[missions] worktrees = "auto"|"always"|"never"` (default `auto`) in
`boss.toml`, or per command with `--worktree` / `--no-worktree` on
`boss dispatch` and `boss mission next`. In this change `auto` keeps the
base-checkout behaviour; `always` and `--worktree` isolate.

Before the first isolated dispatch, commit the plan on the base branch:

```bash
boss plan commit <change> --project <name|path>
```

It commits only `openspec/vision.md`, `openspec/missions/` and
`openspec/changes/` (`status: committed` with the commit id, or `clean` when
already committed) and never touches code. An uncommitted plan returns
`plan_uncommitted`; a dirty base outside `openspec/` returns `base_dirty`. Fix
the named paths before dispatching.

The run then dispatches as usual. The state stays keyed by the base project and
change and records the worktree path, branch, worktree workspace, base commit
and merge state. `boss review` reads git, tasks, `openspec validate` and the
test command from the worktree; the mission and plan stay in the base. The base
checkout must stay unchanged by the apply.

On green, `boss finish` merges the worktree branch into the base
(`--ff-only` at `base_head`, otherwise `--no-ff`), runs the configured or
detected test command on the merged base, then closes the tab, removes the
worktree, deletes the branch and the state. On a conflict it aborts the merge,
keeps worktree and state and returns `merge_conflict` with the paths. A red
integration test keeps the state with `merge_state=test_failed` and
`merge_test_failed`; fix on the base and run `boss finish` again. Under
`explorer` the worktree must be clean and the Explorer commits the reviewed
change paths there first; under `agent` verify the commits. `--keep-worktree`
merges and tests but keeps the worktree, branch and state (`kept=true`,
`merge_state=done`); `--no-merge` closes the tab and keeps them without a finish
event. A later `finish` cleans up either path.

`boss park` keeps the worktree and branch. `boss resume` reuses them and starts
a fresh agent in the same worktree; `boss retrigger` continues in place, or
starts a new agent there when the old one is gone. A missing worktree fails with
`worktree_missing`; never fall back to the base checkout. `boss doctor` reports
missing worktree paths, conflicted or test-failed states, uncommitted change
dirs, orphaned worktrees, a dirty base and an uncommitted plan.

### Caller identity and wake targets

Boss verifies the caller before every write command (`claim`, `dispatch`,
`mission next`, `retrigger`, `resume`, `park`, `finish`, `answer`): the
`HERDR_PANE_ID` pane must be alive, belong to a non-empty `HERDR_WORKSPACE_ID`,
and have a cwd related to the calling process. A stale inherited environment
fails with `caller_pane_mismatch` and records nothing; the error names the pane
found by walking the process ancestry. Never edit `HERDR_*` variables or the
apply state by hand. Rerun the command with `--as <pane|agent>`, or repair a
running apply with `boss retarget <change>` (it defaults to the verified
caller). `boss retarget` is state-only: it changes only the apply's dispatcher
fields and event; it never claims, renames or writes a workspace registry.
`boss claim --as` is the separate registry repair. Read-only commands
(`status`, `review`, `wait`, `doctor`) still work with a stale environment and
`boss doctor` reports it.

A claim on a pane that already carries a different living registered boss name
is refused with `boss_exists` unless `--force` is explicit. Auto-claiming
commands never force it. Statuses are honest: `already_claimed` means nothing
changed, `claimed` means a previously unnamed pane was registered, and
`renamed` means the pane name or registry value changed.

The wake order is unchanged: recorded dispatcher -> workspace boss ->
`BOSS_AGENT_NAME`. The dispatcher is only woken when it is alive, either in the
apply's workspace or explicitly recorded as cross-workspace
(`boss_cross_workspace`), and its recorded cwd is related to the apply project
or explicitly recorded as cross-project (`boss_cross_project`). A verified
dispatch from another workspace or project records the corresponding flag and
returns a warning. A workspace boss with a known unrelated cwd is filtered the
same way. `boss status` and `boss review` show the next wake target, every
skipped candidate with its reason (`cross_workspace`, `cross_project`, `dead`,
`moved`), and the last successful or failed wake.

Legacy applies: a state without `boss_cwd` keeps the workspace-only rule, and a
state without `boss_cross_project` reads as false. An old same-workspace apply
whose recorded `boss_cwd` belongs to another project is skipped as
`cross_project`; an old cross-workspace apply without the flag is skipped as
`cross_workspace`. Repair either with `boss retarget <change>` from the right
pane (or `--to <pane|agent>`); never hand-edit the state file.

### Embedded boss run procedure (verbatim)

The following is the boss run procedure, embedded so each skill is
self-contained. It is adapted only where a slash command would load another
skill: planning commands are the direct `openspec` commands, fixes use
`openspec instructions` + `openspec validate`, and archiving uses
`openspec archive`. All boss command spellings, gates and rules are unchanged.

> **Step 2 (Clarify) belongs to planning.** In a planned run every open
> question is settled in the mission charter before the run; in a run-only run
> it is asked once before the single dispatch. During a run the autonomy policy
> below applies and the skill never waits for the human.

#### Explorer and Executer

Two roles, one command set: the **Explorer** is this session; an **Executer**
is an apply agent (`apply-<change>`). The Explorer plans, delegates one change
at a time, reviews the outcome and keeps the skills sharp; the Executer only
carries out its one change and reports back. One workspace has at most one
Explorer and at most one active Executer – `boss dispatch` refuses a second
apply in the same workspace with `executer_busy`.

#### Workflow

1. **Plan** – in the target project, not in your session: work there with the
   direct CLI (`cd <project> && openspec …`, e.g. `openspec list`,
   `openspec status`) and the planning commands. Project names come from the
   registry in `~/.config/openspec-boss/boss.toml` (the `[projects]` section).
   For a large task that spans several changes, record the plan as a
   **mission** in the target project – `boss mission start <slug> --project <p>`,
   then fill in the goal and the change order (see Missions).
   Before the run, preflight the environment with `boss doctor --project <p>`
   (read-only; `--fix` creates missing directories, runs `openspec init` and
   registers the project – nothing else). On OpenCode V2, doctor checks the
   effective config from `opencode debug config`; on V1 it keeps the tab
   environment check. V2 dispatches use `--auto` and the shared background
   server, so never "fix" permissions by setting `OPENCODE_CONFIG_CONTENT` in
   a tab. Require `herdr integration status` to report `opencode: current`
   (integration v13 or newer).
2. **Clarify** – before the first `boss dispatch` of a new change, or of one
   whose design changed substantially: ask the human the open design questions
   and wait for the answers. List the assumptions the plan rests on –
   thresholds, markups, scope, which data counts, alternatives you discarded –
   as questions, each with your recommendation, and ask them with the tool's
   question mechanism. Dispatch only after an explicit approval in a separate
   message from the human. A pure error fix with no open choice (an off-by-one
   with one obvious solution) needs no question – say in one sentence why
   nothing is open. A broad delegation ("continue autonomously, deploy to
   prod") covers review, deploy and retrigger after review findings, but does
   not replace the questions before the dispatch. A retrigger that changes the
   design goes through here again; a retrigger for pure review findings does
   not. This happens during planning or once before a run-only
   dispatch – never mid-run.
3. **Dispatch** – once all artifacts of the change are ready:
   `boss dispatch <change> --project <name|path> [--runner <name>] [--note "<text>"] [--as <pane|agent>]`.
   In a mission, use `boss mission next <slug> --project <p> [--as <pane|agent>]` instead of naming
   each change: it picks the first startable change that is not `done` and
   dispatches it the same way. Parked changes and changes whose prerequisites
   are not satisfied are skipped; an undeclared dependency keeps the document
   order.
   Use `--note` to hand the apply agent context it cannot know (a real case
   to test against, which tool to use for a check, who reviews). Durable facts
   – URLs, measurements, external formats – belong in the change artifacts
   (proposal/specs/tasks), not in the note; keep the note for what the agent
   cannot learn from the artifacts. Runner-wide expectations, above all
   whether the apply commits its work, belong in the runner's `apply` template
   in `boss.toml`, not in the note. The JSON result contains agent, pane and
   tab. You do not switch into the apply tab; the apply agent works there on
   its own. Every apply prompt ends with a yield instruction: the apply stops
   at the end of its turn and does not wait or poll for a review. An apply
   that is still `working` thus stays silent – if it stays that way longer than
   `BOSS_WAITER_STALL_MS` (default 45 min), the waiter sends you a "still
   working" notice, no action required.
4. **Being woken** – the waiter reports completion to you as a prompt, e.g.
   `Apply add-auth in ~/work/shop: done. Last agent output: … Next step:
   boss status add-auth`; the agent's last output is already attached, you do
   not have to reconstruct it from logs and diffs. If the prompt arrives while
   you are working, it is queued – handle it after the current turn.
   `done` and `idle` both mean "the apply ended its turn": `done` is the
   explicit completion signal, `idle` means the agent is back at its prompt
   (for example after a yield without a final signal). Neither means the
   change is finished – the review decides that, and you react to both the
   same way. The waiter stays armed: every time the apply agent returns to a
   settled state after being prompted again (`boss retrigger`, `boss answer`,
   or a direct `herdr agent prompt`), you are woken again. If you prompted the
   agent directly and are unsure a waiter is alive, run `boss wait <change>`.
   Every wake is also recorded durably: run `boss inbox` at the start of a wake
   to pick up an earlier wake that was lost, and once per session run
   `boss wait --all` to re-arm waiters orphaned by a restart; it is scoped to this project/workspace, use `--all-projects` only when a global pass is intended. The waiter tries
   the dispatcher first only when it is safe (same workspace or flagged
   cross-workspace, and its recorded cwd related to the apply project or flagged
   cross-project), then the workspace boss, then `BOSS_AGENT_NAME`; a skipped
   candidate with its reason (`cross_workspace`, `cross_project`, `dead`,
   `moved`) and the last wake show in `boss status` and `boss review`.
5. **Review** – `boss review <change> --json` gathers the deterministic
   facts (tasks, `openspec validate`, tests, git) and the friction from the
   event log. Check:
   - `quality.tasks.open == 0`?
   - `quality.validate == "pass"`?
   - `quality.tests.result` is `pass` or `not_run` (not `fail`)? A `not_run`
     means no test command was found or its program is missing – look yourself.
   - `quality.git.commit_policy` is `explorer` or `agent`. Under `explorer`
     the boss expects an **uncommitted** working tree; every commit in
     `quality.git.commits` is also listed in
     `friction.commit_policy_violations`. Under `agent` the apply is expected
     to commit its tested work. `quality.git.changed_files` is the remaining
     working tree either way.
   If a write command answers `caller_pane_mismatch`, use the named pane with
   `--as`; if an existing apply wakes the wrong session or its dispatcher is
   dead, run `boss retarget <change> [--to <pane|agent>]` instead of editing
   state or `HERDR_*` variables. Retarget moves only the apply and never
   repairs the registry: use `boss claim --as <pane|agent>` only when the
   workspace registry itself is wrong, and pass `--force` only for an
   intentional rename of a pane that already carries another registered boss
   name.
   - diff plausible? Read the changed files yourself (in the target project).
   - `summary` (also in `boss status`) is the last agent output – a starting
     point, not a replacement for reading the diff.
   - `friction.retriggers` / `friction.blocked_count` show how bumpy the run
     was – a reason to look closer, not a failure by itself. They are counted
     per apply run (since the last `dispatch`).

   A green diff and checked-off tasks are not enough – the expensive mistakes
   live outside the diff. Also check:
   - **Claims with an outside reference** – URLs, IDs, external formats the
     apply agent could not know – verify a sample yourself. Invented source
     URLs look fine in the diff and in a green test run.
   - **Runtime state** for daemons and services: is the process actually
     running, is the data store filling, what does the log say? A worker that
     never started leaves every task checked off.
   - **Checked off is not done**: a task whose verification is "after N
     minutes/hours" or "by a human" is not done without that proof;
     hand-written fixtures do not count as "from the archive".
   `boss status <change>` still shows the live agent state and the apply tab.
6. **Fix** – if the review finds problems: correct proposal/specs in the
   target project with `openspec instructions` (then `openspec validate`), and
   `boss retrigger <change> [--note "<text>"] [--as <pane|agent>]` – the apply continues in the
   same agent, the context is kept, and the waiter reports the next
   completion. A fix that changes the design, not just the code, goes through
   **Clarify** (step 2) before the retrigger.
7. **Finish** – if the review passes, handle the commit policy first:
   - Under `explorer`, commit exactly the reviewed change paths from the
     working tree, using the text of the apply's completion report as the
     commit message. Do not commit unrelated paths. Then run `boss finish`.
   - Under `agent`, verify the commits in `quality.git.commits`; then run
     `boss finish`.
   `boss finish` closes the apply tab and cleans up; it needs the agent to be
   settled, nothing else. Under `explorer` it warns if the working tree is
   still dirty (it does not abort).
   Capture what the review verified, not what the apply agent claimed. A short
   fact that stays relevant goes to a store with `--lesson "<text>"` (and
   `--lesson-scope global` when it is not a property of this project); a
   reusable procedure or trap becomes a **skill** – see Skills from
   experience. Choose the store: a project property (how its tests run, where
   the real data lives) goes to the project store (default), a
   machine/environment property (a firewall, a cold runner) goes global; a
   pure tool/process rule belongs in the runner's `apply` template, in
   neither. Keep the active list short – move stale entries from `## Active`
   to `## Log` yourself; boss never trims.
   If the recorded dispatcher is dead or belongs to another workspace or
   project without the matching flag, run `boss retarget <change>` before the
   next wake; retarget changes only the apply, never the workspace registry;
   never hand-edit the state file.
   After `finish` the apply agent is gone: further work on the same change
   means a new `boss dispatch <change>` (not `retrigger`, which needs the old
   agent). A new dispatch starts a fresh run – the retrigger counter and the
   commit base (`base_head`) are reset. If the change belongs to a mission,
   call `boss mission next <slug> --project <p>` afterwards to start the next
   step (see Missions). Archiving is a separate decision: run
   `openspec archive <change>` in the target project when the change can be
   archived – that may be before or long after `finish`, e.g. when other
   changes still depend on its spec deltas. If only marked human tasks remain,
   do not `finish`: run `boss park <change> [--note "<what the human must
   do>"]` instead, journal the handoff, and call `boss mission next`.
8. **Blocked / interrupt** – if the completion message is `blocked`: `boss status
   <change>` shows the visible dialog of the apply pane. To stop a running
   apply deliberately, use `boss interrupt <change>` (runner-specific keys);
   the next wake is `interrupted`, not a completion. Decide yourself
   whether to answer (`boss answer <change> <key>…`, e.g. `enter`, `esc`,
   `y`) or to end the apply (`boss finish <change> --force`), journal the
   decision with `boss journal` and continue. Never wait for the human. You
   make the decision, not the apply agent.

#### Recommendations from research changes

A research or decision change writes `openspec/recommendations.md` with one row
per recommendation:

```markdown
| ID | Target | Decision | Note |
| --- | --- | --- | --- |
| R17 | export-tool | approved | adopt threshold 3 |
```

The user's decision is `approved` or `rejected`. `boss reconcile <slug> --json`
lists approved recommendations for the next change that have no
`recommendation-adopted` journal entry. Adopt one ID at a time and journal it:
`boss journal --tag recommendation-adopted --change <target> "R17 ..."`.

#### External review pass

External stations (a Mac build machine, a device lab) are batched into one
pass. Use `references/external-review.md`: pull, build, test, osv-scanner,
restore tracked files and report; the station must not modify the repository.
Record a green pass with `boss journal --tag external-pass --project <p>
"<result>"` and check the external tasks off. Attach a red log to
`boss resume <change> --note "<log>"` or the retrigger note. `boss mission
status` shows `external_open`/`external_tasks` while a change waits.

#### Skills from experience

A **skill** is a verified, reusable procedure that the next executer loads
through its own tool – not a paragraph in the apply prompt. Distinguish:

- a **short fact** that stays relevant (the path of the real data) goes to a
  store via `boss finish --lesson "<text>"`;
- a **procedure or trap** that recurs (a multi-step check with a pitfall) is
  written as a skill;
- a **pure runner/process rule** (commit before finishing) goes into the
  runner's `apply` template, in neither.

Only the **Explorer** writes or updates a skill, and only after the review
verified the lesson; the **Executer never writes skills**. If approval is
agreed for the project, the Explorer presents a new or changed skill to the
human before it becomes active – without approval it stays a proposal.

A skill follows the agentskills format: YAML frontmatter with `name` and
`description`, then a body with *When to Use*, *Procedure*, *Pitfalls* and
*Verification*. A pitfall is a general rule plus one sentence of reason – no
narration, no ticket numbers, no dates. Write the skill into both tools'
directories so it is found whatever the runner:

- **project skills** go in `<project>/.opencode/skills/<name>/SKILL.md` and
  `<project>/.claude/skills/<name>/SKILL.md`; they travel with the project
  repo;
- **machine/environment skills** (a firewall, a cold runner) go in the global
  skill directories of both tools.

`boss skills dir [--project <name|path>] [--json]` prints all of these paths.

#### Missions

A large task that breaks into several changes is planned as a **mission**: a
Markdown file in the target project (default `openspec/missions/<slug>.md`,
override with `[missions] dir`). The Explorer owns and writes it; the Executer
never sees the mission, only its one change. The file stores no status –
`boss mission status` derives it live from each change.

The doc has a **charter** – `## Goal`, `## Non-Goals`, `## Constraints`,
`## Authorization`, `## Stop Conditions`, `## Open Questions` – and the change
lists. `## Authorization` is a table (category -> `granted`/`denied`/`bounded`
plus a bound); `## Open Questions` is a `- [ ]`/`- [x]` checklist. Resolve every
question and authorization row *before* the run: `boss mission next` returns
`charter_open` and dispatches nothing while one is open. Questions that affect
the assignment belong here, not in a mid-run prompt.

- `boss mission start <slug> --project <p>` writes the charter skeleton and
  never overwrites an existing doc.
- `boss mission status <slug> --project <p>` shows the goal, the charter state,
  the planning/reconcile mode and every change with its derived state (`done`,
  `in_progress`, `waiting_human`, `change_not_ready`), its declared
  dependencies, and the backlog.
- `boss mission next <slug> --project <p>` gates on the charter, then starts
  the first startable change that is not `done`. It skips `waiting_human`
  changes and changes whose `after:` prerequisites are neither `done` nor
  allowed by `human-ok`. It returns `charter_open`, `mission_complete`,
  `waiting_human` (bundled handoff, not an error), `mission_blocked`,
  `executer_busy`, or `change_not_ready` naming the missing artifact
  (`proposal` vs `specs`/`tasks`).
- `boss park <change> [--note]` detaches a change whose only open tasks belong
  to a human: it closes the tab, releases the workspace, writes the handoff to
  the inbox and journal, and keeps the state and event log. `boss resume
  <change> [--note]` clears the park and starts a fresh dispatch when no apply
  is live. The handoff lists every open human task with its criterion.
- `boss mission add|rm <slug> <change>` append to / remove from `## Changes`;
  reordering, dependencies and the per-change runner stay a doc edit:
  `- data-pipeline (after: spike-api)`, for a prerequisite that may
  still wait for a human
  `- data-pipeline (after: spike-api; human-ok: spike-api)`,
  and with an explicit runner
  `- spike-api (runner: claude-opus)`. A bullet without `runner:` uses
  `default`; `boss mission status` shows the effective runner.

Human tasks are marked in `tasks.md` with `[Nutzer]` or `[human]` by default;
`[missions] human_markers` in `boss.toml` overrides the list. A change whose
only open tasks are human tasks is parked (variant A: no idle tab, no held
workspace), and a later `boss resume` or the human checking the tasks off makes
it selectable again.

**Planning mode** – `planning: planned | rolling | mixed` (default `planned`):
`planned` writes every proposal up front and specs/tasks lazily per change;
`rolling` plans only the next change and keeps the rest in `## Backlog`; `mixed`
combines a planned prefix with a rolling tail. Planning writes
all four artifacts up front, which is deeper than `planned`; keep the file's
mode at `planned` so the boss reads it normally.

**After every apply, reconcile before the next dispatch.** `reconcile: explore |
quick` (default `explore`). The mode `explore` is a self-contained explore pass:
re-read the result, actually read the affected code, question the remaining
proposals and compare options before sharpening them; `quick` is a mechanical
re-check. `boss reconcile <slug> --project <p> [--json]` assembles the context
read-only (charter, remaining changes, backlog, open inbox items, journal tail).
The pass asks no questions: a broken charter assumption becomes a
`[charter-assumption-broken]` journal entry and the conservative in-grant path.

The Explorer calls `boss mission next` after every `boss finish` of a mission
change. `change_not_ready` is the normal signal to create the missing artifacts
(plan first, lazy detail) and call `next` again. The judgement stays with the
Explorer: a `validate` that stays red, three retriggers without progress, or a
`change_not_ready` it does not want to fill are reasons to reorder the mission,
retrigger, or finish with a journal entry (see No stopping).

#### No stopping

During a run the Explorer never waits for the human. The former escalation
cases become deterministic fallbacks – decide, journal with `boss journal`,
continue:

- **Blocked executer** – read the visible dialog; accept a consent/permission
  dialog; otherwise choose the conservative, reversible option. On OpenCode V2
  a missing permission is not a tab-environment problem: check `boss doctor`
  and the effective config (`opencode debug config`), not
  `OPENCODE_CONFIG_CONTENT`. If no safe choice exists,
  `boss finish <change> --force`, journal the open question and turn the
  remaining tasks into a follow-up change.
- **No progress** – after `BOSS_MAX_RETRIGGERS` (default 3) retriggers without
  new tasks and without a plausible new diff, stop retriggering, `boss finish
  <change> --force`, carry the open tasks into a follow-up change and journal.
- **Only marked human tasks left** – `boss park <change> [--note "<what the
  human must do>"]`, journal the handoff, and continue with the changes that
  do not depend on it. Do not retrigger, do not `finish --force`, and do not
  report `mission_complete`. When `boss mission next` returns
  `waiting_human`, hand the bundled tasks and criteria to the human and end the
  mission.
- **Judgment question** – choose the smaller/reversible scope, journal it and
  continue.

A Herdr notification may still be sent for the human's later reading, but the
run does not wait for an answer. Questions that would change the assignment
are settled *before* the run, in the mission charter (`## Open Questions`,
`## Authorization`); planning them up front is the job of the planning phase.

#### The recommended path

Follow this fixed table instead of asking (review outcome -> one action):

| Review outcome | Action |
| --- | --- |
| only marked human tasks open, agent work plausible | `park`, journal the handoff, then `mission next`; a `waiting_human` result goes to the human |
| `tasks.open > 0` (unmarked), diff plausible | `retrigger` with the open tasks as note |
| `validate: fail` | fix proposal/specs with the openspec instructions, then `retrigger` |
| `tests.result: fail` | fix, then `retrigger` with the failing command |
| diff not plausible | read the diff, then `retrigger` with a note |
| green (open 0, validate pass, tests pass or not_run, diff plausible) | `finish` |
| archive | archive only when no later change depends on the spec deltas |
| anything uncertain | choose the smaller/reversible option and journal it |

#### Rules

- You never poll: no repeated `boss status` "to see whether it is done". The
  waiter reports back.
- Never dispatch first and offer a correction afterwards. A question that comes
  after the dispatch comes too late.
- Start every wake with `boss inbox` and, once per session, `boss wait --all`;
  the default scope is this project/workspace, and `--all-projects` is the
  explicit global pass. The durable inbox lets a later wake heal an earlier
  lost one.
- Forks and background sessions inherit `HERDR_PANE_ID`/`HERDR_WORKSPACE_ID`.
  Never trust them blindly: `boss claim`/`boss doctor` compare the pane's agent
  session with the caller session and fail with `caller_session_mismatch`. Use
  `--as` for an explicit repair and `boss retarget` for a running apply.
- The waiter follows the pane id. A lost agent name is not a lost apply; it
  checks `agent get`/`agent list` before reporting `lost`.
- `./install.sh` replaces runtime scripts atomically and leaves running waiters
  untouched. Do not kill them implicitly; a new dispatch starts a fresh waiter.
- `boss doctor --fix` removes dead registry entries; it never deletes an entry
  whose pane is alive but moved.
- You never work in the apply tab; `boss answer` is the only exception for
  deliberate answers to follow-up questions.
- JSON command results go to stdout; logs, warnings and errors go to stderr.
  Pipe stdout to `jq`, never combine the streams. `boss status` and
  `boss doctor` without `--json` are explicit text output.
- Multiple projects: planning always via `cd <project>` in the target
  project, `boss` commands via `--project <name|path>`.
- This skill uses direct CLI only. It never invokes another skill or a
  tool-specific slash command for planning, fixing, finishing or archiving.

### Autonomy policy A

During a run: **conservative, reversible, journaled, reported, no stop**.

- A new decision mid-run never pauses the run. Choose the smaller, reversible
  option; write the decision with

  ```bash
  boss journal --project <name|path> --change <change> --tag <tag> "<decision and reason>"
  ```

  and continue. Report it in the next wake's summary and at the end of the
  run.
- Actions ruled out by the charter are **never** taken, even when they are the
  only obvious path. Look for an in-grant alternative; if none exists, finish
  the change with `--force`, journal a `[charter-assumption-broken]` or
  `grant gap` entry, and carry the rest into a follow-up change.
- Authorization and stop conditions are decided before the run precisely
  so the run has no reason to ask. Broad grants still never include history
  rewrite, force-push or destructive data loss unless the charter explicitly
  grants them with a bound.
- The run ends only at `mission_complete`, at a `waiting_human` handoff, at a
  red line with no in-grant alternative, or after three reconciliation passes
  change nothing. Otherwise it continues without human input.
<!-- shared:run:end -->

## Guardrails

- Run one change at a time; an Executer gets exactly one change.
- Never dispatch before the change's artifacts are ready and validated.
- Do not stop a run for a mid-run question; journal and continue.
- Only marked human tasks left means `boss park`, never `finish --force`.
- The procedure uses only the `openspec` and `boss` CLIs; never load another
  skill or a tool-specific slash command.
