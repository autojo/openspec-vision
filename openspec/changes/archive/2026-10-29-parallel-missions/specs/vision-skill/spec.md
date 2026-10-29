# Spec Delta

## ADDED Requirements

### Requirement: Parallel run phase and lock assignment

Vision P4 SHALL assign `touches:` (or `none`) to every change, and the RUN phase
SHALL fill slots within the effective `max_parallel` using the shared RUN block
and the lock checks. The shared block SHALL stay byte-identical to the boss
skill's copy.

#### Scenario: P4 assigns locks

- **WHEN** P4 finalises the mission change list
- **THEN** each change carries a `touches:` list or an explicit `none`

#### Scenario: RUN fills slots

- **WHEN** the RUN phase has a free slot and a disjoint startable change
- **THEN** it dispatches that change and continues with other work

#### Scenario: Shared block stays in sync

- **WHEN** the parallel fill steps are added
- **THEN** the vision and boss shared blocks remain identical and the drift test
  passes
