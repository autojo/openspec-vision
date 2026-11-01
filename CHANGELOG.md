# Changelog

## 1.1.1

### Fixed

- The integration test (`[tests]` in the config, `merge_test` in the review)
  was skipped on macOS, where `timeout(1)` does not exist (coreutils installs it
  as `gtimeout`). The runtime now runs it through `run_with_deadline`, which
  uses `timeout`/`gtimeout` when present and a watchdog subshell otherwise, so
  the result is no longer a silent `not_run` on macOS.
- The regression suite failed on macOS: it called `timeout` directly and made a
  dummy waiter with `exec -a` (bash 4). It now uses the runtime's
  `run_with_deadline` through a `deadline` stub and a real script named
  `boss-waiter`, so the checks run on bash 3.2 as well.

## 1.1.0

Correctness and hardening pass over the runtime, driven by a review of the
three checkouts (`openspec-herdr`, `boss-mode`, this one).

### Fixed

- A usage error produced invalid JSON when the offending argument contained a
  quote (`usage_error` now builds its output with jq, with an escaped fallback).
- `ensure_config` reported "generated config" even when the write failed; it now
  fails with `config_write` and removes the half-written file.
- The state file was updated read-modify-write without serialization; the
  waiter, `retrigger`, `finish` and `park` could drop each other's fields. All
  state writes now take a per-apply lock.
- Two bosses could pass the "already running" check and start the same change
  twice; dispatch is now serialized per change (`dispatch_busy`).
- `waiter_alive` matched any process whose arguments contained `boss-waiter`;
  it now matches the executable name.
- `now_ms` had one-second resolution even where the platform offers
  milliseconds.
- The OpenCode unknown-version warning test asserted on stderr, which the
  runtime no longer writes to.

### Added

- `boss --version` prints the runtime version and the commit it came from
  (`-dirty` for a checkout with uncommitted runtime changes).
- Deny policy: `BOSS_POLICY_DENY_DEFAULT` and `[runners.<name>] deny = [...]`.
  Claude runners get `--disallowedTools`; OpenCode runners are verified against
  their effective permission rules. Every dispatch result carries a `policy`
  object, `boss doctor` reports a `policy` check, and the run procedure says how
  to react. The boss session itself is exempt - its charter may grant a
  force-push of its own branch.
- `scripts/gen-commands.sh` generates the 34 command wrappers from
  `commands/commands.tsv`; `--check` fails on drift.
- `scripts/runtime-manifest.sh` records and verifies the vendored runtime hashes
  (`runtime/MANIFEST.sha256`).
- `scripts/check-generated.sh` fails when the OpenSpec instruction files are not
  what `openspec update` would write.
- CI: syntax, shellcheck, manifest, generator drift, and the regression suite on
  Linux and macOS (bash 3.2).

### Changed

- `bin/boss` is split into command modules (`boss-apply.sh`, `boss-status.sh`,
  `boss-review.sh`, `boss-run.sh`, `boss-doctor.sh`, `boss-mission.sh`); the
  worktree checks of `doctor` moved into their own function.
- The installer writes `.boss-runtime-commit` and `.boss-runtime-origin`, warns
  when it replaces a runtime it did not install, and installs the new modules.
- The regression suite writes runtime logs to a file instead of the test output,
  and works without GNU `sha1sum` (macOS). It also covers the installer's
  runtime file list, the `.boss-runtime-commit`/`.boss-runtime-origin` stamps,
  the "replacing the boss runtime" warning and the `--version` output of an
  installed copy.
- README: trust model, repository layout, language policy. `runtime/VENDOR.md`
  lists the local changes and how to update the snapshot.
- The skills' `metadata.version` is 1.1.0; the stale `embeddedFrom` date is
  replaced by a pointer to the shared run block.
