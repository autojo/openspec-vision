# Tasks

## 1. Limit and worktree mode

- [x] 1.1 Add `[missions] max_parallel` (default `1`) and the
  `BOSS_MAX_PARALLEL` override, including validation and the `boss doctor`
  output; verify the resolved value in config, env and invalid-input cases
- [x] 1.2 Make the running count exclude parked, finished and kept applies but
  include `merge_test_failed`; verify each case in the runtime tests
- [x] 1.3 Enforce the hard limit in `dispatch_change` and `mission next`:
  return `parallel_limit` with current/max when full and start nothing; verify
  two starts, a third refusal and the status fields
- [x] 1.4 Make `max_parallel > 1` force the worktree lifecycle and refuse a
  base-checkout dispatch with `worktree_required`; verify the base stays clean
  and a serial limit of one keeps today's behaviour
- [x] 1.5 Document `max_parallel`, the env override and the worktree-only
  parallel mode in `README.md`; verify the documented commands against a temp
  repo

## 2. Locks

- [x] 2.1 Extend `mission_change_spec` with `touches:`: comma list, `none` as a
  declared empty list, missing as undeclared/exclusive; verify parsing and
  mission status output for all three forms
- [x] 2.2 Store `touches`/`declared` in the apply state and add the lock
  comparison (exact key, `/`-bounded path prefix); implement the holder set of
  running, parked and `merge_conflict`/`merge_test_failed` applies; verify each
  case
- [x] 2.3 Check locks in `dispatch_change` and `cmd_mission_next`, support
  `--touches`/`--touches none` on a manual dispatch, and return `lock_conflict`
  naming the holder; verify overlapping, disjoint and exclusive cases
- [x] 2.4 Add the merge overlap report: compare changed files of the current
  worktree with running/parked/test-failed worktrees and return
  `overlaps`; verify a shared file and a disjoint pair
- [x] 2.5 Document the `touches` syntax, project scope and `none` semantics in
  `README.md`; verify the examples parse as written

## 3. Mission fill, resources and PLAN

- [x] 3.1 Make `mission next` skip changes that already have state and changes
  whose locks conflict, return `no_startable` with the holders, and expose
  `running`, `slots_used`, `slots_free` in mission status; verify fill, skip
  and limit scenarios
- [x] 3.2 Add the fill loop to the shared RUN block in `vision/SKILL.md`, sync
  `boss/SKILL.md` and keep the drift test green; verify a single-limit run still
  dispatches once and a two-slot run dispatches twice
- [x] 3.3 Add the P4 lock assignment rule to `vision/SKILL.md` (`touches:` or
  `none`, shared resources such as `deps`/`test-env`/`port:`/`db:`) and let
  `boss doctor` warn about missing declarations when `max_parallel > 1`; verify
  the P4 text and the doctor warning
- [x] 3.4 Return the existing resource warning from dispatch and make the fill
  loop stop starting new changes while it is present; verify with fake
  `meminfo`/`loadavg` files that running applies continue
- [x] 3.5 Document the parallel run loop, the resource soft stop and the P4
  lock policy in `README.md`; verify the commands and examples as written

## 4. Integration

- [x] 4.1 Run `./tests/run.sh` completely and `openspec validate
  parallel-missions --strict`; verify zero failures
- [x] 4.2 Run `./install.sh` and a parallel smoke scenario in a temp repository
  with two disjoint changes and one overlapping change: two start, the third
  hits the limit or the lock, status shows the slots and review reports the
  overlap; verify the worktrees and merges end clean

## Workflow follow-up

- Archive the change after the project's review requirements are satisfied.
