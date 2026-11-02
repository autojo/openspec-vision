# Design

## Context

`vision/references/external-review.md` describes a review pass on a station that
does not change the repository: record the commit, build, test, run
`osv-scanner`, restore the tree and report. The boss ACP runner is a different
environment: a detached supervisor drives `goose acp` in an isolated worktree,
and the worker writes a report for the Explorer.

The review branch is based on `change/goose-acp-runner` (`9daf7a4`), so the
vision skill includes the ACP section and the timeout gate. The full suite
currently reports 986 green tests; CI on that commit is green on Linux and
macOS. The active `test-timeout-budget` change is part of the branch.

## Goals / Non-Goals

**Goals**

- Run the external review checklist on the vision-skill repository through the
  Goose ACP runner.
- Produce a report with commands, exit codes, log paths, findings and a verdict.
- Exercise the runner's session, permission, transcript, cancel and finish
  paths without changing the skill.

**Non-Goals**

- Fixing the findings (including the pre-existing generated-file drift).
- Editing source, runtime, specs or dependencies.
- Publishing the review branch or the report.
- A content review of the skill's prose (that is the separate meta-review
  variant).

## Decisions

### 1. Review-only change with `skip_specs`

The change has no capability delta. It sets `skip_specs: true` and carries a
proposal, a design and tasks only. The report lives outside the change under
`openspec/reviews/vision-skill-external/`, so archiving the change does not
remove the evidence.

*Alternative rejected:* a spec capability for "reviews". A review is an
activity, not a durable behavior; inventing a requirement would be noise.

### 2. Adapt the external checklist to an isolated worktree

The checklist's `git pull` and `git reset --hard` do not fit a boss worktree:
there is no upstream branch, and a destructive reset could delete the report.
The tasks therefore:

- record branch, commit and `git status --short` instead of pulling;
- never run a destructive reset;
- check that no source file changed;
- treat the report and ignored artefacts (for example `__pycache__`) as the
  only allowed new files.

The worktree is isolated but local, not an external station. The report says so
instead of claiming a separate machine.

### 3. Gate set and expected classifications

The gates are the full suite, Bash syntax, shellcheck, Python syntax, runtime
manifest, command wrappers, OpenSpec validation, the dependency scan and a final
worktree check.

Two gates are expected to be yellow rather than green:

- `scripts/check-generated.sh` reports six stale `.opencode/skills` files
  because the installed OpenSpec is 1.16.0 and the generated files predate it.
  This is present on `HEAD` and must not be fixed in this review.
- `osv-scanner` finds no package sources; exit 128 with "No package sources
  found" means "nothing to scan", not a failed dependency gate.

The report must distinguish these from a red gate.

### 4. Permissions through the runner policy

The configured `goose` runner uses `mode = "smart_approve"` and
`policy = "ask"`. Read/search/think tools pass automatically; shell commands,
the suite and the report write become `blocked` requests. The Explorer answers
with `boss status` and `boss answer <change> <option>`; `allow_always` on the
shell tool is the intended way to avoid a prompt per command. The default deny
list stays active.

*Alternative rejected:* `policy = "allow"` for an unattended review. It would
hide the permission path that this change is meant to exercise.

### 5. Isolation and ownership

The worker runs in the boss worktree and may write only the report and its
logs. The runner uses `commit = "explorer"`; the worker does not commit, push or
archive. The Explorer reviews the report and the worktree diff, then commits the
report and finishes the change. A source edit by the worker is a review finding,
not an accepted outcome.

### 6. Runner and model

The deterministic gates do not need a stronger model; the current Goose model
(flash) is sufficient for running commands and writing the report. A content
review of the skill's prose (variant A) would use a `goose-pro` runner with a
stronger model, but that is not this change.

### 7. Report format

The report contains:

- branch, commit, worktree path and the installed tool versions;
- one row per gate: command, exit code, log path;
- the two expected yellow classifications;
- a verdict (`green`, `yellow` or `red`);
- the note that this is an isolated local worktree, not an external station;
- the final `git status --short` and a list of changed files.

Logs live next to the report under `logs/`; the report references them and
includes the tail of any failing output.

## Risks / Trade-offs

- **Long suite and repeated prompts** -> use `allow_always` for the shell tool;
  the suite takes several minutes and the ACP turn has no default timeout.
- **Pre-existing generated drift** -> report it as a finding; do not regenerate
  in the review. A follow-up change can run `openspec update`.
- **No package sources** -> record "nothing to scan" explicitly so it is not
  mistaken for a missing dependency check.
- **Local worktree is not an external station** -> state the limitation in the
  report; the CI on the same commit is the independent evidence.
- **Worker edits source** -> tasks forbid it; the Explorer reviews the diff and
  the report; a source edit is rejected.
- **Report write blocked** -> the Explorer answers the write permission; the
  report is the deliverable, not an implementation detail.
- **Review branch not published** -> the branch and report stay local until the
  Explorer decides; PR #1 is unaffected.

## Migration Plan

No runtime or data migration. Create the review branch, commit the plan, run
the review in a worktree, review the report, commit it and finish the change.
Archive the review change after the report is accepted; the report remains
under `openspec/reviews/`.

## Open Questions

- Whether to publish the review branch or attach the report to PR #1.
- Whether to fix the generated-file drift in a separate change.
