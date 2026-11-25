# Proposal

## Why

boss loses the end of an ACP turn although the agent finished its work. The
supervisor reads the agent's protocol with a 64 KiB line limit. A longer line,
for example the tool update of an edit that carries a whole file, makes the
reader raise and stop. Nothing reports this: the agent keeps working, the
transcript ends in the middle of a tool call, the turn stays `working`, and the
boss is told `stalled` after 30 minutes.

In one day of real use, most OpenCode applies that edited larger files ended
this way. Their transcripts all end in an edit that is still `in_progress`. The
Explorer had to read OpenCode's own session store to see that the work was done.
`boss retrigger` was then refused with `turn_active`, and `boss finish --force`
left a supervisor alive until its two-hour timeout.

The same day showed gaps in the review procedure that let wrong conclusions
pass. Both skills should close them.

## What Changes

- Read ACP lines of any realistic size. A line above a configurable limit is
  skipped and reported, and reading continues with the next line.
- Make a dead reader visible at once: the turn ends as `transport_lost`, the
  Explorer is woken once, and the state names the reason.
- Let the Explorer recover after `transport_lost` without losing work:
  `boss retrigger` resumes the agent session or starts a new turn in the same
  worktree instead of answering `turn_active`.
- Stop the supervisor together with the apply. `boss finish` and a lost child
  leave no supervisor, timer or prompt task behind.
- Say in `boss status` and in the wake text what is known when a turn is silent:
  last activity, and whether the child and the reader are alive. The boss no
  longer guesses from the age of the transcript alone.
- Add review rules to the shared run procedure of both skills, so a green gate
  and a "nothing changed" claim count only when they are shown to be real, and
  so nobody is asked to touch a resource that a running operation uses.
- Let `boss doctor` report OpenCode plugins that can inject text from earlier
  sessions into an apply. One such plugin led an apply to mistake an old summary
  for its task and discard finished work.

## Capabilities

### New Capabilities

- none

### Modified Capabilities

- `acp-runner`: protocol reader limits and failure, recovery after a lost turn
  end, supervisor lifetime, status of a silent turn, doctor check.
- `boss-skill`: review rules in the shared run procedure.
- `vision-skill`: the same review rules, because the block is shared.

## Impact

- `runtime/lib/boss_acp.py` (reader, supervisor shutdown, status),
  `runtime/bin/boss-run.sh` and `boss-status.sh` (retrigger, finish, texts),
  `runtime/bin/boss-doctor.sh`, `boss/SKILL.md`, `vision/SKILL.md`, the command
  wrappers for both hosts, `tests/run.sh`, `README.md`, `CHANGELOG.md`.
- No configuration change is required. New settings have defaults.
- Out of scope: reading an agent's private session store, changes to OpenCode
  itself, and any change to permission handling or model selection.
