# vision-skill Specification

## Purpose
Provide a single self-contained skill that plans a very large software project
feature by feature and then runs the resulting work autonomously as ordered,
versioned missions.

## Requirements

### Requirement: Single self-contained skill
The `vision` skill SHALL provide both planning and autonomous running from one
entry point and SHALL NOT require loading any other skill to complete either
phase.

#### Scenario: Only skill loaded
- **WHEN** the user invokes the vision skill for a large project
- **THEN** the workflow completes plan and run without loading the boss,
  openspec-explore or openspec-propose skills

#### Scenario: Run-only entry
- **WHEN** the user invokes the vision skill for a single existing change
  without planning
- **THEN** the run phase proceeds without requiring the plan phase

### Requirement: Project plan document
The skill SHALL keep the project plan in an `openspec/vision.md` document that
holds the vision, the feature map, the milestone table and the plan status.

#### Scenario: Plan persisted
- **WHEN** the plan phase records a feature or a milestone
- **THEN** it is recorded in `openspec/vision.md`

### Requirement: Phase plan is optional and incremental
The skill SHALL treat the plan phase as optional and, when used, SHALL explore
one feature at a time and create that feature's change(s) immediately after its
exploration, not deferred to the end.

#### Scenario: Change created per feature
- **WHEN** a feature's exploration in the plan phase is complete
- **THEN** the skill creates the feature's change with all required artifacts
  before starting the next feature

### Requirement: Deep per-feature exploration
In the plan phase the skill SHALL conduct a multi-round exploration of each
feature before creating its change, and SHALL NOT create a feature's change
until its scope, options and boundaries are understood.

#### Scenario: Multi-round exploration
- **WHEN** a feature is first taken up in the plan phase
- **THEN** the skill explores it across multiple rounds and records the
  resulting understanding before creating any change for it

### Requirement: All artifacts created up front
For each feature the skill SHALL create all schema-required artifacts of its
change (proposal, specs, design, tasks) during the plan phase.

#### Scenario: Four artifacts per change
- **WHEN** the skill creates a change for a planned feature
- **THEN** the change contains proposal, specs, design and tasks artifacts

### Requirement: Milestones map to missions
The plan SHALL organize work into version milestones, one milestone per
version, and each milestone SHALL be represented as one boss mission whose
change list holds the version's changes; the run phase SHALL process missions
in version order.

#### Scenario: One mission per version
- **WHEN** the plan defines milestones v1, v2 and v3
- **THEN** the skill creates missions v1, v2 and v3 and runs them in that order

### Requirement: Provisional milestone assignment with final sort
The skill SHALL assign each feature to a milestone provisionally when its
change is created, and SHALL perform a final pass before the run that MAY only
re-sort changes between milestone change lists.

#### Scenario: Provisional assignment
- **WHEN** a feature's change is created
- **THEN** it is added to a milestone's change list

#### Scenario: Final sort only reorders
- **WHEN** the plan phase finishes and the final sort pass runs
- **THEN** changes are only moved between milestone change lists and are not
  rewritten

### Requirement: Resumable planning
The plan phase SHALL record its progress so that planning can be interrupted
and resumed across sessions.

#### Scenario: Resume after interruption
- **WHEN** planning is stopped partway and resumed in a later session
- **THEN** the skill determines which features are already explored and
  assigned from the recorded plan status and continues from there

### Requirement: Closed charter before running
The run phase SHALL NOT dispatch a mission until every open question and
authorization entry in that mission's charter is resolved.

#### Scenario: Open charter blocks dispatch
- **WHEN** a mission still has an unresolved open question or authorization
- **THEN** the skill does not dispatch that mission

### Requirement: Autonomous run without mid-run stop
During a run the skill SHALL NOT wait for the human; a new decision mid-run
SHALL be resolved conservatively and reversibly, journalled and reported, and
actions ruled out by the charter SHALL NOT be taken.

#### Scenario: New decision mid-run
- **WHEN** an unforeseen decision appears while a mission runs
- **THEN** the skill chooses the conservative reversible option, journals it
  and continues without stopping

#### Scenario: Prohibited action
- **WHEN** the only path forward requires an action denied by the mission
  charter
- **THEN** the skill does not take it

### Requirement: Refresh before each dispatch
Before dispatching each change the run phase SHALL reconcile the remaining
plan against the applied results and update affected changes.

#### Scenario: Reconcile before dispatch
- **WHEN** a change is about to be dispatched
- **THEN** the skill first reconciles the remaining plan and updates any change
  that no longer holds

### Requirement: Direct CLI operation
The skill SHALL operate the `openspec` and `boss` CLIs directly and SHALL NOT
modify project source code during the plan phase.

#### Scenario: Planning writes no code
- **WHEN** the skill performs the plan phase
- **THEN** it creates planning artifacts and run metadata only and does not edit
  project source code

### Requirement: Global installation
The skill SHALL be installed into the global skill directories of both supported
tools so that it is available in any project, using copies of the skill files
and never symbolic links.

#### Scenario: Available in a project
- **WHEN** the skill is installed and a user works in any project
- **THEN** the skill is available to both supported tools from their global
  skill directories

#### Scenario: Copied, not linked
- **WHEN** the installer finishes
- **THEN** every installed skill file is a regular file and no installed path is
  a symbolic link

### Requirement: Whole skill file set installed
The installer SHALL copy every file under the skill source directory, preserving
relative paths, so that a multi-file skill is installed completely.

#### Scenario: Multiple files
- **WHEN** the skill source contains more than one file
- **THEN** all of them are present in each target directory after installation

### Requirement: Installer replaces a symlink at the target
When a target path already exists as a symbolic link, the installer SHALL remove
the link before copying so that the installed result is a real file tree.

