# Proposal

## Why

The repository now ships an ACP runner for Goose, and the vision skill already
describes an external review pass in `vision/references/external-review.md`.
That pass is the first bounded, objective task that exercises the new runner
end-to-end while producing a current review of the vision-skill repository
after the ACP and timeout changes.

## What Changes

- Add a review-only OpenSpec change. The change has no capability delta and sets
  `skip_specs: true`.
- Run the external review checklist on the vision-skill repository in an
  isolated boss worktree, driven by the Goose ACP runner:
  - record branch, commit and pre-flight worktree state;
  - run the full regression suite;
  - run the static gates (Bash syntax, shellcheck, Python syntax, runtime
    manifest, command wrappers, OpenSpec validation);
  - record the pre-existing OpenSpec generated-file drift as a yellow finding;
  - run the dependency scan and record that the repository has no package
    sources;
  - check the worktree after the gates.
- Write a report under `openspec/reviews/vision-skill-external/` with the gate
  table, log paths, findings and a verdict.
- Do not edit source, commit or push from the worker. The Explorer reviews the
  report and owns the commit.

## Capabilities

### New Capabilities

None. This is a review-only change with no spec-level behavior change; it sets
`skip_specs: true`.

### Modified Capabilities

None.

## Impact

- New review artifacts under `openspec/reviews/vision-skill-external/`; no
  runtime, installer or dependency changes.
- Exercises the ACP runner's session, permission policy, transcript, cancel and
  finish paths without changing the skill itself.
- The report is local to the review branch; publishing it is the Explorer's
  decision.
