# Proposal

## Why

ACP applies leave Herdr tabs behind. `boss finish` closes only the tab id stored
in the state; `boss interrupt` closes none. Failed, stopped or retried ACP
applies therefore leave a tab, and repeated dispatches in the same worktree can
leave several tabs with the same label. The operator sees stale OpenCode ACP
tabs that no command will clean up.

## What Changes

- Close the apply tab when an ACP apply is interrupted, after the turn is
  cancelled; add `--keep-tab` for deliberate inspection.
- Make finish close **every** tab belonging to the apply's worktree workspace,
  not only the last recorded tab, before removing the worktree.
- When a dispatch or retrigger reuses an existing worktree, close the previous
  apply tab first or reuse it; keep at most one apply tab per change/worktree.
- Let `boss doctor --fix` close orphaned apply tabs for worktrees and states it
  repairs.
- Cover interrupt, finish, retry and duplicate-tab cases in the regression
  suite and update the skill/README tab lifecycle text.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `acp-runner`: interrupt closes the apply tab by default; `--keep-tab` keeps it.
- `boss-worktrees`: finish cleanup closes every tab of the worktree workspace;
  tab reuse/cleanup for retries and doctor repair.

## Impact

- `runtime/bin/boss-run.sh` (`cmd_interrupt`, `finish_worktree`, `cmd_finish`,
  `cmd_park`), `runtime/bin/boss-apply.sh` (reuse/close on dispatch and
  retrigger), `runtime/bin/boss-lib.sh` (tab lookup/cleanup helpers),
  `runtime/bin/boss-doctor.sh`, `tests/run.sh`, `README.md`, the two skills.
- No change to the ACP protocol, the model selection or the worktree merge/test
  contract. No archived history is changed.
- Closing a tab is a UI action only; the apply state, worktree and branch remain
  readable.
