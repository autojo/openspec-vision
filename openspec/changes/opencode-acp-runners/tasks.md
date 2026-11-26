# Tasks

## 1. Remove the Goose runtime

- [x] 1.1 Remove `build_agent_profile` and the Goose `config/goose`/`data/goose`
      paths from `runtime/lib/boss_acp.py`; an OpenCode command runs with the
      global OpenCode config and `isolate = false`.
- [x] 1.2 Remove `acp_permission_store_path` and the Goose permission-store
      reader from `runtime/bin/boss-lib.sh`; keep the generic ACP `policy`,
      `deny` and grant path.
- [x] 1.3 Update `runtime/bin/boss` and `runtime/bin/boss-doctor.sh` error and
      probe messages so they name `opencode` rather than Goose.

## 2. OpenCode runners and models

- [x] 2.1 Validate an OpenCode ACP runner: command, handshake, `model`, `effort`,
      `mode = ""`, `isolate = false`; reject `isolate = true` for OpenCode.
- [x] 2.2 Teach the doctor to report the effective OpenCode permission
      configuration and never read the Goose store.
- [x] 2.3 Add the OpenCode runner examples for at least two models and document
      the default runner; use the merged `model`/`effort` selection.

## 3. Remove Goose from docs and skills

- [x] 3.1 Replace the Goose ACP section in `README.md` with `opencode acp`,
      `mode = ""`, `isolate = false`, model/effort and multiple runners.
- [x] 3.2 Rewrite the ACP sections in `vision/SKILL.md` and `boss/SKILL.md`; keep
      the shared RUN block byte-identical.
- [x] 3.3 Replace the Goose runner-assignment examples in the vision skill with
      `opencode-*` ACP runners; native `opencode` remains for `boss session`.

## 4. Tests and fixtures

- [x] 4.1 Rename `fake-goose` and Goose-specific fixtures to
      `fake-opencode`; keep the ACP fake protocol generic.
- [x] 4.2 Update the ~100 Goose references in `tests/run.sh`, including the
      profile, permission, doctor and ACP smoke cases.
- [x] 4.3 Add a regression that an OpenCode runner uses the global profile and
      that no Goose profile or permission file is created.

## 5. Verification

- [x] 5.1 Verify the active tree, README, both skills, runtime and tests contain
      no Goose runner/profile/permission fragments; archived changes are exempt.
- [x] 5.2 Run the full suite, shellcheck, `bash -n`, Python compile, manifest,
      wrapper check and `openspec validate --all --strict`.
- [x] 5.3 Run a real OpenCode ACP smoke apply with `opencode-deepseek` and
      confirm `model = deepseek/deepseek-flash`, `isolate = false` and one tab.

## 6. Operator configuration

- [x] 6.1 [Nutzer] Remove `[runners.goose]` and `[runners.goose-review]` from
      `~/.config/openspec-boss/boss.toml`; set `default = "opencode-deepseek"`.
- [x] 6.2 [Nutzer] Add the OpenCode runners and catalog/roles for the models that
      should be used; run `boss doctor` and `boss model list`.
- [ ] 6.3 [Nutzer] Install the resulting runtime with `./install.sh` after the
      change is merged.

## Workflow follow-up

- Do not rewrite archived changes or Git history.
- The stopped `acp-turn-end-reliability` change is not part of this change.
