# Spec Delta

## MODIFIED Requirements

### Requirement: Finish merges and tests

On a green review, finish SHALL merge the worktree branch into the base, run the
project's test command on the merged base and finish only when the test passes.
A conflict, a red test, or a test that exceeds the configured budget SHALL keep
the worktree and state and report the cause. A timeout SHALL be reported as
`merge_test_timeout`, not as a red test.

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

#### Scenario: Test timeout

- **WHEN** the project test does not finish within the configured budget
- **THEN** the state remains, `merge_state` is `test_timeout`, the result
  reports `merge_test_timeout` and the Explorer raises the budget and retries
