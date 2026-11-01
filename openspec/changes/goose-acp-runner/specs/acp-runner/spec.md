# Spec Delta

## Purpose

Let the boss run an ACP-speaking coding agent as a managed apply, with a precise
turn lifecycle, enforceable permissions, cancellation, resume and a transcript,
without requiring a Herdr-native agent kind.

## ADDED Requirements

### Requirement: ACP runner transport

The runtime SHALL support a runner whose agent is driven over the Agent Client
Protocol instead of a Herdr-native agent kind. A dispatch SHALL start a managed
ACP session and SHALL NOT call `herdr agent start` for that runner.

#### Scenario: ACP runner dispatches

- **WHEN** a runner is configured with the ACP transport and a change is
  dispatched
- **THEN** the runtime starts the ACP agent and creates a session for the apply

#### Scenario: Native runners unchanged

- **WHEN** a runner uses a Herdr-native kind
- **THEN** dispatch still starts it with `herdr agent start`

#### Scenario: Missing command

- **WHEN** the configured ACP command is not executable
- **THEN** dispatch fails with a clear error and leaves no apply state behind

### Requirement: ACP session lifecycle

The runtime SHALL initialize the ACP connection, create the session with the
apply root as its working directory, send the configured apply prompt and close
the session when the apply finishes.

#### Scenario: Session uses the apply root

- **WHEN** the apply runs in a worktree
- **THEN** the ACP session's working directory is that worktree

#### Scenario: Prompt is the configured apply prompt

- **WHEN** the session is ready
- **THEN** the runtime sends the runner's apply prompt with the change name

#### Scenario: Finish closes the session

- **WHEN** the apply is finished or abandoned
- **THEN** the runtime closes the ACP session and terminates the agent

### Requirement: Model and mode selection

The runtime SHALL select the runner's model and mode through ACP session
configuration when the agent advertises them, and SHALL fail the dispatch when a
configured value is not offered.

#### Scenario: Model is applied

- **WHEN** the runner names a model the agent advertises
- **THEN** the runtime sets it before the first prompt and records it in the
  apply state

#### Scenario: Mode is applied

- **WHEN** the runner names a mode the agent advertises
- **THEN** the runtime sets it before the first prompt

#### Scenario: Unsupported value

- **WHEN** the runner names a model or mode the agent does not offer
- **THEN** the dispatch fails and names the available values

### Requirement: Permission policy

Every ACP permission request SHALL be answered by the runner's policy before the
agent continues. The policy SHALL allow, reject, or leave the request pending for
the Explorer, and SHALL match a request by its tool input and title.

#### Scenario: Denied command

- **WHEN** a permission request carries a command matching the deny list
- **THEN** the runtime rejects it and the command does not run

#### Scenario: Allowed command

- **WHEN** a permission request matches no deny rule and the policy allows it
- **THEN** the runtime grants it and the tool runs

#### Scenario: Unmatched request escalates

- **WHEN** the policy is configured to ask and no rule matches
- **THEN** the request stays pending, the apply becomes blocked and the boss is
  woken

### Requirement: Blocked state and answer

A pending permission SHALL be reported as `blocked`, and `boss answer` SHALL
resolve it by selecting one of the offered options.

#### Scenario: Status shows blocked

- **WHEN** an apply waits for a permission decision
- **THEN** `boss status` reports `blocked` and names the pending tool call

#### Scenario: Answer resolves the request

- **WHEN** the Explorer answers a blocked apply with an option
- **THEN** the runtime sends that option to the agent and the turn continues

#### Scenario: Interrupt cancels a pending request

- **WHEN** a blocked apply is interrupted
- **THEN** the pending permission is answered as cancelled

### Requirement: Turn completion and wake

The runtime SHALL treat the ACP prompt response as the end of a turn and SHALL
wake the boss from that response rather than from a Herdr agent state.

#### Scenario: Completed turn

- **WHEN** the agent answers the prompt with `end_turn`
- **THEN** the runtime records the stop reason and wakes the boss

#### Scenario: Interrupted turn

- **WHEN** the agent answers the prompt with `cancelled`
- **THEN** the runtime records the cancellation and wakes the boss

