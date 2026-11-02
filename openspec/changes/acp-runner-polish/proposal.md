# Proposal

## Why

The ACP runner works, but its documentation and operational edges still describe
the pre-Goose world. The README claims a read-only tool proceeds and the deny
list is enforced without explaining that Goose's `allow_always` is global; the
vision skill has no Goose entry in its runner assignment table and does not say
that `boss session` rejects ACP runners. `boss doctor` reports a `test_command`
warning for this repository because `detect_test_command` does not know
`tests/run.sh`, so `boss finish` records `merge_test: not_run` even though the
suite exists. Transcripts are created world-readable (`0664`) and contain full
commands and tool output. The external review report also contains a wrong
finding: its F3 attributes the `policy` warning to the Goose runner, while the
warning is about `opencode`. The documentation also makes the isolated profile
sound like a filesystem boundary, and it does not say that a merged runtime
change must be installed before the next ACP dispatch.

## What Changes

- Correct the runner documentation: Goose in the assignment table, ACP session
  limitation, `args`/`env` native-only, `allow_always` persistence warning,
  isolated-profile behaviour and the meaning of `policy = "allow"` as
  auto-allow-once. State that the profile isolates Goose's own state, not the
  filesystem: the agent keeps the user's OS permissions.
- Document the operational prerequisite that a merged runtime change must be
  installed (`./install.sh`) before the next ACP dispatch, and how to verify it
  (`boss --version`, `acp.isolated`/`profile_root` in the state).
- Teach `detect_test_command` the repository's own `tests/run.sh` and
  `scripts/test.sh` conventions, and document `[tests.<project>].timeout_s`.
- Create ACP transcripts and supervisor logs with mode `0600`, and document a
  retention/cleanup expectation.
- Record the local operator follow-up: remove the now-redundant
  `goose-review` runner, register the project in `boss.toml`, and configure the
  suite timeout locally. These are not repository changes.
- Record the review-branch follow-up: correct F3 in
  `openspec/reviews/vision-skill-external/report.md` with a short errata note
  instead of rewriting the evidence. The report lives on the review branch, not
  on this change's branch.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

None. This is a documentation, tooling and local-configuration cleanup. The
runtime has no finish-gate capability to amend, and the transcript permission
change hardens existing behaviour rather than changing a requirement, so the
change sets `skip_specs: true`.

## Impact

- `README.md`, `vision/SKILL.md`, `runtime/bin/boss-review.sh` (test detection),
  `runtime/lib/boss_acp.py` and the supervisor log/transcript creation,
  `tests/run.sh`, `openspec/reviews/vision-skill-external/report.md`.
- Local operator state: `~/.config/openspec-boss/boss.toml` (remove
  `goose-review`, register `openspec-vision`, add `[tests.openspec-vision]`).
- No dependency changes and no change to the ACP protocol.
