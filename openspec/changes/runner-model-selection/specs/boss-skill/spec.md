# Spec Delta

## ADDED Requirements

### Requirement: Confirmed model in reports

The shared RUN procedure SHALL tell the Explorer to check the model status right
after a dispatch and SHALL allow naming a model to the operator only as confirmed
by the runtime. A declared or assumed model SHALL be labelled as such.

#### Scenario: Confirmed

- **WHEN** the dispatch result or status shows a confirmed model
- **THEN** the Explorer reports runner, model, effort and billing class

#### Scenario: Not confirmed

- **WHEN** the model is pending, unpinned or unverifiable
- **THEN** the Explorer says so instead of naming the configured model as fact

#### Scenario: Native confirmation is late

- **WHEN** a native apply is dispatched and the confirmation is pending
- **THEN** the Explorer ends its turn and relies on the wake, without polling

### Requirement: Model errors in the run procedure

The shared RUN procedure SHALL describe the reaction to every model error: never
override the runner, skip and journal the affected change, continue with
independent changes, and hand the decision to the operator at the end.

#### Scenario: Model not offered during a run

- **WHEN** a dispatch fails with `model_not_offered`
- **THEN** the Explorer journals it, leaves the change undispatched and continues
  with changes that do not depend on it

#### Scenario: Mismatch or limit wake

- **WHEN** a wake reports `mismatch` or `cost_limit`
- **THEN** the Explorer reviews the kept work and neither retriggers with another
  model nor raises the limit without an authorization

#### Scenario: Shared block stays identical

- **WHEN** these steps are added
- **THEN** the boss and vision copies of the shared block remain byte-identical
  and the drift test passes
