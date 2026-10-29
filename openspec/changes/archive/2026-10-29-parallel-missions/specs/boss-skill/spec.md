# Spec Delta

## ADDED Requirements

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
