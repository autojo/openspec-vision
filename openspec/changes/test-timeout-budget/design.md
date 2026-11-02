# Design

## Context

`boss review` and `boss finish` share one test gate. The command comes from the
per-project `[tests]` override or from detection; the budget is the single
global `BOSS_REVIEW_TEST_TIMEOUT_S` (default 300, `boss-lib.sh`). Both call
`run_with_deadline` and collapse every non-zero exit into `fail`
(`boss-review.sh`, `boss-run.sh`). The output is redirected to `/dev/null`, and
the apply state has no `merge_test_at` or `merge_test_output` field, so a
timeout leaves no evidence.

The observed failure is exactly this shape: a suite that needs about 740
seconds is killed at 300, marked `test_failed`, and reported as a red test even
though a manual run on the merged base is green. The only workaround is a
per-call environment variable.

## Goals / Non-Goals

**Goals**

- A persistent, per-project test budget.
- A timeout that is reported as a timeout, not as a red test.
- A test log that explains a timeout or a failure without rerunning the suite.
- A retry that reruns only the test after a timeout.
- No behavior change for projects that keep the default budget.

**Non-Goals**

- A detached or asynchronous finish.
- A global timeout default beyond the existing environment variable.
- Changing how the test command is detected.
- Sandboxing the test process; it still runs with the user's rights.

## Decisions

### 1. A structured test gate with a legacy string

```toml
[tests.<project>]
command = "nice -n 10 taskset -c 0-2 npx vitest run"
timeout_s = 1800
```

`[tests.<project>]` is a table; `command` is optional, `timeout_s` is optional.
The legacy `[tests] <project> = "<command>"` form stays valid and means "this
command, default budget". If the table has no `command`, the detected command is
used with the configured budget.

*Why:* command and budget belong to the same project and should be read
together. The table can grow (`env`, `cwd`, retries) without inventing another
map. The legacy string keeps existing configurations working.

*Alternatives rejected:* a separate `[test_timeouts]` map (two places for one
concept, but no room to grow); a `"1800: command"` prefix (fragile parsing).

### 2. Budget precedence and explicit environment detection

Precedence:

1. `BOSS_REVIEW_TEST_TIMEOUT_S`, when it was explicitly set.
2. `[tests.<project>].timeout_s`.
3. 300 seconds.

The library records whether the variable was present before applying the
default, so an exported value wins over the project table, while the fallback
default does not.

*Why:* the environment is the ad-hoc override for a single run; the project
table is the persistent value; the default is the hang guard. A configured value
must be a positive integer and an invalid value fails with the project name.

### 3. A dedicated deadline status and process-group kill

`run_with_deadline` returns `124` on a deadline in both paths:

- GNU `timeout` with `--kill-after` (the timeout status is `124`).
- The no-`timeout` fallback, which starts the command in a new session and
  kills the process group with TERM, then KILL after a grace period.

The fallback currently kills only the direct PID, so `npx vitest` workers can
survive. Python 3.11 is already a hard prerequisite, so the fallback can use a
small `subprocess` watchdog with `start_new_session=True` and `killpg`.

*Why:* a timeout must be distinguishable from a red test, and a killed suite
must not leave workers that starve the next run.

*Trade-off:* the fallback now depends on `python3`; that is already required by
the runtime and the installer.

### 4. Results and state are distinct

Review result values: `pass`, `fail`, `timeout`, `not_run`.
Finish state: `merge_test` is `pass`, `fail`, `timeout` or `not_run`;
`merge_state` adds `test_timeout` next to `test_failed` and `conflict`.

```
finish -> merge -> test gate
                     | pass     -> merge_state=done, cleanup
                     | fail     -> merge_state=test_failed, merge_test=fail
                     | timeout  -> merge_state=test_timeout, merge_test=timeout
                     | not_run  -> done (as today)
```

On a timeout, finish keeps the worktree and state and returns
`merge_test_timeout` with the budget and log path. On a red test it keeps them
and returns `merge_test_failed`. On a retry, `merged=true` skips the merge and
only the test runs; a pass cleans up.

*Why:* the Explorer must be able to decide "raise the budget" rather than "fix
the code". A distinct state also keeps scripts and status honest.

### 5. Test output is captured

Every review or finish test writes to a log under `BOSS_LOGS_DIR` (per change,
per run). The review result names the log. Finish records `merge_test_at` and
`merge_test_output` as `{path, tail}` with a short tail (for example the last 40
lines); the error message names the path.

*Why:* a timeout with no output is not diagnosable, and a stored tail is enough
to see whether the suite was progressing or hung at startup.

*Trade-off:* a log per run needs retention; the state stores a path and a
bounded tail, not the whole output.

### 6. Slots and status follow the state

`open_apply_count` treats `test_timeout` like `test_failed` and `conflict`: the
apply is unfinished and consumes a slot. `boss status` already prints
`merge: <state> (merged: <bool>, test: <result>)`, so `test_timeout`/`timeout`
becomes visible without a new UI.

### 7. Tests exercise the gate, not a real suite

The regression suite uses short commands (`sleep`, `exit 1`, a command that
prints a line) with `timeout_s` values of a few seconds:

- both config forms and the precedence;
- `124` from the GNU path and from the fallback (PATH without `timeout`);
- review `pass`/`fail`/`timeout`/`not_run`;
- finish `test_timeout`, the retry with a larger budget, and cleanup;
- the log file and the stored tail;
- `open_apply_count` with a `test_timeout` state;
- the macOS CI job exercises the fallback naturally.

## Risks / Trade-offs

- **A high budget delays hang detection** -> keep the 300-second default; make
  the budget per project and document that it is a budget, not a liveness
  check.
- **Log growth** -> one log per run, bounded tail in the state, path only;
  retention stays manual like the waiter logs.
- **Mixed TOML types** -> support string and table explicitly and test both;
  document that a table needs the new runtime.
- **Rollback** -> an older runtime sees a table as an unparseable command and
  reports `not_run`; rollback means restoring the legacy string form for the
  affected projects.
- **Environment precedence** -> record whether the variable was explicit and
  test it; otherwise a project table would silently override an ad-hoc run.
- **Fallback process-group kill** -> use `start_new_session` and `killpg`; test
  that a child does not survive. The GNU path keeps its built-in group kill.
- **Outer shell timeouts** -> document that the per-project budget makes an
  outer `timeout` unnecessary; an outer timeout shorter than the suite is still
  a user error.
- **Slower suite under nice/taskset** -> the budget must account for the
  resource shaping; the example uses a generous value.

## Migration Plan

1. Add the new resolver and deadline behavior; existing string configs and the
   300-second default keep working.
2. Move slow projects to `[tests.<project>]` with an explicit budget.
3. Install the updated runtime; no state migration is needed. Existing
   `test_failed` states remain retryable and are re-evaluated on the next
   `boss finish`.
4. Rollback: remove the table for the affected project and restore the string
   form before running an older runtime.

## Open Questions

- Whether `boss finish` should eventually detach the test phase and wake the
  Explorer instead of blocking for the suite duration. That is a separate
  state-machine change and is not required for the budget fix.
- Whether to rename `BOSS_REVIEW_TEST_TIMEOUT_S` to a neutral
  `BOSS_TEST_TIMEOUT_S` with the old name as an alias. Deferred to avoid a
  compatibility change in this budget fix.
