# Proposal

## Why

A runner can start an apply without saying which model does the work. On
2026-11-24 two applies of the native `opencode` runner silently used
`openai/gpt-6.2-sol#high` instead of DeepSeek, because the OpenCode interface
takes the model last chosen by hand. They cost the operator money, and the
Explorer named the wrong model to the operator. Model choice, cost and data
recipient must be explicit, checked and visible for every apply.

## What Changes

- Give every runner a declared `model` and optional `effort`, so one named
  runner stands for one model and effort. **BREAKING** once `strict` is chosen:
  a runner that does not pin a model cannot start an apply.
- Add a model catalog to `boss.toml`: billing class, provider, per-apply limit
  and expected model id for each model.
- Confirm the model and effort that the agent reports, before the first prompt
  where the transport allows it. Stop the apply on a mismatch, also after a
  resume or a change during the run.
- Show wanted and confirmed model, effort, provider and cost in the dispatch
  result, `boss status`, the wake text and the review.
- Remove silent fallback: a model that is not offered fails the dispatch, and
  the mission neither swaps the runner nor uses the default runner for it.
- Enforce a spending limit per apply, and require a small authorized trial run
  before a new metered model gets real work.
- Gate dispatch on a per-project list of allowed providers, and record in the
  charter which data may go to which provider.
- Map task roles (code, hard UI, formula check, second review, ...) to runners.
  Phase PLAN resolves a role to the existing `runner:` bullet; there is no new
  bullet annotation.
- Fix the checks this depends on: the doctor probes an ACP runner with the same
  profile a dispatch uses, and a resumed session is checked as strictly as a
  new one.

## Capabilities

### New Capabilities

- `model-selection`: which model an apply uses, how it is pinned, confirmed,
  shown, limited in cost, tried out before first use and restricted to allowed
  providers.

### Modified Capabilities

- `acp-runner`: effort selection, confirmation of the model after it is set,
  strict re-check on resume, and probes that match the dispatch profile.
- `vision-skill`: Phase PLAN assigns runners by task role and closes the charter
  with model, cost and data decisions.
- `boss-skill`: the shared RUN procedure reacts to model errors and reports only
  confirmed models.

## Impact

- Runtime in this repository (`runtime/bin`, `runtime/lib/boss_acp.py`): runner
  resolution, dispatch, status, waiter, doctor, review and a `boss model`
  command group with its generated wrappers.
- Configuration: new optional `[models]`, `[model_roles]`, `[model_policy]` and
  `[model_providers]` tables and the runner fields `model` (now also native)
  and `effort`. Changing the operator's own `boss.toml` is an operator task.
- Apply state: a new `model` object; old states stay readable.
- Skills: PLAN steps P4/P5 and the byte-identical shared RUN block.
- `boss-mode`: no code in this change. That checkout is an older standalone
  snapshot without ACP, a version or Git, and is not what is installed
  (`~/.local/bin` comes from this repository). Porting is a separate change,
  to be created there only if the snapshot is still maintained; see design.md.
- Depends on nothing in `test-timeout-budget`; the two touch different
  requirements.
- Out of scope: choosing a model automatically by price or quality, provider
  accounts and keys, interactive `boss session` tabs, and filtering what an
  agent reads inside an allowed project.
