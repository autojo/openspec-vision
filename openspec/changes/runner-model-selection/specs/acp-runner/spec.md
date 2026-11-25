# Spec Delta

## MODIFIED Requirements

### Requirement: Model and mode selection

The runtime SHALL select the runner's model, effort and mode through ACP session
configuration when the agent advertises them, SHALL set the model before the
effort, and SHALL fail the dispatch when a configured value is not offered or
the agent reports a different value afterwards.

#### Scenario: Model is applied

- **WHEN** the runner names a model the agent advertises
- **THEN** the runtime sets it before the first prompt and records the declared
  and the reported value in the apply state

#### Scenario: Effort is applied

- **WHEN** the runner names an effort and the agent advertises a thought-level
  option for the selected model
- **THEN** the runtime sets it after the model, because the offered levels
  depend on the model

#### Scenario: Effort not advertised

- **WHEN** the runner names an effort and the agent advertises no thought-level
  option for the model
- **THEN** the dispatch fails with `effort_not_offered`

#### Scenario: Mode is applied

- **WHEN** the runner names a mode the agent advertises
- **THEN** the runtime sets it before the first prompt

#### Scenario: Unsupported value

- **WHEN** the runner names a model, effort or mode the agent does not offer
- **THEN** the dispatch fails and names the available values

#### Scenario: Reported value differs

- **WHEN** the agent accepts the value but its returned configuration reports
  another one
- **THEN** the dispatch fails with `model_mismatch` before the first prompt

### Requirement: Session resume

The runtime SHALL persist the ACP session id and SHALL resume the session after a
supervisor restart when the agent supports loading sessions. A resumed session
SHALL NOT be prompted until its model and effort are confirmed.

#### Scenario: Resume after restart

- **WHEN** a supervisor restarts for an unfinished apply and the agent supports
  session loading
- **THEN** the runtime loads the persisted session and replays its updates into
  the transcript

#### Scenario: Load unsupported

- **WHEN** the agent does not support session loading
- **THEN** the runtime reports that the apply cannot be resumed in place and
  offers a retrigger

#### Scenario: Model cannot be confirmed after load

- **WHEN** the loaded session reports no model option or another model that
  cannot be set back
- **THEN** the resume fails with `model_mismatch` and no prompt is sent

### Requirement: Doctor validation

The doctor SHALL validate an ACP runner only when one is configured: the command
must exist, the ACP handshake must succeed, and the configured model, effort and
mode must be offered. The probe SHALL use the same kind of profile the runner's
dispatch uses.

#### Scenario: Missing binary

- **WHEN** a configured ACP command is not on `PATH`
- **THEN** the doctor reports the missing command and the runner name

#### Scenario: Handshake failure

- **WHEN** the agent does not complete the ACP initialization
- **THEN** the doctor reports the failure with the captured stderr

#### Scenario: Unknown model

- **WHEN** the configured model is not advertised
- **THEN** the doctor reports the offered models

#### Scenario: Unknown effort

- **WHEN** the configured effort is not offered for the configured model
- **THEN** the doctor reports the offered efforts

#### Scenario: Non-isolated runner is probed as dispatched

- **WHEN** the runner sets `isolate = false`
- **THEN** the probe uses the user's agent profile and a model that a dispatch
  could select is not reported as missing

### Requirement: Permission store validation

The doctor SHALL inspect the effective agent permission store for every
configured ACP runner. When a global allow for shell, write or edit would bypass
the supervisor's policy, the doctor SHALL report the policy as weakened and name
the offending entry instead of reporting it as enforced.

#### Scenario: Weakened store is reported

- **WHEN** the agent's global permission store always allows shell, write or edit
- **THEN** the doctor reports `weakened`, names the entry, and does not claim the
  ACP deny list is enforced

#### Scenario: Clean store is reported

- **WHEN** the agent has no global allow that bypasses the supervisor
- **THEN** the doctor reports the ACP policy as enforced

#### Scenario: Probe leaves no state

- **WHEN** the doctor probes an isolated ACP runner
- **THEN** the probe uses a temporary profile and leaves no session or permission
  entry in the user's agent state

#### Scenario: Non-isolated probe cleans up its session

- **WHEN** the doctor probes a non-isolated ACP runner
- **THEN** it sends no prompt, writes no permission entry, closes its own session
  and deletes it when the agent supports deletion, and otherwise reports that an
  empty session remains
