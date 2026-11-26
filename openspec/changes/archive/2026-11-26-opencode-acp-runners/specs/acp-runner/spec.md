# Spec Delta

## REMOVED Requirements

### Requirement: Isolated agent state

**Reason**: The per-apply profile builder is Goose-only. It creates a Goose
`config/`/`data/` root, so an OpenCode ACP runner cannot use it and has to set
`isolate = false`.

**Migration**: OpenCode ACP runs with the user's global OpenCode configuration.
`isolate = true` is rejected for an OpenCode command. The runtime no longer
creates a Goose profile or writes a Goose permission store.

### Requirement: Permission store validation

**Reason**: The doctor read `~/.config/goose/permission.yaml` and reported
Goose's `always_allow` entries, which do not describe an OpenCode runner.

**Migration**: The doctor reports the effective OpenCode permission
configuration instead. Goose's store is not read or changed.

## ADDED Requirements

### Requirement: OpenCode ACP runners

An ACP runner whose command is `opencode` SHALL run with the user's global
OpenCode configuration and SHALL set `isolate = false`. It SHALL NOT create a
Goose profile or write a Goose permission store. Named OpenCode runners SHALL be
independent, each pinning its own model and effort; the configured default SHALL
be one of them.

#### Scenario: OpenCode uses the global profile

- **WHEN** an OpenCode ACP apply starts
- **THEN** it uses `~/.config/opencode` and `~/.local/share/opencode`, and no
  per-apply Goose profile is created

#### Scenario: Several models coexist

- **WHEN** the configuration defines several `opencode-*` runners with different
  models and efforts
- **THEN** each runner starts its own model/effort and the default is one of them

#### Scenario: Goose is absent

- **WHEN** an apply is dispatched without an explicit runner
- **THEN** the configured default is an OpenCode ACP runner, not a Goose runner

### Requirement: OpenCode permission validation

The doctor SHALL report the effective OpenCode permission configuration for an
OpenCode ACP runner and SHALL NOT read the Goose permission store. A broad
permission setting SHALL be reported as the actual boundary, not as ACP policy
enforcement.

#### Scenario: Broad OpenCode permission is visible

- **WHEN** `opencode.jsonc` allows shell, write or edit broadly
- **THEN** the doctor reports that boundary for the OpenCode runner

#### Scenario: Doctor does not read Goose

- **WHEN** the doctor validates an OpenCode runner
- **THEN** it does not read or modify `~/.config/goose/permission.yaml`

#### Scenario: ACP policy remains the request gate

- **WHEN** OpenCode sends an ACP permission request
- **THEN** the runner's `policy` and `deny` decide it as before
