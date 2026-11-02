# Tasks

## 1. Preflight

- [x] 1.1 Run `boss --version` and `openspec status --change acp-runner-smoke --json`; record the output for the smoke report.
      - `boss --version` → `boss 1.2.0 (d4b9b5b)`
      - `openspec status` → schema `spec-driven`, `isPlanningComplete: true`, proposal/design/tasks `done`, specs `skipped` (skip_specs), root = worktree `6f34b479.../acp-runner-smoke`.
- [x] 1.2 Run `boss status acp-runner-smoke --json` and verify `.acp.isolated` is true and `.acp.profile_root` is non-null; record both values.
      - `.acp.isolated` = `true`
      - `.acp.profile_root` = `/home/ps/.local/state/openspec-boss/acp/profile-03f37a763d6bc92577f067c71ee04deabf7690e3`
      - session_id `20261102_1`, runner `goose`, mode `smart_approve`, policy `ask`, transport `acp`, agent `apply-acp-runner-smoke`.

## 2. Concurrent queue

- [x] 2.1 Issue two separate shell tool calls in the same turn, before reading
      either result: `sleep 3; printf 'alpha\n'` and
      `sleep 3; printf 'beta\n'`. Do not combine them into one shell command.
      - Issued as two parallel shell calls in one assistant turn; neither result read before both were sent.
- [x] 2.2 After both return, record both outputs and that the Explorer saw two
      pending requests and answered them one at a time by tool-call id.
      - Outputs: call 1 → `alpha`; call 2 → `beta`.
      - Events log: two `acp_permission` events at 2026-11-02T19:20:26+0100
        (`call_00_OcPXRV5UUq8mJdDGnSNd6371` = `sleep 3; printf 'alpha\n'`,
        `call_01_aqmNsIFvgwvjJP0XqoaW0006` = `sleep 3; printf 'beta\n'`), and a
        `blocked` event with text `blocked on 2 ACP permission requests`.
      - Answered sequentially by tool-call id: alpha `allow_once` at 19:20:35,
        beta `allow_once` at 19:20:36 (both `apply_allow: false`). The second
        request stayed pending while the first was answered — queue verified.

## 3. Apply-scoped allow-always

- [x] 3.1 Run exactly `echo smoke-allow-always` once and wait for the Explorer
      to answer with `allow_always`. Record the output.
      - Command sent verbatim (no `cd` prefix), so the grant matched.
      - Output: `smoke-allow-always`.
      - Events: `acp_permission` at 19:21:02 (`call_00_8z2prukztVWZWyU75vMO3393`),
        answered 19:21:08 with `option: allow_once`, `apply_allow: true` — i.e. the
        allow-always answer is sent to Goose as `allow_once` plus an apply-scoped grant.
      - `.acp.apply_allows` afterwards: `[{title: "shell · echo smoke-allow-always",
        kind: "other", command: "echo smoke-allow-always"}]`.
- [x] 3.2 Run exactly `echo smoke-allow-always` a second time; it must run
      without a new permission request. Record the output and the fact that no
      new request appeared.
      - Output: `smoke-allow-always` — ran.
      - Events: at 19:21:27 an `acp_permission` entry for the same command
        (`call_00_WSuUcgaZMAQA6vKmjAQh6342`) carries `apply_allow: true` and is
        followed by **no** `blocked`/`wake` and **no** `acp_permission_answered`.
        Auto-granted from the apply allow; no human prompt, no second question.
      - Global store `~/.config/goose/permission.yaml` untouched (mtime
        `Nov 2 15:24`, before the run started at 19:19).

## 4. Interrupt with two pending requests

- [x] 4.1 Issue two separate shell tool calls in the same turn:
      `sleep 30; printf 'gamma\n'` and `sleep 30; printf 'delta\n'`.
      The Explorer will interrupt once both are pending; do not continue after
      the interrupt.
      - Issued as two parallel shell calls in one turn (tool-call ids recorded in
        the events log). Report draft is already at
        `openspec/reviews/acp-runner-smoke/report.md`; if the interrupt ends this
        turn the Explorer appends section 4 and writes the final verdict.

## 5. Report

- [x] 5.1 If the turn is still active after step 4, write
      `openspec/reviews/acp-runner-smoke/report.md` with versions, session id,
      isolation, the two parallel ids and outputs, the allow-always result and
      the interrupt outcome. If the interrupt ended the turn, the Explorer
      writes the report instead.

## Workflow follow-up

- The Explorer adds the interrupt evidence and the global permission store check
  to the report, then archives or removes this smoke change.
