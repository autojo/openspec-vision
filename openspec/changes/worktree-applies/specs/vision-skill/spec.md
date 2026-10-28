# Spec Delta

## ADDED Requirements

### Requirement: Isolated run phase

The vision skill's RUN phase SHALL commit the plan before the first isolated
dispatch and SHALL use the worktree lifecycle for dispatch, review, finish and
resume. PLAN and P4 behaviour is unchanged by this capability.

#### Scenario: Plan commit before the first worktree

- **WHEN** the RUN phase starts an isolated apply
- **THEN** the plan is committed on the base branch first

#### Scenario: Worktree run

- **WHEN** a change runs in a worktree
- **THEN** the run reviews, merges, tests and cleans up through the worktree
  lifecycle

#### Scenario: Single change without a plan

- **WHEN** the vision skill runs a single change without planning
- **THEN** it may use the same worktree lifecycle without requiring a mission
