# Spec Delta

## Purpose

Make the model behind every apply an explicit, confirmed and visible choice,
with a cost limit, a trial before first paid use and a restriction to the
providers a project allows.

## ADDED Requirements

### Requirement: Runner pins one model

A runner SHALL be able to declare one `model` and an optional `effort`, for
native and ACP transports alike. Work on a different model or effort SHALL be
expressed as a different named runner, not as a per-dispatch override.

#### Scenario: One runner per model

- **WHEN** the operator configures two runners with the same agent and different
  models
- **THEN** each dispatch uses the model of the runner named on the mission
  bullet or command line

#### Scenario: Native runner with a model flag

- **WHEN** a native runner of a kind that accepts a model at start declares a
  model and effort
- **THEN** the runtime passes both to the agent at start

#### Scenario: Conflicting declaration

- **WHEN** a runner declares `model` and its `args` also select a model
- **THEN** the runner is rejected with `invalid_runner_model` before anything is
  created

### Requirement: Unpinned runner

A runner is unpinned when it declares no model or its agent kind cannot be given
one at start. Under the policy `strict` an apply with an unpinned runner SHALL
be refused with `model_unpinned`; under `warn` it SHALL start with a warning and
an `unpinned` status.

#### Scenario: Strict refuses

- **WHEN** the policy is `strict` and a change is dispatched with the native
  `opencode` runner that has no model
- **THEN** the dispatch fails with `model_unpinned`, names the pinned runners and
  leaves no tab, worktree or state behind

#### Scenario: Warn starts visibly

- **WHEN** the policy is `warn` and the same runner is dispatched
- **THEN** the apply starts and the dispatch result, status and wake mark the
  model as `unpinned`

#### Scenario: Unpinned ACP runner

- **WHEN** an ACP runner declares no model
- **THEN** it is treated as unpinned and the agent's own default is not presented
  as a chosen model

#### Scenario: Doctor lists unpinned runners

- **WHEN** the doctor runs and the configuration contains unpinned runners
- **THEN** it names each one and the changes of open missions that use it

### Requirement: Model catalog

Every pinned model SHALL have a catalog entry naming its provider and its
billing class `free`, `metered` or `quota`. A model without an entry SHALL be
refused with `model_uncataloged` under the policy `strict`; under `warn` it SHALL
start with a warning that cost and provider are unchecked.

#### Scenario: Entry present

- **WHEN** a runner's model has a catalog entry
- **THEN** the dispatch result names the provider and billing class

#### Scenario: Entry missing

- **WHEN** the policy is `strict` and a runner's model has no catalog entry
- **THEN** the dispatch fails with `model_uncataloged` and names the model

#### Scenario: Entry missing under warn

- **WHEN** the policy is `warn` and a runner's model has no catalog entry
- **THEN** the apply starts and its status marks cost and provider as unchecked

#### Scenario: Alias with expected id

- **WHEN** a catalog entry for an alias declares the model ids it may resolve to
- **THEN** a reported id outside that set counts as a mismatch

### Requirement: Confirmation before the first prompt

When the transport exposes the session configuration, the runtime SHALL read the
model and effort back from the agent after setting them and SHALL send no prompt
until both equal the declared values.

#### Scenario: Confirmed

- **WHEN** the agent reports the declared model and effort
- **THEN** the state records them as confirmed with source and time, and the
  prompt is sent

#### Scenario: Accepted but different

- **WHEN** the agent accepts the setting without an error but reports another
  model or effort
- **THEN** the dispatch fails with `model_mismatch`, names both values and no
  prompt is sent

#### Scenario: Every prompt is guarded

- **WHEN** a retrigger or resume is about to send a further prompt
- **THEN** the same confirmation is repeated first

### Requirement: Confirmation after a native start

For a native agent the runtime SHALL read the model from the agent's own session
record as soon as the first turn exposes it, within a configurable interval, and
SHALL record the result as `confirmed`, `mismatch` or `unverifiable`.

#### Scenario: Session record available

- **WHEN** the agent's session record names the model of the first answer
- **THEN** the runtime compares it with the declared model and records the result

