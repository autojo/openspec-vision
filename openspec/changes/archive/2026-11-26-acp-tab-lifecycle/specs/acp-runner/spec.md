# Spec Delta

## MODIFIED Requirements

### Requirement: Cancel and interrupt

`boss interrupt` SHALL cancel the active ACP turn and SHALL NOT send keystrokes
to the agent. The runtime SHALL confirm the cancellation from the prompt
response. By default it SHALL close the apply tab after the turn ends;
`--keep-tab` SHALL preserve the tab for inspection.

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

#### Scenario: Interrupt closes the tab

- **WHEN** an ACP apply is interrupted without `--keep-tab`
- **THEN** its recorded apply tab is closed after the cancellation

#### Scenario: Keep the tab

- **WHEN** an ACP apply is interrupted with `--keep-tab`
- **THEN** the apply tab remains for inspection and the state says so
