## ADDED Requirements

### Requirement: Oversized protocol lines

The runtime SHALL accept ACP lines larger than 64 KiB. A configurable limit SHALL
bound memory use. A line above the limit SHALL be skipped and reported once with
its size, and reading SHALL continue with the next line.

#### Scenario: Large tool update

- **WHEN** the agent sends a tool update of 300 KiB followed by the prompt response
- **THEN** the turn ends with the reported stop reason and the boss is woken once

#### Scenario: Line above the limit

- **WHEN** the agent sends a line above the configured limit
- **THEN** the runtime logs the size, skips the line and processes the next one

#### Scenario: Skipped response

- **WHEN** the skipped line is the response to the open prompt
- **THEN** the turn ends as `transport_lost` instead of waiting for the timeout

### Requirement: Reader failure is visible

The runtime SHALL never let the protocol reader stop silently. When it stops for
any reason while the child is alive, every open request SHALL fail, the turn SHALL
end as `transport_lost` with a reason, and the boss SHALL be woken once.

#### Scenario: Reader raises

- **WHEN** the reader stops with an error while the child still runs
- **THEN** the apply becomes idle with `transport_lost` and the error text

#### Scenario: Child keeps working

- **WHEN** the reader is gone and the child is still alive
- **THEN** the runtime does not report `end_turn` and the wake text says that
  the agent may still be working

#### Scenario: One wake

- **WHEN** the reader stops during a stalled turn that was already reported
- **THEN** the boss receives one further wake naming `transport_lost`

### Requirement: Recovery after a lost turn end

After `transport_lost` the runtime SHALL accept a new prompt. It SHALL first ask
the agent to resume the recorded session and otherwise start a new session in the
same worktree. It SHALL NOT change or discard files in the worktree.

#### Scenario: Retrigger after a lost end

- **WHEN** the operator retriggers an apply whose turn ended as `transport_lost`
- **THEN** the agent receives the prompt and the command is not refused with
  `turn_active`

#### Scenario: Agent still working

- **WHEN** the child is alive and may still be working
- **THEN** the runtime stops that child before it starts a new turn, or refuses
  with a reason that names the child

#### Scenario: Files are kept

- **WHEN** a retrigger starts a new session
- **THEN** the worktree still contains every uncommitted file of the previous turn

### Requirement: Supervisor lifetime

A supervisor SHALL end when its apply is finished, when its child is gone and no
turn can complete, or when it is asked to stop. It SHALL NOT wait for an open
turn, and a removed apply state SHALL NOT make it crash.

#### Scenario: Finish during a lost turn

- **WHEN** the operator finishes an apply whose prompt is unanswered
- **THEN** the supervisor and its child end within the shutdown budget

#### Scenario: State removed

- **WHEN** the apply state was removed before the supervisor stops
- **THEN** the supervisor logs this, closes its child and exits without an error

### Requirement: Silent turn report

A stalled wake and `boss status` SHALL state the last activity, the age of the
last transcript entry, whether the child process is alive and whether the protocol
reader is alive. They SHALL NOT claim that the agent stopped working.

#### Scenario: Reader alive, quiet agent

- **WHEN** a turn is silent but the child and the reader are alive
- **THEN** the report says that the agent may be running a long command

#### Scenario: Reader gone

- **WHEN** the reader is gone
- **THEN** the report names this first and does not suggest only `interrupt`

### Requirement: Doctor reports memory plugins

`boss doctor` SHALL report OpenCode plugins from the effective configuration that
can add text from earlier sessions to a prompt. The report SHALL be a warning,
SHALL name the plugin and SHALL NOT change any file.

#### Scenario: Memory plugin enabled

- **WHEN** a runner's effective configuration enables a known memory plugin
- **THEN** the doctor names the plugin and says how to exclude it for the runner

#### Scenario: No memory plugin

- **WHEN** no known memory plugin is enabled
- **THEN** the doctor prints no warning
