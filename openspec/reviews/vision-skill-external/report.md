# Vision-skill external review

- **Change:** `vision-skill-external-review` (review-only, `skip_specs: true`)
- **Date:** 2026-11-02, ~12:28–12:39 CET
- **Verdict:** 🟡 **yellow** — every gate passed or is a known pre-existing yellow; no red gate, no source change.
- **Runner:** Goose ACP runner (`boss 1.2.0`), driven by the boss supervisor in an isolated worktree.

## Identity

| Item | Value |
| --- | --- |
| Branch | `boss/vision-skill-external-review` |
| Commit | `7cd8595cc73ee605eed9cf27714ce32d2823c6dc` — "journal: ACP concurrent permission finding" |
| Base commit from design | `9daf7a4` — "fix(boss): make runner start and ACP sockets work on macOS" (2 commits below HEAD) |
| Worktree | `/home/ps/.local/state/openspec-boss/worktrees/6f34b479a2b363e9ce7915181978bfe836f2321e/vision-skill-external-review` |
| `git status --short` before gates | empty — worktree clean |
| Commits on HEAD | 22 |

### Tool versions

| Tool | Version |
| --- | --- |
| boss | `boss 1.2.0 (9daf7a4)` |
| goose | `1.57.0` |
| openspec | `1.16.0` |
| osv-scanner | `2.7.0` (osv-scalibr 0.5.3) |
| shellcheck | `0.10.0` |
| python3 | `3.15.2` |

### Host

`Linux 6.18.50+rpt-rpi-2712 aarch64`, Debian GNU/Linux 13 (trixie), 4 cores, 15 GiB RAM —
i.e. the Raspberry Pi 5 development machine, not an external review station
(see "Scope limitations").

### `boss doctor --json`

Overall `warn` (exit 0), full output in `logs/01-boss-doctor.json`.

- **`acp_runner:goose`: ok** — `command goose, protocol 1, models deepseek-flash,
  deepseek-v4-pro, deepseek-reasoner`. The runner check required by task 1.2 passes.
