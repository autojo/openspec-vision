# Tasks

## 1. Configuration and state foundation

- [x] 1.1 Add the runner fields `start` (`herdr` default, `acp`), `command`,
      `model`, `mode` and `policy` to the config parser and validation, and
      document them in the runner table in `README.md`. Verify with a config
      fixture that the defaults resolve and an unknown `start` value is
      rejected.
- [x] 1.2 Extend the apply state with a `transport` field and an `acp` object
      (session id, model, mode, supervisor pid, control socket, transcript,
      pending permission, last stop reason), keeping old state files
      compatible. Verify with `run_lib` state round-trips and a legacy state
      fixture.
- [x] 1.3 Introduce one `start_runner` path used by `dispatch`, `retrigger` and
      `session`, dispatching on `start` and leaving the Herdr-native start
      byte-for-byte unchanged. Verify that the existing dispatch tests still
      pass and that a native runner still calls `herdr agent start`.

## 2. ACP supervisor

- [x] 2.1 Add `runtime/lib/boss_acp.py` and a small `runtime/bin/boss-acp`
      wrapper that speaks newline-delimited JSON-RPC to `<command> acp`,
      performs `initialize` and `session/new` with the apply root, and closes
      the child on exit. Verify with `python3 -m py_compile`, `bash -n` on the
      wrapper, and a fake peer that asserts the `initialize`/`session/new`
      shapes.
- [x] 2.2 Send the apply prompt, read `session/update` notifications, append
      them to a per-apply JSONL transcript with a size cap, and record the
      `stopReason`. Verify with a fake peer that the transcript contains
      message, tool and usage updates and the final stop reason.
- [x] 2.3 Read `configOptions` and `modes` from `session/new`, apply the
      runner's model and mode, and fail with the offered values when a
      configured value is absent. Verify with fake sessions that advertise and
      omit each option.
- [x] 2.4 Implement the permission policy: deny rules first, then allow rules
      and read-only tools, then `ask` or the runner default. Persist a pending
      request, report `blocked`, and let the control socket answer with a
      selected option. Verify allow, reject and ask with a fake peer that
      inspects the tool input and title.
- [x] 2.5 Implement `session/cancel`, `session/load` and `session/close`,
      including a bounded wait for `cancelled` and a `cancel_unconfirmed`
      state when the agent does not answer. Verify cancel during generation and
      during a tool call, and a load replay that deduplicates by message and
      tool-call id.
- [x] 2.6 Add a hidden `boss acp-event` command that reuses the existing event
      and wake helpers so the supervisor writes the same inbox messages as
      `boss-waiter`. Verify that a fake turn end produces exactly one wake and
      that a parked apply stays quiet.
- [x] 2.7 Add the supervisor heartbeat and a per-apply Unix control socket with
      `answer`, `cancel`, `finish` and `status` commands. Verify a client can
      answer a pending permission and that a stale socket is removed on start
      and exit.

## 3. Dispatch and apply lifecycle

- [x] 3.1 Make `dispatch` and `retrigger` start the ACP supervisor for
      `start = "acp"`, create the apply tab with a transcript tail and no
      agent, write the state before the first prompt, and clean up the tab,
      worktree and socket on a start failure. Verify with a fake peer and a
      worktree fixture.
- [x] 3.2 Count an ACP apply in `open_apply_count` while its supervisor is
      alive, free the slot when it is dead, and wake the boss on a crash.
      Verify with a running fake, a killed fake and a parallel-limit dispatch.
- [x] 3.3 Wire `boss interrupt`, `boss answer`, `boss finish`, `boss status`
      and `boss resume` to the control socket and the ACP state, without
      sending keystrokes or reading a pane. Verify each command against a fake
      peer, including `cancelled`, option selection and `session/close`.
- [x] 3.4 Keep the worktree, lock and slot checks transport-neutral: an ACP
      apply still holds its declared locks and still uses the worktree
      lifecycle. Verify a lock conflict and a slot refusal with one ACP apply
      running.

## 4. Prompt, doctor and documentation

- [x] 4.1 Build the ACP apply prompt from
      `openspec instructions apply --change <change> --json` plus the existing
      charter, lessons, external-verification and commit-policy blocks, and
      assert it contains the change name and no slash command. Verify with a
      prompt-composition unit test.
- [x] 4.2 Extend `boss doctor` to validate an ACP runner only when configured:
      command on `PATH`, successful `initialize`, and an offered model/mode.
      Verify missing command, handshake failure and unknown model.
- [x] 4.3 Install the new supervisor library and wrapper through `install.sh`
      and the runtime manifest, including a `python3 -m py_compile` check in
      CI, and update `README.md` and the boss/vision runner documentation.
      Verify `./scripts/runtime-manifest.sh --verify`, `./install.sh` in a
      temporary HOME, and the CI static checks.
- [x] 4.4 Document the ACP runner example (`start`, `command`, `model`,
      `mode`, `policy`, `apply`) and the `blocked`/`answer`/`interrupt`
      workflow in `README.md`, keeping the shared boss/vision RUN block
      byte-identical. Verify the drift test and the documented commands.

## 5. Integration verification

- [x] 5.1 Add an end-to-end fake-ACP scenario to `tests/run.sh`: dispatch,
      blocked permission, `boss answer`, `end_turn`, status, finish and
      transcript. Verify the suite passes on Linux and the scenario is
      macOS-safe (no GNU-only tools).
- [x] 5.2 Run the full suite, `shellcheck`, `bash -n`, the runtime manifest,
      the wrapper drift check and `openspec validate --all --strict`. Verify
      all commands exit zero.
- [x] 5.3 Run a manual smoke test with a real Goose ACP runner on a trivial
      change: dispatch, watch the transcript, interrupt once, resume/load,
      finish. Verify the state records the stop reasons and the worktree is
      clean; keep this out of CI.

## Workflow follow-up

- Archive the change after the review and the full suite are green.
- Sync the new `acp-runner` spec into the main specs and verify
  `openspec validate --all --strict`.
