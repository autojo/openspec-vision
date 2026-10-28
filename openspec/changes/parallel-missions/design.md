# Design

## Context

See `proposal.md` for motivation and `worktree-applies` for the foundation. The
current runtime already has most of the raw material:

- `open_apply_count` counts non-parked apply states; `free_mem_mb`, `load_1min`
  and `resource_warning` expose the existing resource thresholds.
- `mission_change_spec` parses `after:`, `human-ok:` and `runner:`; a bullet with
  only an unknown annotation is treated as a change name.
- `mission next` selects one startable change and dispatches it.
- `dispatch_change` is the single choke point before a tab is created.
- `executer_busy` is per Herdr workspace; worktree applies already use separate
  workspaces.

## Goals / Non-Goals

**Goals:**

- A hard, configurable cap on concurrently running applies.
- Only declared, disjoint changes start together; everything else stays serial.
- The run fills free slots, handles multiple wakes and refills after a finish.
- No silent overlap at merge; a stale lock is visible.

**Non-Goals:**

- Per-project or per-mission limits, machine-wide `global:` lock namespaces.
- Shared dependency directories or remote runners.
- Automatic conflict resolution or automatic merge ordering.

## Decisions

### D1: One hard limit, globally counted

`[missions] max_parallel` defaults to `1`. `BOSS_MAX_PARALLEL` overrides it for
one process (tests, a one-off larger run). The limit is a hard stop in
`dispatch_change`; a dispatch beyond it returns `parallel_limit` with
`current/max` and starts nothing.

The count is **global** (`open_apply_count`), because the limit protects the
machine, not one project. Parked applies and finished/kept applies do not count;
a `test_failed` state does, because the change is unfinished. The existing
`BOSS_DISPATCH_MAX_APPLIES` warning stays advisory and independent; document
that a user who raises `max_parallel` above it should raise the warning too.

Alternative: a per-project count. Rejected for v1 because one project could
still exhaust a small machine; it can be added later without changing the
config key.

### D2: Parallel means worktrees

When `max_parallel > 1`, `worktrees = "auto"` resolves to a worktree for every
apply. `--no-worktree` or `worktrees = "never"` is refused with
`worktree_required`; mixing a base checkout and worktrees would leave the merge
target dirty. The plan commit and base-clean check from `worktree-applies` are
prerequisites.

At `max_parallel = 1` nothing changes: a worktree is opt-in through
`--worktree`/`always`.

### D3: Locks are declared resources

Mission bullet:

```markdown
- feat-a (runner: opencode-flash; touches: src/auth, deps)
- feat-b (runner: opencode-flash; touches: none)
- feat-c (runner: opencode-flash)
```

Parsing:

- Extend the `mission_change_spec` recognition condition with `touches:`.
- Split on commas, trim, drop empties. `none` becomes an empty lock list with
  `declared=true`; a missing annotation is `declared=false`.
- Store `touches` and `declared` in `change_specs`, the apply state and the
  status output.

Comparison in one helper:

- exact string match (`deps`, `test-env`, `port:3000`);
- path prefix when both sides contain `/`: `src/auth` and `src/auth/login`
  overlap; a trailing slash is ignored;
- a lock without `/` never matches a path by prefix.

Scope is the **base project** in v1: locks of applies whose state `project`
equals the base project. A later change can add a `global:` prefix for
machine-wide resources; until then `port:3000` only serialises within the
project. Document this explicitly.

### D4: Lock holders and exclusive changes

A change is blocked when any holder in the same project intersects it.
Holders are:

- running applies (state exists, not parked, `merge_state` not `done`);
- parked applies with a worktree (unmerged work);
- `merge_conflict` and `merge_test_failed` states (code not safely finished).

A merged, green, kept worktree holds no locks; its code is already in the base.

Rules:

- candidate undeclared -> starts only when there is **no** holder at all;
- candidate declared, any holder undeclared -> wait;
- both declared -> start only when the lock sets are disjoint.

Checks run in `dispatch_change` (authoritative) and in `cmd_mission_next`
(selection, so a conflict does not abort the fill loop). A manual dispatch
accepts `--touches <list>`/`--touches none`; without it, the change is
exclusive. `mission next` passes the parsed locks into the dispatch and records
them in state.

Alternative: implicit file analysis from `tasks.md`. Rejected: unreliable and
unable to express ports, databases and shared fixtures.

### D5: Filling slots and multiple wakes

`cmd_mission_next` skips:

- done, waiting_human and dependency-blocked changes (as today);
- changes that already have an apply state (running, parked or test-failed);
- candidates whose locks conflict with a holder;
- when no slot is free, the whole call reports `parallel_limit` before selecting.