- `acp_runner:goose-review`: ok.
- Warnings, verbatim, all pre-existing environment/config warnings and unrelated to
  this branch:
  - `project_init`: "run 'openspec init --tools claude,opencode' in <worktree>"
  - `test_command`: "no test command recognized; the review will report not_run" —
    a `.boss` config heuristic; the suite is run directly as `./tests/run.sh` (gate G1),
    which is the authoritative check for this repository.
  - `project_registry`: worktree not listed under `[projects]` in
    `/home/ps/.config/openspec-boss/boss.toml`
  - `caller_identity`: "environment pane wE:pA has cwd /home/ps/work/vision-skill but the
    calling process runs in <worktree>; … caller identity is unverified"
  - `write_access`: "run 'boss doctor --fix' to create the journal/lessons/missions directories"
  - `policy`: the `opencode` runner has no explicit deny for
    `git push --force`, `git push -f`, `git push --mirror`, `git push --delete`,
    `git filter-branch`, `git filter-repo` (the `goose` runner's deny list is separate)

## Gate results

| # | Gate | Command | Exit | Class | Log |
| --- | --- | --- | --- | --- | --- |
| G1 | Full regression suite | `./tests/run.sh` | 0 | 🟢 green — `986 passed, 0 failed` | `logs/10-tests.log` |
| G2a | Bash syntax | `bash -n` over `runtime/bin/*`, `scripts/*.sh`, `install.sh`, `tests/run.sh` (15 files) | 0 | 🟢 green | `logs/11-static-gates.log` |
| G2b | ShellCheck | `shellcheck -S warning` over the same 15 files | 0 | 🟢 green | `logs/11-static-gates.log` |
| G2c | Python syntax | `python3 -m py_compile runtime/lib/boss_acp.py` | 0 | 🟢 green | `logs/11-static-gates.log` |
| G3a | Runtime manifest | `./scripts/runtime-manifest.sh --verify` | 0 | 🟢 green — "runtime matches the manifest (11 files)" | `logs/12-repo-gates.log` |
| G3b | Command wrappers | `./scripts/gen-commands.sh --check` | 0 | 🟢 green — "command wrappers are current" | `logs/12-repo-gates.log` |
| G3c | OpenSpec validation | `openspec validate --all --strict` | 0 | 🟢 green — 7 passed, 0 failed | `logs/12-repo-gates.log` |
| G4 | Generated-file freshness | `./scripts/check-generated.sh` | 1 | 🟡 yellow — known pre-existing drift (F1) | `logs/13-generated.log`, `logs/16-generated-drift-evidence.log` |
| G5 | Dependency scan | `osv-scanner scan source -r .` | 128 | 🟡 yellow — "No package sources found" (F2) | `logs/14-osv-scanner.log` |
| G6 | Worktree after gates | `git status --short` | 0 | 🟢 green — only `openspec/reviews/` untracked | `logs/15-worktree-after.log` |

Suite runtime: 12:29:17 → 12:37:37 (~8 min 20 s) on the Pi 5; the whole gate block
ran 12:29–12:39.

`openspec validate --all --strict` result detail:

```
✓ spec/acp-runner
✓ spec/boss-skill
✓ spec/boss-worktrees
✓ spec/parallel-missions
✓ change/test-timeout-budget
✓ spec/vision-skill
✓ change/vision-skill-external-review
  ℹ [INFO] file: skip_specs is set in .openspec.yaml: change declares no spec-level
    behavior changes, zero deltas accepted
Totals: 7 passed, 0 failed (7 items)
```

## Findings

### F1 — 🟡 pre-existing OpenSpec generated-file drift (six files, not caused by this review)

`check-generated.sh` exits 1 and reports that six `.opencode/skills/**/SKILL.md`
files are stale:

```
openspec instruction files are not current (openspec update --dry-run, rc=0):
6 file(s) would change:
  update  .opencode/skills/openspec-apply-change/SKILL.md  (opencode)
  update  .opencode/skills/openspec-archive-change/SKILL.md  (opencode)
  update  .opencode/skills/openspec-explore/SKILL.md  (opencode)
  update  .opencode/skills/openspec-propose/SKILL.md  (opencode)
  update  .opencode/skills/openspec-sync-specs/SKILL.md  (opencode)
  update  .opencode/skills/openspec-update-change/SKILL.md  (opencode)
Regenerate them with: openspec update
```

Evidence that it predates the review (log `16-generated-drift-evidence.log`):

- `git ls-files -m .opencode/skills` is empty — no skill file is modified in this worktree;
- the last commit touching `.opencode/skills` is `3ade503` "chore(openspec): update tool
  files to 1.15.0" (2026-10-30);
- the installed CLI is `openspec 1.16.0`, so the committed generated files are one
  minor version behind.

Per the design this is **not** fixed here (out of scope for a review-only change);
`openspec update` belongs in a separate change. Any checkout of this commit reproduces it.

### F2 — 🟡 no package sources to scan (nothing to scan, not a failed dependency gate)

```
Scanning dir .
No package sources found, --help for usage information.
```

Exit 128 with "No package sources found" is `osv-scanner`'s way of saying the tree has
no dependency manifests (no `package.json`, `requirements.txt`, `Cargo.toml`,
`go.mod`, …). There is therefore no third-party dependency surface in this repository
to scan: the runtime is Bash plus one Python ACP client using the standard library.
This is recorded as yellow so it is not mistaken for a passing dependency audit, and
not as red because no vulnerability was found nor left unscanned behind a manifest.

### F3 — ℹ️ observations, not gate failures

- `boss doctor` warns that the **`goose` runner** (this review's runner) has no
  destructive-command deny list comparable to `opencode`'s; the review itself ran no
  destructive command, but the runner policy is worth tightening.
- `boss doctor`'s `test_command` heuristic does not recognise `./tests/run.sh`; it
  reports `not_run` even though the suite is green. Cosmetic for this review.
- The worktree is addressed only as a raw `boss` worktree; `caller_identity` stays
  unverified because the supervisor process is not attached to a Herdr pane. This is
  expected for a boss-driven worker and is why the Explorer owns the commit.

## Worktree state after the gates (task 2.6 / 4.1)

Snapshot taken mid-run (`logs/15-worktree-after.log`, right after gate G6) and again at
hand-off (`logs/21-final-handoff.log`). The only tracked-file change is the task-tracking
edit to `openspec/changes/vision-skill-external-review/tasks.md` (13 checkboxes flipped
to `[x]`), which the apply workflow requires; it is expected and is not a source change.

```
$ git status --short
?? openspec/reviews/

$ git status --short --ignored
?? openspec/reviews/
!! runtime/lib/__pycache__/

$ git diff --stat            # tracked files
(empty)

$ git diff --cached --stat   # staged
(empty)
```

- Files added by this review: only `openspec/reviews/vision-skill-external/` (this
  report and `logs/`).
- `runtime/lib/__pycache__/` is a git-ignored artefact produced by `py_compile` (gate G2c).
- **No file under `runtime/`, `vision/`, `boss/`, `commands/`, `openspec/specs/`,
  `openspec/changes/`, `scripts/` or `tests/` was modified, added or deleted.**
- Nothing committed, staged, pushed or archived — the Explorer owns the commit
  (`commit = "explorer"`).

## Verdict

**🟡 yellow.** Eight of the ten gate rows exit zero — seven gate commands (the full
suite `986 passed, 0 failed`, Bash syntax, ShellCheck, Python syntax, runtime manifest,
command wrappers, strict OpenSpec validation) plus the post-gate worktree check. The
two non-zero exits are both expected and pre-existing/by design: the six-file OpenSpec
1.16.0 generated-file drift (F1) and the "no package sources" result of the dependency
scan (F2). No red gate, no regression, and the worktree contains no source change.

This means: the commit under review is sane and the repository's own quality gates
hold; the generated-file drift is the only thing a follow-up should fix, and it is not
caused by this branch.

## Scope limitations

- This ran in an **isolated local boss worktree on the Raspberry Pi 5**, not on a
  separate/external review station as `vision/references/external-review.md` assumes.
  The isolation is a `git worktree` plus the runner's permission policy; it does not
  provide a clean machine, a fresh toolchain or an independent network.
- Consequently the destructive steps of the upstream checklist (`git pull`,
  `git reset --hard`) were deliberately **not** run: there is no upstream branch in a
  boss worktree, and a hard reset could delete the report. The tree was verified clean
  before and after instead.
- CI status on the same commit was **not** re-verified in this run (the design records
  green CI on Linux and macOS for `9daf7a4`); this report claims only what was executed
  above. The runner environment is `aarch64` Linux only.
- This is a **deterministic-gate** review, not a content review of the vision skill's
  prose (summary/generation-quality variant A) — that needs a stronger model and is a
  separate change.

## Evidence

All logs live next to this report and are byte-for-byte the captured output of the
commands listed above (each log starts with `date -Is` and the command line):

| File | Contents |
| --- | --- |
| `logs/00-preflight.txt` | branch, commit, worktree, clean status, tool versions, doctor summary |
| `logs/01-boss-doctor.json` | `boss doctor --json` (pretty-printed, exit 0) |
| `logs/10-tests.log` | `./tests/run.sh` — `986 passed, 0 failed` |
| `logs/11-static-gates.log` | `bash -n`, `shellcheck -S warning`, `py_compile` |
| `logs/12-repo-gates.log` | manifest verify, command wrappers, `openspec validate --all --strict` |
| `logs/13-generated.log` | `check-generated.sh` — six stale files, exit 1 |
| `logs/14-osv-scanner.log` | `osv-scanner scan source -r .` — no package sources, exit 128 |
| `logs/15-worktree-after.log` | `git status --short`, `--ignored`, `git diff --stat` after gates |
| `logs/16-generated-drift-evidence.log` | proof F1 predates this review |
| `logs/20-report-selfcheck.log` | self-check: every referenced log exists, exit codes and counts in the logs match the table above |

## Recommended follow-ups (for the Explorer / separate changes)

1. Decide whether to publish this review branch or attach the report to PR #1.
2. Open a small change that runs `openspec update` to clear the six stale
   `.opencode/skills` files (F1), and re-run `check-generated.sh` there.
3. Consider adding a destructive-command deny list to the `goose` runner policy (F3).
4. Consider a content review of the vision skill's prose with the `goose-pro` runner.

## Explorer addendum (2026-11-02)

The first dispatch of this review used the `goose` runner with
`policy = "ask"`. Goose issued two concurrent shell tool calls (`cat proposal.md`
and `cat design.md; cat tasks.md`), which produced two
`session/request_permission` requests. The ACP supervisor holds a single pending
permission slot, answered only the second request and left the first stranded;
the turn stayed `working` and `boss answer` reported no pending request. The
apply was interrupted and restarted with the `goose-review` runner
(`policy = "allow"`, deny list unchanged), which completed the review.

- Recorded in `openspec/journal.md` (commit `7cd8595`, tag `acp-runner`).
- Follow-up proposal: queue pending permissions by `tool_call_id`, persist the
  queue, surface all entries in `boss status`, answer/clear per id, cancel all on
  interrupt, and add a fake-ACP test with two concurrent requests.
- Because the hung turn wrote no gate logs, the run in this report is the
  `goose-review` run; the report's gate evidence is unaffected.
