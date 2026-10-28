# Design

## Context

See `proposal.md` for motivation. The current shape that matters:

- `dispatch_change` resolves the project, creates or reuses one Herdr
  workspace for the path, refuses a second executer in that workspace
  (`executer_busy`), creates a tab, starts the agent and writes one state file
  keyed by project path and change.
- `state_file_for`, `review_locate`, `mission_done_state` and `boss finish` all
  treat the project path as the place where the change lives and where git
  runs.
- `boss finish` warns about a dirty tree, closes the tab and removes the state;
  it does not merge.
- Herdr ships `worktree create|open|list|remove`; the runtime does not use it.
- Planning artifacts are usually uncommitted during PLAN and RUN, so a fresh
  `git worktree` would not contain the change.

## Goals / Non-Goals

**Goals:**

- One apply can run in an isolated worktree, with the plan committed first.
- The base checkout stays clean; state, status, review, park, resume, retrigger
  and finish find the apply from the base project.
- Finish merges, tests the merged base and cleans up; conflicts and red tests
  lose no work.
- Existing applies and `max_parallel = 1` behaviour keep working.

**Non-Goals:**

- More than one concurrent apply, slot limits, lock annotations and mission
  filling (follow-up `parallel-missions`).
- Sharing `node_modules`, virtualenvs or other ignored directories between
  worktrees.
- A new commit policy; the existing `explorer`/`agent` rules stay.

## Decisions

### D1: Plan commit before worktree dispatch

Add `boss plan commit <change> --project <name|path>`:

- Commits `openspec/vision.md`, `openspec/missions/` and `openspec/changes/`
  on the base branch. It never commits code or runtime files.
- Does nothing when those paths are clean (`status: clean`); otherwise returns
  the commit id and the committed paths.
- The message is `plan: <change> artifacts`.

Worktree dispatch requires:

1. the plan paths are committed (no `openspec/` entries in `git status`);
2. the rest of the tree is clean (`git status --porcelain` outside `openspec/`
   is empty). If not, dispatch fails with `base_dirty` and names the paths.

Alternatives: auto-commit inside `dispatch` (implicit, surprising) and a
symlink into the worktree (untracked link, split commit accounting). Committing
once keeps the worktree, the agent's commits and the merge ordinary git.

If a design update lands after dispatch, the Explorer commits it on the base
and brings the change dir into the worktree with
`git -C <worktree> checkout <base> -- openspec/changes/<change>` before
`boss retrigger`.

### D2: Worktree creation and configuration

`[missions] worktrees = "auto" | "always" | "never"` (default `auto`) plus
`--worktree` / `--no-worktree` on `dispatch` and `mission next`. In this change
`auto` does not create a worktree (the follow-up makes it follow
`max_parallel > 1`); `always` and `--worktree` do.

Creation uses Herdr's native command:

```text
herdr worktree create --cwd <base> --branch boss/<change> \
  --base <base head> --path <worktree path> --label <change> --no-focus
```

- Branch: `boss/<normalized-change>`.
- Path: `$BOSS_STATE_DIR/worktrees/<sha1(base)>/<normalized-change>`, outside
  the project tree. Inside the project tree would match
  `find_workspace_for_repo` (it accepts `startswith(project + "/")`) and share
  the base workspace, defeating isolation.
- Parse `.result.worktree.path`, `.result.worktree.branch` and the workspace id;
  fall back to `herdr worktree list --cwd <base>` when the create result does
  not carry them. A short implementation spike confirms the exact shape.
- Create a tab in that worktree workspace (`--cwd <worktree>`), start the agent
  as today and record pane/tab/workspace.
- On any failure, close the tab, remove the worktree and delete the branch
  before returning; never leave a half-created apply.

### D3: State identity stays the base project

The state file key remains base project + change. New fields:

```json
{
  "project": "<base>",
  "worktree": "<path>|null",
  "branch": "boss/<change>|null",
  "worktree_workspace": "<ws>|null",
  "base_head": "<commit>",
  "merge_state": "none|conflict|test_failed|done",
  "merged": false,
  "merge_test": "not_run|pass|fail",
  "kept": false
}
```

- `state_file_for`, `events_file_for` and `mission_done_state` keep working on
  the base.
- `find_running_apply` matches the agent name and the recorded worktree (or the
  base when no worktree); it must not use the base prefix for a worktree path.
- `review_locate` returns the worktree in addition to the project; old states
  without the field behave as before.
- The `project` value is used for mission/plan lookup; git and task commands use
  `worktree // project`.

### D4: Review and status read the worktree

- `boss review` uses the worktree for `git status`, commits, diff, tasks,
  `openspec validate` and the test command; the mission file stays in the base.
