## Log

- 2026-11-02T15:24:24+0100 [interrupt] interrupted acp-runner-observability (ACP session/cancel: cancelled)

- 2026-11-02T15:24:51+0100 [acp-runner] ACP dispatch uses the installed runtime, not the repo branch. B was dispatched with the old 9daf7a4 supervisor after A merged: the state had no isolated/profile_root, and policy=allow auto-answered Goose allow_always, which re-added shell to ~/.config/goose/permission.yaml. Interrupted B, cleaned the store, and must reinstall the runtime from the current branch before the next goose dispatch. Verify acp.isolated/profile_root in the state immediately after dispatch.
