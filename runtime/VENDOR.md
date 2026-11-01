# Vendored runtime

The files in `bin/` are the boss runtime this repository ships.

- Source: `openspec-boss` (the standalone boss runtime)
- Snapshot commit: `279ca8e58915e0e96f727b918f16e5cbec9e27ea` (2026-10-14)
- Vendored: 2026-10-17
- Runtime version: see `BOSS_VERSION` in `bin/boss-lib.sh` (`boss --version`)

The runtime is licensed under the MIT license; see `LICENSE` in this directory.

## Local changes since the snapshot

The snapshot is the starting point, not the current state. Everything below was
added or changed here and has no upstream counterpart:

- human-task parking, the `waiting_human` state, and the `park` / `resume`
  commands
- mission dependency annotations, per-change mission runners, and the
  `reconcile` gate
- caller identity and wake routing hardening (`boss retrigger --as`,
  `boss claim --as`, wake plans, wake events)
- OpenCode V1/V2 runner support (`--auto` for V2, inline permission env for V1)
- worktree applies, per-change `touches` locks, parallel missions
- command modules: `bin/boss` is now the entry point and the command groups
  live in `bin/boss-{apply,status,review,run,doctor,mission}.sh`
- state and dispatch locking (`lock_acquire` and friends in `bin/boss-lib.sh`)
- the deny policy (`BOSS_POLICY_DENY_DEFAULT`, `policy_check`,
  `--disallowedTools` for claude runners)
- `run_with_deadline` in `bin/boss-lib.sh`, so the integration test runs on
  macOS instead of being skipped for the missing `timeout(1)`

## Updating

Updating the snapshot is a deliberate change, not an automatic sync with the
source repository:

1. Diff the new snapshot against `bin/` and carry the local changes above.
2. Run `./tests/run.sh` - the suite covers the local behaviour, not upstream's.
3. Run `./scripts/runtime-manifest.sh --write` and commit the new
   `MANIFEST.sha256` together with the code.
4. Bump `BOSS_VERSION` when the change is user-visible.