#### Scenario: Nothing readable

- **WHEN** no session record names a model within the interval
- **THEN** the status is `unverifiable`, the boss is woken once, and the declared
  model is not shown as confirmed

#### Scenario: Unverifiable under strict

- **WHEN** the policy is `strict` and the model of a metered runner stays
  unverifiable
- **THEN** the turn is stopped like a mismatch

### Requirement: Metered models need early confirmation

A model of billing class `metered` SHALL only be dispatched through a transport
that confirms the model before the first prompt. Otherwise the dispatch SHALL be
refused with `model_confirmation_late`.

#### Scenario: Metered over ACP

- **WHEN** a metered model is dispatched through an ACP runner that advertises
  its model option
- **THEN** the dispatch continues to the confirmation step

#### Scenario: Metered over a late transport

- **WHEN** a metered model is dispatched through a runner whose model is readable
  only after the first turn
- **THEN** the dispatch is refused with `model_confirmation_late`

#### Scenario: Quota model over a native runner

- **WHEN** a `quota` model is dispatched through a native runner with a model
  flag
- **THEN** the dispatch continues and the model is confirmed after the start

### Requirement: Mismatch stops the apply

A confirmed deviation from the declared model or effort SHALL stop the running
turn, set the model status `mismatch`, keep worktree and state, and wake the boss
with the declared and the actual value. The runtime SHALL NOT continue the apply
until the Explorer acts.

#### Scenario: Wrong model in a native tab

- **WHEN** the session record of a running apply names another model
- **THEN** the turn is interrupted and the boss is woken with both values

#### Scenario: Model changes during the run

- **WHEN** the agent reports a model or effort change after the confirmation
- **THEN** the turn is stopped as a mismatch and the recorded declared model is
  not overwritten

#### Scenario: Work is kept

- **WHEN** an apply is stopped for a mismatch
- **THEN** its worktree, state and transcript remain available for review

### Requirement: No silent fallback

When a declared model or effort is not available, the runtime SHALL fail with
`model_not_offered` or `effort_not_offered`, name the available values and start
nothing. It SHALL NOT substitute another model, effort, runner or the default
runner.

#### Scenario: Model not offered

- **WHEN** the agent does not offer the declared model
- **THEN** the dispatch fails, the change stays startable and no other model is
  used

#### Scenario: Mission does not swap runners

- **WHEN** `boss mission next` selects a change whose model is not offered
- **THEN** it reports the failure for that change and does not dispatch it with
  another runner

#### Scenario: Agent-side fallback

- **WHEN** a runner's arguments enable an agent-side fallback model
- **THEN** the runner is rejected with `model_fallback_configured`

### Requirement: Model in status and wake

The dispatch result, `boss status`, the wake text and `boss review` SHALL show
runner, declared model and effort, confirmed model and effort with source, and
provider. A value that was not read from the agent SHALL be labelled as declared
only.

#### Scenario: Confirmed apply

- **WHEN** status is requested after the confirmation
- **THEN** text and JSON name the confirmed model, effort, source and time

#### Scenario: Not yet confirmed

- **WHEN** status is requested before the confirmation
- **THEN** the model is shown as declared and pending

#### Scenario: Old state

- **WHEN** status reads an apply state written before this capability
- **THEN** the model is shown as `unknown` and the command succeeds

### Requirement: Additional models are visible

The runtime SHALL record every model an apply's main and child sessions report.
A model beyond the declared one SHALL be listed, and one whose provider is not
allowed or whose billing is `metered` and undeclared SHALL be handled as a
mismatch.

#### Scenario: Helper model

- **WHEN** a child session reports another model that the runner lists as an
  allowed helper
- **THEN** status lists it and the apply continues

#### Scenario: Undeclared paid helper

- **WHEN** a child session reports a metered model that the runner does not list
- **THEN** the turn is stopped as a mismatch

#### Scenario: Doctor names configured helpers

- **WHEN** the agent's effective configuration sets other models for helpers
- **THEN** the doctor names them for that runner

### Requirement: Cost display

