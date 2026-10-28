# Tasks

## 1. Plan commit and worktree mode

- [x] 1.1 Add `boss plan commit <change> --project <name|path>`: commit
  `openspec/vision.md`, `openspec/missions/` and `openspec/changes/` with the
  message `plan: <change> artifacts`, return `clean` when nothing is staged,
  and never touch code paths; verify commit, no-op and dirty-code cases in
  `tests/run.sh`
- [x] 1.2 Add `[missions] worktrees = "auto"|"always"|"never"` (default `auto`)
  and `--worktree`/`--no-worktree` on `dispatch` and `mission next`, plus the
  help text; verify flag and config resolution in the runtime tests
- [x] 1.3 Require a committed plan and a clean base for worktree dispatch;
  return `plan_uncommitted` and `base_dirty` with the offending paths; verify
  both errors and the clean success case
- [x] 1.4 Document the plan commit and the worktree mode in `README.md`; verify
  every documented command runs as written against a temp repo

## 2. Worktree creation and state

- [x] 2.1 Wrap `herdr worktree create|open|list|remove` in the runtime, add a
  Herdr stub, and fall back to `herdr worktree list` when the create result
  lacks path/branch; verify the parsed path, branch and workspace
- [x] 2.2 Create the worktree at
  `$BOSS_STATE_DIR/worktrees/<sha1(base)>/<change>` on branch `boss/<change>`,
  outside the project tree; verify the path, branch and base commit, and that a
  failed create leaves no tab, state or branch
- [x] 2.3 Add `worktree`, `branch`, `worktree_workspace`, `merge_state`,
  `merged`, `merge_test` and `kept` to the state; make `find_running_apply`,
  `review_locate` and `state_file_for` worktree-aware while keeping the base
  key; verify a legacy state without the fields behaves as today
- [x] 2.4 Dispatch into the worktree workspace: create the tab with the
  worktree cwd, start the agent there and record pane/tab/workspace; verify the
  base checkout stays unchanged and `boss status --project <base>` finds the
  apply
- [x] 2.5 Document worktree path, branch and workspace in `README.md`; verify
  the paths named there match a real dispatch

## 3. Review, finish, park and doctor

- [x] 3.1 Make `boss review` and `boss status` read git, tasks, validate and
  tests from the worktree and show `worktree`, `branch`, `merge_state`,
  `merged` and `merge_test`; verify a review of a worktree apply reports the
  worktree diff and leaves the base untouched
- [x] 3.2 Implement the finish merge: `--ff-only` at `base_head`, else
  `--no-ff --no-edit`; on conflict `git merge --abort`, keep worktree and state
  and report `merge_conflict` with paths; verify clean merge and conflict cases
- [x] 3.3 Run the configured or detected test command on the merged base; on
  red keep the state with `merge_state=test_failed` and `merged=true`; verify a
  second finish reruns the test and completes on green
- [x] 3.4 Clean up on green: close the tab, remove the worktree, delete the
  branch and the state; verify `--keep-worktree` and `--no-merge` preserve what
  they name
- [x] 3.5 Make park keep the worktree, and resume/retrigger reuse the same
  worktree and branch; verify a missing worktree fails with
  `worktree_missing` instead of falling back to the base
- [x] 3.6 Extend `boss doctor` with worktree support, orphaned worktrees, a
  dirty base and an uncommitted plan; verify findings and that `--fix` only
  removes merged worktrees with a finished/kept state
- [x] 3.7 Document finish, merge, park, resume and cleanup in `README.md`;
  verify the documented commands against a temp repo

## 4. Skill and integration

- [x] 4.1 Update the shared RUN block in `vision/SKILL.md` with plan commit,
  worktree review, finish merge/test/cleanup and resume reuse, then sync
  `boss/SKILL.md`; verify the drift test and a read-through of both skills
- [x] 4.2 Run `./tests/run.sh` completely and `openspec validate
  worktree-applies --strict`; verify zero failures
- [x] 4.3 Run `./install.sh` and a worktree smoke scenario in a temp repository
  (plan commit, dispatch, review, merge, cleanup); verify both skills install
  and the worktree is removed after finish

## Workflow follow-up

- Archive the change after the project's review requirements are satisfied.
