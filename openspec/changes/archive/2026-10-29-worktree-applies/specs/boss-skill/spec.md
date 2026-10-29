# Spec Delta

## ADDED Requirements

### Requirement: Worktree-aware run procedure

The boss skill SHALL describe the worktree lifecycle in its shared RUN
procedure: plan commit, isolated dispatch, worktree review, merge/test/cleanup
on finish and worktree reuse on resume. It SHALL NOT claim that every apply runs
in the project checkout.

#### Scenario: Shared block covers the worktree lifecycle

- **WHEN** the boss skill's shared RUN block is read
- **THEN** it describes plan commit, worktree dispatch and worktree-aware review

#### Scenario: Finish merges and cleans up

- **WHEN** the skill finishes a worktree apply
- **THEN** it merges into the base, tests the merged base and removes the
  worktree on success

#### Scenario: Drift test stays green

- **WHEN** the worktree steps are added to the shared RUN block
- **THEN** the boss and vision copies remain byte-identical and the drift test
  passes
