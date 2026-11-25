## ADDED Requirements

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
