# Proposal

## Why

Every apply currently runs in the project checkout, and `boss` deliberately
allows only one executer per Herdr workspace because two changes would share the
same working tree. `boss finish` only closes the tab: it neither merges nor
cleans up a worktree. That blocks isolated work and makes any later parallelism
impossible. Herdr already ships native worktree support; the missing part is a
worktree-aware apply lifecycle in the boss runtime.

## What Changes

- **Plan commit before dispatch.** The run commits the planning artifacts
  (`openspec/vision.md`, the mission file and `openspec/changes/`) to the base
  branch before the first worktree apply, so a worktree checkout contains the
  change. A dirty code tree is reported and blocks worktree dispatch.
- **Worktree dispatch.** `boss dispatch` and `boss mission next` accept
  `--worktree` (and the config chooses the mode). The apply runs in a git
  worktree outside the project tree, on branch `boss/<change>`, in its own
  Herdr workspace, started through `herdr worktree create`.
- **State identity.** The apply state stays keyed by base project + change; new
  fields record the worktree path, branch, worktree workspace and base commit.
  Running-apply lookup, `status`, `review`, `retrigger`, `park` and `resume` are
  worktree-aware.
- **Review in the worktree.** `boss review` reads tasks, validate, tests and the
  git diff from the worktree; the mission order and the plan stay in the base.
- **Finish merges and cleans up.** After a green review, `boss finish` merges the
  worktree branch into the base, runs the project's test command on the merged
  base, then closes the tab and removes the worktree and branch. A merge
  conflict aborts the merge and keeps the worktree and state; a red integration
  test keeps the state and reports `merge_test_failed`. `--keep-worktree` and
  `--no-merge` preserve the manual path.
- **Park and resume keep the worktree.** Parking closes the agent but keeps the
  worktree for a later resume; a resumed apply reuses the same worktree and
  branch. Retrigger continues in the same worktree.
- **Doctor and observability.** `boss status` shows worktree, branch and merge
  state; `boss doctor` reports orphaned worktrees, a dirty base and a missing
  plan commit.
- **Skill documentation.** The shared RUN procedure in `vision/SKILL.md` and
  `boss/SKILL.md` gains the plan-commit, worktree-review and merge steps; the
  drift test keeps both copies equal.

Out of scope: more than one concurrent apply, `max_parallel`, lock annotations,
mission slot filling and the P4 lock policy. Those belong to the follow-up
change `parallel-missions`. Default behaviour remains one apply at a time;
worktrees are opt-in through `--worktree` or config.

## Capabilities

### New Capabilities

- `boss-worktrees`: isolated worktree-backed applies: plan commit, worktree
  creation and state, worktree-aware review, merge/test/cleanup on finish, and
  park/resume/retrigger reuse.

### Modified Capabilities

- `boss-skill`: the standalone run procedure dispatches, reviews and finishes
  in worktrees when the run is configured for isolation.
- `vision-skill`: the run phase uses the same worktree lifecycle and the plan
  commit before the first isolated dispatch.

## Impact

- `runtime/bin/boss` and `runtime/bin/boss-lib.sh`: dispatch, state, review,
  finish, park/resume, doctor and worktree helpers.
- `vision/SKILL.md` and `boss/SKILL.md`: shared RUN procedure, finish and review
  steps (drift test).
- `tests/run.sh`: Herdr worktree stubs, git worktree scenarios, merge and
  conflict tests, park/resume.
- `README.md`: worktree mode, plan commit, merge and cleanup.
- No runtime dependency changes; no config/state migration for existing applies
  (an apply without worktree fields keeps today's behaviour).
