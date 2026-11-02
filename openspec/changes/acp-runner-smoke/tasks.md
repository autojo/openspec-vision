# Tasks

## 1. Preflight

- [ ] 1.1 Run `boss --version` and `openspec status --change acp-runner-smoke --json`; record the output for the smoke report.
- [ ] 1.2 Run `boss status acp-runner-smoke --json` and verify `.acp.isolated` is true and `.acp.profile_root` is non-null; record both values.

## 2. Concurrent queue

- [ ] 2.1 Issue two separate shell tool calls in the same turn, before reading
      either result: `sleep 3; printf 'alpha\n'` and
      `sleep 3; printf 'beta\n'`. Do not combine them into one shell command.
- [ ] 2.2 After both return, record both outputs and that the Explorer saw two
      pending requests and answered them one at a time by tool-call id.

## 3. Apply-scoped allow-always

- [ ] 3.1 Run exactly `echo smoke-allow-always` once and wait for the Explorer
      to answer with `allow_always`. Record the output.
- [ ] 3.2 Run exactly `echo smoke-allow-always` a second time; it must run
      without a new permission request. Record the output and the fact that no
      new request appeared.

## 4. Interrupt with two pending requests

- [ ] 4.1 Issue two separate shell tool calls in the same turn:
      `sleep 30; printf 'gamma\n'` and `sleep 30; printf 'delta\n'`.
      The Explorer will interrupt once both are pending; do not continue after
      the interrupt.

## 5. Report

- [ ] 5.1 If the turn is still active after step 4, write
      `openspec/reviews/acp-runner-smoke/report.md` with versions, session id,
      isolation, the two parallel ids and outputs, the allow-always result and
      the interrupt outcome. If the interrupt ended the turn, the Explorer
      writes the report instead.

## Workflow follow-up

- The Explorer adds the interrupt evidence and the global permission store check
  to the report, then archives or removes this smoke change.
