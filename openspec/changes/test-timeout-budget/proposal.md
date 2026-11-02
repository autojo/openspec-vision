# Proposal

## Why

`boss finish` and `boss review` run the project's test command behind a
hardcoded 300-second deadline. A suite that legitimately needs longer is killed
and reported as a red test: the merged base is marked `test_failed`, the error
says the tests failed, and the only workaround is a per-call
`BOSS_REVIEW_TEST_TIMEOUT_S`. Long suites on slow hardware therefore look broken
even when they are green, and the Explorer has to re-run them by hand.

## What Changes

- Add a per-project test gate table: `[tests.<project>]` with `command` and
  `timeout_s`. The existing string form (`[tests] name = "cmd"`) stays valid and
  uses the default budget.
- Resolve the budget as: explicit `BOSS_REVIEW_TEST_TIMEOUT_S` >
  `[tests.<project>].timeout_s` > 300 seconds.
- Make a deadline a distinct outcome. The deadline helper returns a dedicated
  timeout code, review reports `timeout` instead of `fail`, and finish records
  `merge_state = "test_timeout"` with `merge_test = "timeout"` and the error
  `merge_test_timeout`.
- Keep the worktree and state on a timeout, exactly as for a red test, so a
  retry with a larger budget re-runs only the test and does not merge again.
- Capture the test output to a log for review and finish, and record the log
  path, a short tail, and the test timestamp in the apply state.
- Count `test_timeout` as an unfinished apply for the concurrency limit and show
  it distinctly in `boss status`.
- Harden the deadline helper: normalize the timeout exit code in the GNU and
  fallback paths and terminate the whole process group so test workers do not
  survive a timeout.
- Cover the configuration forms, precedence, timeout classification, retry and
  log capture in the regression suite; update the README, the skills and the
  `boss-worktrees` spec.

## Capabilities

### New Capabilities

- `test-gate`: the review and finish test gate, including per-project command
  and budget configuration, deadline handling, result classification, output
  capture and the timeout state.

### Modified Capabilities

- `boss-worktrees`: finish distinguishes a test timeout from a red test and
  keeps the worktree and state for a retry with a larger budget.

## Impact

- Runtime: `boss-lib.sh` (deadline, timeout resolution), `boss-review.sh`
  (config and result), `boss-run.sh` (finish state and error), `boss-status.sh`
  (state display) and `boss-lib.sh` `open_apply_count`.
- Configuration: optional `[tests.<project>]` tables; existing string entries
  and existing runner/project entries are unchanged.
- Apply state: new `merge_test_at` and `merge_test_output` fields and the
  `merge_state = "test_timeout"` value. Old states remain readable and a
  `test_failed` state stays retryable.
- Tests and docs: `tests/run.sh`, README, boss/vision skill text and the
  `boss-worktrees` delta spec.
- Out of scope: a detached/asynchronous finish, a global timeout default, and
  changes to test-command detection itself.
