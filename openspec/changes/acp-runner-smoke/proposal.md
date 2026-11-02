# Proposal

## Why

The permission queue, answer-by-id and apply-scoped allow-always were tested
against the fake ACP agent, but the real Goose path with `policy = "ask"` has
not yet produced concurrent pending requests and human answers. This change is a
deliberately tiny end-to-end smoke test: it forces two parallel shell calls,
answers one request by id, grants allow-always once, and interrupts two parallel
long-running calls. It produces a report, not a product feature.

## What Changes

- Add a temporary smoke change with `skip_specs: true` and no capability delta.
- Drive the real Goose ACP runner through:
  - two concurrent `sleep 3` shell calls and answer-by-id;
  - one `echo smoke-allow-always` call answered with `allow_always`, then the
    same command again without a new prompt;
  - two concurrent `sleep 30` calls interrupted with `boss interrupt`.
- Record the evidence under `openspec/reviews/acp-runner-smoke/`.
- Remove or archive the smoke change after the run.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

None. This is a test-only change; `.openspec.yaml` sets `skip_specs: true`.

## Impact

- No runtime, dependency or product change.
- Creates a boss worktree and a real Goose ACP session for the duration of the
  smoke test; the per-apply profile is removed on finish.
- The report is the only retained artifact.
