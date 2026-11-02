# Tasks

## 1. Permission queue

- [x] 1.1 Replace the single `permission_future`/`permission_request` with a
      pending collection keyed by tool-call id; persist
      `acp.pending_permissions` and keep `acp.pending_permission` as the first
      entry for older readers.
- [x] 1.2 Insert each request with its own future and options; set `blocked`
      only on the first pending request and return to `working` only when the
      last one is answered.
- [x] 1.3 Resolve or cancel every pending request on interrupt, finish,
      shutdown and unexpected child exit; leave no future unresolved.

## 2. Answer and status

- [x] 2.1 Add an optional `tool_call_id` to the control `answer` command;
      return `ambiguous_pending` with the ids when several requests are pending
      and no id is given.
- [x] 2.2 Extend `boss answer` with `--tool-call <id>` (and the id as a second
      positional argument); keep the option-only form working for one request.
- [x] 2.3 Report every pending request in `boss status` and the blocked dialog,
      with tool-call id, command and offered options.

## 3. Allow semantics

- [x] 3.1 Prefer Goose's `allow_once` option for every automatic allow; never
      send `allow_always` for an automatic decision.
- [x] 3.2 Map an Explorer `allow_always` answer to an apply-scoped grant in
      `acp.apply_allows`, send `allow_once` to the agent, and auto-allow every
      later matching request for the rest of the apply.
- [x] 3.3 Fail closed (leave the request pending) when the agent offers no
      allow-once option and the runner is not isolated; log the reason.

## 4. Isolated agent profile

- [x] 4.1 Build a per-apply profile under the boss state directory with
      `config/goose` and `data/goose`; symlink `config.yaml`, `secrets.yaml` and
      provider state, and generate a boss-owned `permission.yaml` with empty
      `always_allow`/`never_allow` lists in the `user` and `smart_approve`
      sections and shell/write/edit under both `ask_before` lists.
- [x] 4.2 Start the ACP child with `XDG_CONFIG_HOME` and `XDG_DATA_HOME` pointing
      at the profile; keep the profile across a supervisor resume and remove it
      on finish.
- [x] 4.3 Use a temporary profile for `boss doctor` probes and delete it in a
      `finally` path so no probe session or permission entry remains.

## 5. Doctor and policy

- [x] 5.1 Teach `policy_check` for ACP to report `enforced` only for an isolated
      profile or a clean store, and `weakened` with the offending entry when
      shell/write/edit is globally always-allowed.
- [x] 5.2 Report the isolation state and the effective permission store in
      `boss doctor` without modifying the user's files.

## 6. Diagnostics

- [x] 6.1 Add `tool_call_id` and `request_id` to permission and
      permission-answered transcript entries, and `request_id` to the event.

## 7. Tests

- [x] 7.1 Extend the fake ACP agent with two concurrent permission requests and
      distinct tool-call ids.
- [x] 7.2 Cover queue order, answer-by-id, ambiguous answer, cancel-all and
      shutdown with pending requests.
- [x] 7.3 Assert that automatic allow selects `allow_once` and that an
      `allow_always` answer stores an apply grant without writing a global file.
- [x] 7.4 Cover profile creation, symlinks, finish removal, resume reuse and the
      doctor's temporary profile; assert the user's profile is untouched.
- [x] 7.5 Cover `weakened` and `enforced` policy output.

## 8. Documentation and verification

- [x] 8.1 Document the queue, answer-by-id, apply-scoped allow-always and the
      per-apply profile in `README.md` and `vision/SKILL.md`.
- [x] 8.2 Run `./tests/run.sh`, the Bash/ShellCheck/Python gates, the runtime
      manifest, the wrappers and `openspec validate --all --strict`; verify all
      green.
- [x] 8.3 Verify the worktree contains no change outside the planned files and
      record the gate results for the Explorer.

## Workflow follow-up

- Remove the already-written `shell` entry from the user's
  `~/.config/goose/permission.yaml` before the next non-isolated Goose run.
- Consider a retention policy for transcripts and per-apply profiles.
