# Spec Delta

## ADDED Requirements

### Requirement: Model assignment by task role

Phase P4 SHALL assign each change a runner through the configured task roles and
SHALL write the resolved runner name to the existing `runner:` bullet. A role
without a configured runner SHALL be asked during planning, never resolved during
the run.

#### Scenario: Role resolves to a runner

- **WHEN** P4 classifies a change as hard UI work and that role names a runner
- **THEN** the bullet carries `runner:` with that name

#### Scenario: Default code work

- **WHEN** a change is ordinary code and the default runner is pinned
- **THEN** the bullet may omit `runner:` and uses the default runner

#### Scenario: Existing annotation

- **WHEN** a bullet already carries a `runner:` the operator chose
- **THEN** P4 keeps it and reports a differing role instead of replacing it

#### Scenario: Role not configured

- **WHEN** a change needs a role that names no runner
- **THEN** the skill asks the operator before the charter closes

### Requirement: Independent second review

When a change is planned as an independent second review, P4 SHALL assign it a
runner whose model vendor differs from the vendor that implemented the reviewed
change, and SHALL record both vendors in the charter.

#### Scenario: Different vendor

- **WHEN** the implementing change uses one vendor's model
- **THEN** the review change is assigned a runner of another vendor

#### Scenario: No other vendor available

- **WHEN** no runner of another allowed vendor exists
- **THEN** the skill reports the gap during planning and does not label the
  review as independent

### Requirement: Charter closes model decisions

Before a mission is dispatched, its charter SHALL list for every runner it uses
the model, effort, provider, billing class, per-apply limit and the data classes
that may be sent, and its `## Authorization` SHALL decide paid models and trial
runs with an amount.

#### Scenario: Complete runner policy

- **WHEN** the charter lists every used runner with these values and a decision
- **THEN** the charter gate may open

#### Scenario: Paid model undecided

- **WHEN** a mission uses a metered model without an authorization amount
- **THEN** the charter stays open and the mission is not dispatched

#### Scenario: Sensitive data

- **WHEN** a change works with personal or otherwise sensitive data
- **THEN** the charter names the providers allowed for it before the run
