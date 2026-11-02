## Log

- 2026-11-02T12:27:07+0100 [interrupt] interrupted vision-skill-external-review (ACP session/cancel: cancelled)

- 2026-11-02T12:27:52+0100 [acp-runner] ACP runner: concurrent session/request_permission requests are not queued. Two parallel shell tool calls (two `cat`s) produced two requests; the supervisor holds one pending permission, answered only the second, and stranded the first; the turn stayed working and boss answer reported no pending. Fix: queue pending permissions by tool_call_id, persist the list, answer/clear per id, expose all in status, cancel all on interrupt; add a fake-ACP test with two concurrent requests. Prefer the read tool over shell `cat`; consider a read-only shell allowlist. Workaround used: goose-review runner with policy=allow (deny still applies).
