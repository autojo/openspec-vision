# boss-worktrees Specification

## Purpose
Run each apply in an isolated git worktree with a committed plan, worktree-aware
review, a merge back into the base and deterministic cleanup, so the base
checkout stays clean and an apply can be resumed or retried without touching it.

## Requirements

### Requirement: Plan commit before worktree dispatch

The run SHALL commit the planning artifacts to the base branch before the first
worktree apply, and the worktree SHALL start from that commit. A dirty code tree
SHALL block worktree dispatch.

#### Scenario: Plan committed

- **WHEN** a worktree apply is about to start
- **THEN** `openspec/vision.md`, the mission file and `openspec/changes/` are
  committed on the base branch first

#### Scenario: Worktree contains the change

- **WHEN** the worktree is created from the plan commit
- **THEN** `openspec/changes/<change>/` is present as a tracked directory

#### Scenario: Dirty code tree blocked

- **WHEN** the base has uncommitted changes outside `openspec/`
- **THEN** worktree dispatch is refused and names the dirty paths

### Requirement: Isolated worktree apply

A worktree apply SHALL run in a git worktree outside the project tree, on branch
`boss/<change>`, in its own Herdr workspace; the base checkout SHALL remain
unchanged.

#### Scenario: Worktree outside the project

- **WHEN** the worktree is created
- **THEN** its path is outside the base project tree and the branch is
  `boss/<change>`

#### Scenario: Base checkout unchanged

- **WHEN** the apply edits and tests code
- **THEN** the base checkout has no modified files from that apply

#### Scenario: Creation failure cleaned up

- **WHEN** worktree creation or agent start fails
- **THEN** no tab, state file or half-created worktree is left behind

### Requirement: Worktree-aware apply state

The apply state SHALL remain keyed by base project and change and SHALL record
the worktree path, branch, workspace and base commit; status, review, retrigger,
park and resume SHALL locate the apply from the base project.

#### Scenario: Status from the base project

- **WHEN** the user runs `boss status <change> --project <base>`
- **THEN** it finds the apply and shows the worktree and branch

#### Scenario: Mission lookup

- **WHEN** mission status or the next-change selection runs on the base
- **THEN** it sees the worktree apply under the change's base key

#### Scenario: Legacy apply without worktree fields

- **WHEN** an apply state predates the worktree fields
- **THEN** it keeps today's project-checkout behaviour

### Requirement: Review reads the worktree

Review SHALL read tasks, validation, the test result and the git diff from the
worktree, while the mission order and the plan remain in the base project.

#### Scenario: Diff from the worktree

- **WHEN** the Explorer reviews a worktree apply
- **THEN** the changed files and commits come from the worktree, not the base

#### Scenario: Tasks and validation from the worktree

- **WHEN** the review counts tasks or validates the change
- **THEN** it uses the worktree copy of the change

#### Scenario: Base mission unaffected

- **WHEN** the worktree is reviewed
- **THEN** the mission file and the base checkout are not modified by the review

### Requirement: Finish merges and tests

On a green review, finish SHALL merge the worktree branch into the base, run the
project's test command on the merged base and finish only when the test passes.
A conflict or a red test SHALL keep the worktree and state and report it.

#### Scenario: Clean merge

- **WHEN** the worktree is committed and the base is clean
- **THEN** the branch is merged into the base and the change is finished

#### Scenario: Merge conflict

- **WHEN** the merge conflicts
- **THEN** the merge is aborted, the worktree and state remain and the command
  reports `merge_conflict` with the conflicting paths

#### Scenario: Red integration test

- **WHEN** the project test fails on the merged base
- **THEN** the state remains, the result reports `merge_test_failed` and the
  Explorer fixes on the base or retriggers

### Requirement: Finish cleanup

A successful finish SHALL close the tab and remove the worktree and branch.
`--keep-worktree` or `--no-merge` SHALL preserve them for a manual path.

#### Scenario: Cleanup after merge

- **WHEN** finish completes successfully
- **THEN** the tab is closed, the worktree is removed, the branch is deleted and
  the state file is gone

#### Scenario: Keep worktree

- **WHEN** `--keep-worktree` or `--no-merge` is given
- **THEN** the worktree and branch stay and the command names them

### Requirement: Park and resume reuse the worktree

Park SHALL close the agent and keep the worktree; resume and retrigger SHALL
reuse the same worktree and branch.

#### Scenario: Park keeps the worktree

- **WHEN** a change is parked
- **THEN** its worktree and branch remain for the later resume

#### Scenario: Resume reuses the worktree

- **WHEN** a parked change is resumed
- **THEN** the new agent runs in the existing worktree and branch

#### Scenario: Retrigger stays in place

- **WHEN** a worktree apply is retriggered
- **THEN** the same agent and worktree continue

### Requirement: Worktree observability

`boss status` SHALL show worktree, branch and merge state; `boss doctor` SHALL
report orphaned worktrees, a dirty base and a missing plan commit.

#### Scenario: Status fields

- **WHEN** a worktree apply is running or parked
- **THEN** status shows its worktree, branch and merge state

#### Scenario: Doctor findings

- **WHEN** a worktree has no apply state or the base is dirty
- **THEN** `boss doctor` reports the worktree or the dirty paths
