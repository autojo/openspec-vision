# Tasks

## 1. Interrupt

- [x] 1.1 Add `--keep-tab` to `boss interrupt` and close the recorded apply tab
      by default after the turn is cancelled or the supervisor is stopped.
- [x] 1.2 Keep the state/worktree readable after closing the tab; a later
      resume/retrigger creates a new tab.

## 2. Finish

- [x] 2.1 Close every tab whose cwd/label belongs to the apply's worktree
      workspace before `herdr_worktree_remove`; keep the base workspace untouched.
- [x] 2.2 Keep the recorded-tab close as a fallback for the base-checkout path
      and for workspaces that cannot be resolved.

## 3. Retry and dispatch

- [x] 3.1 When dispatch/retrigger reuses an existing worktree, reuse the live
      recorded tab; otherwise close stale tabs for that change/worktree before
      creating the new one.
- [x] 3.2 Record the current tab and clear a closed `tab_id`; never leave two
      tabs for one change/worktree.

## 4. Doctor

- [x] 4.1 Extend `boss doctor --fix` to close orphaned apply tabs for the
      worktrees and states it repairs and to report each closed tab.
- [x] 4.2 Keep unrelated tabs in the base project workspace out of the cleanup.

## 5. Tests

- [x] 5.1 Cover interrupt with and without `--keep-tab`.
- [x] 5.2 Cover finish with one tab, a stale extra tab and `--keep-worktree`.
- [x] 5.3 Cover retry/dispatch reuse, duplicate prevention and doctor cleanup.

## 6. Documentation and verification

- [x] 6.1 Document the tab lifecycle and `--keep-tab` in `README.md` and both
      skills.
- [x] 6.2 Run the full suite, shellcheck, `bash -n`, Python compile, manifest,
      wrapper check and `openspec validate --all --strict`.
- [x] 6.3 Run a real ACP apply, interrupt it, finish it and confirm no apply tab
      remains.

## Workflow follow-up

- The stopped `acp-turn-end-reliability` change is separate; this change only
  covers tab lifecycle.
