# Tasks

## 1. Preflight

- [x] 1.1 Record the branch, commit, worktree path and `git status --short`
      before any gate; verify the worktree is clean and write all four values
      into the report.
- [x] 1.2 Record `boss --version`, `goose --version` and `openspec --version`,
      and run `boss doctor --json`; verify the `acp_runner:goose` check is `ok`
      (or record its failure verbatim in the report).

## 2. Gates

- [x] 2.1 Run `./tests/run.sh`; capture the full log; verify it reports
      `986 passed, 0 failed` and record the log path and tail in the report.
- [x] 2.2 Run `bash -n` over `runtime/bin/*`, `scripts/*.sh`, `install.sh` and
      `tests/run.sh`, `shellcheck -S warning` over the same files, and
      `python3 -m py_compile runtime/lib/boss_acp.py`; verify every command
      exits zero.
- [x] 2.3 Run `./scripts/runtime-manifest.sh --verify`,
      `./scripts/gen-commands.sh --check` and `openspec validate --all --strict`;
      verify every command exits zero and record the manifest file count.
- [x] 2.4 Run `./scripts/check-generated.sh`; record the six stale
      `.opencode/skills` files as the known pre-existing OpenSpec 1.16.0 drift
      and classify it as yellow, not as a review failure.
- [x] 2.5 Run `osv-scanner scan source -r .`; verify the output says no package
      sources (exit 128 with "No package sources found" means nothing to scan)
      and record that explicitly in the report.
- [x] 2.6 Run `git status --short` after the gates; verify no source file
      changed and only the report, its logs and ignored artefacts such as
      `runtime/lib/__pycache__` are present.

## 3. Report

- [x] 3.1 Write `openspec/reviews/vision-skill-external/report.md` with branch,
      commit, worktree, tool versions, a gate table (command, exit code, log
      path), findings, verdict and the isolated-worktree note; verify the file
      exists and covers every gate from group 2.
- [x] 3.2 Write the gate logs under
      `openspec/reviews/vision-skill-external/logs/` (or record stable paths);
      verify every log referenced by the report exists and any failure tail is
      included.
- [x] 3.3 Verify the verdict and classifications: green only for zero-exit
      gates, yellow for the generated drift and the no-package-source scan, and
      red for any real failure; verify no gate is claimed that was not run.

## 4. Explorer handoff

- [x] 4.1 Leave the report and logs uncommitted for the Explorer; verify
      `git status --short` lists only those files and ignored artefacts, and
      that no source file under `runtime/`, `vision/`, `boss/`, `openspec/specs/`
      or `tests/` changed.
- [x] 4.2 Report the verdict, commit, gate summary and evidence paths to the
      Explorer; do not commit, push or archive.

## Workflow follow-up

- The Explorer reviews the report and commits the report/logs before `boss finish`.
- Archive the review change after the report is accepted; the report remains
  under `openspec/reviews/vision-skill-external/`.
- Decide separately whether to regenerate the stale OpenSpec skill files.