#### Scenario: Existing symlink target
- **WHEN** a target skill path is a symbolic link to another location
- **THEN** installation removes the link and places copied files at that path

### Requirement: Idempotent installation
Running the installer repeatedly SHALL produce the same installed result without
duplicating or nesting files.

#### Scenario: Run twice
- **WHEN** the installer is run a second time
- **THEN** the target contains exactly one copy of each skill file and the
  command succeeds

### Requirement: Install verification

The installer SHALL verify after copying that every installed skill entry file
exists and is a regular file, and SHALL fail with a non-zero status otherwise.

#### Scenario: Verify after install

- **WHEN** installation finishes
- **THEN** the installer checks each installed `SKILL.md` (vision, and boss
  unless disabled) is a regular file and reports failure if one is missing or a
  symlink

### Requirement: Uninstall

The installer SHALL support `--uninstall` to remove the vision skill, an owned
boss skill, the installed runtime binaries and the command wrappers, while
keeping configuration and runtime state; a foreign boss directory SHALL NOT be
removed.

#### Scenario: Uninstall

- **WHEN** the user runs the installer with `--uninstall`
- **THEN** both owned skill files, runtime binaries and command wrappers are
  removed

#### Scenario: Uninstall keeps data

- **WHEN** the user runs the installer with `--uninstall`
- **THEN** `~/.config/openspec-boss` and `~/.local/state/openspec-boss` are not
  removed

#### Scenario: Foreign boss directory kept on uninstall

- **WHEN** the boss skill path is a real directory the installer does not own
- **THEN** `--uninstall` leaves it in place and reports it

### Requirement: Migration documented
The repository documentation SHALL describe the manual steps to migrate from the
boss skill to the vision skill, including that the boss CLI and its command
wrappers remain usable.

#### Scenario: Migration steps available
- **WHEN** a user reads the documentation
- **THEN** it lists the ordered migration steps and states that the boss CLI and
  slash-command wrappers are unaffected

### Requirement: Bundled runtime
The repository SHALL contain the runtime needed to run a mission (`boss`,
`boss-lib.sh`, `boss-waiter`) so that no separate boss installation is
required.

#### Scenario: Runtime present in the repository
- **WHEN** the repository is checked out
- **THEN** the three runtime binaries are present under the repository and are
  executable

#### Scenario: No separate boss install needed
- **WHEN** a user installs only the vision skill
- **THEN** dispatch, waiting and review work without an installed `boss-mode`
  repository

### Requirement: One-command install

A single installer run SHALL install the vision skill and, by default, the
bundled boss skill, together with the runtime and the command wrappers, as
copies and never as symbolic links; `--no-boss-skill` SHALL install vision only.

#### Scenario: One run installs everything

- **WHEN** the user runs the installer once
- **THEN** both skills, the runtime binaries and the command wrappers are
  installed without a second command

#### Scenario: Vision only

- **WHEN** the user runs the installer with `--no-boss-skill`
- **THEN** only the vision skill is installed and no boss directory is created
  or changed

### Requirement: Runtime installation
The installer SHALL copy the runtime binaries into the user's bin directory,
replace an existing symlink at those paths with regular executable files, and
SHALL NOT clear unrelated files from that directory.

#### Scenario: Existing symlink replaced
- **WHEN** the user's `boss` binary is a symbolic link to another repository
- **THEN** after installation it is a regular executable file in the bin
  directory

#### Scenario: Unrelated files survive
- **WHEN** the bin directory contains other executables
- **THEN** installation leaves them in place

### Requirement: Command wrappers installed
The installer SHALL install the `boss` command wrappers for both supported
tools as copies, replacing existing symlinks.

#### Scenario: Wrappers copied
- **WHEN** installation finishes
- **THEN** the opencode and Claude command wrappers are regular files, not
  symlinks

### Requirement: Herdr integration
The installer SHALL install or update the Herdr integration for `opencode` and
`claude` when `herdr` is available.

#### Scenario: Integration refreshed
- **WHEN** the Herdr integration for a supported tool is missing or outdated
- **THEN** the installer installs the current integration for that tool

### Requirement: Prerequisite check
The installer SHALL check for `bash`, `jq`, `python3 >= 3.11`, `openspec` and
`herdr`, and SHALL fail with a clear message naming every missing prerequisite.

#### Scenario: Missing prerequisite
- **WHEN** a required program is missing
- **THEN** the installer stops with a non-zero status and names the missing
  program

### Requirement: Default boss-skill migration

By default the installer SHALL replace an old `boss` skill symlink with the
bundled boss skill, refresh only a boss directory it owns (identified by a
marker), and leave a foreign boss directory untouched and reported unless
`--force-boss-skill` is given.

#### Scenario: Boss skill symlinks removed

- **WHEN** the installer runs and the `boss` skill is installed as a symlink
- **THEN** the link is removed and the bundled boss skill is installed at that
  path

#### Scenario: Owned copy updated

- **WHEN** the boss directory carries the ownership marker of this installer
- **THEN** its files are replaced with the bundled ones

#### Scenario: Foreign boss directory kept

- **WHEN** the boss skill path is a real directory without the ownership marker
- **THEN** the installer leaves it in place and reports it

#### Scenario: Forced replacement

- **WHEN** the installer runs with `--force-boss-skill`
- **THEN** a foreign boss directory is replaced with the bundled boss skill

### Requirement: Runtime attribution
The bundled runtime SHALL include its MIT license and a vendor record naming
the source and version it was copied from.

#### Scenario: Attribution present
- **WHEN** the runtime is bundled
- **THEN** the repository contains the MIT license and a vendor record with the
  source commit
