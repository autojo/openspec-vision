# Tasks

## 1. Reader

- [x] 1.1 Add a regression test that drives the real client with a child writing lines of 1 KiB, 60 KiB, 70 KiB, 300 KiB and one above the limit. Prüfen: the test fails on the current code for 70 KiB and 300 KiB and passes after 1.2.
- [x] 1.2 Start the child with an explicit line limit in the supervisor and in the doctor probe, configurable, default 64 MiB; skip and log longer lines. Prüfen: 1.1 is green, and a line above the limit is skipped with its size in the log.
- [x] 1.3 Guard the reader loop: every exit sets `closed`, fails open requests with `transport_lost` and runs the close handler once. Prüfen: a test injects an error into the reader and sees the failed future, the close handler and one wake.

## 2. Turn result and recovery

- [x] 2.1 Add `transport_lost` as a turn result with a reason in the apply state, the transcript, the wake text and `boss status`. Prüfen: regression test for state, wake text (once) and status output.
- [x] 2.2 Report child alive, reader alive, last activity and age in a stalled wake and in `boss status`; keep the stall interval. Prüfen: tests for "reader alive, quiet agent" and "reader gone".
- [x] 2.3 Accept a prompt after `transport_lost`: stop a child that still runs, resume the recorded session if offered, otherwise start a new one in the same worktree. Prüfen: test with a fake agent that resumes, one that cannot, and one whose child still runs; uncommitted files stay in the worktree; no `turn_active`.

## 3. Shutdown

- [x] 3.1 `finish` and `request_stop` cancel the open prompt first, close the child, tolerate a missing state file and end within one shared budget. Prüfen: regression test that finishes an apply with an unanswered prompt; no supervisor process, socket or heartbeat file is left, no traceback in the log.
- [x] 3.2 The turn timeout on a closed transport ends the supervisor without a crash. Prüfen: test with a child that exits before the timeout fires.

## 4. Doctor

- [x] 4.1 Warn about enabled memory plugins of an OpenCode runner, naming the plugin and the way to leave it out for this runner; change nothing. Prüfen: tests with and without a plugin in a temporary configuration.

## 5. Skills and documentation

- [x] 5.1 Write the evidence, coordination and reporting rules into the shared run block of `boss/SKILL.md` and `vision/SKILL.md`, byte-identical. Prüfen: repository test for the shared block is green, and it fails when one copy is edited alone.
- [x] 5.2 Update the procedure text for `transport_lost`, `retrigger` after a lost end and `finish`, remove the advice that `stalled` alone means the apply has failed. Prüfen: both skill files mention the new result and the recovery command.
- [x] 5.3 `boss review` shows the executed test count when the output contains one, and flags zero executed tests. Prüfen: regression test with a command that prints a count, one that prints zero and one without a count.
- [x] 5.4 README and CHANGELOG: line limit, `transport_lost`, doctor warning. Prüfen: every new setting is named with its default.

## 6. Verification

- [x] 6.1 Run the full regression suite and `openspec validate acp-turn-end-reliability --strict`. Prüfen: both are green.
- [ ] 6.2 [Nutzer] Install the runtime while no apply runs, then run one real OpenCode apply that edits a file above 100 KB. Prüfen: the boss is woken with `end_turn`, and no supervisor process is left after `boss finish`.
