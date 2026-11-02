# Spec Delta

## Purpose

Run a project's review and finish tests with a per-project budget, distinguish a
timeout from a red test, and keep the output so a long suite is diagnosable
instead of being reported as broken.

## ADDED Requirements

### Requirement: Project test configuration

The runtime SHALL read a project's test gate from `[tests.<project>]` with
`command` and `timeout_s`, and SHALL accept the legacy
`[tests] <project> = "<command>"` string as a command with the default budget.
A missing command SHALL fall back to the detected test command.

#### Scenario: Table form

- **WHEN** a project table defines a command and a timeout
- **THEN** review and finish use both values

#### Scenario: Legacy string

- **WHEN** only the legacy string is configured
- **THEN** the command runs with the default budget

#### Scenario: Timeout without command

- **WHEN** the table defines `timeout_s` but no command
- **THEN** the detected test command runs with that budget

### Requirement: Timeout resolution

An explicitly set `BOSS_REVIEW_TEST_TIMEOUT_S` SHALL win; otherwise the
project's `timeout_s`; otherwise 300 seconds. A configured timeout SHALL be a
positive integer, and an invalid value SHALL fail with a clear error naming the
project.

#### Scenario: Explicit environment

- **WHEN** `BOSS_REVIEW_TEST_TIMEOUT_S` is set and the project has a budget
- **THEN** the environment value is used

#### Scenario: Project budget

- **WHEN** no environment value is set and the project defines `timeout_s`
- **THEN** the project value is used

#### Scenario: Default budget

- **WHEN** neither is set
- **THEN** the budget is 300 seconds

#### Scenario: Invalid budget

- **WHEN** `timeout_s` is zero, negative or not a number
- **THEN** the configuration is rejected with an error naming the project

### Requirement: Deadline outcome

The deadline helper SHALL return a dedicated timeout status (`124`) when the
command exceeds its budget, in both the GNU `timeout` path and the fallback, and
SHALL terminate the command's process group so child workers do not survive.

#### Scenario: GNU timeout

- **WHEN** a command runs past its budget and GNU `timeout` is available
- **THEN** the helper returns `124` and leaves no child process behind

#### Scenario: Fallback path

- **WHEN** the platform has no `timeout` or `gtimeout`
- **THEN** the fallback returns `124` and leaves no child process behind

#### Scenario: Early failure

- **WHEN** the command exits non-zero before its budget
- **THEN** the helper returns that exit status, not `124`

### Requirement: Review result

Review SHALL classify the test gate as `pass`, `fail`, `timeout` or `not_run`,
SHALL NOT report a timeout as `fail`, and SHALL include the budget and the test
log path in its result.

#### Scenario: Long test times out

- **WHEN** the review test exceeds its budget
- **THEN** `test_result` is `timeout` and the budget and log path are reported

#### Scenario: Red test

- **WHEN** the review test exits non-zero before its budget
- **THEN** `test_result` is `fail`

#### Scenario: Command unavailable

- **WHEN** the configured command is not on `PATH`
- **THEN** `test_result` is `not_run`

### Requirement: Finish timeout

When the merged-base test exceeds its budget, finish SHALL keep the worktree and
state, record `merge_state = test_timeout`, `merge_test = timeout`,
`merge_test_at` and `merge_test_output`, and report `merge_test_timeout` with
the budget and log path. A retry with a larger budget SHALL re-run only the test
and SHALL not merge again.

#### Scenario: Timeout keeps the apply

- **WHEN** the merged-base test exceeds its budget
- **THEN** the state records `test_timeout` and the command reports
  `merge_test_timeout`

#### Scenario: Retry with a larger budget

- **WHEN** finish runs again after the budget was raised and the test passes
- **THEN** no second merge happens and the apply is finished and cleaned up

#### Scenario: Red test stays red

- **WHEN** the merged-base test exits non-zero before its budget
- **THEN** the state records `test_failed` and the command reports
  `merge_test_failed`

### Requirement: Test output capture

Review and finish SHALL write the test output to a log file and SHALL expose its
path; on a timeout or failure the apply state SHALL retain the path and a short
tail in `merge_test_output`.

#### Scenario: Log on timeout

- **WHEN** a test times out
- **THEN** the log exists, the state records its path and a short tail

#### Scenario: Log on success

- **WHEN** a test passes
- **THEN** the log exists and the result names it

#### Scenario: Empty output

- **WHEN** a command produces no output
- **THEN** the log still exists and the state remains valid

### Requirement: Slots and status

`open_apply_count` SHALL count an apply in `merge_state = test_timeout` as
unfinished, and `boss status` SHALL show the timeout separately from a red test.

#### Scenario: Timeout consumes a slot

- **WHEN** an apply is in `test_timeout` and the limit is reached
- **THEN** the next dispatch is refused

#### Scenario: Status names the timeout

- **WHEN** `boss status` reads a timed-out apply
- **THEN** it shows `test_timeout` and `test: timeout`
