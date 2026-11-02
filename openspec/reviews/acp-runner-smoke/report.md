# Smoke report — real Goose ACP runner (`acp-runner-smoke`)

Status: **PASS** — sections 1–4 verified. Queue, answer-by-id, apply-scoped
allow-always and interrupt all work with the real Goose ACP runner.

## Environment

| Item | Value |
| --- | --- |
| boss | `boss 1.2.0 (d4b9b5b)` |
| change | `acp-runner-smoke` (schema `spec-driven`, `skip_specs: true`) |
| project | `/home/ps/work/vision-skill` |
| worktree | `/home/ps/.local/state/openspec-boss/worktrees/6f34b479a2b363e9ce7915181978bfe836f2321e/acp-runner-smoke` |
| branch | `boss/acp-runner-smoke` (base head `760a9045555ce305bee3fa6443082917b3d6ecc8`) |
| runner | `goose` (real Goose ACP runner, not `goose-review`) |
| agent | `apply-acp-runner-smoke` |
| transport / protocol | `acp` / `1` |
| session id | `20261102_1` |
| supervisor pid | `1648300` |
| model / mode / policy | `deepseek-flash` / `smart_approve` / `ask` |
| deny list | `git push --force`, `-f`, `--mirror`, `--delete`, `git filter-branch`, `git filter-repo` |
| transcript | `/home/ps/.local/state/openspec-boss/transcripts/a25e066ce44fa443c39fef49396fbf647f108b6b.jsonl` |
| events | `/home/ps/.local/state/openspec-boss/cycles/6f34b479a2b363e9ce7915181978bfe836f2321e-acp-runner-smoke.events.jsonl` |

### Isolation (task 1.2)

- `.acp.isolated` = `true`
- `.acp.profile_root` = `/home/ps/.local/state/openspec-boss/acp/profile-03f37a763d6bc92577f067c71ee04deabf7690e3`

### `openspec status --change acp-runner-smoke --json` (task 1.1)

`isPlanningComplete: true`, `isComplete: true`; artifacts: proposal `done`,
specs `skipped`, design `done`, tasks `done`; `applyRequires: ["tasks"]`.

## 2. Concurrent queue — PASS

Two shell tool calls were issued in one turn, neither result read before both
were sent:

| # | tool call id | command | output |
| --- | --- | --- | --- |
| 1 | `call_00_OcPXRV5UUq8mJdDGnSNd6371` | `sleep 3; printf 'alpha\n'` | `alpha` |
| 2 | `call_01_aqmNsIFvgwvjJP0XqoaW0006` | `sleep 3; printf 'beta\n'` | `beta` |

Supervisor evidence (events log):

- `19:20:26` — two `acp_permission` events, one per call, landed in the same
  second, both `decision: ask`. Goose really does emit concurrent
  `session/request_permission` messages.
- `19:20:27` — `blocked` with text `blocked on 2 ACP permission requests`
  (both ids listed) — both stayed pending simultaneously.
- `19:20:35` — `acp_permission_answered` for alpha, `allow_once`,
  `apply_allow: false`.
- `19:20:36` — `acp_permission_answered` for beta, `allow_once`,
  `apply_allow: false`.

Answering by tool-call id left the other request pending and worked one at a
time, as designed. No `smart_approve` auto-approval occurred for these commands.

## 3. Apply-scoped allow-always — PASS

Command sent verbatim (no `cd` prefix so the grant matches):
`echo smoke-allow-always`.

1. First run: `19:21:02` `acp_permission` (`call_00_8z2prukztVWZWyU75vMO3393`),
   answered `19:21:08` with `option: allow_once` and **`apply_allow: true`**.
   That is the designed encoding: the human answer `allow_always` is sent to
   Goose as `allow_once` and a boss-side apply grant is recorded.
   - Output: `smoke-allow-always`
   - `.acp.apply_allows` after: `[{ "title": "shell · echo smoke-allow-always",
     "kind": "other", "command": "echo smoke-allow-always" }]`
2. Second run (identical command): `19:21:27` an `acp_permission` entry with
   `apply_allow: true` for `call_00_WSuUcgaZMAQA6vKmjAQh6342`, and **no**
   `blocked`/`wake` and **no** `acp_permission_answered` afterwards. The call was
   auto-granted from the apply allow; no human was prompted.
   - Output: `smoke-allow-always`
   - No new pending request appeared.

Global store check: `~/.config/goose/permission.yaml` still has mtime
`Nov 2 15:24` (before the run started at 19:19) — no global grant was written.

## 4. Interrupt with two pending requests — PASS

The worker issued two separate shell calls in one turn:

| # | tool call id | command |
| --- | --- | --- |
| 1 | `call_00_ET_3OcTaikPQBqY2XijGwZo0246` | `sleep 30; printf 'gamma\n'` |
| 2 | `call_01_ET_is7CFZtaQvCq4qBEVY8k2391` | `sleep 30; printf 'delta\n'` |

Supervisor evidence (events log):

- `19:23:05` — two `acp_permission` events, both `decision: ask`, one per
  tool-call id.
- `19:23:06` — `blocked` with text `blocked on 2 ACP permission requests`;
  both stayed pending.
- `19:23:13` — the Explorer ran `boss interrupt acp-runner-smoke` (controller
  log: `interrupt: rc=0`, status `cancelled`, phase `idle`).
- `19:23:14` — both requests have an `acp_permission_answered` event with
  `decision: cancelled`; `acp_stop` records `stop_reason: cancelled`; the
  settled event is `cancelled`; the `interrupt` event is recorded.
- State after the turn: `idle`, `last_stop_reason: cancelled`, tasks 7/8 (the
  report task was still open at the interrupt and is completed by the Explorer).
- The global `~/.config/goose/permission.yaml` mtime stayed `2026-11-02 15:24:47`,
  before the smoke run; no global grant was written.

## Verdict

**PASS.** With real Goose and `policy = "ask"`:

- two real concurrent permission requests were queued and reported together;
- one request was answered by tool-call id while the other stayed pending;
- an `allow_always` answer became an apply-scoped grant, was sent to Goose as
  `allow_once`, and the identical second command did not prompt again;
- `boss interrupt` cancelled both pending requests and ended the turn with
  `cancelled`;
- the per-apply profile kept the global permission store untouched.

Caveats: this was 17 human/controller answers on one session; the turn timeout
and stall watchdog were not triggered; the profile is not a filesystem sandbox.

## Notes

- Preflight commands were each answered individually with `allow_once`, so the
  worker's own inspection calls produced one pending request at a time; only the
  deliberately parallel blocks produced concurrent requests.
- No product code, spec delta or dependency changed. Report only.
