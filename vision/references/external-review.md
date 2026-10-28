# External review pass

Use this checklist on an external station (for example the build station).
The station must not change the repository.

1. `git pull --ff-only` and record the commit.
2. `git status --short` must be clean before building.
3. Run the project's build command.
4. Run the project's test command.
5. Run `osv-scanner` with the project's lockfiles.
6. Restore tracked files (`git reset --hard HEAD`) and remove generated
   artefacts that are not ignored.
7. Report: commit, commands, exit codes, failing output/log, and whether the
   worktree is clean again.

Do not edit source, do not commit, do not push. Send the report to the
Explorer; a green pass can check external tasks off, a red pass goes into
`boss resume <change> --note "<log>"` or a retrigger note.