The result of a skipped-by-lock selection is `no_startable` with the blocking
holders named, so the skill can wait for a wake instead of spinning.

The shared RUN procedure gains a fill loop:

1. call `mission next`; on `started` repeat;
2. stop on `parallel_limit`, `no_startable`, `waiting_human`,
   `mission_complete` or a resource warning;
3. end the turn and wait for a wake;
4. on a wake, drain the inbox, review each finished change, merge/finish, then
   refill.

The limit of one keeps the current one-dispatch-then-wait path.

### D6: Resource warning stops new starts

`resource_warning` remains non-blocking for a single dispatch (today's
behaviour). The fill loop treats a non-empty warning in the dispatch result as
"do not start more", but does not interrupt running applies. The hard
`max_parallel` is the only capacity refusal; the memory/load/open-apply
thresholds remain tunable warnings.

Alternative: make the thresholds hard in `dispatch_change`. Rejected for v1
because it would also block a single serial apply; the user can lower
`max_parallel` instead.

### D7: P4 assigns the locks

Vision P4 writes `touches:` on every mission bullet:

- source paths or directories the change will edit;
- shared resources: `deps`, `test-env`, `port:<n>`, `db:<name>`;
- `touches: none` when the change is isolated;
- no annotation when uncertain; the change then runs exclusively.

The final sort may add or adjust annotations but does not rewrite artifacts.
The boss skill (run-only) uses the mission's declarations; a manual change uses
`--touches`. `boss doctor` warns for every change without a declaration when
`max_parallel > 1`.

### D8: Overlap backstop and observability

`boss review` computes the changed file set of the current worktree and of
other running/parked/test-failed worktrees of the same base:

- `git -C <wt> status --porcelain` for uncommitted files;
- `git -C <wt> diff --name-only <base_head>...HEAD` for committed files.

Intersections are returned as `overlaps: [{file, changes:[...]}]`; the runtime
does not merge, rebase or resolve. The Explorer uses the report to order merges
or retrigger.

`boss status` adds `touches`, `declared` and `merge_state`.
`boss mission status` adds `max_parallel`, `running`, `slots_used`,
`slots_free` and per-change `running`/`touches`/`declared`.
`boss doctor` checks the limit value, lock declarations (when parallel) and
stale worktree holders.

### D9: Tests

- Temp git repo with two disjoint changes and one overlapping change; Herdr
  stub from `worktree-applies`.
- Limit: `max_parallel=2` starts two, the third returns `parallel_limit`; a
  parked apply frees the slot but keeps its locks.
- Locks: exact, path prefix, `none`, missing -> exclusive; a parked holder
  blocks; disjoint starts.
- Mission fill: two `mission next` calls start different changes; a third
  reports `parallel_limit`; status shows slots.
- Resource soft stop: fake `meminfo`/`loadavg` produce a warning; the fill loop
  stops, running applies stay.
- Overlap report: two worktrees edit the same file; review names it.
- `max_parallel=1`: unchanged serial path; existing 559 tests stay green.

## Risks / Trade-offs

- **Lock accuracy** -> the P4 policy, doctor warning and merge overlap report;
  an omitted lock serialises, an incorrect lock is caught at merge.
- **Ports/databases are not isolated by worktrees** -> declare `port:`/`db:`
  locks or a shared `test-env`; post-merge tests catch the rest.
- **Per-worktree dependencies** -> `deps` serialises installs where needed;
  sharing directories is out of scope.
- **Global limit counts other projects** -> documented; the user can raise
  `BOSS_MAX_PARALLEL` or use a per-project limit later.
- **Two bosses on the same base** -> state keys and `find_running_apply` make
  the same change idempotent; different changes can still race the slot/lock
  check. A per-project `flock` around the check + state write is the hardening
  if this becomes real; v1 assumes one Explorer per base.
- **Stale locks from a test-failed apply** -> the state stays a holder until the
  Explorer finishes or abandons it; this is intentional because the code is in
  the base and may still change.
- **P4 burden** -> changes without locks fall back to serial, which is safe.

## Migration Plan

1. Ship with `max_parallel = 1`; behaviour is unchanged.
2. Set `[missions] max_parallel = 2` (or `BOSS_MAX_PARALLEL=2`) to opt in.
3. Add `touches:` in P4, or set `none` for isolated changes.
4. Rollback: set `max_parallel = 1`; locks are ignored and the serial path
   resumes. No state migration; an old state without `touches` is exclusive.

## Open Questions

None.
