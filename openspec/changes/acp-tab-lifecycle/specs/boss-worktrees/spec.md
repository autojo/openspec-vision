# Spec Delta

## MODIFIED Requirements

### Requirement: Finish cleanup

A successful finish SHALL close every tab belonging to the apply's worktree
workspace and remove the worktree and branch. `--keep-worktree` or `--no-merge`
SHALL preserve them for a manual path.

#### Scenario: Cleanup after merge

- **WHEN** finish completes successfully
- **THEN** every apply tab in the worktree workspace is closed, the worktree is
  removed, the branch is deleted and the state file is gone

#### Scenario: Stale tab from an earlier dispatch

- **WHEN** the worktree contains a tab whose id is no longer the recorded state
  tab
- **THEN** finish closes it with the rest of the worktree workspace

#### Scenario: Keep worktree

- **WHEN** `--keep-worktree` or `--no-merge` is given
- **THEN** the worktree and branch stay and the command names them

## ADDED Requirements

### Requirement: Apply tab lifecycle

The runtime SHALL keep at most one apply tab per change and worktree. A dispatch
or retrigger that reuses an existing worktree SHALL reuse the recorded tab if it
is alive and close it before creating a new one otherwise. `boss doctor --fix`
SHALL close orphaned apply tabs for the worktrees and states it repairs.

#### Scenario: Retry keeps one tab

- **WHEN** a change is retriggered in an existing worktree
- **THEN** the runtime reuses the live apply tab or replaces the stale one, and
  at most one tab remains for that change

#### Scenario: Orphan tab cleanup

- **WHEN** `boss doctor --fix` finds an orphaned apply tab for a worktree
- **THEN** it closes the tab and reports what it closed

#### Scenario: Base workspace untouched

- **WHEN** the runtime closes apply tabs
- **THEN** it does not close tabs in the base project workspace that do not
  belong to the apply
