#!/usr/bin/env bash
# gen-commands.sh -- generate the boss command wrappers for Claude Code and
# OpenCode from commands/commands.tsv.
#
#   ./scripts/gen-commands.sh           rewrite the wrappers
#   ./scripts/gen-commands.sh --check   verify they are current (exit 1 if not)
#
# The wrappers are one-line shims: they tell the agent to run the CLI and
# summarize its JSON. Keeping them generated removes the 34 hand-copied files
# that used to drift apart (one wrapper had the wrong frontmatter, others a
# different hint than their sibling).

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TABLE="$ROOT/commands/commands.tsv"
CLAUDE_DIR="$ROOT/commands/claude/boss"
OPENCODE_DIR="$ROOT/commands/opencode"
mode="${1:-write}"
rc=0

[ -f "$TABLE" ] || { printf 'error: missing %s\n' "$TABLE" >&2; exit 1; }

# title_of <name> -- "Boss: Dispatch"
title_of() {
  local name="$1"
  printf 'Boss: %s%s\n' "$(printf '%s' "${name:0:1}" | tr '[:lower:]' '[:upper:]')" "${name:1}"
}

# claude_wrapper <name> <description> <hint>
claude_wrapper() {
  printf -- '---\n'
  printf 'name: "%s"\n' "$(title_of "$1")"
  printf 'description: "%s"\n' "$2"
  printf 'allowed-tools: Bash(boss:*)\n'
  printf 'category: "Boss"\n'
  printf 'tags: ["boss", "workflow"]\n'
  printf -- '---\n\n'
  printf '%s\n' "$3"
}

# opencode_wrapper <name> <description> <hint>
opencode_wrapper() {
  printf -- '---\n'
  printf 'description: "%s"\n' "$2"
  printf -- '---\n\n'
  printf '%s\n' "$3"
}

# emit <file> <content> -- write or compare
emit() {
  local file="$1" want="$2" have
  if [ "$mode" = "--check" ]; then
    if [ -f "$file" ]; then
      have="$(cat "$file")"
      if [ "$have" = "$want" ]; then
        return 0
      fi
      printf 'stale: %s\n' "${file#"$ROOT"/}" >&2
      rc=1
      return 0
    fi
    printf 'missing: %s\n' "${file#"$ROOT"/}" >&2
    rc=1
    return 0
  fi
  printf '%s\n' "$want" >"$file"
}

mkdir -p "$CLAUDE_DIR" "$OPENCODE_DIR"

while IFS='	' read -r name description hint; do
  [ -n "${name:-}" ] || continue
  case "$name" in \#*) continue ;; esac
  [ -n "${description:-}" ] && [ -n "${hint:-}" ] || {
    printf 'error: malformed row for %s in %s\n' "$name" "$TABLE" >&2
    exit 1
  }
  emit "$CLAUDE_DIR/$name.md" "$(claude_wrapper "$name" "$description" "$hint")"
  emit "$OPENCODE_DIR/boss-$name.md" "$(opencode_wrapper "$name" "$description" "$hint")"
done <"$TABLE"

if [ "$mode" = "--check" ]; then
  # A wrapper whose command no longer exists in the table is stale too.
  for file in "$CLAUDE_DIR"/*.md; do
    [ -e "$file" ] || continue
    name="$(basename "$file" .md)"
    cut -f1 "$TABLE" | grep -qx -- "$name" || { printf 'orphan: commands/claude/boss/%s.md\n' "$name" >&2; rc=1; }
  done
  for file in "$OPENCODE_DIR"/boss-*.md; do
    [ -e "$file" ] || continue
    name="$(basename "$file" .md)"; name="${name#boss-}"
    cut -f1 "$TABLE" | grep -qx -- "$name" || { printf 'orphan: commands/opencode/boss-%s.md\n' "$name" >&2; rc=1; }
  done
  [ "$rc" -eq 0 ] && printf 'command wrappers are current\n'
  exit "$rc"
fi

printf 'wrote %s wrappers\n' "$(wc -l <"$TABLE" | tr -d ' ')"
