# Design

## Context

The apply tab is a Herdr shell that tails the ACP transcript; the state records
`tab_id`/`pane_id`. `finish_worktree` closes `tab_id` and calls
`herdr_worktree_remove`, which only removes the worktree. `cmd_finish` closes the
state tab for a base-checkout apply. `cmd_park` closes the state tab.
`cmd_interrupt` cancels the turn but never closes the tab. A retry or a failed
dispatch can create a new tab while an older tab in the same worktree remains.
The current `w7F` tab is a stopped ACP apply; the finished
`runner-model-selection` workspace is gone.

## Goals / Non-Goals

**Goals**

- No stale apply tab after interrupt, finish, park, retry or doctor repair.
- At most one apply tab per change/worktree.
- Keep `--keep-tab` for inspection.

**Non-Goals**

- Closing unrelated tabs in the user's project workspace.
- Changing the merge, test or worktree lifecycle.
- Rewriting Herdr internals; use its tab/workspace API and `boss doctor --fix`.

## Decisions

### 1. Interrupt closes the tab by default

After `session/cancel` (and after the existing cancel confirmation path),
`cmd_interrupt` closes the recorded `tab_id`. `--keep-tab` leaves it for
inspection and records that choice. The state keeps the apply/worktree; a later
resume/retrigger creates a new tab when it runs.

### 2. Finish closes all apply tabs in the worktree

`finish_worktree` resolves the worktree workspace and closes every tab whose cwd
or label belongs to the change/worktree before `herdr_worktree_remove`. This
covers tabs from earlier dispatches whose ids are no longer in the state. The
base-checkout finish keeps closing the recorded tab.

### 3. Retry/dispatch reuses or closes the old tab

When `dispatch_change` reuses an existing worktree/state, it first looks up the
recorded tab and the worktree workspace:
- if the recorded tab is alive, reuse it for the new tail;
- otherwise close any stale tab for the change/worktree and create one new tab.

The state continues to record the current tab. The old `tab_id` is cleared when
it is closed.

### 4. Park and doctor

Park already closes the recorded tab; it keeps the worktree. `boss doctor --fix`
adds a stale-tab cleanup for apply worktrees/states it already repairs, using the
same close-by-workspace helper. The doctor reports any tab it had to close.

## Risks / Trade-offs

- **Closing on interrupt removes the live view** -> `--keep-tab` and the
  transcript preserve inspection.
- **Workspace lookup can be stale** -> close by tab id first, then by workspace
  cwd/label; never touch the base project workspace.
- **A tab close fails while the pane is busy** -> report it, do not fail finish
  or interrupt; `boss doctor --fix` retries.
- **Duplicate tabs from old states** -> finish/doctor close the whole worktree
  workspace, not only the state tab.

## Migration Plan

No data migration. New `--keep-tab` is additive. Existing states keep working;
their recorded tab is closed by finish/interrupt/doctor. A stopped ACP apply can
be cleaned with `boss doctor --fix` or `boss park`.

## Open Questions

None. The operator chose closing tabs by default and keeping a `--keep-tab`
escape hatch.