Status, wake and review SHALL show the cost and tokens an apply has reported so
far together with the billing class. An unreported cost SHALL be shown as
`unknown`, never as zero, and a `quota` model SHALL be shown without a currency
amount.

#### Scenario: Reported cost

- **WHEN** the agent reports a cost
- **THEN** status and wake show the amount, currency, tokens and configured limit

#### Scenario: Cost unknown

- **WHEN** the agent reports no cost
- **THEN** the cost is `unknown` and the reported tokens are still shown

#### Scenario: Quota model

- **WHEN** the model's billing class is `quota`
- **THEN** tokens are shown and no currency amount is claimed

### Requirement: Spending limit per apply

A `metered` model SHALL have a per-apply limit in cost, tokens or both, and SHALL
be refused with `model_limit_missing` otherwise. When the reported use reaches
the limit the runtime SHALL cancel the turn with the stop reason `cost_limit` and
wake the boss.

#### Scenario: Limit reached

- **WHEN** the reported cost or tokens reach the limit
- **THEN** the turn is cancelled, the work is kept and the boss is woken with the
  use and the limit

#### Scenario: Warning threshold

- **WHEN** the reported use passes 80 percent of the limit
- **THEN** status shows a warning once and the turn continues

#### Scenario: Limit spans prompts

- **WHEN** an apply is retriggered or resumed
- **THEN** its earlier use counts against the same limit

#### Scenario: Unknown cost with a token limit

- **WHEN** the agent reports tokens but no cost
- **THEN** the token limit is enforced, and a runner with only a cost limit is
  refused

### Requirement: Trial run before first use

A `metered` model SHALL only receive a change after a recorded, successful trial
run with the same runner command, model and effort. Without one the dispatch
SHALL be refused with `model_untried`.

#### Scenario: First use

- **WHEN** a metered model without a trial record is dispatched
- **THEN** the dispatch is refused and names the trial command

#### Scenario: Trial is small and harmless

- **WHEN** a trial runs
- **THEN** it uses a fixed prompt in an empty temporary directory with its own
  small limit and sends no project content

#### Scenario: Trial record

- **WHEN** a trial succeeds
- **THEN** the record holds the confirmed model and effort, cost, tokens, agent
  version and date

#### Scenario: Trial becomes stale

- **WHEN** the model, effort, command or agent version differs from the record
- **THEN** the trial counts as missing

### Requirement: Trial authorization

A trial of a `metered` model SHALL run only with an explicit spending
confirmation of the operator or a charter authorization that names the model and
an amount. Doctor, status and dispatch SHALL NOT start a trial on their own.

#### Scenario: No confirmation

- **WHEN** a trial of a metered model is requested without a confirmation
- **THEN** nothing is sent and the command names the limit and how to confirm

#### Scenario: Charter authorization

- **WHEN** the mission charter grants a trial for that model up to an amount
- **THEN** the Explorer may run it within that amount and journals the result

### Requirement: Allowed providers per project

A project SHALL be able to list the providers its content may be sent to.
Dispatch SHALL be refused with `provider_not_allowed` when the model's provider
is not listed, and under `strict` also when the project has no list.

#### Scenario: Provider listed

- **WHEN** the model's provider is on the project's list
- **THEN** the dispatch continues

#### Scenario: Provider not listed

- **WHEN** the model's provider is not on the list
- **THEN** nothing is started and the error names the provider and the project

#### Scenario: No list

- **WHEN** a project has no list
- **THEN** `strict` refuses the dispatch and `warn` starts it with a warning

#### Scenario: Gateway provider

- **WHEN** a model is reached through a gateway
- **THEN** the catalog names the gateway and the model vendor, and both must be
  allowed

### Requirement: Honest data boundary

The doctor and the documentation SHALL state that the provider list gates which
provider is used and does not filter what the agent reads. For a runner without
an isolated profile the doctor SHALL name the provider and that the user's agent
profile is in use.

#### Scenario: Non-isolated runner

- **WHEN** the doctor checks a runner with `isolate = false`
- **THEN** its result names the provider and the non-isolated profile

#### Scenario: No sandbox claim

- **WHEN** an allowed provider is reported
- **THEN** the report does not claim that only worktree files can be sent