- `base_head` from the state is the review base.
- `boss status` (text and JSON) adds `worktree`, `branch`, `merge_state`,
  `merged` and `merge_test`; the tab/pane/workspace shown are the worktree's.
- No task or validate reads from the base while the apply is unmerged.

### D5: Finish merges, tests and cleans up

Normal path, in order:

1. Locate the state; refuse when the agent is still working (`agent_working`).
2. Under `explorer`, require a clean worktree (uncommitted changes mean the
   Explorer has not committed; refuse with `worktree_dirty`). Under `agent`,
   verify the commits.
3. Refuse when the base has uncommitted changes (`base_dirty`).
4. If the branch is already an ancestor of the base (`git merge-base
   --is-ancestor`), skip the merge and set `merged=true`.
5. Otherwise merge: `git -C <base> merge --ff-only <branch>` when the base is
   still at `base_head`, else `--no-ff --no-edit`. On conflict: `git merge
   --abort`, set `merge_state=conflict`, report `merge_conflict` with the
   conflicting paths, keep the tab/worktree/state.
6. Run the configured or detected test command in the base. `not_run` passes.
   A failure sets `merged=true`, `merge_state=test_failed`,
   `merge_test=fail`, reports `merge_test_failed` and keeps the state. The
   Explorer fixes on the base; a second `finish` sees `merged=true`, runs the
   test again and continues when green.
7. On green: record the finish event, close the tab, remove the worktree
   (`herdr worktree remove`), delete the branch, remove the state file.

`--keep-worktree` performs steps 1-7 but keeps the worktree and branch and the
state (with `kept=true`, `merge_state=done`) so the Explorer can inspect them; a
later `finish` cleans up. `--no-merge` closes the tab, keeps the worktree and
state, and records no finish event; the Explorer merges manually and calls
`finish` again.

Alternative: a separate `boss merge` command. Rejected for the normal path
because it doubles the number of state transitions; the flags keep the manual
path open.

### D6: Park, resume and retrigger reuse the worktree

- `park`: close the tab, release the workspace, keep the worktree and branch;
  the state stays parked. No merge.
- `resume`: clear the park and reuse the recorded worktree. If the workspace is
  gone, create a new workspace/tab for the worktree path (or `herdr worktree
  open`); start a fresh agent there. If the worktree path is missing, fail with
  `worktree_missing` instead of silently starting in the base.
- `retrigger`: continue the same agent/worktree. If the agent is gone,
  `dispatch_change` detects the recorded worktree and starts a new agent in it
  instead of creating a second worktree.
- Interrupt keeps the worktree.

### D7: Doctor and observability

`boss doctor` adds:

- git repository and worktree support (`git worktree list`, `herdr worktree
  list`);
- worktree states whose path is missing, and worktrees under the state root
  with no state;
- a dirty base, or a worktree apply whose change dir is not committed;
- `--fix` removes worktrees that belong to a finished/kept state and are merged;
  unmerged worktrees are only reported.

### D8: Tests

- Stub `herdr worktree create|open|list|remove` and create a real git worktree
  in a temporary repository, so tests exercise git itself.
- Cover: plan commit (commit, clean no-op, dirty code untouched); dirty base
  refusal; worktree dispatch and state; review from the worktree; clean merge;
  merge conflict; red integration test and retry; cleanup; `--keep-worktree`;
  park/resume/retrigger; legacy state; doctor findings.
- Keep the existing suite green; without `--worktree`/`always` the behaviour is
  unchanged.

## Risks / Trade-offs

- **Herdr worktree JSON shape is not documented locally** -> implementation
  spike plus a `herdr worktree list` fallback; the design does not depend on a
  specific key name.
- **Dependencies are per worktree** (`node_modules`, `.venv` are ignored) ->
  documented; `touches: deps` in the follow-up serialises installs where
  needed.
- **Base must be clean** -> explicit `base_dirty` error; the Explorer commits or
  stashes. This is stricter than today's serial finish, but a merge into a
  dirty base is worse.
- **Merge adds a test run** -> the test command is the existing configured or
  detected one; `not_run` passes and the doctor warns.
- **Parked worktrees consume disk** -> doctor reports them; park keeps them on
  purpose so no work is lost.
- **Merge history** -> `--ff-only` when possible, a merge commit otherwise; the
  Explorer can squash later if desired.
- **Legacy applies** -> no worktree fields means today's project-checkout
  behaviour; no state migration.

## Migration Plan

1. Ship with `worktrees = "auto"`; without `--worktree`/`always` nothing changes.
2. Run `boss plan commit <change>` before the first worktree dispatch.
3. Rollback: set `worktrees = "never"`; existing worktree applies can be
   finished/merged first, or removed with `boss doctor --fix` after review.

## Open Questions

None. The Herdr worktree JSON shape is an implementation spike with a documented
fallback, not a design decision.
