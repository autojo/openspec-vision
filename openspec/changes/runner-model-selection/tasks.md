# Tasks

## 1. Decisions

- [x] 1.1 [Nutzer] Answer the eight Open Questions in design.md. Prüfen: every
      question has a decision in design.md, and a decision that differs from the
      recommendation is worked into the specs and tasks before group 2 starts.

## 2. Configuration and runner resolution

- [ ] 2.1 Accept `model` and `effort` on native and ACP runners, pass them to
      `claude` as start flags, and reject a double declaration
      (`invalid_runner_model`) and fallback flags (`model_fallback_configured`).
      Verify with config fixtures for each kind and both errors.
- [ ] 2.2 Read `[models]`, `[model_policy]`, `[model_roles]` and
      `[model_providers]` with validation (billing class, positive limits, known
      runner names). Verify valid, missing and invalid fixtures, and that a
      config without these tables behaves as before under `warn`.
- [ ] 2.3 Refuse `model_unpinned`, `model_uncataloged`, `model_limit_missing` and
      `provider_not_allowed` before a tab, worktree or state exists, and warn
      under `warn`. Verify each error leaves nothing behind.
- [ ] 2.4 Document the tables, fields and error codes in `README.md`. Verify the
      documented snippet parses with the runtime's config reader.

## 3. ACP confirmation

- [ ] 3.1 Set model, then effort (category `thought_level`), read both back from
      the returned configuration, and fail with `model_not_offered`,
      `effort_not_offered` or `model_mismatch`. Verify with the fake ACP agent,
      including an agent that accepts a value and reports another.
- [ ] 3.2 Repeat the confirmation before every prompt and after `session/load`,
      also when the load returns no config options. Verify retrigger, resume and
      the missing-options case.
- [ ] 3.3 Treat a later `config_option_update` that deviates as a mismatch:
      cancel the turn, keep the declared value, wake once. Verify with the fake
      agent.
- [ ] 3.4 Make the doctor probe a non-isolated runner in the user's profile, check
      the effort, close and delete the probe session, and report a remaining one.
      Verify isolated and non-isolated fixtures and that no prompt is sent.
- [ ] 3.5 Update the ACP sections of `README.md` (effort, confirmation, probe).
      Verify the documented doctor call against the fake agent.

## 4. Native confirmation

- [ ] 4.1 Add a session-record adapter for `claude` (transcript model, ignoring
      synthetic entries) and for OpenCode 2 (session API), both read-only.
      Verify with recorded fixtures without personal content, and that an
      unknown format yields `unverifiable`.
- [ ] 4.2 Let the waiter run the adapter after the first answer, record the
      result, and interrupt on a mismatch or on `unverifiable` for a metered
      model. Verify confirmed, mismatch, timeout and one-wake behavior.
- [ ] 4.3 Refuse a metered model on a late transport with
      `model_confirmation_late`. Verify the native and the ACP case.
- [ ] 4.4 Document per transport when a model is confirmed. Verify the README
      table matches the tested cases.

## 5. Visibility and cost

- [ ] 5.1 Add the `model` object to the apply state and show it in the dispatch
      result, status (text and JSON, single and aggregate), wake and review; an
      old state reads as `unknown`. Verify all six status values.
- [ ] 5.2 Collect cost and tokens across prompts and show them with the billing
      class; unknown cost is never zero. Verify cost, token-only and quota
      fixtures.
- [ ] 5.3 Check which usage OpenCode 2.4.1 reports over ACP during and after a
      turn, using only a run that takes place anyway, and record the result in
      design.md. Verify the limit code matches the recorded fields.
- [ ] 5.4 Enforce the limit with the 80 percent warning and `cost_limit`, across
      retrigger and resume. Verify each with the fake agent.
- [ ] 5.5 Record models of child sessions, allow listed helpers, and stop on an
      undeclared metered one. Verify both, plus the doctor's helper listing.
- [ ] 5.6 Document cost display, overshoot by one turn and the provider-side cap
      in `README.md`. Verify the documented status output matches a test run.

## 6. Trial and commands

- [ ] 6.1 Add `boss model list`, `check` and `trial` with the generated wrappers
      for both tools. Verify `check` sends no prompt and the wrapper drift check
      passes.
- [ ] 6.2 Require `--confirm-spend` or the charter amount, use an empty directory
      and the fixed prompt, and write the trial record. Verify refusal, success
      and that no project path or content is sent.
- [ ] 6.3 Refuse `model_untried` and treat a changed model, effort, command or
      agent version as missing. Verify each stale reason.
- [ ] 6.4 Document the onboarding order for a new model. Verify the commands run
      as written against the fake agent.

## 7. Skills

- [ ] 7.1 Update `vision/SKILL.md` P4 and P5: roles to runners, kept operator
      annotations, second review by another vendor, and the charter's model, cost
      and data decisions. Verify every scenario of the vision-skill delta has a
      matching instruction.
- [ ] 7.2 Update the shared RUN block in both skills: check the model after
      dispatch, report only confirmed models, and react to each model error.
      Verify the drift test and that every error code is named.
- [ ] 7.3 Add `## Runner Policy` columns to the charter skeleton and keep the gate
      closed for a metered runner without an authorization amount. Verify with
      mission fixtures, including an existing charter without the columns.
- [ ] 7.4 Update `CHANGELOG.md` and the migration notes. Verify they name the
      order of the Migration Plan.

## 8. Integration

- [ ] 8.1 Add an end-to-end regression: pinned ACP runner, mismatch, missing
      model, limit and mission that does not swap runners. Verify the full suite
      passes.
- [ ] 8.2 Run `./tests/run.sh`, `shellcheck`, `bash -n`, the runtime manifest, the
      wrapper drift check, `osv-scanner` and `openspec validate --all --strict`.
      Verify all exit zero.
- [ ] 8.3 [Nutzer] Update the own `boss.toml` (catalog, runners, roles, providers,
      default) and authorize the trials. Prüfen: `boss doctor` names no unpinned
      runner in use, and `boss model list` shows a valid trial for every metered
      model.

## Workflow follow-up

- Archive the change after review and sync the specs.
- If the `boss-mode` snapshot is still maintained, create a separate change in
  that project; do not edit it from this one.
- Consider a follow-up for the ACP `mode` config option of OpenCode.
