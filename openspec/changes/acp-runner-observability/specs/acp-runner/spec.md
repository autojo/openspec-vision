# Spec Delta

## MODIFIED Requirements

### Requirement: Transcript and status

The runtime SHALL append ACP session updates to an apply transcript and SHALL
expose the last event, model, mode, usage and every pending permission in status.
Permission transcript entries SHALL carry the tool-call id and request id. The
last-update field SHALL describe the last message or tool activity, not a
fragment of streamed text.

#### Scenario: Transcript during a run

- **WHEN** the agent streams messages and tool calls
- **THEN** the runtime appends them to the apply transcript

#### Scenario: Status after a turn

- **WHEN** a turn ends
- **THEN** status shows the stop reason, usage and the last tool activity

#### Scenario: Status names the runner

- **WHEN** status is requested for an ACP apply
- **THEN** the JSON names the runner, model and mode that drive the session

#### Scenario: Several permissions are visible

- **WHEN** several permission requests are pending
- **THEN** status lists each one with its tool-call id and options

#### Scenario: Permission entries are traceable

- **WHEN** a permission request is recorded or answered
- **THEN** its transcript entry carries the tool-call id and request id

### Requirement: Turn completion and wake

The runtime SHALL treat the ACP prompt response as the end of a turn and SHALL
wake the boss from that response rather than from a Herdr agent state. A blocked
transition SHALL wake the boss once, not once per concurrent permission request.

#### Scenario: Completed turn

- **WHEN** the prompt response reports `end_turn`
- **THEN** the apply becomes idle and the boss is woken once

#### Scenario: Interrupted turn

- **WHEN** the prompt response reports `cancelled`
- **THEN** the apply records `cancelled` and the boss is woken once

#### Scenario: Other stop reason

- **WHEN** the prompt response reports another reason
- **THEN** the apply records that reason and the boss is woken with it

#### Scenario: One wake for several requests

- **WHEN** several permission requests arrive in the same blocked transition
- **THEN** the boss receives one wake that names the number of pending requests

### Requirement: State, slots and liveness

An ACP apply SHALL count as a running apply for the concurrency limit and the
resource locks, and its liveness SHALL be derived from the supervisor process,
not from a Herdr agent. The aggregate status view SHALL use the same liveness
rule as the per-apply view.

#### Scenario: ACP apply consumes a slot

- **WHEN** an ACP apply is running and another dispatch is attempted at the limit
- **THEN** the dispatch is refused with the current and maximum counts

#### Scenario: Dead supervisor frees the slot

- **WHEN** a supervisor is no longer alive and no turn is pending
- **THEN** the apply no longer consumes a slot and the boss is woken

#### Scenario: Aggregate status agrees with detail

- **WHEN** the supervisor of an ACP apply is alive
- **THEN** both the aggregate and the per-apply status report the waiter as alive

#### Scenario: Locks still apply

- **WHEN** an ACP apply holds a lock and a conflicting change is dispatched
- **THEN** the conflict is refused as for a pane-based apply

## ADDED Requirements

### Requirement: Turn timeout and stall detection

An ACP turn SHALL have a configurable timeout. When a turn is `working` and its
transcript has made no progress for a configurable stall interval, the runtime
SHALL wake the Explorer with a stalled state. Both intervals SHALL be
configurable and SHALL default above the longest expected command.

#### Scenario: Turn timeout

- **WHEN** a prompt response does not arrive within the configured turn timeout
- **THEN** the runtime records `turn_timeout`, ends the turn and wakes the boss

#### Scenario: Stall is reported

- **WHEN** a working turn has produced no transcript update for the stall
  interval
- **THEN** the runtime wakes the boss with a stalled state and the last activity

#### Scenario: Progress resets the stall timer

- **WHEN** the agent emits a message or tool update
- **THEN** the stall timer restarts from that update

#### Scenario: Long command is not a stall

- **WHEN** a tool call is running longer than the stall interval but the turn
  timeout has not expired
- **THEN** the runtime does not report a stall solely because the command is
  still running
