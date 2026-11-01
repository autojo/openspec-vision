#!/usr/bin/env bash
# check-generated.sh -- the OpenSpec instruction files in this repo
# (.opencode/skills, .opencode/commands, .claude/skills, .claude/commands/opsx)
# are output of 'openspec update', not hand-written. This check fails when the
# checkout is not what the installed OpenSpec CLI would write, which is how the
# copies in the three repos drifted apart (1.14.2 vs 1.15.0) without anyone
# noticing.

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

if ! command -v openspec >/dev/null 2>&1; then
  printf 'skipped: openspec is not installed\n'
  exit 0
fi

out="$(cd "$ROOT" && openspec update --dry-run 2>&1)"
rc=$?
case "$out" in
  *"No changes"*)
    printf 'openspec instruction files are current\n'
    exit 0
    ;;
esac

printf 'openspec instruction files are not current (openspec update --dry-run, rc=%s):\n' "$rc" >&2
printf '%s\n' "$out" >&2
printf 'Regenerate them with: openspec update\n' >&2
exit 1
