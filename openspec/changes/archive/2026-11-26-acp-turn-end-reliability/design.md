# Design

## Context

`AcpClient.reader_loop` reads the child's stdout with `asyncio` streams and their
default limit of 64 KiB. A longer line raises `ValueError` from `readline()`. The
call is not guarded, the task is not awaited, and `closed` is not set, so:

1. the reader task ends with an exception nobody sees;
2. the open prompt future never resolves;
3. `on_closed` never runs, so the supervisor still believes the child is there;
4. the stall watchdog reports `stalled` after 30 minutes, the turn timeout after
   two hours, and `prompt` is refused with `turn_active` in between;
5. `finish` waits ten seconds, terminates the child, and the supervisor stays
   alive because it still waits for the prompt; after its timeout it cannot find
   the removed apply state and crashes with `FileNotFoundError`.

### Evidence

A child that writes one line of the given size and then the response, driven
through the real `AcpClient`:

| Line size | Notifications seen | Response | Reader |
| --- | --- | --- | --- |
| 1,000 bytes | all | received | alive |
| 60,000 bytes | all | received | alive |
| 70,000 bytes | stops before the large one | **never** | dead, `ValueError` |
| 300,000 bytes | stops before the large one | **never** | dead, `ValueError` |

In field use the affected transcripts all end in an `edit` update with status
`in_progress`. Runs that edited files from about 30 KB upwards were affected, runs
that edited files up to about 21 KB were not. That fits an update that carries the
old and the new file text, so a 30 KB file already exceeds the limit after JSON
escaping. This link between field runs and the cause is an inference: the exact
protocol line was not captured. The reader defect itself is proven.

## Goals / Non-Goals

**Goals:** no silent reader death, correct turn end for large updates, immediate
and honest report when the transport is lost, recovery without data loss, no
leftover supervisors, and review rules that catch empty evidence.

**Non-Goals:** reading the agent's session database, changing OpenCode, changing
permissions or model selection, changing how applies are planned.

## Decisions

### D1 – Larger limit plus a bounded reader

Start the child with an explicit stream limit (`BOSS_ACP_LINE_LIMIT`, default
64 MiB) at both places that start a child, the supervisor and the doctor probe.
Above the limit the reader drops the rest of the line, logs its size and goes on.
Alternative: a hand-written reader. Rejected, the limit is one parameter.

### D2 – Guard the reader loop

Wrap the loop so that every exit sets `closed`, fails open futures with
`transport_lost`, and runs the close handler. Cancellation stays cancellation.
The supervisor keeps the child's exit status and the reader's error apart.

### D3 – New turn result `transport_lost`

It is not `end_turn`, `cancelled` or `turn_timeout`. The wake says what is known:
the child is alive or gone, and what the last transcript entry was. `boss status`
shows the same fields.

### D4 – Retrigger

`prompt` is refused only while a turn is really open. After `transport_lost` the
supervisor starts a new child if the old one is gone, resumes the recorded session
when the agent offers that, and otherwise opens a new session. A child that still
runs is terminated with the existing shutdown budget first.

### D5 – Shutdown

`finish` and `request_stop` cancel the prompt future first, then close the child.
State writes tolerate a missing state file. The closing steps get one shared
budget, and the process exits after it.

### D6 – Doctor

Read the plugin list from the effective configuration that the doctor already
loads. A small list of known memory plugins is enough; unknown plugins are not
reported. The warning names the option to start the runner without plugins.

### D7 – Review rules

Write the rules into the shared block, short and as imperatives. They describe
behaviour and need no new command. `boss review` additionally prints the number of
executed tests when the project's test output contains one, and flags zero.

## Risks / Trade-offs

- A large limit lets one broken line use memory. The limit is configurable and
  far below what a supervisor can hold.
- Skipping a line can drop a notification. The transcript is a view, and the
  agent's own session is the record; a dropped response ends the turn as
  `transport_lost`.
- Restarting a child could duplicate work if the old one still runs. D4 stops it
  first.
- A memory-plugin list ages. The warning is advisory.

## Open Questions

- none. The limit default, the list of memory plugins and the shutdown budget are
  implementation choices inside the decisions above.
