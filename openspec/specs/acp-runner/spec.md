# acp-runner Specification

## Purpose
Let the boss run an ACP-speaking coding agent as a managed apply, with a precise
turn lifecycle, enforceable permissions, cancellation, resume and a transcript,
without requiring a Herdr-native agent kind.

## Requirements

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
the Explorer, and SHALL match a request by its tool input and title. Concurrent
requests SHALL be queued independently; answering one SHALL NOT discard another.

#### Scenario: Denied command

- **WHEN** a permission request carries a command matching the deny list
- **THEN** the runtime rejects it and the command does not run

#### Scenario: Allowed command

- **WHEN** a permission request matches no deny rule and the policy allows it
- **THEN** the runtime grants it once and the tool runs

#### Scenario: Unmatched request escalates

- **WHEN** the policy is configured to ask and no rule matches
- **THEN** the request stays pending, the apply becomes blocked and the boss is
  woken

#### Scenario: Concurrent requests are queued

- **WHEN** two permission requests arrive before either is answered
- **THEN** both are recorded as pending and answering the first leaves the
  second pending

### Requirement: Permission grants

An automatic allow SHALL select an allow-once option and SHALL NOT create a
persistent agent-level grant. An Explorer allow-always SHALL be scoped to the
current apply and SHALL be sent to the agent as allow-once.

#### Scenario: Automatic allow does not persist

- **WHEN** the policy allows a request without the Explorer
- **THEN** the runtime selects an allow-once option and the agent's persistent
  permission store is unchanged

#### Scenario: Allow-always is apply-scoped

- **WHEN** the Explorer answers a request with allow-always
- **THEN** the runtime remembers the grant for this apply, sends allow-once to
  the agent, and does not write a global agent permission

### Requirement: Blocked state and answer

Every pending permission SHALL be reported as `blocked`, and `boss answer` SHALL
resolve a specific request by tool-call id. With exactly one pending request the
option alone SHALL remain sufficient; with several, an answer without an id
SHALL fail with an error that names the pending ids.

#### Scenario: Status shows blocked

- **WHEN** an apply waits for one or more permission decisions
- **THEN** `boss status` reports `blocked` and lists every pending tool call with
  its id and offered options

#### Scenario: Answer resolves the request

- **WHEN** the Explorer answers a blocked apply with an option and a tool-call id
- **THEN** the runtime sends that option to that request and the turn continues

#### Scenario: Ambiguous answer is refused

- **WHEN** several requests are pending and the Explorer answers without an id
- **THEN** the runtime refuses the answer and names the pending ids

#### Scenario: Interrupt cancels a pending request

- **WHEN** a blocked apply is interrupted
- **THEN** the pending permission is answered as cancelled

#### Scenario: Interrupt cancels every pending request

- **WHEN** a blocked apply with several pending requests is interrupted
- **THEN** every pending permission is answered as cancelled and the turn ends

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

### Requirement: Isolated agent state

The runtime SHALL run an ACP agent with a per-apply configuration and data root.
Provider configuration and secrets MAY be linked from the user's profile, but the
agent permission store SHALL be owned by the runtime and SHALL contain no
`always_allow` entry for shell, write or edit. The profile SHALL be removed when
the apply finishes and SHALL survive a supervisor restart so a resumed session
keeps its state.

#### Scenario: Apply uses its own profile

- **WHEN** an ACP apply starts
- **THEN** the agent's configuration, permission and session state come from the
  per-apply root, not from the user's global agent profile

#### Scenario: Global profile is not modified

- **WHEN** the agent asks for or receives a permission during an apply
- **THEN** the user's global permission store is unchanged

#### Scenario: Finish removes the profile

- **WHEN** an ACP apply is finished
- **THEN** its configuration, permission and session data are removed with the
  apply state

#### Scenario: Resume keeps the profile

- **WHEN** a supervisor restarts and resumes the same apply
- **THEN** it reuses the per-apply profile and the agent can load its session

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

- **WHEN** the doctor probes an ACP runner
- **THEN** the probe uses a temporary profile and leaves no session or permission
  entry in the user's agent state

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

#### Scenario: Long command with progress is not a stall

- **WHEN** a tool call runs longer than the stall interval and emits progress
  updates
- **THEN** the runtime does not report a stall
