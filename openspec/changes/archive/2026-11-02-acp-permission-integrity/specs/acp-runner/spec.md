# Spec Delta

## MODIFIED Requirements

### Requirement: Permission policy

Every ACP permission request SHALL be answered by the runner's policy before the
agent continues. The policy SHALL allow, reject, or leave the request pending for
the Explorer, and SHALL match a request by its tool input and title. Concurrent
requests SHALL be queued independently; answering one SHALL NOT discard another.

An automatic allow SHALL select an allow-once option and SHALL NOT create a
persistent agent-level grant. An Explorer allow-always SHALL be scoped to the
current apply and SHALL be sent to the agent as allow-once.

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

## ADDED Requirements

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
