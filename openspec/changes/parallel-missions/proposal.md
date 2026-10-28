# Proposal

## Why

The worktree foundation makes one apply isolated, but the run still starts one
change at a time. On a machine with free capacity, independent changes could
run side by side without sharing a working tree. What is missing is a hard
concurrency limit, an explicit way to declare which changes may safely overlap,
and a mission loop that fills free slots. Without those, parallel applies would
exhaust RAM/CPU, collide on test ports or databases, and produce avoidable merge
conflicts.

## What Changes

- **Hard concurrency limit.** `[missions] max_parallel` (default `1`) with the
  `BOSS_MAX_PARALLEL` environment override caps running applies. A dispatch
  beyond the limit returns `parallel_limit`; parked applies do not count.
- **Parallel mode uses worktrees.** When `max_parallel > 1`, every apply of the
  run uses the worktree lifecycle from `worktree-applies`; mixing a base
  checkout and worktrees is refused with `worktree_required`.
- **Explicit overlap declarations.** Mission bullets gain
  `touches: src/auth, deps`. `touches: none` declares "shares nothing"; a
  missing `touches:` means exclusive and runs alone. Locks are resource keys or
  path prefixes, compared by exact match or path-prefix overlap.
- **Lock-aware dispatch and mission selection.** `boss dispatch` and
  `boss mission next` refuse a change whose locks intersect a running or
  unmerged apply (`lock_conflict`), count parked/unmerged worktrees as lock
  holders, and skip running changes. A manual `--touches` covers dispatches
  outside a mission.
- **Mission fill loop.** `mission next` returns the next startable,
  non-conflicting change; the shared RUN procedure fills free slots, waits for
  any wake and refills after review/finish. `mission status` shows running
  changes, slots and the effective limit.
- **Resource soft stop.** Dispatch keeps the existing open-apply, free-memory
  and load warnings; the run does not start additional parallel changes while a
  threshold is reached, but running applies continue.
- **Lock assignment in PLAN.** Vision P4 assigns `touches:` for every change
  (or an explicit `none`); `boss doctor` warns when `max_parallel > 1` and a
  change lacks a declaration.
- **Merge overlap backstop.** Review compares the changed files of running,
  parked and finished worktrees and reports intersections, so a stale lock does
  not silently merge into the same file.
- **Documentation.** README and both skills document the limit, the lock
  syntax, the fill loop and the P4 policy.

Out of scope: per-project or per-mission limits, machine-wide `global:` locks,
shared dependency directories between worktrees, remote runners and automatic
conflict resolution.

## Capabilities

### New Capabilities

- `parallel-missions`: hard concurrency limit, worktree-only parallel mode,
  `touches` lock declarations and checks, mission slot filling, resource soft
  stops, status and the merge overlap backstop.

### Modified Capabilities

- `boss-skill`: the shared RUN procedure fills free slots and handles multiple
  wakes while keeping the existing serial path.
- `vision-skill`: P4 assigns lock declarations and the RUN phase fills slots
  within the configured limit.

## Impact

- `runtime/bin/boss` and `runtime/bin/boss-lib.sh`: config, capacity checks,
  lock parsing/state/checks, mission selection, status, doctor and overlap
  reporting.
- `vision/SKILL.md` and `boss/SKILL.md`: shared RUN fill loop and P4 lock
  policy (drift test).
- `tests/run.sh`: two-change parallel scenarios, limit, locks, parked holders,
  resource stop, overlap report and the fill loop.
- `README.md`: `max_parallel`, lock syntax, parallel mode and the P4 rule.
- Depends on the completed `worktree-applies` lifecycle. Default `max_parallel
  = 1` keeps today's behaviour; a mission without `touches:` stays serial.
