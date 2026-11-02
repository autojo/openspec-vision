# Tasks

## 1. Documentation

- [ ] 1.1 Add Goose to the runner assignment table and describe the ACP
      apply-only limitation (`boss session` rejects it) in `vision/SKILL.md`.
- [ ] 1.2 Document `allow_always` as an agent-level grant and the runner's
      apply-scoped mapping; describe the per-apply profile and the
      `isolate = false` escape hatch.
- [ ] 1.3 State explicitly that the per-apply profile is not a filesystem
      sandbox: shell/write/edit keep the user's OS permissions, and only an OS
      sandbox or a separate user would confine them.
- [ ] 1.4 State that `args` and `env` are native-only, and that ACP supports
      `command`, `model`, `mode`, `policy`, `deny` and `apply`.
- [ ] 1.5 Document the new status fields, the timeout variables and the
      one-wake-per-blocked-transition behaviour after the observability change.
- [ ] 1.6 Document that the installed runtime, not the repository branch, runs
      a new apply; after a merge run `./install.sh` and verify `boss --version`
      plus `acp.isolated`/`profile_root` in the dispatch state.

## 2. Finish gate

- [ ] 2.1 Teach `detect_test_command` the executable `tests/run.sh` and
      `scripts/test.sh` conventions after the existing manifest checks.
- [ ] 2.2 Document `[tests.<project>].command` and `timeout_s`, including the
      need for a budget above the full suite runtime.
- [ ] 2.3 Add a regression test for the new detection and for the manifest
      checks taking precedence.

## 3. Privacy

- [ ] 3.1 Create ACP transcripts with mode `0600` and correct an existing file
      on the next append.
- [ ] 3.2 Create supervisor logs with mode `0600`; leave the state file as is.
- [ ] 3.3 Document that a transcript is retained until the operator removes it
      and that `boss finish` does not delete evidence.

## 4. Verification

- [ ] 4.1 Run the full suite and the static, manifest, wrapper and OpenSpec
      gates; verify all green.
- [ ] 4.2 Verify the worktree contains no change outside the planned files and
      record the gate results for the Explorer.

## Workflow follow-up

These steps are owned by the Explorer and are not part of the apply worktree:

- Correct F3 in `openspec/reviews/vision-skill-external/report.md` on the
  `review/vision-skill-external` branch: the `policy` warning is about the
  `opencode` runner, not the Goose ACP runner, whose default deny list is
  reported as enforced. Name the queue and permission-store issues as the real
  follow-up.
- Remove `[runners.goose-review]` from
  `~/.config/openspec-boss/boss.toml` after the integrity change lands, and keep
  the single `goose` runner with its explicit `policy`.
- Add `openspec-vision = "~/work/vision-skill"` under `[projects]` and
  `[tests.openspec-vision]` with `command = "./tests/run.sh"` and
  `timeout_s = 1800`.
- Verify with `boss doctor`, a dry-run `boss review` and a TOML parse; confirm
  no private project names are added to repository files.
- Decide separately whether to add a transcript retention policy or leave
  cleanup to the operator.
