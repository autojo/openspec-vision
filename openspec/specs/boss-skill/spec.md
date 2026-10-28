# boss-skill Specification

## Purpose
Provide a standalone boss skill that runs OpenSpec changes and missions from one
session without the large-project planning phase, shipped from the same
repository as the vision skill and driven by one shared run procedure.

## Requirements

### Requirement: Standalone Explorer skill

The repository SHALL ship a `boss` skill whose procedure is self-contained: it
dispatches, reviews, retriggers, parks, resumes, retargets, interrupts and
finishes OpenSpec changes, including changes in a mission, without loading the
vision skill or any other skill.

#### Scenario: Single change without a plan

- **WHEN** the user asks to run one existing change with the boss skill
- **THEN** the skill dispatches, reviews and finishes that change without
  creating or reading `openspec/vision.md`

#### Scenario: Mission change

- **WHEN** the change belongs to a mission
- **THEN** the skill applies the mission order, the reconcile gate and
  `boss mission next` exactly as a planned run does

#### Scenario: Human endpoints

- **WHEN** only marked human tasks remain, or the human reports progress
- **THEN** the skill parks the change or resumes it instead of retriggering it

#### Scenario: No other skill loaded

- **WHEN** the skill runs any phase
- **THEN** it never invokes another skill or a tool-specific planning command

### Requirement: Shared run procedure

The boss skill SHALL reuse the vision skill's phase-RUN procedure as one shared
text block, delimited by markers in both skill files, and editing either copy
alone SHALL be detectable.

#### Scenario: Identical shared block

- **WHEN** both installed skill files are compared
- **THEN** the marked run-procedure blocks are byte-identical

#### Scenario: Drift is detected

- **WHEN** a change edits the run procedure in only one of the two skill files
- **THEN** the repository test fails and names the command that re-synchronises
  the block

### Requirement: Disjoint skill descriptions

The frontmatter descriptions of `boss` and `vision` SHALL describe disjoint
scopes so a session selects the right skill: `boss` for a single change or a
small ad-hoc batch without a plan, `vision` for a large project and ordered
version missions.

#### Scenario: Single change selects boss

- **WHEN** the user asks to dispatch, review or finish one OpenSpec change
- **THEN** the request matches the boss skill's description

#### Scenario: Large project selects vision

- **WHEN** the user asks to plan a large project or run several version missions
- **THEN** the request matches the vision skill's description