#### Scenario: Other stop reason

- **WHEN** the agent answers with a stop reason other than `end_turn`
- **THEN** the runtime records it and reports it in the wake or status

### Requirement: Cancel and interrupt

`boss interrupt` SHALL cancel the active ACP turn and SHALL NOT send keystrokes
to the agent. The runtime SHALL confirm the cancellation from the prompt
response.

#### Scenario: Cancel during generation

- **WHEN** an apply is generating output and is interrupted
- **THEN** the runtime sends `session/cancel` and records the `cancelled` stop
  reason

#### Scenario: Cancel during a tool call

- **WHEN** an apply is running a tool and is interrupted
- **THEN** the runtime sends `session/cancel` and the turn ends without the tool
  continuing

#### Scenario: No keystrokes

- **WHEN** any ACP runner apply is interrupted
- **THEN** no key sequence is sent to the agent terminal

### Requirement: Session resume

The runtime SHALL persist the ACP session id and SHALL resume the session after a
supervisor restart when the agent supports loading sessions.

#### Scenario: Resume after restart

- **WHEN** a supervisor restarts for an unfinished apply and the agent supports
  session loading
- **THEN** the runtime loads the persisted session and replays its updates into
  the transcript

#### Scenario: Load unsupported

- **WHEN** the agent does not support session loading
- **THEN** the runtime reports that the apply cannot be resumed in place and
  offers a retrigger

### Requirement: Transcript and status

The runtime SHALL append ACP session updates to an apply transcript and SHALL
expose the last event, model, mode, usage and pending permission in status.

#### Scenario: Transcript during a run

- **WHEN** the agent streams messages and tool calls
- **THEN** the runtime appends them to the apply transcript

#### Scenario: Status after a turn

- **WHEN** a turn ends
- **THEN** status shows the stop reason, usage and the last tool activity

### Requirement: State, slots and liveness

An ACP apply SHALL count as a running apply for the concurrency limit and the
resource locks, and its liveness SHALL be derived from the supervisor process,
not from a Herdr agent.

#### Scenario: ACP apply consumes a slot

- **WHEN** an ACP apply is running and another dispatch is attempted at the limit
- **THEN** the dispatch is refused with the current and maximum counts

#### Scenario: Dead supervisor frees the slot

- **WHEN** a supervisor is no longer alive and no turn is pending
- **THEN** the apply no longer consumes a slot and the boss is woken

#### Scenario: Locks still apply

- **WHEN** an ACP apply holds a lock and a conflicting change is dispatched
- **THEN** the conflict is refused as for a pane-based apply

### Requirement: Doctor validation

The doctor SHALL validate an ACP runner only when one is configured: the command
must exist, the ACP handshake must succeed, and the configured model and mode
must be offered.

#### Scenario: Missing binary

- **WHEN** a configured ACP command is not on `PATH`
- **THEN** the doctor reports the missing command and the runner name

#### Scenario: Handshake failure

- **WHEN** the agent does not complete the ACP initialization
- **THEN** the doctor reports the failure with the captured stderr

#### Scenario: Unknown model

- **WHEN** the configured model is not advertised
- **THEN** the doctor reports the offered models

### Requirement: Apply prompt independence

The apply prompt for an ACP runner SHALL NOT depend on a slash command. It SHALL
reference the OpenSpec apply workflow or an installed skill and SHALL include the
change name.

#### Scenario: Prompt contains the change

- **WHEN** an ACP session is prompted
- **THEN** the prompt names the change and the apply workflow to follow

#### Scenario: No slash command assumed

- **WHEN** the agent does not implement the project's slash commands
- **THEN** the prompt still describes the work without relying on one

### Requirement: No terminal control

The runtime SHALL NOT treat the ACP runner as a terminal agent: it SHALL not
read the pane for state, send keystrokes for prompts, or depend on a Herdr agent
name for waiting.

#### Scenario: Prompt without keystrokes

- **WHEN** the first apply prompt is sent
- **THEN** the runtime sends it over ACP rather than typing it into a pane

#### Scenario: Wait without Herdr state

- **WHEN** the runtime waits for a turn to finish
- **THEN** it waits for the ACP response, not for `herdr agent wait`
