## ADDED Requirements

### Requirement: Shared evidence rules

The vision skill SHALL carry the same review, coordination and reporting rules as
the boss skill, because both use the shared run block. A drift between the two
copies SHALL fail the repository test.

#### Scenario: Rules present in both

- **WHEN** both skill files are installed
- **THEN** the evidence rules appear in the marked block of each

#### Scenario: Drift fails

- **WHEN** one copy of the rules is edited alone
- **THEN** the repository test fails and names the command that re-synchronises
  the block
