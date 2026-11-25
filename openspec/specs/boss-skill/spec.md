# boss-skill Specification

## Purpose
Provide a standalone boss skill that runs OpenSpec changes and missions from one
session without the large-project planning phase, shipped from the same
repository as the vision skill and driven by one shared run procedure.

## Requirements

### Requirement: Standalone Explorer skill

The repository SHALL ship a `boss` skill whose procedure is self-contained: it
dispatches, reviews, retriggers, parks, resumes, retargets, interrupts and
finishes OpenSpec changes, including changes in a mission, without loading the
vision skill or any other skill.

#### Scenario: Single change without a plan

- **WHEN** the user asks to run one existing change with the boss skill
- **THEN** the skill dispatches, reviews and finishes that change without
  creating or reading `openspec/vision.md`

#### Scenario: Mission change

- **WHEN** the change belongs to a mission
- **THEN** the skill applies the mission order, the reconcile gate and
  `boss mission next` exactly as a planned run does

#### Scenario: Human endpoints

- **WHEN** only marked human tasks remain, or the human reports progress
- **THEN** the skill parks the change or resumes it instead of retriggering it

#### Scenario: No other skill loaded

- **WHEN** the skill runs any phase
- **THEN** it never invokes another skill or a tool-specific planning command

### Requirement: Shared run procedure

The boss skill SHALL reuse the vision skill's phase-RUN procedure as one shared
text block, delimited by markers in both skill files, and editing either copy
alone SHALL be detectable.

#### Scenario: Identical shared block

- **WHEN** both installed skill files are compared
- **THEN** the marked run-procedure blocks are byte-identical

#### Scenario: Drift is detected

- **WHEN** a change edits the run procedure in only one of the two skill files
- **THEN** the repository test fails and names the command that re-synchronises
  the block

### Requirement: Disjoint skill descriptions

The frontmatter descriptions of `boss` and `vision` SHALL describe disjoint
scopes so a session selects the right skill: `boss` for a single change or a
small ad-hoc batch without a plan, `vision` for a large project and ordered
version missions.

#### Scenario: Single change selects boss

- **WHEN** the user asks to dispatch, review or finish one OpenSpec change
- **THEN** the request matches the boss skill's description

#### Scenario: Large project selects vision

- **WHEN** the user asks to plan a large project or run several version missions
- **THEN** the request matches the vision skill's description

### Requirement: Worktree-aware run procedure

The boss skill SHALL describe the worktree lifecycle in its shared RUN
procedure: plan commit, isolated dispatch, worktree review, merge/test/cleanup
on finish and worktree reuse on resume. It SHALL NOT claim that every apply runs
in the project checkout.

#### Scenario: Shared block covers the worktree lifecycle

- **WHEN** the boss skill's shared RUN block is read
- **THEN** it describes plan commit, worktree dispatch and worktree-aware review

#### Scenario: Finish merges and cleans up

- **WHEN** the skill finishes a worktree apply
- **THEN** it merges into the base, tests the merged base and removes the
  worktree on success

#### Scenario: Drift test stays green

- **WHEN** the worktree steps are added to the shared RUN block
- **THEN** the boss and vision copies remain byte-identical and the drift test
  passes

### Requirement: Parallel slot filling in the run procedure

The boss skill SHALL fill free slots up to the effective `max_parallel`, skip
running and lock-conflicting changes, handle multiple wakes and keep the serial
path when the limit is 1.

#### Scenario: Fill free slots

- **WHEN** the limit is two and a second disjoint change is startable
- **THEN** the skill dispatches it before ending the turn

#### Scenario: Limit of one is serial

- **WHEN** `max_parallel` is 1
- **THEN** the skill dispatches one change and waits for its wake as today

#### Scenario: Multiple wakes

- **WHEN** two parallel applies finish
- **THEN** the skill processes both wake messages without blocking the other
  apply

### Requirement: Evidence rules for review

The shared run procedure SHALL tell the Explorer which evidence a review needs
before it accepts an apply. The rules SHALL be part of the marked block, so boss
and vision stay identical.

#### Scenario: A green gate that ran nothing

- **WHEN** a test command succeeds with zero executed tests or without a count
- **THEN** the procedure tells the Explorer to treat the gate as not run

#### Scenario: A claim that nothing changed

- **WHEN** the Explorer compares old and new output and finds no difference
- **THEN** the procedure requires a control that shows the comparison can detect
  a difference, before the claim is reported

#### Scenario: A changed screen

- **WHEN** an apply changes a screen that other tests also open
- **THEN** the procedure requires every test that opens that screen, not only
  the tests written for the change

#### Scenario: An unverified tool option

- **WHEN** a script is about to delete or overwrite files with an option whose
  scope is undocumented
- **THEN** the procedure requires the documented scope or a trial on a disposable
  target before real data

### Requirement: No instructions into a running operation

The shared run procedure SHALL forbid asking a human or another session to use a
resource that a running operation is reading or writing. The Explorer SHALL name
what must stay untouched and when that ends.

#### Scenario: Transfer in progress

- **WHEN** an external station is copying data to a device
- **THEN** the Explorer tells the human to leave the application closed and
  reports when it may be opened

#### Scenario: Aborted transfer

- **WHEN** a transfer aborts
- **THEN** the procedure treats a partial result as present until a read-only
  check shows otherwise

### Requirement: Reports separate proof from inference

The shared run procedure SHALL require that a report to the human separates what
was measured from what was inferred, and that a wrong earlier statement is
corrected in the next report, with its consequence.

#### Scenario: Inference corrected

- **WHEN** later evidence contradicts an earlier explanation
- **THEN** the next report names the correction and every file or task that
  carried the old explanation is updated
