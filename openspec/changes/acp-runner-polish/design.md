# Design

## Context

See `proposal.md` - Why. This is the cleanup change after the two runtime
changes. It has no spec delta because it does not introduce or change a
capability requirement; it corrects documentation, tooling defaults, file
permissions and one review artifact. The local operator configuration is part of
the tasks but is not committed to the repository.

## Goals / Non-Goals

**Goals**

- Make the documentation match the ACP runner's actual trust model.
- Make `boss finish` see the repository's suite.
- Keep ACP transcripts and supervisor logs private.
- Correct the wrong finding in the external review report.

**Non-Goals**

- Changing ACP permission or status behaviour (delivered by the two runtime
  changes).
- Rewriting the review report; the errata is additive and keeps the evidence.
- Editing the user's global Goose permission store.

## Decisions

### 1. Documentation describes the runner as it is

- Add Goose to the assignment table in `vision/SKILL.md` and the README, with
  `policy`, `mode` and the apply-only limitation.
- State explicitly that `boss session` rejects an ACP runner with
  `acp_session_unsupported`; it is not a bug and there is no hidden native path.
- State that `args` and `env` are native-only, and that ACP model/mode/policy
  are the supported knobs.
- State that `allow_always` is an agent-level grant. With the integrity change
  the runner maps it to the apply; a user who edits Goose's own config gets a
  global grant and the doctor will report `weakened`.
- Describe the per-apply profile and what it means for provider configuration.

### 2. Test detection knows the repository conventions

`detect_test_command` currently checks `Justfile`, `package.json`, `pytest` and
`Makefile`. Add, after those:

- `tests/run.sh` when it is executable -> `./tests/run.sh`;
- `scripts/test.sh` when it is executable -> `./scripts/test.sh`.

The order keeps project-specific manifests ahead of the generic convention. The
command is run from the project root, which is how `boss finish` invokes it. Add
a `tests/run.sh` case to the regression suite and document
`[tests.<project>].timeout_s`.

*Alternative rejected:* special-case this repository by path. The convention is
generic and the detection is already the place for it.

### 3. Private transcripts

ACP transcripts contain full commands and tool output. Create them with mode
`0600` (open with `O_CREAT|O_WRONLY|O_APPEND`, mode `0600`, and `chmod` after
open so an existing file is corrected). Supervisor logs use the same rule. Do
not change the state file mode; it is already `0600`.

Retention is documented, not implemented: the transcript stays until the
operator removes it, and `boss finish` does not delete it because it is the
evidence for the apply. A future change can add a retention policy.

### 4. Local configuration is an operator task

The local `boss.toml` changes are tasks, not repository changes:

- remove `[runners.goose-review]` once `policy = "allow"` no longer leaks;
- add `openspec-vision = "~/work/vision-skill"` under `[projects]`;
- add `[tests.openspec-vision]` with `command = "./tests/run.sh"` and
  `timeout_s = 1800`.

The tasks record the exact edits and the verification (`boss doctor`, a dry-run
`boss review`).

### 5. Report errata

Append an errata section to `openspec/reviews/vision-skill-external/report.md`:
F3's claim that the Goose runner has no destructive-command deny list is wrong;
the `policy` warning is about the `opencode` runner, while the Goose ACP runner
reports `enforced` with the default deny list. The errata names the actual
follow-up: the permission store and queue issues, not a missing deny list. The
original finding stays visible so the review record is not rewritten.

## Risks / Trade-offs

- **Test detection picks a script that is not a suite** -> require an executable
  file and keep the manifest-based checks ahead of it; a project can override
  with `[tests.<project>]`.
- **Chmod on every open** -> one extra syscall; it also repairs old files.
- **Local config tasks are not reproducible** -> the repo cannot own
  `~/.config/openspec-boss/boss.toml`; the tasks name the exact entries and the
  verification.
- **Errata looks like rewriting history** -> it is additive and keeps F3.

## Migration Plan

No runtime migration. Existing transcripts are chmodded on the next append. The
operator applies the local config edits after the two runtime changes are
merged.

## Open Questions

- Should the repository ship an example `boss.toml` snippet for Goose, or keep
  the documentation generic? The change documents the snippet in the README.
- Should transcript retention be a follow-up change or an operator cron? The
  change documents the expectation and leaves the mechanism out.
