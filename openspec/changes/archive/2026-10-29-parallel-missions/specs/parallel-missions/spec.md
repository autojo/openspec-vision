# Spec Delta

## Purpose

Run independent OpenSpec changes of one mission side by side in isolated
worktrees, bounded by a hard concurrency limit and explicit resource locks, while
selecting only changes whose declared scopes do not overlap.

## ADDED Requirements

### Requirement: Hard concurrency limit

The run SHALL refuse a dispatch when the number of running applies reaches
`[missions] max_parallel` (default `1`) or the `BOSS_MAX_PARALLEL` override.
Parked applies SHALL NOT count against the limit.

#### Scenario: Limit reached

- **WHEN** the number of running applies equals `max_parallel`
- **THEN** dispatch returns `parallel_limit` with the current and maximum counts
  and starts nothing

#### Scenario: Parked does not count

- **WHEN** an apply is parked and another change is dispatched
- **THEN** the parked apply does not consume a slot

#### Scenario: Environment override

- **WHEN** `BOSS_MAX_PARALLEL` is set
- **THEN** it overrides the configured `max_parallel` for that process

### Requirement: Worktree-only parallel mode

When `max_parallel > 1`, every apply of the run SHALL use the worktree lifecycle.
A dispatch without a worktree SHALL be refused and the base checkout SHALL stay
clean.

#### Scenario: Parallel dispatch in a worktree

- **WHEN** `max_parallel` is greater than one and a change is dispatched
- **THEN** the apply runs in the worktree lifecycle from `worktree-applies`

#### Scenario: Base dispatch refused

- **WHEN** `max_parallel > 1` and a dispatch would run in the base checkout
- **THEN** it is refused with `worktree_required`

### Requirement: Touches declaration

Mission bullets SHALL support `touches:` with a comma-separated list of resource
keys or path prefixes. `touches: none` SHALL declare that the change shares
nothing; a missing `touches:` SHALL make the change exclusive.

#### Scenario: Declared locks are parsed

- **WHEN** a bullet contains `touches: auth, deps`
- **THEN** mission parsing and mission status report both locks for that change

#### Scenario: Explicit none

- **WHEN** a bullet contains `touches: none`
- **THEN** the change is declared and shares no locks

#### Scenario: Missing declaration is exclusive

- **WHEN** a bullet has no `touches:` annotation
- **THEN** the change may not start while another apply is running

### Requirement: Lock conflict

Dispatch and mission selection SHALL refuse a change whose locks intersect a
running or unmerged apply, by exact key or path-prefix overlap, and SHALL name
the holding change. Locks SHALL be scoped to the project.

#### Scenario: Exact key conflict

- **WHEN** a running change holds `deps` and the candidate also declares `deps`
- **THEN** the candidate is refused with `lock_conflict`

#### Scenario: Path prefix conflict

- **WHEN** a running change holds `src/auth` and the candidate holds
  `src/auth/login`
- **THEN** the candidate is refused as overlapping

#### Scenario: Unmerged parked holder

- **WHEN** a parked worktree still holds `auth` and a candidate declares `auth`
- **THEN** the candidate waits for the merge or an explicit release

#### Scenario: Disjoint locks

- **WHEN** the candidate's locks do not intersect any holder
- **THEN** the candidate may start if a slot is free

### Requirement: Mission slot filling

`mission next` SHALL skip running and lock-conflicting changes and return the
next startable change. The run procedure SHALL fill free slots and refill after a
finish. Mission status SHALL show running changes, used slots and the effective
limit.

#### Scenario: Fill two slots

- **WHEN** `max_parallel` is two and two disjoint changes are startable
- **THEN** the run dispatches both and both appear as running

#### Scenario: Third change waits

- **WHEN** two applies are running and a third disjoint change is startable
- **THEN** the run reports `parallel_limit` and starts nothing

#### Scenario: Status shows slots

- **WHEN** mission status is read during parallel work
- **THEN** it lists running changes, used slots and the effective `max_parallel`

### Requirement: Resource soft stop

Dispatch SHALL report the existing open-apply, free-memory and load warnings. The
run SHALL NOT start additional parallel changes while a warning is present;
running applies SHALL continue.

#### Scenario: Warning stops new starts

- **WHEN** a resource threshold is reached and a slot is free
- **THEN** the run does not start another change and reports the warning

#### Scenario: Running applies continue

- **WHEN** a resource threshold is reached while applies are running
- **THEN** those applies are not interrupted

### Requirement: Merge overlap backstop

Review SHALL compare the changed files of running, parked and finished worktrees
and report intersections. It SHALL NOT resolve them automatically.

#### Scenario: Overlap reported

- **WHEN** two worktrees changed the same file
- **THEN** review names the file and both changes

#### Scenario: Disjoint changes silent

- **WHEN** the changed file sets are disjoint
- **THEN** no overlap is reported

### Requirement: Plan lock assignment

Vision P4 SHALL assign `touches:` (or `none`) to every change. `boss doctor`
SHALL warn when `max_parallel > 1` and a change has no declaration.

#### Scenario: P4 writes locks

- **WHEN** P4 assigns runners and dependencies
- **THEN** it also writes `touches:` or `touches: none` for each change

#### Scenario: Doctor warns

- **WHEN** `max_parallel > 1` and a mission change lacks `touches:`
- **THEN** `boss doctor` reports that the change will run exclusively
