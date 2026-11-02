# Tasks

## 1. Test gate configuration

- [ ] 1.1 Extend `config_test_command` to accept both the legacy
      `[tests] <project> = "<command>"` string and a `[tests.<project>]` table
      with a `command` field, and fall back to detection when the table omits
      the command. Verify with config fixtures for string, table and
      timeout-only forms.
- [ ] 1.2 Add `config_test_timeout` with the precedence explicit
      `BOSS_REVIEW_TEST_TIMEOUT_S` > `[tests.<project>].timeout_s` > 300, and
      reject zero, negative or non-numeric values with an error naming the
      project. Verify the four precedence cases and the invalid value.
- [ ] 1.3 Document the table form, the legacy form and the precedence in
      `README.md`, including a slow-project example. Verify the documented
      snippet parses with the runtime's config reader.

## 2. Deadline helper

- [ ] 2.1 Make `run_with_deadline` return `124` on a deadline in the GNU
      `timeout` path and keep a non-zero early exit distinct. Verify with a
      `sleep` past a one-second budget and a command that exits `1` before the
      budget.
- [ ] 2.2 Replace the no-`timeout` fallback with a process-group watchdog
      (Python, `start_new_session`, TERM then KILL) that returns `124` and
      leaves no child behind. Verify with a PATH that hides `timeout`/
      `gtimeout` and a command that spawns a child; assert the child is gone.
      The macOS CI job exercises the same path.

## 3. Review and finish outcomes

- [ ] 3.1 Make `boss review` use the resolved command and budget, capture the
      test output to a log, and report `test_result` as `pass`, `fail`,
      `timeout` or `not_run` plus the budget and log path. Verify each outcome
      with short fake commands.
- [ ] 3.2 Make both finish paths (worktree and base checkout) use the resolved
      budget. On a timeout, record `merge_state = test_timeout`,
      `merge_test = test_timeout`, `merge_test_at` and `merge_test_output`,
      return `merge_test_timeout`, and keep the worktree and state; on a red
      test keep `test_failed`/`merge_test_failed`. Verify both branches.
- [ ] 3.3 Store the log path and a bounded tail in `merge_test_output` and
      expose the path from review and finish. Verify a timeout log exists, the
      tail is bounded, and an empty-output command still leaves a valid state.
- [ ] 3.4 Treat `merge_state = test_timeout` as unfinished in
      `open_apply_count` and show it distinctly in `boss status`. Verify a slot
      refusal with a timed-out apply and the status text `test: timeout`.
- [ ] 3.5 Verify the retry path after a timeout: a second finish with a larger
      budget skips the merge, reruns only the test, finishes on success and
      cleans up the worktree and state.

## 4. Integration and documentation

- [ ] 4.1 Add an end-to-end regression in `tests/run.sh`: a slow test times
      out, the state says `test_timeout`, a retry with a larger budget passes
      and cleans up, and the log is present. Verify the full suite passes.
- [ ] 4.2 Update the boss/vision skill text where it describes finish testing,
      keep the shared RUN block byte-identical, and document the timeout state,
      error code and retry in `README.md`. Verify the drift test and the
      documented commands.
- [ ] 4.3 Run `./tests/run.sh`, `shellcheck`, `bash -n`, the runtime manifest,
      the wrapper drift check and `openspec validate --all --strict`. Verify all
      commands exit zero, and exercise the fallback on macOS CI.

## Workflow follow-up

- Archive the change after review and a green full suite.
- Sync `test-gate` into the main specs and verify
  `openspec validate --all --strict`.
