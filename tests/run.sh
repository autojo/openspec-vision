#!/usr/bin/env bash
# Regression tests for the boss runtime and the vision skill.
#
# Everything runs in a temporary HOME with stub `herdr`, `openspec` and
# `opencode` commands, so no real workspace, apply, global config or other
# project is touched. The installer tests use a separate temporary HOME.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

BIN="$TMP/bin"
STATE="$TMP/state"
CONFIG="$TMP/boss.toml"
SOCKET="$TMP/herdr.sock"
mkdir -p "$BIN" "$STATE"
PASS=0
FAIL=0

cleanup_server() {
  if [ -n "${SOCKET_PID:-}" ]; then
    kill "$SOCKET_PID" >/dev/null 2>&1 || true
  fi
}
trap 'cleanup_server; rm -rf "$TMP"' EXIT

ok() {
  PASS=$((PASS + 1))
}

bad() {
  FAIL=$((FAIL + 1))
  printf 'FAIL: %s\n' "$1" >&2
}

check_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then ok; else bad "$name: expected '$expected', got '$actual'"; fi
}

check_contains() {
  local name="$1" needle="$2" haystack="$3"
  case "$haystack" in
    *"$needle"*) ok ;;
    *) bad "$name: '$needle' not found in '$haystack'" ;;
  esac
}

check_not_contains() {
  local name="$1" needle="$2" haystack="$3"
  case "$haystack" in
    *"$needle"*) bad "$name: '$needle' unexpectedly present in '$haystack'" ;;
    *) ok ;;
  esac
}

# --------------------------------------------------------------- stubs ---

cat >"$BIN/openspec" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  validate)
    if [ "${OPENSPEC_STUB_VALIDATE_FAIL:-0}" = "1" ]; then
      printf '%s\n' "validation error: missing scenario"
      exit 1
    fi
    exit 0
    ;;
  status)
    printf '%s\n' '{"artifacts":[{"id":"proposal","status":"done"},{"id":"specs","status":"done"},{"id":"tasks","status":"done"}],"applyRequires":["tasks"]}'
    ;;
  *) exit 0 ;;
esac
EOF

cat >"$BIN/opencode" <<'EOF'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "--version ")
    printf '%s\n' "${OPENCODE_STUB_VERSION:-opencode v2.1.1}"
    ;;
  "debug config")
    if [ -n "${OPENCODE_STUB_CWD_LOG:-}" ]; then
      printf 'debug:%s\n' "$PWD" >>"$OPENCODE_STUB_CWD_LOG"
    fi
    [ "${OPENCODE_STUB_DEBUG_FAIL:-0}" = "1" ] && exit 1
    if [ -n "${OPENCODE_STUB_DEBUG_CONFIG:-}" ]; then
      printf '%s\n' "$OPENCODE_STUB_DEBUG_CONFIG"
    else
      printf '%s\n' '[{"type":"document","path":"/stub/opencode.jsonc","info":{"permissions":[{"action":"*","resource":"*","effect":"allow"}]}}]'
    fi
    ;;
  "api get")
    [ "${OPENCODE_STUB_API_FAIL:-0}" = "1" ] && exit 1
    if [ -n "${OPENCODE_STUB_API_CONFIG:-}" ]; then
      printf '%s\n' "$OPENCODE_STUB_API_CONFIG"
    else
      exit 1
    fi
    ;;
  *) exit 0 ;;
esac
EOF

cat >"$BIN/herdr" <<'EOF'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "integration install")
    printf '%s\n' '{"result":{}}'
    ;;
  "integration status")
    if [ -n "${HERDR_INTEGRATION_STATUS:-}" ]; then
      printf '%s\n' "$HERDR_INTEGRATION_STATUS"
    else
      printf 'claude: current (v11)\nopencode: current (v13)\n'
    fi
    ;;
  "agent list")
    printf '{"result":{"agents":%s}}\n' "${HERDR_AGENTS_JSON:-[]}"
    ;;
  "pane list")
    if [ -n "${HERDR_PANES_JSON:-}" ]; then
      printf '{"result":{"panes":%s}}\n' "$HERDR_PANES_JSON"
    else
      printf '{"result":{"panes":[{"pane_id":"p-boss","workspace_id":"ws-1","cwd":"%s","foreground_cwd":"%s"}]}}\n' "$PWD" "$PWD"
    fi
    ;;
  "pane process-info")
    pane=""
    i=1
    while [ "$i" -le "$#" ]; do
      eval "arg=\${$i}"
      if [ "$arg" = "--pane" ]; then
        i=$((i + 1))
        eval "pane=\${$i}"
      fi
      i=$((i + 1))
    done
    if [ -n "${HERDR_PROCESS_LEGACY_JSON:-}" ]; then
      # Old flat shape: result.<pane process fields>.
      printf '%s' "$HERDR_PROCESS_LEGACY_JSON" | jq -c --arg p "$pane" '{result: (.[$p] // {pane_id: $p})}'
    elif [ -n "${HERDR_PROCESS_JSON:-}" ]; then
      # Real Herdr shape: result.process_info.<pane process fields>.
      printf '%s' "$HERDR_PROCESS_JSON" | jq -c --arg p "$pane" '{result: {process_info: (.[$p] // {pane_id: $p})}}'
    else
      printf '{"result":{"process_info":{"pane_id":"%s"}}}\n' "$pane"
    fi
    ;;
  "workspace create")
    printf '%s\n' '{"result":{"workspace":{"workspace_id":"ws-1"}}}'
    ;;
  "tab create")
    if [ -n "${HERDR_TAB_CREATE_LOG:-}" ]; then
      printf '%s\n' "$*" >>"$HERDR_TAB_CREATE_LOG"
    fi
    label=""; ws="ws-1"; cwd=""
    i=1
    while [ "$i" -le "$#" ]; do
      eval "arg=\${$i}"
      case "$arg" in
        --label) i=$((i + 1)); eval "label=\${$i}" ;;
        --workspace) i=$((i + 1)); eval "ws=\${$i}" ;;
        --cwd) i=$((i + 1)); eval "cwd=\${$i}" ;;
      esac
      i=$((i + 1))
    done
    [ -n "$label" ] || label="change"
    printf '{"result":{"root_pane":{"pane_id":"pane-%s","tab_id":"tab-%s","workspace_id":"%s","cwd":"%s"},"tab":{"tab_id":"tab-%s","workspace_id":"%s"}}}\n' \
      "$label" "$label" "$ws" "$cwd" "$label" "$ws"
    ;;
  "agent start")
    if [ -n "${HERDR_AGENT_START_LOG:-}" ]; then
      printf '%s\n' "$*" >>"$HERDR_AGENT_START_LOG"
    fi
    printf '%s\n' '{"result":{}}'
    ;;
  "agent prompt")
    if [ -n "${HERDR_PROMPT_LOG:-}" ]; then
      printf '%s\n' "$*" >>"$HERDR_PROMPT_LOG"
    fi
    printf '%s\n' '{"result":{}}'
    ;;
  "agent send-keys")
    if [ -n "${HERDR_SEND_KEYS_LOG:-}" ]; then
      printf '%s\n' "$*" >>"$HERDR_SEND_KEYS_LOG"
    fi
    printf '%s\n' '{"result":{}}'
    ;;
  "agent get")
    id="${3:-}"
    case " ${HERDR_LIVE_PANES:-} " in
      *" $id "*) printf '{"result":{"agent":{"pane_id":"%s","agent_status":"idle","state_change_seq":1}}}\n' "$id" ;;
      *) exit 1 ;;
    esac
    ;;
  "agent wait")
    if [ "${HERDR_AGENT_WAIT_FAIL:-0}" = "1" ]; then
      printf '%s\n' '{"error":{"code":"agent_not_found","message":"name lost"}}'
      exit 1
    fi
    printf '%s\n' '{"result":{}}'
    ;;
  "agent rename")
    if [ -n "${HERDR_RENAME_LOG:-}" ]; then
      printf '%s %s\n' "${3:-}" "${4:-}" >>"$HERDR_RENAME_LOG"
    fi
    printf '%s\n' '{"result":{}}'
    ;;
  "worktree create"|"worktree open"|"worktree list"|"worktree remove")
    action="${2:-}"
    cwd=""; branch=""; base=""; path=""; label=""; workspace=""
    seen_cwd=0; seen_path=0
    i=3
    while [ "$i" -le "$#" ]; do
      eval "arg=\${$i}"
      case "$arg" in
        --cwd) seen_cwd=1; i=$((i + 1)); eval "cwd=\${$i}" ;;
        --branch) i=$((i + 1)); eval "branch=\${$i}" ;;
        --base) i=$((i + 1)); eval "base=\${$i}" ;;
        --path) seen_path=1; i=$((i + 1)); eval "path=\${$i}" ;;
        --label) i=$((i + 1)); eval "label=\${$i}" ;;
        --workspace) i=$((i + 1)); eval "workspace=\${$i}" ;;
      esac
      i=$((i + 1))
    done
    [ -n "$cwd" ] || cwd="$PWD"
    map_file="${HERDR_WORKTREE_MAP:-}"
    if [ "$action" = "create" ]; then
      if [ "${HERDR_WORKTREE_CREATE_FAIL:-0}" = "after" ]; then
        git -C "$cwd" worktree add -q -b "$branch" "$path" "${base:-HEAD}" >/dev/null 2>&1 || true
        printf '%s\n' '{"error":{"code":"worktree_create_failed","message":"stub failure after create"}}'
        exit 1
      fi
      if [ "${HERDR_WORKTREE_CREATE_FAIL:-0}" = "1" ]; then
        printf '%s\n' '{"error":{"code":"worktree_create_failed","message":"stub create failure"}}'
        exit 1
      fi
      git -C "$cwd" worktree add -q -b "$branch" "$path" "${base:-HEAD}" >/dev/null 2>&1 || {
        printf '%s\n' '{"error":{"code":"worktree_create_failed","message":"git worktree add failed"}}'
        exit 1
      }
      [ -n "$label" ] || label="$(basename "$path")"
      ws="ws-wt-$label"
      if [ -n "$map_file" ]; then
        mkdir -p "$(dirname "$map_file")"
        jq -nc --arg w "$ws" --arg p "$path" --arg b "$cwd" '{workspace:$w,path:$p,base:$b}' >>"$map_file"
      fi
      if [ "${HERDR_WORKTREE_CREATE_MINIMAL:-0}" = "1" ]; then
        printf '%s\n' '{"result":{}}'
      else
        printf '{"result":{"worktree":{"path":"%s","branch":"%s","open_workspace_id":"%s"},"workspace":{"workspace_id":"%s"}}}\n' \
          "$path" "$branch" "$ws" "$ws"
      fi
      exit 0
    fi
    if [ "$action" = "remove" ]; then
      if [ -n "${HERDR_WORKTREE_REMOVE_LOG:-}" ]; then
        printf '%s\n' "$*" >>"$HERDR_WORKTREE_REMOVE_LOG"
      fi
      if [ "$seen_cwd" -eq 1 ] || [ "$seen_path" -eq 1 ]; then
        if [ "$seen_cwd" -eq 1 ]; then printf '%s\n' 'unknown option: --cwd'
        else printf '%s\n' 'unknown option: --path'; fi
        exit 0
      fi
      if [ -n "$workspace" ] && [ -n "$map_file" ] && [ -f "$map_file" ]; then
        entry="$(jq -sr --arg w "$workspace" \
          'map(select(.workspace == $w)) | .[-1] // empty | [.base, .path] | @tsv' \
          "$map_file" 2>/dev/null || true)"
        if [ -n "$entry" ]; then
          rbase="${entry%%$'\t'*}"
          rpath="${entry#*$'\t'}"
          git -C "$rbase" worktree remove --force "$rpath" >/dev/null 2>&1 || true
        fi
      fi
      printf '%s\n' '{"result":{}}'
      exit 0
    fi
    if [ "$action" = "open" ]; then
      [ -n "$label" ] || label="$(basename "$path")"
      printf '{"result":{"worktree":{"path":"%s","branch":"%s","open_workspace_id":"ws-wt-%s"}}}\n' \
        "$path" "$branch" "$label"
      exit 0
    fi
    # list: linked worktrees only; the real row carries open_workspace_id.
    rows="[]"; cur=""; br=""
    while IFS= read -r line; do
      case "$line" in
        "worktree "*) cur="${line#worktree }" ;;
        "branch "*) br="${line#branch }"; br="${br#refs/heads/}"
          rows="$(printf '%s' "$rows" | jq -c --arg p "$cur" --arg b "$br" \
            --arg w "ws-wt-$(basename "$cur")" '. + [{path:$p,branch:$b,open_workspace_id:$w}]')" ;;
      esac
    done < <(git -C "$cwd" worktree list --porcelain 2>/dev/null | tail -n +5)
    printf '{"result":{"worktrees":%s}}\n' "$rows"
    exit 0
    ;;
  *)
    printf '%s\n' '{"result":{}}'
    ;;
esac
EOF

cat >"$BIN/setsid" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

chmod +x "$BIN/openspec" "$BIN/herdr" "$BIN/opencode" "$BIN/setsid"

# A tiny Herdr socket server for the pane.report_metadata call.
python3 - "$SOCKET" <<'PY' &
import json, os, socket, sys
path = sys.argv[1]
try:
    os.unlink(path)
except FileNotFoundError:
    pass
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(path)
s.listen(8)
while True:
    conn, _ = s.accept()
    try:
        f = conn.makefile("rw")
        for line in f:
            if not line.strip():
                continue
            f.write(json.dumps({"id": "boss", "result": {}}) + "\n")
            f.flush()
    finally:
        conn.close()
PY
SOCKET_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -S "$SOCKET" ] && break
  sleep 0.1
done

# --------------------------------------------------------------- helpers ---

base_config() {
  local file="$1" project="${2:-}"
  {
    printf 'default = "opencode"\n'
    if [ -n "$project" ]; then
      printf '\n[projects]\nmission-test = "%s"\n' "$project"
    fi
    printf '\n[runners.opencode]\nkind = "opencode"\nargs = []\napply = "/opsx-apply {change}"\n'
    printf '\n[missions]\n'
  } >"$file"
}

run_boss() {
  env PATH="$BIN:$PATH" HOME="$TMP" BOSS_CONFIG="${BOSS_CONFIG:-$CONFIG}" BOSS_STATE_DIR="$STATE" \
    HERDR_ENV=1 HERDR_PANE_ID="${BOSS_TEST_PANE:-p-boss}" HERDR_WORKSPACE_ID="${BOSS_TEST_WORKSPACE:-ws-1}" \
    HERDR_SOCKET_PATH="$SOCKET" HERDR_LIVE_PANES="${HERDR_LIVE_PANES:-}" \
    HERDR_RENAME_LOG="${HERDR_RENAME_LOG:-}" \
    HERDR_INTEGRATION_STATUS="${HERDR_INTEGRATION_STATUS:-}" \
    HERDR_AGENT_START_LOG="${HERDR_AGENT_START_LOG:-}" \
    HERDR_TAB_CREATE_LOG="${HERDR_TAB_CREATE_LOG:-}" \
    HERDR_PROMPT_LOG="${HERDR_PROMPT_LOG:-}" \
    HERDR_WORKTREE_CREATE_FAIL="${HERDR_WORKTREE_CREATE_FAIL:-}" \
    HERDR_WORKTREE_CREATE_MINIMAL="${HERDR_WORKTREE_CREATE_MINIMAL:-}" \
    HERDR_WORKTREE_MAP="${HERDR_WORKTREE_MAP:-$TMP/herdr-worktrees.jsonl}" \
    HERDR_WORKTREE_REMOVE_LOG="${HERDR_WORKTREE_REMOVE_LOG:-}" \
    FAIL_MARKER="${FAIL_MARKER:-}" \
    OPENCODE_STUB_VERSION="${OPENCODE_STUB_VERSION:-}" \
    OPENCODE_STUB_DEBUG_CONFIG="${OPENCODE_STUB_DEBUG_CONFIG:-}" \
    OPENCODE_STUB_CWD_LOG="${OPENCODE_STUB_CWD_LOG:-}" \
    OPENCODE_STUB_DEBUG_FAIL="${OPENCODE_STUB_DEBUG_FAIL:-}" \
    OPENCODE_STUB_API_CONFIG="${OPENCODE_STUB_API_CONFIG:-}" \
    OPENCODE_STUB_API_FAIL="${OPENCODE_STUB_API_FAIL:-}" \
    OPENSPEC_STUB_VALIDATE_FAIL="${OPENSPEC_STUB_VALIDATE_FAIL:-}" \
    bash "$ROOT/runtime/bin/boss" "$@"
}

run_boss_fail() {
  env PATH="$BIN:$PATH" HOME="$TMP" BOSS_CONFIG="${BOSS_CONFIG:-$CONFIG}" BOSS_STATE_DIR="$STATE" \
    HERDR_ENV=1 HERDR_PANE_ID="${BOSS_TEST_PANE:-p-boss}" HERDR_WORKSPACE_ID="${BOSS_TEST_WORKSPACE:-ws-1}" \
    HERDR_SOCKET_PATH="$SOCKET" HERDR_LIVE_PANES="${HERDR_LIVE_PANES:-}" \
    HERDR_RENAME_LOG="${HERDR_RENAME_LOG:-}" \
    HERDR_INTEGRATION_STATUS="${HERDR_INTEGRATION_STATUS:-}" \
    HERDR_AGENT_START_LOG="${HERDR_AGENT_START_LOG:-}" \
    HERDR_TAB_CREATE_LOG="${HERDR_TAB_CREATE_LOG:-}" \
    HERDR_PROMPT_LOG="${HERDR_PROMPT_LOG:-}" \
    HERDR_WORKTREE_CREATE_FAIL="${HERDR_WORKTREE_CREATE_FAIL:-}" \
    HERDR_WORKTREE_CREATE_MINIMAL="${HERDR_WORKTREE_CREATE_MINIMAL:-}" \
    HERDR_WORKTREE_MAP="${HERDR_WORKTREE_MAP:-$TMP/herdr-worktrees.jsonl}" \
    HERDR_WORKTREE_REMOVE_LOG="${HERDR_WORKTREE_REMOVE_LOG:-}" \
    FAIL_MARKER="${FAIL_MARKER:-}" \
    OPENCODE_STUB_VERSION="${OPENCODE_STUB_VERSION:-}" \
    OPENCODE_STUB_DEBUG_CONFIG="${OPENCODE_STUB_DEBUG_CONFIG:-}" \
    OPENCODE_STUB_CWD_LOG="${OPENCODE_STUB_CWD_LOG:-}" \
    OPENCODE_STUB_DEBUG_FAIL="${OPENCODE_STUB_DEBUG_FAIL:-}" \
    OPENCODE_STUB_API_CONFIG="${OPENCODE_STUB_API_CONFIG:-}" \
    OPENCODE_STUB_API_FAIL="${OPENCODE_STUB_API_FAIL:-}" \
    OPENSPEC_STUB_VALIDATE_FAIL="${OPENSPEC_STUB_VALIDATE_FAIL:-}" \
    bash "$ROOT/runtime/bin/boss" "$@" 2>&1
}

run_boss_state() {
  local st="$1"; shift
  env PATH="$BIN:$PATH" HOME="$TMP" BOSS_CONFIG="${BOSS_CONFIG:-$CONFIG}" BOSS_STATE_DIR="$st" \
    HERDR_ENV=1 HERDR_PANE_ID="${BOSS_TEST_PANE:-p-boss}" HERDR_WORKSPACE_ID="${BOSS_TEST_WORKSPACE:-ws-1}" \
    HERDR_SOCKET_PATH="$SOCKET" HERDR_LIVE_PANES="${HERDR_LIVE_PANES:-}" \
    HERDR_RENAME_LOG="${HERDR_RENAME_LOG:-}" \
    HERDR_INTEGRATION_STATUS="${HERDR_INTEGRATION_STATUS:-}" \
    HERDR_AGENT_START_LOG="${HERDR_AGENT_START_LOG:-}" \
    HERDR_TAB_CREATE_LOG="${HERDR_TAB_CREATE_LOG:-}" \
    HERDR_PROMPT_LOG="${HERDR_PROMPT_LOG:-}" \
    HERDR_WORKTREE_CREATE_FAIL="${HERDR_WORKTREE_CREATE_FAIL:-}" \
    HERDR_WORKTREE_CREATE_MINIMAL="${HERDR_WORKTREE_CREATE_MINIMAL:-}" \
    HERDR_WORKTREE_MAP="${HERDR_WORKTREE_MAP:-$TMP/herdr-worktrees.jsonl}" \
    HERDR_WORKTREE_REMOVE_LOG="${HERDR_WORKTREE_REMOVE_LOG:-}" \
    FAIL_MARKER="${FAIL_MARKER:-}" \
    OPENCODE_STUB_VERSION="${OPENCODE_STUB_VERSION:-}" \
    OPENCODE_STUB_DEBUG_CONFIG="${OPENCODE_STUB_DEBUG_CONFIG:-}" \
    OPENCODE_STUB_CWD_LOG="${OPENCODE_STUB_CWD_LOG:-}" \
    OPENCODE_STUB_DEBUG_FAIL="${OPENCODE_STUB_DEBUG_FAIL:-}" \
    OPENCODE_STUB_API_CONFIG="${OPENCODE_STUB_API_CONFIG:-}" \
    OPENCODE_STUB_API_FAIL="${OPENCODE_STUB_API_FAIL:-}" \
    OPENSPEC_STUB_VALIDATE_FAIL="${OPENSPEC_STUB_VALIDATE_FAIL:-}" \
    bash "$ROOT/runtime/bin/boss" "$@"
}

run_boss_fail_state() {
  local st="$1"; shift
  env PATH="$BIN:$PATH" HOME="$TMP" BOSS_CONFIG="${BOSS_CONFIG:-$CONFIG}" BOSS_STATE_DIR="$st" \
    HERDR_ENV=1 HERDR_PANE_ID="${BOSS_TEST_PANE:-p-boss}" HERDR_WORKSPACE_ID="${BOSS_TEST_WORKSPACE:-ws-1}" \
    HERDR_SOCKET_PATH="$SOCKET" HERDR_LIVE_PANES="${HERDR_LIVE_PANES:-}" \
    HERDR_RENAME_LOG="${HERDR_RENAME_LOG:-}" \
    HERDR_INTEGRATION_STATUS="${HERDR_INTEGRATION_STATUS:-}" \
    HERDR_AGENT_START_LOG="${HERDR_AGENT_START_LOG:-}" \
    HERDR_TAB_CREATE_LOG="${HERDR_TAB_CREATE_LOG:-}" \
    HERDR_PROMPT_LOG="${HERDR_PROMPT_LOG:-}" \
    HERDR_WORKTREE_CREATE_FAIL="${HERDR_WORKTREE_CREATE_FAIL:-}" \
    HERDR_WORKTREE_CREATE_MINIMAL="${HERDR_WORKTREE_CREATE_MINIMAL:-}" \
    HERDR_WORKTREE_MAP="${HERDR_WORKTREE_MAP:-$TMP/herdr-worktrees.jsonl}" \
    HERDR_WORKTREE_REMOVE_LOG="${HERDR_WORKTREE_REMOVE_LOG:-}" \
    FAIL_MARKER="${FAIL_MARKER:-}" \
    OPENCODE_STUB_VERSION="${OPENCODE_STUB_VERSION:-}" \
    OPENCODE_STUB_DEBUG_CONFIG="${OPENCODE_STUB_DEBUG_CONFIG:-}" \
    OPENCODE_STUB_CWD_LOG="${OPENCODE_STUB_CWD_LOG:-}" \
    OPENCODE_STUB_DEBUG_FAIL="${OPENCODE_STUB_DEBUG_FAIL:-}" \
    OPENCODE_STUB_API_CONFIG="${OPENCODE_STUB_API_CONFIG:-}" \
    OPENCODE_STUB_API_FAIL="${OPENCODE_STUB_API_FAIL:-}" \
    OPENSPEC_STUB_VALIDATE_FAIL="${OPENSPEC_STUB_VALIDATE_FAIL:-}" \
    bash "$ROOT/runtime/bin/boss" "$@" 2>&1
}

run_lib() {
  env PATH="$BIN:$PATH" HOME="$TMP" BOSS_CONFIG="${BOSS_CONFIG:-$CONFIG}" BOSS_STATE_DIR="$STATE" \
    HERDR_INTEGRATION_STATUS="${HERDR_INTEGRATION_STATUS:-}" \
    HERDR_WORKTREE_MAP="${HERDR_WORKTREE_MAP:-$TMP/herdr-worktrees.jsonl}" \
    HERDR_WORKTREE_REMOVE_LOG="${HERDR_WORKTREE_REMOVE_LOG:-}" \
    OPENCODE_STUB_VERSION="${OPENCODE_STUB_VERSION:-}" \
    OPENCODE_STUB_DEBUG_CONFIG="${OPENCODE_STUB_DEBUG_CONFIG:-}" \
    OPENCODE_STUB_CWD_LOG="${OPENCODE_STUB_CWD_LOG:-}" \
    OPENCODE_STUB_DEBUG_FAIL="${OPENCODE_STUB_DEBUG_FAIL:-}" \
    OPENCODE_STUB_API_CONFIG="${OPENCODE_STUB_API_CONFIG:-}" \
    OPENCODE_STUB_API_FAIL="${OPENCODE_STUB_API_FAIL:-}" \
    OPENSPEC_STUB_VALIDATE_FAIL="${OPENSPEC_STUB_VALIDATE_FAIL:-}" \
    bash -c '. "$1/runtime/bin/boss-lib.sh"; shift; "$@"' _ "$ROOT" "$@"
}

# run_lib_state <state-dir> <function...> -- the same library call against a
# dedicated state root, so tests can control open_apply_count and lock_holders.
run_lib_state() {
  local st="$1"; shift
  env PATH="$BIN:$PATH" HOME="$TMP" BOSS_CONFIG="${BOSS_CONFIG:-$CONFIG}" BOSS_STATE_DIR="$st" \
    HERDR_AGENTS_JSON="${HERDR_AGENTS_JSON:-}" \
    HERDR_INTEGRATION_STATUS="${HERDR_INTEGRATION_STATUS:-}" \
    HERDR_WORKTREE_MAP="${HERDR_WORKTREE_MAP:-$TMP/herdr-worktrees.jsonl}" \
    bash -c '. "$1/runtime/bin/boss-lib.sh"; shift; "$@"' _ "$ROOT" "$@"
}

make_project() {
  local dir="$1"; shift
  mkdir -p "$dir/openspec/changes/archive" "$dir/openspec/missions"
  printf 'schema: spec-driven\n' >"$dir/openspec/config.yaml"
}

make_change() {
  local project="$1" change="$2" tasks="$3"
  local dir="$project/openspec/changes/$change"
  mkdir -p "$dir"
  printf '# Proposal: %s\n' "$change" >"$dir/proposal.md"
  printf '# Specs\n' >"$dir/specs.md"
  printf '%s\n' "$tasks" >"$dir/tasks.md"
}

make_mission() {
  local project="$1" slug="$2" changes="$3"
  cat >"$project/openspec/missions/$slug.md" <<EOF
# Mission: $slug

## Goal

Test mission.

## Non-Goals

## Constraints

## Authorization

| Category | Decision | Bound |
| --- | --- | --- |

## Stop Conditions

## Open Questions

## Plan

planning: planned
reconcile: explore

## Changes

$changes
EOF
}

park_change() {
  local project="$1" change="$2"
  run_lib append_event "$(run_lib events_file_for "$project" "$change")" park '{}'
}

# make_git_project <dir> -- a git repository with a committed README, so a plan
# commit has a clean base to start from.
make_git_project() {
  local dir="$1"
  make_project "$dir"
  printf 'base\n' >"$dir/README.md"
  git -C "$dir" init -q
  git -C "$dir" config user.name "Explorer"
  git -C "$dir" config user.email "explorer@example.com"
  git -C "$dir" add README.md openspec/config.yaml
  git -C "$dir" commit -qm "initial code"
}

# plan_commit <project> <change> -- convenience wrapper around the CLI.
plan_commit() {
  run_boss plan commit "$2" --project "$1"
}

# =============================================================== tests ====

# 1. Default markers, criteria and waiting_human.
P="$TMP/project-1"
make_project "$P"
make_change "$P" human-default $'- [x] 1.1 done\n- [ ] 2.1 [Nutzer] Konto verknüpfen. Prüfen: Konto ist verknüpft.\n- [ ] 2.2 [human] Kaufen. Prüfen: Kaufbeleg liegt vor.'
park_change "$P" human-default
st="$(run_lib mission_done_state "$P" human-default)"
check_eq "default markers: state" "waiting_human" "$(printf '%s' "$st" | jq -r '.state')"
check_eq "default markers: human_open" "2" "$(printf '%s' "$st" | jq -r '.tasks.human_open')"
check_eq "default markers: criterion" "Konto ist verknüpft." "$(printf '%s' "$st" | jq -r '.human_tasks[0].criterion')"

# 2. Custom markers replace the defaults.
P="$TMP/project-2"
make_project "$P"
make_change "$P" custom-marker $'- [ ] 1.1 [Mensch] Abnehmen. Prüfen: bestanden.'
park_change "$P" custom-marker
CUSTOM="$TMP/custom.toml"
base_config "$CUSTOM"
printf 'human_markers = ["[Mensch]"]\n' >>"$CUSTOM"
st="$(BOSS_CONFIG="$CUSTOM" run_lib mission_done_state "$P" custom-marker)"
check_eq "custom marker: state" "waiting_human" "$(printf '%s' "$st" | jq -r '.state')"

# 3. Unmarked open task keeps the change in progress even when parked.
P="$TMP/project-3"
make_project "$P"
make_change "$P" mixed $'- [ ] 1.1 [Nutzer] Konto verknüpfen.\n- [ ] 1.2 Code schreiben.'
park_change "$P" mixed
st="$(run_lib mission_done_state "$P" mixed)"
check_eq "unmarked task: state" "in_progress" "$(printf '%s' "$st" | jq -r '.state')"
check_eq "unmarked task: agent_open" "1" "$(printf '%s' "$st" | jq -r '.tasks.agent_open')"

# 4. Checked-off human tasks leave waiting_human without a resume.
P="$TMP/project-4"
make_project "$P"
make_change "$P" checked $'- [x] 1.1 [Nutzer] Konto verknüpfen.'
park_change "$P" checked
st="$(run_lib mission_done_state "$P" checked)"
check_eq "checked tasks: state" "in_progress" "$(printf '%s' "$st" | jq -r '.state')"
check_eq "checked tasks: not parked" "in_progress" "$(printf '%s' "$st" | jq -r '.state')"

# 5. Park writes event, inbox, journal and keeps the mission doc unchanged.
P="$TMP/project-5"
make_project "$P"
make_change "$P" park-me $'- [x] 1.0 done\n- [ ] 2.1 [Nutzer] Konto verknüpfen. Prüfen: Konto ist verknüpft.'
make_mission "$P" v1 "- park-me"
base_config "$CONFIG" "$P"
before="$(cksum "$P/openspec/missions/v1.md")"
out="$(run_boss park park-me --project mission-test --note "human links the account")"
check_eq "park: status" "parked" "$(printf '%s' "$out" | jq -r '.status')"
check_eq "park: workspace released" "true" "$(printf '%s' "$out" | jq -r '.workspace_released')"
state_file="$STATE/applies/$(run_lib sha1_hex "$P")-park-me.json"
check_eq "park: state flag" "true" "$(jq -r '.parked' "$state_file")"
check_eq "park: note" "human links the account" "$(jq -r '.parked_note' "$state_file")"
check_contains "park: event" '"event":"park"' "$(cat "$STATE/cycles/$(run_lib sha1_hex "$P")-park-me.events.jsonl")"
check_contains "park: inbox" "Konto ist verknüpft." "$(cat "$STATE/inbox/"*.json)"
check_contains "park: journal" "Prüfkriterium: Konto ist verknüpft." "$(cat "$P/openspec/journal.md")"
after="$(cksum "$P/openspec/missions/v1.md")"
check_eq "park: mission doc unchanged" "$before" "$after"
mission_status="$(run_boss mission status v1 --project mission-test)"
check_eq "park: mission status" "waiting_human" "$(printf '%s' "$mission_status" | jq -r '.changes[0].state')"

# 6. Status and wait --all expose waiting_human and skip the parked state.
status="$(run_boss status park-me --project mission-test --json | jq -c '{state,human_tasks}')"
check_eq "status: waiting_human" "waiting_human" "$(printf '%s' "$status" | jq -r '.state')"
check_eq "status: human task" "2.1 [Nutzer] Konto verknüpfen. Prüfen: Konto ist verknüpft." "$(printf '%s' "$status" | jq -r '.human_tasks[0].text')"
w="$(run_boss wait --all --project "$P")"
check_eq "wait --all: parked" "parked" "$(printf '%s' "$w" | jq -r '.[0].status')"

# 7. Park refuses a change with unmarked agent work.
P="$TMP/project-7"
make_project "$P"
make_change "$P" needs-agent $'- [ ] 2.1 [Nutzer] Konto verknüpfen.\n- [ ] 2.2 Code schreiben.'
err="$(run_boss_fail park needs-agent --project "$P")"
check_contains "park refuses agent work" "agent_tasks_open" "$err"
check_contains "park refuses agent work: names task" "Code schreiben" "$err"

# 8. Resume without a live apply starts a fresh dispatch.
P="$TMP/project-8"
make_project "$P"
make_change "$P" resume-me $'- [ ] 2.1 [Nutzer] Konto verknüpfen. Prüfen: Konto ist verknüpft.'
make_mission "$P" v1 "- resume-me"
run_boss park resume-me --project "$P" >/dev/null
out="$(run_boss resume resume-me --project "$P" --note "account is linked")"
check_eq "resume: started" "started" "$(printf '%s' "$out" | jq -r '.status')"
check_eq "resume: fresh agent" "apply-resume-me" "$(printf '%s' "$out" | jq -r '.agent')"
last="$(run_lib mission_park_event "$P" resume-me)"
check_eq "resume: park cleared" "dispatch" "$last"

# 9. Resume with a live apply only clears the park.
P="$TMP/project-9"
make_project "$P"
make_change "$P" live-resume $'- [ ] 2.1 [Nutzer] Konto verknüpfen.'
mkdir -p "$STATE/applies"
jq -n --arg c live-resume --arg p "$P" '{change:$c,project:$p,agent:"apply-live-resume",pane_id:"p-live",tab_id:"tab-live",workspace_id:"ws-1",waiter_pid:null,parked:true,parked_at:"2026-01-01T00:00:00+0000"}' >"$STATE/applies/$(run_lib sha1_hex "$P")-live-resume.json"
run_lib append_event "$(run_lib events_file_for "$P" live-resume)" park '{}' >/dev/null
out="$(HERDR_LIVE_PANES=p-live run_boss resume live-resume --project "$P")"
check_eq "resume live: started" "false" "$(printf '%s' "$out" | jq -r '.started')"
check_eq "resume live: status" "resumed" "$(printf '%s' "$out" | jq -r '.status')"

# 10. Dependencies parse additively; legacy bullets keep the old order.
P="$TMP/project-10"
make_project "$P"
make_mission "$P" v1 $'- alpha\n- beta (after: alpha; human-ok: alpha)\n- gamma (after: alpha, beta)'
status="$(run_boss mission status v1 --project "$P")"
check_eq "deps: beta after" "alpha" "$(printf '%s' "$status" | jq -r '.dependencies[] | select(.name=="beta") | .after[0]')"
check_eq "deps: beta human-ok" "alpha" "$(printf '%s' "$status" | jq -r '.dependencies[] | select(.name=="beta") | .human_ok[0]')"
check_eq "deps: gamma after count" "2" "$(printf '%s' "$status" | jq -r '.dependencies[] | select(.name=="gamma") | .after | length')"
check_eq "deps: alpha plain" "[]" "$(printf '%s' "$status" | jq -c '.dependencies[] | select(.name=="alpha") | .after')"
make_mission "$P" legacy $'- old-one\n- old-two'
status="$(run_boss mission status legacy --project "$P")"
check_eq "legacy: order" "old-one old-two" "$(printf '%s' "$status" | jq -r '.changes | map(.change) | join(" ")')"
check_eq "legacy: no deps" "0" "$(printf '%s' "$status" | jq -r '.dependencies | map(.after | length) | add // 0')"

# 11. mission next skips a parked change and honours human-ok.
P="$TMP/project-11"
make_project "$P"
make_change "$P" alpha $'- [ ] 1.1 [Nutzer] Konto verknüpfen.'
make_change "$P" beta $'- [ ] 1.1 Code schreiben.'
make_change "$P" gamma $'- [ ] 1.1 Code schreiben.'
make_mission "$P" v1 $'- alpha\n- beta (after: alpha; human-ok: alpha)\n- gamma (after: alpha)'
run_boss park alpha --project "$P" >/dev/null
out="$(run_boss mission next v1 --project "$P" --skip-reconcile)"
check_eq "next: human-ok target" "beta" "$(printf '%s' "$out" | jq -r '.change')"
check_eq "next: human-ok status" "started" "$(printf '%s' "$out" | jq -r '.status')"

# 12. waiting_human bundles the handoff, and no runner is needed.
P="$TMP/project-12"
make_project "$P"
make_change "$P" parked $'- [ ] 2.1 [Nutzer] Konto verknüpfen. Prüfen: Konto ist verknüpft.\n- [ ] 2.2 [human] Kaufen. Prüfen: Beleg liegt vor.'
make_mission "$P" v1 "- parked"
run_boss park parked --project "$P" >/dev/null
out="$(env PATH="$BIN:$PATH" HOME="$TMP" BOSS_CONFIG="$CONFIG" BOSS_STATE_DIR="$STATE" HERDR_ENV=1 HERDR_PANE_ID=p-boss HERDR_WORKSPACE_ID=ws-1 HERDR_SOCKET_PATH="$SOCKET" bash "$ROOT/runtime/bin/boss" mission next v1 --project "$P" 2>/dev/null)"
check_eq "handoff: status" "waiting_human" "$(printf '%s' "$out" | jq -r '.status')"
check_eq "handoff: change" "parked" "$(printf '%s' "$out" | jq -r '.handoff[0].change')"
check_eq "handoff: tasks" "2" "$(printf '%s' "$out" | jq -r '.handoff[0].tasks | length')"
check_eq "handoff: criterion" "Beleg liegt vor." "$(printf '%s' "$out" | jq -r '.handoff[0].tasks[1].criterion')"

# 13. Checking off the parked tasks makes the change selectable again.
printf -- '- [x] 2.1 [Nutzer] Konto verknüpfen.\n- [x] 2.2 [human] Kaufen.\n' >"$P/openspec/changes/parked/tasks.md"
out="$(run_boss mission next v1 --project "$P" --skip-reconcile)"
check_eq "checked resume: change" "parked" "$(printf '%s' "$out" | jq -r '.change')"
check_eq "checked resume: status" "started" "$(printf '%s' "$out" | jq -r '.status')"

# 14. A legacy mission still selects its first unfinished change.
P="$TMP/project-14a"
make_project "$P"
make_change "$P" old-one $'- [ ] 1.1 Code.'
make_change "$P" old-two $'- [ ] 1.1 Code.'
make_mission "$P" legacy $'- old-one\n- old-two'
out="$(run_boss mission next legacy --project "$P")"
check_eq "legacy next: first change" "old-one" "$(printf '%s' "$out" | jq -r '.change')"

# 15. Dependency deadlock is not called mission_complete.
P="$TMP/project-14"
make_project "$P"
make_change "$P" lonely $'- [ ] 1.1 Code.'
make_mission "$P" v1 "- lonely (after: missing-change)"
out="$(run_boss mission next v1 --project "$P")"
check_eq "deadlock: status" "mission_blocked" "$(printf '%s' "$out" | jq -r '.status')"
check_eq "deadlock: remaining" "lonely" "$(printf '%s' "$out" | jq -r '.remaining[0]')"

# 15. The waiter exits quietly for a parked change.
P="$TMP/project-15"
make_project "$P"
make_change "$P" quiet $'- [ ] 1.1 [Nutzer] Konto verknüpfen.'
run_boss park quiet --project "$P" >/dev/null
state_file="$STATE/applies/$(run_lib sha1_hex "$P")-quiet.json"
if timeout 3 env PATH="$BIN:$PATH" HOME="$TMP" BOSS_CONFIG="$CONFIG" BOSS_STATE_DIR="$STATE" bash "$ROOT/runtime/bin/boss-waiter" "$state_file" >/dev/null 2>&1; then
  ok
else
  bad "waiter: parked change did not exit quietly"
fi

# 16. Doctor warns about a first human change without dependencies.
P="$TMP/project-16"
make_project "$P"
make_change "$P" first-human $'- [ ] 1.1 [Nutzer] Konto verknüpfen.'
make_mission "$P" v1 "- first-human"
doctor="$(run_boss doctor --project "$P" --json 2>/dev/null)"
check_eq "doctor: human dependency warn" "warn" "$(printf '%s' "$doctor" | jq -r '.checks[] | select(.id=="mission_human_dependencies") | .status')"
make_mission "$P" v1 $'- first-human\n- later (after: first-human)'
doctor="$(run_boss doctor --project "$P" --json 2>/dev/null)"
check_eq "doctor: dependency declared" "ok" "$(printf '%s' "$doctor" | jq -r '.checks[] | select(.id=="mission_human_dependencies") | .status')"

# 17. Documentation and skill mention the new behavior.
skill="$(cat "$ROOT/vision/SKILL.md")"
readme="$(cat "$ROOT/README.md")"
check_contains "skill: park" "boss park" "$skill"
check_contains "skill: resume" "boss resume" "$skill"
check_contains "skill: waiting_human" "waiting_human" "$skill"
check_contains "skill: human-ok" "human-ok" "$skill"
check_contains "skill: markers" "human_markers" "$skill"
check_contains "readme: park" "boss park" "$readme"
check_contains "readme: dependencies" "human-ok" "$readme"

# ------------------------------------------------- caller identity tests ---

REAL="$(pwd -P)"
PANES_MATCH="$(jq -nc --arg c "$REAL" '[{pane_id:"p-boss",workspace_id:"ws-1",cwd:$c}]')"
PANES_INCIDENT="$(jq -nc --arg c "$REAL" '[
  {pane_id:"p-beta",workspace_id:"ws-beta",cwd:"/tmp/beta"},
  {pane_id:"p-alpha",workspace_id:"ws-1",cwd:$c}]')"
PROC_INCIDENT="$(jq -nc --argjson a "$$" '{
  "p-beta":{pane_id:"p-beta",shell_pid:null,foreground_processes:[]},
  "p-alpha":{pane_id:"p-alpha",shell_pid:null,foreground_processes:[{pid:$a,name:"bash"}]}}')"
PROC_EMPTY='{"p-beta":{"pane_id":"p-beta","foreground_processes":[]},"p-alpha":{"pane_id":"p-alpha","foreground_processes":[]}}'

# 17a. process-info parsing: the real nested shape, the legacy flat shape and
# an empty shape.
PROC_REAL="$(jq -nc --argjson a "$$" '{"p-x":{shell_pid:42,foreground_processes:[{pid:$a,name:"bash"}]}}')"
pids="$(HERDR_PROCESS_JSON="$PROC_REAL" run_lib boss_pane_process_pids p-x)"
check_contains "process-info: real foreground pid" "$$" "$pids"
check_contains "process-info: real shell pid" "42" "$pids"

PROC_LEGACY="$(jq -nc --argjson a "$$" '{"p-x":{shell_pid:41,foreground_pid:42,foreground_pids:[43],processes:[{pid:44},45],pids:[46]}}')"
pids="$(HERDR_PROCESS_LEGACY_JSON="$PROC_LEGACY" run_lib boss_pane_process_pids p-x)"
for pid in 41 42 43 44 45 46; do
  check_contains "process-info: legacy pid $pid" "$pid" "$pids"
done

pids="$(HERDR_PROCESS_LEGACY_JSON='{"p-x":{}}' run_lib boss_pane_process_pids p-x)"
check_eq "process-info: empty shape" "" "$pids"

# 17b. A missing workspace id fails closed even with a living pane, and writes
# neither a registry nor an apply state.
out="$(HERDR_ENV=1 HERDR_PANE_ID=p-boss HERDR_WORKSPACE_ID="" \
  HERDR_PANES_JSON="$PANES_MATCH" run_lib boss_caller_identity_json "")"
check_eq "resolver: missing workspace" "missing" "$(printf '%s' "$out" | jq -r '.status')"
check_eq "resolver: missing workspace code" "caller_pane_missing" "$(printf '%s' "$out" | jq -r '.code')"
check_contains "resolver: missing workspace message" "HERDR_WORKSPACE_ID" "$(printf '%s' "$out" | jq -r '.message')"

P="$TMP/project-no-ws"
make_project "$P"
make_change "$P" no-ws '- [ ] 1.1 Code.'
NOWS="$TMP/no-ws-state"
mkdir -p "$NOWS"
sf="$NOWS/applies/$(run_lib sha1_hex "$P")-no-ws.json"
err="$(env PATH="$BIN:$PATH" HOME="$TMP" BOSS_CONFIG="$CONFIG" BOSS_STATE_DIR="$NOWS" \
  HERDR_ENV=1 HERDR_PANE_ID=p-boss HERDR_WORKSPACE_ID="" \
  HERDR_SOCKET_PATH="$SOCKET" HERDR_PANES_JSON="$PANES_MATCH" \
  bash "$ROOT/runtime/bin/boss" claim 2>&1)"
check_contains "claim: missing workspace fails" "HERDR_WORKSPACE_ID" "$err"
if [ -f "$NOWS/bosses/ws-1.json" ]; then bad "claim: missing workspace wrote registry"; else ok; fi
err="$(env PATH="$BIN:$PATH" HOME="$TMP" BOSS_CONFIG="$CONFIG" BOSS_STATE_DIR="$NOWS" \
  HERDR_ENV=1 HERDR_PANE_ID=p-boss HERDR_WORKSPACE_ID="" \
  HERDR_SOCKET_PATH="$SOCKET" HERDR_PANES_JSON="$PANES_MATCH" \
  bash "$ROOT/runtime/bin/boss" dispatch no-ws --project "$P" 2>&1)"
check_contains "dispatch: missing workspace fails" "HERDR_WORKSPACE_ID" "$err"
if [ -f "$sf" ]; then bad "dispatch: missing workspace wrote apply state"; else ok; fi


# 18. The resolver accepts a matching environment, fails stale/missing ones
# and reports the pane found by process ancestry.
out="$(HERDR_ENV=1 HERDR_PANE_ID=p-boss HERDR_WORKSPACE_ID=ws-1 \
  HERDR_PANES_JSON="$PANES_MATCH" run_lib boss_caller_identity_json "")"
check_eq "resolver: matching env" "ok" "$(printf '%s' "$out" | jq -r '.status')"
check_eq "resolver: matching source" "env" "$(printf '%s' "$out" | jq -r '.source')"

out="$(HERDR_ENV=1 HERDR_PANE_ID=p-none HERDR_WORKSPACE_ID=ws-1 \
  HERDR_PANES_JSON="$PANES_MATCH" run_lib boss_caller_identity_json "")"
check_eq "resolver: missing pane" "missing" "$(printf '%s' "$out" | jq -r '.status')"
check_eq "resolver: missing code" "caller_pane_missing" "$(printf '%s' "$out" | jq -r '.code')"

out="$(HERDR_ENV=1 HERDR_PANE_ID=p-boss HERDR_WORKSPACE_ID=ws-1 \
  HERDR_PANES_JSON="$PANES_MATCH" HERDR_AGENTS_JSON='[]' \
  run_lib boss_caller_identity_json "no-such-target")"
check_eq "resolver: invalid override" "invalid_override" "$(printf '%s' "$out" | jq -r '.status')"

out="$(HERDR_ENV=1 HERDR_PANE_ID=p-beta HERDR_WORKSPACE_ID=ws-beta \
  HERDR_PANES_JSON="$PANES_INCIDENT" HERDR_PROCESS_JSON="$PROC_INCIDENT" \
  HERDR_AGENTS_JSON='[]' run_lib boss_caller_identity_json "")"
check_eq "resolver: stale env" "mismatch" "$(printf '%s' "$out" | jq -r '.status')"
check_eq "resolver: stale code" "caller_pane_mismatch" "$(printf '%s' "$out" | jq -r '.code')"
check_eq "resolver: detected pane" "p-alpha" "$(printf '%s' "$out" | jq -r '.detected_pane.pane_id')"
check_contains "resolver: names likely pane" "p-alpha" "$(printf '%s' "$out" | jq -r '.message')"

out="$(HERDR_ENV=1 HERDR_PANE_ID=p-beta HERDR_WORKSPACE_ID=ws-beta \
  HERDR_PANES_JSON="$PANES_INCIDENT" HERDR_PROCESS_JSON="$PROC_EMPTY" \
  HERDR_AGENTS_JSON='[]' run_lib boss_caller_identity_json "")"
check_eq "resolver: no ancestry match" "null" "$(printf '%s' "$out" | jq -c '.detected_pane')"
check_contains "resolver: unverified" "unverified" "$(printf '%s' "$out" | jq -r '.message')"

PANES_OTHER="$(jq -nc --arg c "$REAL" '[{pane_id:"p-boss",workspace_id:"ws-1",cwd:$c},{pane_id:"p-other",workspace_id:"ws-2",cwd:"/tmp/other"}]')"
out="$(HERDR_ENV=1 HERDR_PANE_ID=p-boss HERDR_WORKSPACE_ID=ws-1 \
  HERDR_PANES_JSON="$PANES_OTHER" HERDR_AGENTS_JSON='[]' \
  run_lib boss_caller_identity_json "p-other")"
check_eq "resolver: as pane" "ok" "$(printf '%s' "$out" | jq -r '.status')"
check_eq "resolver: as pane source" "as" "$(printf '%s' "$out" | jq -r '.source')"
check_eq "resolver: as pane workspace" "ws-2" "$(printf '%s' "$out" | jq -r '.workspace_id')"

AGENTS_NAMED='[{"name":"boss-wc","pane_id":"p-agent","workspace_id":"ws-9","cwd":"/agent"}]'
PANES_AGENT='[{"pane_id":"p-agent","workspace_id":"ws-9","cwd":"/agent"}]'
out="$(HERDR_ENV=1 HERDR_PANE_ID=p-boss HERDR_WORKSPACE_ID=ws-1 \
  HERDR_PANES_JSON="$PANES_AGENT" HERDR_AGENTS_JSON="$AGENTS_NAMED" \
  run_lib boss_caller_identity_json "boss-wc")"
check_eq "resolver: as agent" "ok" "$(printf '%s' "$out" | jq -r '.status')"
check_eq "resolver: as agent pane" "p-agent" "$(printf '%s' "$out" | jq -r '.pane_id')"
check_eq "resolver: as agent name" "boss-wc" "$(printf '%s' "$out" | jq -r '.agent')"

# 19. claim fails closed on the stale environment and writes nothing; --as
# repairs it with the real pane.
err="$(BOSS_TEST_PANE=p-beta BOSS_TEST_WORKSPACE=ws-beta \
  HERDR_PANES_JSON="$PANES_INCIDENT" HERDR_PROCESS_JSON="$PROC_INCIDENT" \
  run_boss_fail claim)"
check_contains "claim: stale env fails" "caller_pane_mismatch" "$err"
if [ -f "$STATE/bosses/ws-beta.json" ]; then
  bad "claim: stale env wrote a registry entry"
else
  ok
fi
out="$(BOSS_TEST_PANE=p-beta BOSS_TEST_WORKSPACE=ws-beta \
  HERDR_PANES_JSON="$PANES_INCIDENT" HERDR_PROCESS_JSON="$PROC_INCIDENT" \
  run_boss claim --as p-alpha)"
check_eq "claim: --as succeeds" "claimed" "$(printf '%s' "$out" | jq -r '.status')"
check_eq "claim: --as registry pane" "p-alpha" "$(jq -r '.pane_id' "$STATE/bosses/ws-1.json")"

# 19b. Claim guard: a pane that already carries another registered living boss
# name is never renamed without --force. This is the exact cross-project repro: a
# stale HERDR_PANE_ID in workspace wD asking to claim the boss-w3 name.
CL="$TMP/claim-state"
mkdir -p "$CL/bosses" "$CL/applies"
PANES_TWO_WS="$(jq -nc --arg c "$REAL" '[
  {pane_id:"w3:p1",workspace_id:"w3",cwd:$c},
  {pane_id:"wD:p1",workspace_id:"wD",cwd:"/tmp/wd"}]')"
AGENTS_TWO_WS="$(jq -nc --arg c "$REAL" '[
  {name:"boss-w3",pane_id:"w3:p1",workspace_id:"w3",cwd:$c},
  {name:"boss-wd",pane_id:"wD:p1",workspace_id:"wD",cwd:"/tmp/wd"}]')"
PROC_TWO_WS="$(jq -nc --argjson a "$$" '{
  "w3:p1":{shell_pid:null,foreground_processes:[{pid:$a}]},
  "wD:p1":{shell_pid:null,foreground_processes:[]}}')"
jq -n '{workspace_id:"wD",pane_id:"wD:p1",agent:"boss-wd",claimed_at:"2026-01-01T00:00:00+0000"}' \
  >"$CL/bosses/wd.json"
wd_before="$(cksum "$CL/bosses/wd.json")"
RENAME_CLAIM="$TMP/rename-claim.log"
: >"$RENAME_CLAIM"
err="$(HERDR_RENAME_LOG="$RENAME_CLAIM" BOSS_TEST_PANE=wD:p1 BOSS_TEST_WORKSPACE=wD \
  HERDR_PANES_JSON="$PANES_TWO_WS" HERDR_AGENTS_JSON="$AGENTS_TWO_WS" \
  HERDR_PROCESS_JSON="$PROC_TWO_WS" run_boss_fail_state "$CL" claim --name boss-w3)"
check_contains "claim repro: stale env refused" "caller_pane_mismatch" "$err"
check_contains "claim repro: names real pane" "w3:p1" "$err"
check_eq "claim repro: registry unchanged" "$wd_before" "$(cksum "$CL/bosses/wd.json")"
check_eq "claim repro: no rename" "" "$(cat "$RENAME_CLAIM")"
if [ -f "$CL/bosses/w3.json" ]; then bad "claim repro: wrote a w3 registry"; else ok; fi

err="$(HERDR_RENAME_LOG="$RENAME_CLAIM" HERDR_PANES_JSON="$PANES_TWO_WS" \
  HERDR_AGENTS_JSON="$AGENTS_TWO_WS" run_boss_fail_state "$CL" claim --as wD:p1 --name boss-w3)"
check_contains "claim repro: explicit --as refused" "boss_exists" "$err"
check_contains "claim repro: naming the foreign boss" "boss-wd" "$err"
check_eq "claim repro: registry still unchanged" "$wd_before" "$(cksum "$CL/bosses/wd.json")"
check_eq "claim repro: --as did not rename" "" "$(cat "$RENAME_CLAIM")"

# The explicit --force is the only exception and reports 'renamed'.
out="$(HERDR_RENAME_LOG="$RENAME_CLAIM" HERDR_PANES_JSON="$PANES_TWO_WS" \
  HERDR_AGENTS_JSON="$AGENTS_TWO_WS" run_boss_state "$CL" claim --as wD:p1 --name boss-w3 --force)"
check_eq "claim force: status" "renamed" "$(printf '%s' "$out" | jq -r '.status')"
check_eq "claim force: registry agent" "boss-w3" "$(jq -r '.agent' "$CL/bosses/wd.json")"
check_contains "claim force: rename recorded" "wD:p1 boss-w3" "$(cat "$RENAME_CLAIM")"

# Auto-claiming paths never force. The session path calls boss_claim_pane with
# three arguments, so a foreign registered name still aborts.
out="$(HERDR_RENAME_LOG="$RENAME_CLAIM" HERDR_PANES_JSON="$PANES_TWO_WS" \
  HERDR_AGENTS_JSON="$AGENTS_TWO_WS" run_boss_state "$CL" claim --as w3:p1 --name boss-w3)"
check_eq "claim unnamed: status" "claimed" "$(printf '%s' "$out" | jq -r '.status')"
check_eq "claim unnamed: registry pane" "w3:p1" "$(jq -r '.pane_id' "$CL/bosses/w3.json")"
out="$(HERDR_RENAME_LOG="$RENAME_CLAIM" HERDR_PANES_JSON="$PANES_TWO_WS" \
  HERDR_AGENTS_JSON="$AGENTS_TWO_WS" run_boss_state "$CL" claim --as w3:p1 --name boss-w3)"
check_eq "claim repeat: already_claimed" "already_claimed" "$(printf '%s' "$out" | jq -r '.status')"
err="$(HERDR_RENAME_LOG="$RENAME_CLAIM" HERDR_PANES_JSON="$PANES_TWO_WS" \
  HERDR_AGENTS_JSON="$AGENTS_TWO_WS" run_boss_state "$CL" claim --as w3:p1 --name boss-w3x 2>&1)"
check_contains "claim rename guard: refused" "boss_exists" "$err"
check_eq "claim rename guard: registry kept" "boss-w3" "$(jq -r '.agent' "$CL/bosses/w3.json")"
out="$(HERDR_RENAME_LOG="$RENAME_CLAIM" HERDR_PANES_JSON="$PANES_TWO_WS" \
  HERDR_AGENTS_JSON="$AGENTS_TWO_WS" run_boss_state "$CL" claim --as w3:p1 --name boss-w3x --force)"
check_eq "claim rename force: status" "renamed" "$(printf '%s' "$out" | jq -r '.status')"
check_eq "claim rename force: registry agent" "boss-w3x" "$(jq -r '.agent' "$CL/bosses/w3.json")"

# A dispatch whose auto-claim would rename a foreign boss aborts instead.
P="$TMP/project-claim-dispatch"
make_project "$P"
make_change "$P" claim-dispatch '- [ ] 1.1 Code.'
sf="$CL/applies/$(run_lib sha1_hex "$P")-claim-dispatch.json"
PANES_DISPATCH="$(jq -nc --arg c "$REAL" '[{pane_id:"p-disp",workspace_id:"ws-disp",cwd:$c}]')"
AGENTS_DISPATCH='[{"name":"boss-wd","pane_id":"p-disp","workspace_id":"ws-disp","cwd":"/tmp/wd"}]'
jq -n '{workspace_id:"wd",pane_id:"p-disp",agent:"boss-wd",claimed_at:"2026-01-01T00:00:00+0000"}' \
  >"$CL/bosses/wd.json"
wd_disp_before="$(cksum "$CL/bosses/wd.json")"
err="$(HERDR_RENAME_LOG="$RENAME_CLAIM" BOSS_TEST_PANE=p-disp BOSS_TEST_WORKSPACE=ws-disp \
  HERDR_PANES_JSON="$PANES_DISPATCH" HERDR_AGENTS_JSON="$AGENTS_DISPATCH" \
  run_boss_fail_state "$CL" dispatch claim-dispatch --project "$P")"
check_contains "dispatch auto-claim: refused foreign rename" "boss_exists" "$err"
check_eq "dispatch auto-claim: registry unchanged" "$wd_disp_before" "$(cksum "$CL/bosses/wd.json")"
if [ -f "$sf" ]; then bad "dispatch auto-claim: wrote apply state"; else ok; fi

# 20. dispatch from a stale environment fails before any registry or state write.
P="$TMP/project-stale-dispatch"
make_project "$P"
make_change "$P" stale-dispatch '- [ ] 1.1 Code.'
sf="$STATE/applies/$(run_lib sha1_hex "$P")-stale-dispatch.json"
err="$(BOSS_TEST_PANE=p-beta BOSS_TEST_WORKSPACE=ws-beta \
  HERDR_PANES_JSON="$PANES_INCIDENT" HERDR_PROCESS_JSON="$PROC_INCIDENT" \
  run_boss_fail dispatch stale-dispatch --project "$P")"
check_contains "dispatch: stale env fails" "caller_pane_mismatch" "$err"
if [ -f "$sf" ]; then bad "dispatch: stale env wrote apply state"; else ok; fi
if [ -f "$STATE/bosses/ws-beta.json" ]; then bad "dispatch: stale env wrote registry"; else ok; fi

# 21. A same-workspace, same-project dispatch records the verified dispatcher
# scope and a wake target; a cross-project dispatch (same or other workspace)
# adds the project flag and warning.
P="$TMP/project-same-ws"
make_project "$P"
make_change "$P" same-ws '- [ ] 1.1 Code.'
out="$(cd "$P" && run_boss dispatch same-ws --project "$P")"
sf="$STATE/applies/$(run_lib sha1_hex "$P")-same-ws.json"
check_eq "dispatch same: status" "started" "$(printf '%s' "$out" | jq -r '.status')"
check_eq "dispatch same: boss workspace" "ws-1" "$(jq -r '.boss_workspace' "$sf")"
check_eq "dispatch same: boss cwd" "$P" "$(jq -r '.boss_cwd' "$sf")"
check_eq "dispatch same: no cross flag" "false" "$(jq -r '.boss_cross_workspace' "$sf")"
check_eq "dispatch same: no cross-project flag" "false" "$(jq -r '.boss_cross_project' "$sf")"
check_eq "dispatch same: wake target workspace" "ws-1" "$(printf '%s' "$out" | jq -r '.wake_target.workspace')"
check_eq "dispatch same: no warnings" "0" "$(printf '%s' "$out" | jq -r '.warnings | length')"

P="$TMP/project-cross-project"
make_project "$P"
make_change "$P" cross-project '- [ ] 1.1 Code.'
out="$(run_boss dispatch cross-project --project "$P")"
sf="$STATE/applies/$(run_lib sha1_hex "$P")-cross-project.json"
check_eq "dispatch cross-project: same workspace" "ws-1" "$(jq -r '.boss_workspace' "$sf")"
check_eq "dispatch cross-project: workspace flag" "false" "$(jq -r '.boss_cross_workspace' "$sf")"
check_eq "dispatch cross-project: project flag" "true" "$(jq -r '.boss_cross_project' "$sf")"
check_eq "dispatch cross-project: one warning" "1" "$(printf '%s' "$out" | jq -r '.warnings | length')"
check_contains "dispatch cross-project: warning text" "cross-project" "$(printf '%s' "$out" | jq -r '.warnings[0]')"

P="$TMP/project-cross-ws"
make_project "$P"
make_change "$P" cross-ws '- [ ] 1.1 Code.'
PANES_CROSS="$(jq -nc --arg c "$REAL" '[{pane_id:"p-other",workspace_id:"ws-2",cwd:$c}]')"
out="$(BOSS_TEST_PANE=p-other BOSS_TEST_WORKSPACE=ws-2 \
  HERDR_PANES_JSON="$PANES_CROSS" HERDR_AGENTS_JSON='[]' \
  run_boss dispatch cross-ws --project "$P")"
sf="$STATE/applies/$(run_lib sha1_hex "$P")-cross-ws.json"
check_eq "dispatch cross: boss workspace" "ws-2" "$(jq -r '.boss_workspace' "$sf")"
check_eq "dispatch cross: cross flag" "true" "$(jq -r '.boss_cross_workspace' "$sf")"
check_eq "dispatch cross: cross-project flag" "true" "$(jq -r '.boss_cross_project' "$sf")"
check_eq "dispatch cross: two warnings" "2" "$(printf '%s' "$out" | jq -r '.warnings | length')"
check_eq "dispatch cross: wake target workspace" "ws-2" "$(printf '%s' "$out" | jq -r '.wake_target.workspace')"

# A dispatcher whose cwd is unknown keeps the legacy workspace-only rule.
P="$TMP/project-no-cwd"
make_project "$P"
make_change "$P" no-cwd '- [ ] 1.1 Code.'
PANES_NO_CWD='[{"pane_id":"p-nocwd","workspace_id":"ws-1"}]'
out="$(HERDR_PANES_JSON="$PANES_NO_CWD" HERDR_AGENTS_JSON='[]' \
  run_boss dispatch no-cwd --project "$P" --as p-nocwd)"
sf="$STATE/applies/$(run_lib sha1_hex "$P")-no-cwd.json"
check_eq "dispatch no-cwd: blank boss cwd" "null" "$(jq -r '.boss_cwd' "$sf")"
check_eq "dispatch no-cwd: project flag" "false" "$(jq -r '.boss_cross_project' "$sf")"
check_eq "dispatch no-cwd: no warnings" "0" "$(printf '%s' "$out" | jq -r '.warnings | length')"

# 22. Wake-time filtering: same workspace, flagged cross, unflagged legacy,
# moved registry entry and no safe candidate.
WF="$TMP/wake-same.json"
jq -n '{change:"w",project:"/p",workspace_id:"ws-1",boss:"boss-a",boss_pane:"p-a",boss_workspace:"ws-1",boss_cross_workspace:false}' >"$WF"
AG_SAME='[{"name":"boss-a","pane_id":"p-a","workspace_id":"ws-1"}]'
check_eq "wake: same-workspace dispatcher" "boss-a" \
  "$(HERDR_AGENTS_JSON="$AG_SAME" run_lib boss_resolve_agent "$WF" | sed -n '1p')"

WF2="$TMP/wake-cross-flagged.json"
jq -n '{change:"w",project:"/p",workspace_id:"ws-1",boss:"boss-a",boss_pane:"p-a",boss_workspace:"ws-2",boss_cross_workspace:true}' >"$WF2"
AG_CROSS='[{"name":"boss-a","pane_id":"p-a","workspace_id":"ws-2"}]'
check_eq "wake: flagged cross dispatcher" "boss-a" \
  "$(HERDR_AGENTS_JSON="$AG_CROSS" run_lib boss_resolve_agent "$WF2" | sed -n '1p')"

WF3="$TMP/wake-legacy-cross.json"
jq -n '{change:"w",project:"/p",workspace_id:"ws-1",boss:"boss-a",boss_pane:"p-a"}' >"$WF3"
mkdir -p "$STATE/bosses"
run_lib boss_write_registry "$STATE/bosses/ws-1.json" ws-1 p-ws boss-w >/dev/null
AG_LEGACY='[{"name":"boss-a","pane_id":"p-a","workspace_id":"ws-2"},{"name":"boss-w","pane_id":"p-ws","workspace_id":"ws-1"}]'
check_eq "wake: legacy cross skipped" "boss-w" \
  "$(HERDR_AGENTS_JSON="$AG_LEGACY" run_lib boss_resolve_agent "$WF3" | sed -n '1p')"
check_eq "wake: legacy cross reason" "cross_workspace" \
  "$(HERDR_AGENTS_JSON="$AG_LEGACY" run_lib boss_wake_plan "$WF3" | jq -r '.skipped[0].reason')"

jq -n '{change:"w",project:"/p",workspace_id:"ws-1",boss:"boss-a",boss_pane:"p-a",boss_workspace:"ws-1"}' >"$TMP/wake-legacy-same.json"
check_eq "wake: legacy same workspace" "boss-a" \
  "$(HERDR_AGENTS_JSON='[{"name":"boss-a","pane_id":"p-a","workspace_id":"ws-1"}]' \
    run_lib boss_resolve_agent "$TMP/wake-legacy-same.json" | sed -n '1p')"

jq -n '{change:"w",project:"/p",workspace_id:"ws-1",boss:"boss-a",boss_pane:"p-a"}' >"$TMP/wake-no-safe.json"
check_eq "wake: no safe candidate" "" \
  "$(HERDR_AGENTS_JSON="$AG_CROSS" run_lib boss_resolve_agent "$TMP/wake-no-safe.json")"

jq -n '{change:"w",project:"/p",workspace_id:"ws-1"}' >"$TMP/wake-moved.json"
check_eq "wake: moved registry skipped" "moved" \
  "$(HERDR_AGENTS_JSON='[{"name":"boss-w","pane_id":"p-ws","workspace_id":"ws-9"}]' \
    run_lib boss_wake_plan "$TMP/wake-moved.json" | jq -r '.skipped[0].reason')"

# 22a. Project-scoped wake safety: a same-workspace dispatcher whose recorded
# cwd is unrelated is skipped, an explicit cross-project flag allows it, and a
# legacy state without boss_cwd keeps the workspace-only rule.
P_WAKE="$TMP/project-wake"
make_project "$P_WAKE"
WF_CP="$TMP/wake-cross-project.json"
jq -n --arg p "$P_WAKE" '{change:"w",project:$p,workspace_id:"ws-1",
  boss:"boss-a",boss_pane:"p-a",boss_workspace:"ws-1",
  boss_cwd:"/tmp/other-project",boss_cross_workspace:false,boss_cross_project:false}' >"$WF_CP"
AG_CP='[{"name":"boss-a","pane_id":"p-a","workspace_id":"ws-1","cwd":"/tmp/other-project"}]'
check_eq "wake: cross-project dispatcher skipped" "" \
  "$(HERDR_AGENTS_JSON="$AG_CP" run_lib boss_resolve_agent "$WF_CP")"
check_eq "wake: cross-project reason" "cross_project" \
  "$(HERDR_AGENTS_JSON="$AG_CP" run_lib boss_wake_plan "$WF_CP" | jq -r '.skipped[0].reason')"

jq '.boss_cross_project = true' "$WF_CP" >"$TMP/wake-cross-project-flag.json"
check_eq "wake: flagged cross-project dispatcher" "boss-a" \
  "$(HERDR_AGENTS_JSON="$AG_CP" run_lib boss_resolve_agent "$TMP/wake-cross-project-flag.json" | sed -n '1p')"

# Legacy without boss_cross_project reads as false and without boss_cwd keeps
# the workspace-only rule.
jq -n '{change:"w",project:"/p",workspace_id:"ws-1",boss:"boss-a",boss_pane:"p-a",boss_workspace:"ws-1"}' \
  >"$TMP/wake-legacy-noflag.json"
check_eq "wake: legacy no flag allowed" "boss-a" \
  "$(HERDR_AGENTS_JSON='[{"name":"boss-a","pane_id":"p-a","workspace_id":"ws-1","cwd":"/tmp/other"}]' \
    run_lib boss_resolve_agent "$TMP/wake-legacy-noflag.json" | sed -n '1p')"

# 22b. A workspace boss whose known cwd is unrelated is skipped as
# cross_project; a related cwd keeps it as a candidate.
WF_WS="$TMP/wake-workspace-boss.json"
jq -n --arg p "$P_WAKE" '{change:"w",project:$p,workspace_id:"ws-1"}' >"$WF_WS"
check_eq "wake: workspace boss cross-project reason" "cross_project" \
  "$(HERDR_AGENTS_JSON='[{"name":"boss-w","pane_id":"p-ws","workspace_id":"ws-1","cwd":"/tmp/other-project"}]' \
    run_lib boss_wake_plan "$WF_WS" | jq -r '.skipped[0].reason')"
AG_WS_REL="$(jq -nc --arg p "$P_WAKE" '[{name:"boss-w",pane_id:"p-ws",workspace_id:"ws-1",cwd:$p}]')"
check_eq "wake: workspace boss related cwd" "boss-w" \
  "$(HERDR_AGENTS_JSON="$AG_WS_REL" run_lib boss_resolve_agent "$WF_WS" | sed -n '1p')"

# 23. retarget: default caller, explicit target, unknown apply, and the wake
# order after a retarget.
P="$TMP/project-retarget"
make_project "$P"
jq -n --arg p "$P" '{change:"retarget-me",project:$p,workspace_id:"ws-1",agent:"apply-retarget-me",
  pane_id:"apply-pane",tab_id:"tab",boss:"boss-old",boss_pane:"p-old",
  boss_workspace:"ws-1",boss_cross_workspace:false,waiter_pid:null}' \
  >"$STATE/applies/$(run_lib sha1_hex "$P")-retarget-me.json"
sf="$STATE/applies/$(run_lib sha1_hex "$P")-retarget-me.json"
AG_RET='[{"name":"boss-old","pane_id":"p-old","workspace_id":"ws-1"},{"name":"boss-new","pane_id":"p-boss","workspace_id":"ws-1"}]'
out="$(HERDR_AGENTS_JSON="$AG_RET" run_boss retarget retarget-me --project "$P")"
check_eq "retarget: status" "retargeted" "$(printf '%s' "$out" | jq -r '.status')"
check_eq "retarget: new boss" "boss-new" "$(jq -r '.boss' "$sf")"
check_eq "retarget: new pane" "p-boss" "$(jq -r '.boss_pane' "$sf")"
check_eq "retarget: old target kept in result" "boss-old" "$(printf '%s' "$out" | jq -r '.old.boss')"
check_contains "retarget: event" '"event":"retarget"' \
  "$(cat "$STATE/cycles/$(run_lib sha1_hex "$P")-retarget-me.events.jsonl")"
check_eq "retarget: next wake uses new target" "boss-new" \
  "$(HERDR_AGENTS_JSON="$AG_RET" run_lib boss_resolve_agent "$sf" | sed -n '1p')"

out="$(HERDR_AGENTS_JSON="$AG_RET" HERDR_PANES_JSON="$PANES_OTHER" \
  run_boss retarget retarget-me --project "$P" --to p-other)"
check_eq "retarget: explicit cross flag" "true" "$(jq -r '.boss_cross_workspace' "$sf")"
check_eq "retarget: explicit workspace" "ws-2" "$(jq -r '.boss_workspace' "$sf")"

err="$(HERDR_AGENTS_JSON="$AG_RET" run_boss_fail retarget no-such-apply --project "$P")"
check_contains "retarget: unknown apply" "no_apply" "$err"

# 23a. Retarget is state-only: an explicit target in a free workspace is not
# renamed and creates no registry; the default caller path leaves a pre-existing
# registry byte-for-byte unchanged.
PT="$TMP/project-retarget-free"
make_project "$PT"
RET1="$TMP/retarget-free-state"
mkdir -p "$RET1/applies"
jq -n --arg p "$PT" '{change:"free-target",project:$p,workspace_id:"ws-1",
  agent:"apply-free-target",pane_id:"apply-pane",tab_id:"tab",
  boss:"boss-old",boss_pane:"p-old",boss_workspace:"ws-1",waiter_pid:null}' \
  >"$RET1/applies/$(run_lib sha1_hex "$PT")-free-target.json"
RENAME_LOG="$TMP/rename-free.log"
: >"$RENAME_LOG"
out="$(HERDR_RENAME_LOG="$RENAME_LOG" HERDR_AGENTS_JSON="$AG_RET" HERDR_PANES_JSON="$PANES_OTHER" \
  run_boss_state "$RET1" retarget free-target --project "$PT" --to p-other)"
check_eq "retarget free: status" "retargeted" "$(printf '%s' "$out" | jq -r '.status')"
check_eq "retarget free: new workspace" "ws-2" "$(jq -r '.boss_workspace' "$RET1/applies/$(run_lib sha1_hex "$PT")-free-target.json")"
if [ -f "$RET1/bosses/ws-2.json" ]; then bad "retarget free: created a registry entry"; else ok; fi
check_eq "retarget free: no rename" "" "$(cat "$RENAME_LOG")"

RET2="$TMP/retarget-registry-state"
mkdir -p "$RET2/applies" "$RET2/bosses"
jq -n --arg p "$PT" '{change:"keep-registry",project:$p,workspace_id:"ws-1",
  agent:"apply-keep-registry",pane_id:"apply-pane",tab_id:"tab",
  boss:"boss-old",boss_pane:"p-old",boss_workspace:"ws-1",waiter_pid:null}' \
  >"$RET2/applies/$(run_lib sha1_hex "$PT")-keep-registry.json"
jq -n '{workspace_id:"ws-1",pane_id:"p-ws",agent:"boss-w",claimed_at:"2026-01-01T00:00:00+0000"}' \
  >"$RET2/bosses/ws-1.json"
before="$(cksum "$RET2/bosses/ws-1.json")"
RENAME_LOG2="$TMP/rename-default.log"
: >"$RENAME_LOG2"
out="$(HERDR_RENAME_LOG="$RENAME_LOG2" HERDR_AGENTS_JSON="$AG_RET" \
  run_boss_state "$RET2" retarget keep-registry --project "$PT")"
check_eq "retarget default: status" "retargeted" "$(printf '%s' "$out" | jq -r '.status')"
check_eq "retarget default: dispatcher updated" "boss-new" \
  "$(jq -r '.boss' "$RET2/applies/$(run_lib sha1_hex "$PT")-keep-registry.json")"
check_eq "retarget default: registry unchanged" "$before" "$(cksum "$RET2/bosses/ws-1.json")"
check_eq "retarget default: no rename" "" "$(cat "$RENAME_LOG2")"

# 23b. 'boss claim --as' remains the separate registry repair after a
# state-only retarget.
RET3="$TMP/retarget-claim-state"
mkdir -p "$RET3/applies"
jq -n --arg p "$PT" '{change:"claim-after-retarget",project:$p,workspace_id:"ws-1",
  agent:"apply-claim-after-retarget",pane_id:"apply-pane",tab_id:"tab",
  boss:"boss-old",boss_pane:"p-old",boss_workspace:"ws-1",waiter_pid:null}' \
  >"$RET3/applies/$(run_lib sha1_hex "$PT")-claim-after-retarget.json"
PANES_CLAIM='[{"pane_id":"p-claim3","workspace_id":"ws-3","cwd":"/tmp/claim3"}]'
AGENTS_CLAIM='[{"name":"boss-claim3","pane_id":"p-claim3","workspace_id":"ws-3","cwd":"/tmp/claim3"}]'
out="$(HERDR_AGENTS_JSON="$AGENTS_CLAIM" HERDR_PANES_JSON="$PANES_CLAIM" \
  run_boss_state "$RET3" retarget claim-after-retarget --project "$PT" --to p-claim3)"
check_eq "retarget claim: state target" "boss-claim3" \
  "$(jq -r '.boss' "$RET3/applies/$(run_lib sha1_hex "$PT")-claim-after-retarget.json")"
if [ -f "$RET3/bosses/ws-3.json" ]; then bad "retarget claim: retarget wrote registry"; else ok; fi
out="$(HERDR_AGENTS_JSON="$AGENTS_CLAIM" HERDR_PANES_JSON="$PANES_CLAIM" \
  run_boss_state "$RET3" claim --as p-claim3 --name boss-claim3)"
check_eq "claim repair: status" "claimed" "$(printf '%s' "$out" | jq -r '.status')"
check_eq "claim repair: registry pane" "p-claim3" "$(jq -r '.pane_id' "$RET3/bosses/ws-3.json")"

# 23c. A cross-project retarget records the flag and the next wake still uses
# the target; a same-project retarget records false.
RET4="$TMP/retarget-project-state"
mkdir -p "$RET4/applies"
jq -n --arg p "$PT" '{change:"cross-project-retarget",project:$p,workspace_id:"ws-1",
  agent:"apply-cross-project-retarget",pane_id:"apply-pane",tab_id:"tab",
  boss:"boss-old",boss_pane:"p-old",boss_workspace:"ws-1",waiter_pid:null}' \
  >"$RET4/applies/$(run_lib sha1_hex "$PT")-cross-project-retarget.json"
P_OTHER="$TMP/project-other"
make_project "$P_OTHER"
PANES_PROJ="$(jq -nc --arg a "$PT" --arg b "$P_OTHER" '[
  {pane_id:"p-proj",workspace_id:"ws-1",cwd:$a},
  {pane_id:"p-otherproj",workspace_id:"ws-1",cwd:$b}]')"
AGENTS_PROJ="$(jq -nc --arg a "$PT" --arg b "$P_OTHER" '[
  {name:"boss-proj",pane_id:"p-proj",workspace_id:"ws-1",cwd:$a},
  {name:"boss-otherproj",pane_id:"p-otherproj",workspace_id:"ws-1",cwd:$b}]')"
out="$(HERDR_AGENTS_JSON="$AGENTS_PROJ" HERDR_PANES_JSON="$PANES_PROJ" \
  run_boss_state "$RET4" retarget cross-project-retarget --project "$PT" --to p-proj)"
check_eq "retarget project: same flag" "false" \
  "$(jq -r '.boss_cross_project' "$RET4/applies/$(run_lib sha1_hex "$PT")-cross-project-retarget.json")"
out="$(HERDR_AGENTS_JSON="$AGENTS_PROJ" HERDR_PANES_JSON="$PANES_PROJ" \
  run_boss_state "$RET4" retarget cross-project-retarget --project "$PT" --to p-otherproj)"
check_eq "retarget project: cross flag" "true" "$(jq -r '.boss_cross_project' \
  "$RET4/applies/$(run_lib sha1_hex "$PT")-cross-project-retarget.json")"
check_eq "retarget project: result flag" "true" "$(printf '%s' "$out" | jq -r '.boss_cross_project')"
check_eq "retarget project: result new flag" "true" "$(printf '%s' "$out" | jq -r '.new.boss_cross_project')"
check_eq "retarget project: next wake uses target" "boss-otherproj" \
  "$(HERDR_AGENTS_JSON="$AGENTS_PROJ" run_lib boss_resolve_agent \
    "$RET4/applies/$(run_lib sha1_hex "$PT")-cross-project-retarget.json" | sed -n '1p')"

check_eq "retarget wrapper count" "17" "$(ls "$ROOT/commands/opencode"/boss-*.md | wc -l | tr -d ' ')"
check_eq "retarget claude wrapper count" "17" "$(ls "$ROOT/commands/claude/boss"/*.md | wc -l | tr -d ' ')"
help_out="$(run_boss_fail --help)"
check_contains "retarget: help" "boss retarget" "$help_out"

# 24. Wake visibility: next target and the last wake in status JSON/text.
# Point the apply back at the same-workspace caller before inspecting its plan.
HERDR_AGENTS_JSON="$AG_RET" run_boss retarget retarget-me --project "$P" >/dev/null
ev="$(run_lib events_file_for "$P" retarget-me)"
run_lib boss_record_wake_event "$ev" retarget-me "$P" boss-old sleeper >/dev/null
out="$(HERDR_AGENTS_JSON="$AG_RET" run_boss status retarget-me --project "$P" --json)"
check_eq "status: next wake source" "dispatcher" "$(printf '%s' "$out" | jq -r '.wake_target.source')"
check_eq "status: last wake event" "wake" "$(printf '%s' "$out" | jq -r '.last_wake.event')"
check_eq "status: last wake target" "boss-old" "$(printf '%s' "$out" | jq -r '.last_wake.target')"
txt="$(HERDR_AGENTS_JSON="$AG_RET" run_boss status retarget-me --project "$P" 2>/dev/null)"
check_contains "status: text next wake" "wake next:" "$txt"
check_contains "status: text last wake" "last wake: boss-old" "$txt"

# 24a. Review defines the same wake block as status and completes in text mode
# without an unbound variable.
P="$TMP/project-review-text"
make_project "$P"
make_change "$P" review-text '- [ ] 1.1 Code.'
jq -n --arg p "$P" '{change:"review-text",project:$p,workspace_id:"ws-1",
  agent:"apply-review-text",pane_id:"apply-pane",tab_id:"tab",
  boss:"boss-rev",boss_pane:"p-rev",boss_workspace:"ws-1",boss_cwd:$p,waiter_pid:null}' \
  >"$STATE/applies/$(run_lib sha1_hex "$P")-review-text.json"
AG_REV="$(jq -nc --arg p "$P" '[{name:"boss-rev",pane_id:"p-rev",workspace_id:"ws-1",cwd:$p}]')"
ev_rev="$(run_lib events_file_for "$P" review-text)"
HERDR_AGENTS_JSON="$AG_REV" run_lib boss_record_wake_event "$ev_rev" review-text "$P" boss-rev sleeper >/dev/null
if txt="$(HERDR_AGENTS_JSON="$AG_REV" run_boss review review-text --project "$P" 2>&1)"; then
  ok
else
  bad "review text: non-zero exit"
fi
check_contains "review text: wake next" "wake next:" "$txt"
check_contains "review text: wake target" "boss-rev" "$txt"
check_contains "review text: last wake" "last wake: boss-rev" "$txt"
check_not_contains "review text: no unbound variable" "unbound variable" "$txt"
check_eq "review text: no test run" "not_run" \
  "$(HERDR_AGENTS_JSON="$AG_REV" run_boss review review-text --project "$P" --json | jq -r '.quality.tests.result')"

review_json="$(HERDR_AGENTS_JSON="$AG_REV" run_boss review review-text --project "$P" --json)"
status_json="$(HERDR_AGENTS_JSON="$AG_REV" run_boss status review-text --project "$P" --json)"
check_eq "review json: wake fields match status" \
  "$(printf '%s' "$status_json" | jq -c '{wake_plan,wake_target,last_wake}')" \
  "$(printf '%s' "$review_json" | jq -c '{wake_plan,wake_target,last_wake}')"
check_eq "review json: events file" "$ev_rev" "$(printf '%s' "$review_json" | jq -r '.events_file')"

P="$TMP/project-skip-status"
make_project "$P"
jq -n --arg p "$P" '{change:"skip-me",project:$p,workspace_id:"ws-1",agent:"apply-skip-me",
  pane_id:"apply-pane",tab_id:"tab",boss:"boss-old",boss_pane:"p-old",boss_workspace:"ws-2",
  waiter_pid:null}' >"$STATE/applies/$(run_lib sha1_hex "$P")-skip-me.json"
out="$(HERDR_AGENTS_JSON='[{"name":"boss-old","pane_id":"p-old","workspace_id":"ws-2"}]' \
  run_boss status skip-me --project "$P" --json)"
check_eq "status: no safe target" "null" "$(printf '%s' "$out" | jq -c '.wake_target')"
check_eq "status: skipped reason" "cross_workspace" "$(printf '%s' "$out" | jq -r '.wake_plan.skipped[0].reason')"
txt="$(HERDR_AGENTS_JSON='[{"name":"boss-old","pane_id":"p-old","workspace_id":"ws-2"}]' \
  run_boss status skip-me --project "$P" 2>/dev/null)"
check_contains "status: text skipped" "wake skipped: boss-old (dispatcher, reason: cross_workspace)" "$txt"

ev2="$(run_lib events_file_for "$P" skip-me)"
run_lib boss_record_wake_failed_event "$ev2" skip-me "$P" idle "no_candidate" \
  '{"candidates":[],"skipped":[{"target":"boss-old","source":"dispatcher","reason":"cross_workspace"}]}' >/dev/null
out="$(HERDR_AGENTS_JSON='[]' run_boss status skip-me --project "$P" --json)"
check_eq "status: failed wake event" "wake_failed" "$(printf '%s' "$out" | jq -r '.last_wake.event')"
check_eq "status: failed wake reason" "no_candidate" "$(printf '%s' "$out" | jq -r '.last_wake.reason')"
check_eq "status: failed wake skipped" "cross_workspace" "$(printf '%s' "$out" | jq -r '.last_wake.skipped[0].reason')"

# 25. A failed wake keeps the durable inbox item.
inbox_state="$TMP/inbox-state.json"
jq -n --arg p "$TMP/project-inbox" '{change:"inbox-change",project:$p,workspace_id:"ws-1"}' >"$inbox_state"
id="$(run_lib inbox_write "$inbox_state" lost)"
if [ -n "$id" ] && [ -f "$STATE/inbox/$id" ]; then ok; else bad "inbox: item was not written"; fi
run_lib boss_record_wake_failed_event "$(run_lib events_file_for "$TMP/project-inbox" inbox-change)" \
  inbox-change "$TMP/project-inbox" lost "no_candidate" '{"candidates":[],"skipped":[]}' >/dev/null
check_eq "inbox: survives failed wake" "1" \
  "$(run_lib inbox_count "$TMP/project-inbox" inbox-change)"

# 26. Doctor: registry, wake target and caller identity checks.
DOC="$TMP/doctor-state"
mkdir -p "$DOC/bosses" "$DOC/applies"
P="$TMP/project-doctor"
make_project "$P"
make_change "$P" doc-change '- [ ] 1.1 Code.'
jq -n '{workspace_id:"ws-1",pane_id:"p-dead",agent:"boss-ws-1"}' >"$DOC/bosses/ws-1.json"
doctor="$(HERDR_AGENTS_JSON='[]' run_boss_state "$DOC" doctor --project "$P" --json 2>/dev/null)"
check_eq "doctor: dead registry" "warn" "$(printf '%s' "$doctor" | jq -r '.checks[] | select(.id=="boss_registry") | .status')"
doctor="$(HERDR_AGENTS_JSON='[{"name":"boss-ws-1","pane_id":"p-dead","workspace_id":"ws-1"}]' \
  HERDR_PANES_JSON="$PANES_MATCH" run_boss_state "$DOC" doctor --project "$P" --json 2>/dev/null)"
check_eq "doctor: live registry" "ok" "$(printf '%s' "$doctor" | jq -r '.checks[] | select(.id=="boss_registry") | .status')"

jq -n --arg p "$P" '{change:"doc-change",project:$p,workspace_id:"ws-1",agent:"apply-doc-change",
  pane_id:"apply-pane",tab_id:"tab",boss:"boss-old",boss_pane:"p-old",boss_workspace:"ws-2",
  waiter_pid:null}' >"$DOC/applies/$(run_lib sha1_hex "$P")-doc-change.json"
AG_DOC='[{"name":"boss-old","pane_id":"p-old","workspace_id":"ws-2"}]'
doctor="$(HERDR_AGENTS_JSON="$AG_DOC" HERDR_PANES_JSON="$PANES_MATCH" \
  run_boss_state "$DOC" doctor --project "$P" --json 2>/dev/null)"
check_eq "doctor: unsafe dispatcher" "warn" "$(printf '%s' "$doctor" | jq -r '.checks[] | select(.id=="wake_target") | .status')"
check_contains "doctor: retarget hint" "boss retarget" \
  "$(printf '%s' "$doctor" | jq -r '.checks[] | select(.id=="wake_target") | .hint')"

jq '.boss_workspace = "ws-1"' "$DOC/applies/$(run_lib sha1_hex "$P")-doc-change.json" \
  >"$DOC/applies/tmp.json" && mv "$DOC/applies/tmp.json" "$DOC/applies/$(run_lib sha1_hex "$P")-doc-change.json"
doctor="$(HERDR_AGENTS_JSON='[{"name":"boss-old","pane_id":"p-old","workspace_id":"ws-1"}]' \
  HERDR_PANES_JSON="$PANES_MATCH" run_boss_state "$DOC" doctor --project "$P" --json 2>/dev/null)"
check_eq "doctor: healthy dispatcher" "ok" "$(printf '%s' "$doctor" | jq -r '.checks[] | select(.id=="wake_target") | .status')"

PANES_STALE="$(jq -nc '[{pane_id:"p-boss",workspace_id:"ws-1",cwd:"/elsewhere"}]')"
doctor="$(HERDR_PANES_JSON="$PANES_STALE" run_boss_state "$DOC" doctor --project "$P" --json 2>/dev/null)"
check_eq "doctor: stale caller warns" "warn" "$(printf '%s' "$doctor" | jq -r '.checks[] | select(.id=="caller_identity") | .status')"
doctor="$(HERDR_PANES_JSON="$PANES_MATCH" run_boss_state "$DOC" doctor --project "$P" --json 2>/dev/null)"
check_eq "doctor: correct caller ok" "ok" "$(printf '%s' "$doctor" | jq -r '.checks[] | select(.id=="caller_identity") | .status')"

# 26b. Every write command parses --as with a pane and an agent name.
for cmd in "claim" "dispatch" "mission next" "retrigger" "resume" "park" "finish" "answer"; do
  case "$cmd" in
    "mission next") args="mission next v1 --project $TMP/project-doctor --help" ;;
    *) args="$cmd --help" ;;
  esac
  out="$(run_boss_fail $args --as p-alpha)"
  check_not_contains "--as pane accepted: $cmd" "unknown option: --as" "$out"
  check_contains "--as in help: $cmd" "--as" "$out"
  out="$(run_boss_fail $args --as boss-wc)"
  check_not_contains "--as agent accepted: $cmd" "unknown option: --as" "$out"
done

# 26c. Status names the workspace-boss fallback when the dispatcher is dead.
P="$TMP/project-ws-boss"
make_project "$P"
jq -n --arg p "$P" '{change:"ws-boss-change",project:$p,workspace_id:"ws-1",
  agent:"apply-ws-boss-change",pane_id:"apply-pane",tab_id:"tab",
  boss:"boss-dead",boss_pane:"p-dead",boss_workspace:"ws-1",waiter_pid:null}'   >"$STATE/applies/$(run_lib sha1_hex "$P")-ws-boss-change.json"
run_lib boss_write_registry "$STATE/bosses/ws-1.json" ws-1 p-ws boss-ws-1 >/dev/null
out="$(HERDR_AGENTS_JSON='[{"name":"boss-ws-1","pane_id":"p-ws","workspace_id":"ws-1"}]'   run_boss status ws-boss-change --project "$P" --json)"
check_eq "status: workspace-boss fallback source" "workspace_boss" "$(printf '%s' "$out" | jq -r '.wake_target.source')"
check_eq "status: workspace-boss fallback target" "boss-ws-1" "$(printf '%s' "$out" | jq -r '.wake_target.target')"

# 27. Documentation and skill describe the verified identity and wake rules.
skill="$(cat "$ROOT/vision/SKILL.md")"
readme="$(cat "$ROOT/README.md")"
check_contains "skill: caller mismatch" "caller_pane_mismatch" "$skill"
check_contains "skill: --as" "--as" "$skill"
check_contains "skill: retarget" "boss retarget" "$skill"
check_contains "skill: wake order" "dispatcher -> workspace boss" "$skill"
check_contains "skill: state-only retarget" "state-only" "$skill"
check_contains "skill: cross-project skip" "cross_project" "$skill"
check_contains "skill: claim force" "--force" "$skill"
check_contains "skill: renamed status" "renamed" "$skill"
check_contains "skill: legacy wrong-project cwd" "belongs to another project" "$skill"
check_contains "readme: caller mismatch" "caller_pane_mismatch" "$readme"
check_contains "readme: --as" "--as" "$readme"
check_contains "readme: retarget" "boss retarget" "$readme"
check_contains "readme: cross flag" "boss_cross_workspace" "$readme"
check_contains "readme: cross-project flag" "boss_cross_project" "$readme"
check_contains "readme: state-only retarget" "state-only" "$readme"
check_contains "readme: claim repair" "boss claim --as" "$readme"
check_contains "readme: claim force" "--force" "$readme"
check_contains "readme: renamed status" "renamed" "$readme"
check_contains "readme: legacy behavior" "fail-closed" "$readme"
check_contains "readme: legacy unrelated cwd" "unrelated to the apply project" "$readme"

# ------------------------------------------------- OpenCode V1/V2 tests ---

# 28. Version detection: V2, V1 and an unparsable version that warns and keeps
# the legacy path.
check_eq "opencode version: v2" "2" \
  "$(OPENCODE_STUB_VERSION='opencode v2.1.1' run_lib opencode_major_version)"
check_eq "opencode version: v1" "1" \
  "$(OPENCODE_STUB_VERSION='opencode v1.18.4' run_lib opencode_major_version)"
check_eq "opencode version: unknown" "unknown" \
  "$(OPENCODE_STUB_VERSION='opencode not-a-version' run_lib opencode_major_version 2>/dev/null)"
warn="$(OPENCODE_STUB_VERSION='opencode not-a-version' run_lib opencode_major_version 2>&1 >/dev/null)"
check_contains "opencode version: unknown warns" "cannot determine the OpenCode major version" "$warn"

# 29. Runner defaults: V2 adds --auto and no inline env; V1 keeps the inline
# default. Explicit args and env always win (the five precedence cases).
V2_RUNNER='{"kind":"opencode","args":[]}'
V1_RUNNER='{"kind":"opencode","args":[]}'
check_eq "runner v2: auto args" "--auto" \
  "$(OPENCODE_STUB_VERSION='opencode v2.1.1' run_lib runner_args_of "$V2_RUNNER")"
check_eq "runner v2: no inline env" "" \
  "$(OPENCODE_STUB_VERSION='opencode v2.1.1' run_lib runner_env_of "$V2_RUNNER")"
check_eq "runner v1: no extra args" "" \
  "$(OPENCODE_STUB_VERSION='opencode v1.18.4' run_lib runner_args_of "$V1_RUNNER")"
check_eq "runner v1: inline env" 'OPENCODE_CONFIG_CONTENT={"permission":"allow"}' \
  "$(OPENCODE_STUB_VERSION='opencode v1.18.4' run_lib runner_env_of "$V1_RUNNER")"
check_eq "runner explicit args win on v2" "--standalone" \
  "$(OPENCODE_STUB_VERSION='opencode v2.1.1' \
    run_lib runner_args_of '{"kind":"opencode","args":["--standalone"]}')"
check_eq "runner explicit env wins on v2" "FOO=bar" \
  "$(OPENCODE_STUB_VERSION='opencode v2.1.1' \
    run_lib runner_env_of '{"kind":"opencode","args":[],"env":["FOO=bar"]}')"
check_eq "runner unknown version: no auto" "" \
  "$(OPENCODE_STUB_VERSION='broken' run_lib runner_args_of "$V2_RUNNER" 2>/dev/null)"
check_eq "runner unknown version: inline fallback" 'OPENCODE_CONFIG_CONTENT={"permission":"allow"}' \
  "$(OPENCODE_STUB_VERSION='broken' run_lib runner_env_of "$V2_RUNNER" 2>/dev/null)"
check_eq "runner mode: v2" '{"opencode_version":2,"permission_mode":"auto"}' \
  "$(OPENCODE_STUB_VERSION='opencode v2.1.1' run_lib runner_mode_of "$V2_RUNNER" | jq -c .)"
check_eq "runner mode: v1" '{"opencode_version":1,"permission_mode":"inline"}' \
  "$(OPENCODE_STUB_VERSION='opencode v1.18.4' run_lib runner_mode_of "$V1_RUNNER" | jq -c .)"
check_eq "runner mode: non-opencode" '{"opencode_version":null,"permission_mode":null}' \
  "$(run_lib runner_mode_of '{"kind":"claude","args":[]}')"

# 30. Effective-permission probe: debug config, API fallback, broad deny,
# narrow deny and both queries unavailable.
allow_cfg='[{"type":"document","info":{"permissions":[{"action":"*","resource":"*","effect":"allow"}]}}]'
deny_cfg='[{"type":"document","info":{"permissions":[{"action":"*","resource":"*","effect":"deny"}]}}]'
narrow_cfg='[{"type":"document","info":{"permissions":[{"action":"shell","resource":"git status","effect":"deny"}]}}]'
out="$(OPENCODE_STUB_DEBUG_CONFIG="$allow_cfg" run_lib opencode_permission_probe)"
check_eq "probe: allow" "ok" "$(printf '%s' "$out" | jq -r '.status')"
check_eq "probe: debug source" "debug_config" "$(printf '%s' "$out" | jq -r '.source')"
out="$(OPENCODE_STUB_DEBUG_CONFIG="$deny_cfg" run_lib opencode_permission_probe)"
check_eq "probe: broad deny" "deny" "$(printf '%s' "$out" | jq -r '.status')"
check_contains "probe: names shell" "shell" "$(printf '%s' "$out" | jq -r '.denied | join(",")')"
out="$(OPENCODE_STUB_DEBUG_CONFIG="$narrow_cfg" run_lib opencode_permission_probe)"
check_eq "probe: narrow deny ignored" "ok" "$(printf '%s' "$out" | jq -r '.status')"
out="$(OPENCODE_STUB_DEBUG_CONFIG='{"permissions":[{"action":"external_directory","resource":"*","effect":"deny"}]}' \
  run_lib opencode_permission_probe)"
check_eq "probe: object shape deny" "deny" "$(printf '%s' "$out" | jq -r '.status')"
check_contains "probe: external directory" "external_directory" \
  "$(printf '%s' "$out" | jq -r '.denied | join(",")')"
out="$(OPENCODE_STUB_DEBUG_FAIL=1 OPENCODE_STUB_API_CONFIG="$allow_cfg" \
  run_lib opencode_permission_probe)"
check_eq "probe: api fallback" "api_config" "$(printf '%s' "$out" | jq -r '.source')"
out="$(OPENCODE_STUB_DEBUG_FAIL=1 OPENCODE_STUB_API_FAIL=1 run_lib opencode_permission_probe)"
check_eq "probe: unavailable" "unavailable" "$(printf '%s' "$out" | jq -r '.status')"
check_contains "probe: names failed query" "opencode debug config" \
  "$(printf '%s' "$out" | jq -r '.message')"

# 31. Dispatch and session carry the mode, and the V2 tab gets no inline
# allow-all while the agent start gets --auto.
PV2="$TMP/project-opencode-v2"
make_project "$PV2"
make_change "$PV2" v2-dispatch '- [ ] 1.1 Code.'
V2S="$TMP/opencode-v2-state"
V2_START="$TMP/opencode-v2-start.log"
V2_TAB="$TMP/opencode-v2-tab.log"
out="$(cd "$PV2" && OPENCODE_STUB_VERSION='opencode v2.1.1' \
  HERDR_AGENT_START_LOG="$V2_START" HERDR_TAB_CREATE_LOG="$V2_TAB" \
  run_boss_state "$V2S" dispatch v2-dispatch --project "$PV2")"
sf="$V2S/applies/$(run_lib sha1_hex "$PV2")-v2-dispatch.json"
check_eq "dispatch v2: status" "started" "$(printf '%s' "$out" | jq -r '.status')"
check_eq "dispatch v2: result version" "2" "$(printf '%s' "$out" | jq -r '.opencode_version')"
check_eq "dispatch v2: result mode" "auto" "$(printf '%s' "$out" | jq -r '.permission_mode')"
check_eq "dispatch v2: state version" "2" "$(jq -r '.opencode_version' "$sf")"
check_eq "dispatch v2: state mode" "auto" "$(jq -r '.permission_mode' "$sf")"
check_contains "dispatch v2: runner gets --auto" "--auto" "$(cat "$V2_START")"
check_not_contains "dispatch v2: no inline env" "OPENCODE_CONFIG_CONTENT" "$(cat "$V2_TAB")"

out="$(cd "$PV2" && OPENCODE_STUB_VERSION='opencode v2.1.1' \
  HERDR_AGENT_START_LOG="$TMP/session-start.log" HERDR_TAB_CREATE_LOG="$TMP/session-tab.log" \
  run_boss_state "$TMP/opencode-session-state" session --project "$PV2")"
check_eq "session v2: status" "started" "$(printf '%s' "$out" | jq -r '.status')"
check_eq "session v2: version" "2" "$(printf '%s' "$out" | jq -r '.opencode_version')"
check_eq "session v2: mode" "auto" "$(printf '%s' "$out" | jq -r '.permission_mode')"
check_contains "session v2: runner gets --auto" "--auto" "$(cat "$TMP/session-start.log")"
check_not_contains "session v2: no inline env" "OPENCODE_CONFIG_CONTENT" "$(cat "$TMP/session-tab.log")"

# A fresh generated config describes both runner modes without rewriting an
# existing file.
GEN="$TMP/generated-boss.toml"
rm -f "$GEN"
BOSS_CONFIG="$GEN" run_boss_fail_state "$TMP/generated-state" doctor --help >/dev/null 2>&1 || true
check_contains "generated config: --auto" "--auto" "$(cat "$GEN")"
check_contains "generated config: V1 fallback" "OpenCode V1" "$(cat "$GEN")"

# 32. V1 dispatch keeps the inline environment and gets no --auto.
P="$TMP/project-opencode-v1"
make_project "$P"
make_change "$P" v1-dispatch '- [ ] 1.1 Code.'
V1S="$TMP/opencode-v1-state"
V1_START="$TMP/opencode-v1-start.log"
V1_TAB="$TMP/opencode-v1-tab.log"
out="$(cd "$P" && OPENCODE_STUB_VERSION='opencode v1.18.4' \
  HERDR_AGENT_START_LOG="$V1_START" HERDR_TAB_CREATE_LOG="$V1_TAB" \
  run_boss_state "$V1S" dispatch v1-dispatch --project "$P")"
sf="$V1S/applies/$(run_lib sha1_hex "$P")-v1-dispatch.json"
check_eq "dispatch v1: result version" "1" "$(printf '%s' "$out" | jq -r '.opencode_version')"
check_eq "dispatch v1: result mode" "inline" "$(printf '%s' "$out" | jq -r '.permission_mode')"
check_eq "dispatch v1: state mode" "inline" "$(jq -r '.permission_mode' "$sf")"
check_not_contains "dispatch v1: no --auto" "--auto" "$(cat "$V1_START")"
check_contains "dispatch v1: inline env" 'OPENCODE_CONFIG_CONTENT={"permission":"allow"}' "$(cat "$V1_TAB")"

# An explicit args/env runner is passed exactly as configured on V2.
P="$TMP/project-opencode-explicit"
make_project "$P"
make_change "$P" explicit-runner '- [ ] 1.1 Code.'
VCONF="$TMP/explicit.toml"
cat >"$VCONF" <<'EOF'
default = "opencode"

[runners.opencode]
kind = "opencode"
args = ["--standalone"]
env = ["FOO=bar"]
apply = "/opsx-apply {change}"
EOF
EX_START="$TMP/opencode-explicit-start.log"
EX_TAB="$TMP/opencode-explicit-tab.log"
out="$(cd "$P" && BOSS_CONFIG="$VCONF" OPENCODE_STUB_VERSION='opencode v2.1.1' \
  HERDR_AGENT_START_LOG="$EX_START" HERDR_TAB_CREATE_LOG="$EX_TAB" \
  run_boss_state "$TMP/opencode-explicit-state" dispatch explicit-runner --project "$P")"
check_eq "dispatch explicit: mode auto" "auto" "$(printf '%s' "$out" | jq -r '.permission_mode')"
check_contains "dispatch explicit: args win" "--standalone" "$(cat "$EX_START")"
check_not_contains "dispatch explicit: no auto duplicate" "--auto" "$(cat "$EX_START")"
check_contains "dispatch explicit: env wins" "--env FOO=bar" "$(cat "$EX_TAB")"
check_not_contains "dispatch explicit: no inline env" "OPENCODE_CONFIG_CONTENT" "$(cat "$EX_TAB")"

# 33. Status shows the mode in JSON and text for a V2 apply.
out="$(HERDR_AGENTS_JSON='[]' run_boss_state "$V2S" status v2-dispatch --project "$PV2" --json)"
check_eq "status v2: version" "2" "$(printf '%s' "$out" | jq -r '.opencode_version')"
check_eq "status v2: mode" "auto" "$(printf '%s' "$out" | jq -r '.permission_mode')"
txt="$(HERDR_AGENTS_JSON='[]' run_boss_state "$V2S" status v2-dispatch --project "$PV2" 2>/dev/null)"
check_contains "status v2: text mode" "permission auto" "$txt"

# 34. Doctor: V2 effective config allow, broad deny, unavailable and the
# runner --auto check; V1 keeps the tab-environment check.
D2="$TMP/doctor-opencode-state"
doctor="$(OPENCODE_STUB_VERSION='opencode v2.1.1' OPENCODE_STUB_DEBUG_CONFIG="$allow_cfg" \
  run_boss_state "$D2" doctor --project "$P" --json 2>/dev/null)"
check_eq "doctor v2: allow ok" "ok" \
  "$(printf '%s' "$doctor" | jq -r '.checks[] | select(.id=="boss_permission") | .status')"
doctor="$(OPENCODE_STUB_VERSION='opencode v2.1.1' OPENCODE_STUB_DEBUG_CONFIG="$deny_cfg" \
  run_boss_state "$D2" doctor --project "$P" --json 2>/dev/null)"
check_eq "doctor v2: broad deny warns" "warn" \
  "$(printf '%s' "$doctor" | jq -r '.checks[] | select(.id=="boss_permission") | .status')"
check_contains "doctor v2: deny hint" "broad deny" \
  "$(printf '%s' "$doctor" | jq -r '.checks[] | select(.id=="boss_permission") | .hint')"
doctor="$(OPENCODE_STUB_VERSION='opencode v2.1.1' OPENCODE_STUB_DEBUG_FAIL=1 OPENCODE_STUB_API_FAIL=1 \
  run_boss_state "$D2" doctor --project "$P" --json 2>/dev/null)"
check_eq "doctor v2: unavailable warns" "warn" \
  "$(printf '%s' "$doctor" | jq -r '.checks[] | select(.id=="boss_permission") | .status')"
check_contains "doctor v2: unavailable names query" "opencode debug config" \
  "$(printf '%s' "$doctor" | jq -r '.checks[] | select(.id=="boss_permission") | .hint')"
doctor="$(OPENCODE_STUB_VERSION='opencode v2.1.1' run_boss_state "$D2" doctor --project "$P" --json 2>/dev/null)"
check_eq "doctor v2: default args get auto" "ok" \
  "$(printf '%s' "$doctor" | jq -r '.checks[] | select(.id=="opencode_runner_args") | .status')"
doctor="$(BOSS_CONFIG="$VCONF" OPENCODE_STUB_VERSION='opencode v2.1.1' \
  run_boss_state "$D2" doctor --project "$P" --json 2>/dev/null)"
check_eq "doctor v2: explicit args without auto warns" "warn" \
  "$(printf '%s' "$doctor" | jq -r '.checks[] | select(.id=="opencode_runner_args") | .status')"
# A multi-runner config must not hide the opencode runner: kinds is a
# newline-separated list, so both the permission probe and the --auto check
# must still run when claude is configured alongside opencode.
MULTI="$TMP/multi-runner.toml"
cat >"$MULTI" <<'EOF'
default = "opencode"

[runners.claude]
kind = "claude"
args = ["--permission-mode", "bypassPermissions"]
apply = "/opsx:apply {change}"

[runners.opencode]
kind = "opencode"
args = []
apply = "/opsx-apply {change}"
EOF
doctor="$(BOSS_CONFIG="$MULTI" OPENCODE_STUB_VERSION='opencode v2.1.1' \
  OPENCODE_STUB_DEBUG_CONFIG="$deny_cfg" \
  run_boss_state "$D2" doctor --project "$P" --json 2>/dev/null)"
check_eq "doctor multi-runner: permission probe runs" "warn" \
  "$(printf '%s' "$doctor" | jq -r '.checks[] | select(.id=="boss_permission") | .status')"
check_contains "doctor multi-runner: deny is named" "broad deny" \
  "$(printf '%s' "$doctor" | jq -r '.checks[] | select(.id=="boss_permission") | .hint')"
check_eq "doctor multi-runner: args check runs" "ok" \
  "$(printf '%s' "$doctor" | jq -r '.checks[] | select(.id=="opencode_runner_args") | .status')"

# The effective-config probe must run in the target project, not in the
# caller's cwd. The stub records the cwd of every 'opencode debug config'.
CWDL="$TMP/opencode-cwd.log"
: >"$CWDL"
doctor="$(cd "$TMP" && OPENCODE_STUB_VERSION='opencode v2.1.1' \
  OPENCODE_STUB_CWD_LOG="$CWDL" OPENCODE_STUB_DEBUG_CONFIG="$allow_cfg" \
  run_boss_state "$D2" doctor --project "$P" --json 2>/dev/null)"
check_eq "doctor project cwd: probe status" "ok" \
  "$(printf '%s' "$doctor" | jq -r '.checks[] | select(.id=="boss_permission") | .status')"
check_eq "doctor project cwd: probe runs in project" "debug:$P" "$(cat "$CWDL")"

doctor="$(OPENCODE_STUB_VERSION='opencode v1.18.4' OPENCODE_CONFIG_CONTENT='{"permission":"allow"}' \
  run_boss_state "$D2" doctor --project "$P" --json 2>/dev/null)"
check_eq "doctor v1: env allow ok" "ok" \
  "$(printf '%s' "$doctor" | jq -r '.checks[] | select(.id=="boss_permission") | .status')"
doctor="$(OPENCODE_STUB_VERSION='opencode v1.18.4' OPENCODE_CONFIG_CONTENT= \
  run_boss_state "$D2" doctor --project "$P" --json 2>/dev/null)"
check_eq "doctor v1: missing env warns" "warn" \
  "$(printf '%s' "$doctor" | jq -r '.checks[] | select(.id=="boss_permission") | .status')"

# 35. The installer verifies the Herdr opencode integration in a temporary
# HOME: current succeeds, stale fails with the v13 hint, Claude is unchanged.
IH="$TMP/install-home"
IH2="$TMP/install-claude-home"
SH="$TMP/install-stale-home"
mkdir -p "$IH" "$IH2" "$SH"
if out="$(HOME="$IH" PATH="$BIN:$PATH" HERDR_INTEGRATION_STATUS='opencode: current (v13)' \
  bash "$ROOT/install.sh" 2>&1)"; then ok; else bad "installer current: non-zero exit: $out"; fi
check_contains "installer current: opencode ready" "Herdr integration ready for opencode" "$out"
check_contains "installer current: claude ready" "Herdr integration ready for claude" "$out"
check_eq "installer current: skill copied" "vision" \
  "$(basename "$(dirname "$IH/.config/opencode/skills/vision/SKILL.md")")"
if [ -x "$IH/.local/bin/boss" ] && [ ! -L "$IH/.local/bin/boss" ]; then
  ok
else
  bad "installer current: boss runtime missing or a symlink"
fi
if [ -z "$(find "$IH/.config/opencode/skills/vision" "$IH/.local/bin" -type l -print -quit 2>/dev/null)" ]; then
  ok
else
  bad "installer current: installed a symlink"
fi
if out="$(HOME="$IH2" PATH="$BIN:$PATH" \
  HERDR_INTEGRATION_STATUS=$'opencode: current (v13)\nclaude: stale (v1)' \
  bash "$ROOT/install.sh" 2>&1)"; then ok; else bad "installer claude path: non-zero exit"; fi
check_contains "installer claude path: still ready" "Herdr integration ready for claude" "$out"
if out="$(HOME="$SH" PATH="$BIN:$PATH" HERDR_INTEGRATION_STATUS='opencode: stale (v11)' \
  bash "$ROOT/install.sh" 2>&1)"; then
  bad "installer stale: unexpectedly succeeded"
else
  ok
fi
check_contains "installer stale: names v13" "v13" "$out"
check_not_contains "installer stale: no opencode ready" "Herdr integration ready for opencode" "$out"

# 36. Documentation names the V1/V2 behavior and the migration knobs.
skill="$(cat "$ROOT/vision/SKILL.md")"
readme="$(cat "$ROOT/README.md")"
for doc in "$readme" "$skill"; do
  check_contains "docs: shared background server" "shared background server" "$doc"
  check_contains "docs: --auto" "--auto" "$doc"
  check_contains "docs: V1 fallback" "V1" "$doc"
  check_contains "docs: effective config" "opencode debug config" "$doc"
  check_contains "docs: herdr integration status" "herdr integration status" "$doc"
  check_contains "docs: integration v13" "v13" "$doc"
done
check_contains "readme: args = [] migration" "args = []" "$readme"
check_contains "readme: standalone opt-in" "--standalone" "$readme"
check_contains "skill: no V2 tab env advice" "OPENCODE_CONFIG_CONTENT" "$skill"

# 37. Per-change mission runners: parsing, status, selection, default,
# unknown runner, resume and retrigger preservation, and doctor.
RCONF="$TMP/runner.toml"
cat >"$RCONF" <<'EOF'
default = "opencode"

[runners.opencode]
kind = "opencode"
args = []
apply = "/opsx-apply {change}"

[runners.claude-opus]
kind = "claude"
args = ["--model", "opus", "--permission-mode", "auto"]
apply = "/opsx:apply {change}"
EOF
P="$TMP/project-runner"
make_project "$P"
make_change "$P" research '- [ ] 1.1 Research.'
make_change "$P" coding '- [ ] 1.1 Code.'
make_change "$P" plain '- [ ] 1.1 Code.'
make_mission "$P" v1 $'- research (runner: claude-opus)\n- coding (after: research; human-ok: research; runner: opencode)\n- plain'
status="$(BOSS_CONFIG="$RCONF" run_boss_state "$TMP/runner-status-state" mission status v1 --project "$P")"
check_eq "runner status: research runner" "claude-opus" \
  "$(printf '%s' "$status" | jq -r '.changes[] | select(.change=="research") | .runner')"
check_eq "runner status: coding runner" "opencode" \
  "$(printf '%s' "$status" | jq -r '.changes[] | select(.change=="coding") | .runner')"
check_eq "runner status: plain default" "opencode" \
  "$(printf '%s' "$status" | jq -r '.changes[] | select(.change=="plain") | .runner')"
check_eq "runner status: dependency runner" "claude-opus" \
  "$(printf '%s' "$status" | jq -r '.dependencies[] | select(.name=="research") | .runner')"
check_eq "runner status: dependency default" "opencode" \
  "$(printf '%s' "$status" | jq -r '.dependencies[] | select(.name=="plain") | .runner')"

P_RUN="$TMP/project-runner-next"
make_project "$P_RUN"
make_change "$P_RUN" research '- [ ] 1.1 Research.'
make_change "$P_RUN" coding '- [ ] 1.1 Code.'
make_mission "$P_RUN" v1 $'- research (runner: claude-opus)\n- coding'
RST="$TMP/runner-next-state"
START="$TMP/runner-next-start.log"
out="$(BOSS_CONFIG="$RCONF" HERDR_AGENT_START_LOG="$START" \
  run_boss_state "$RST" mission next v1 --project "$P_RUN")"
check_eq "runner next: custom status" "started" "$(printf '%s' "$out" | jq -r '.status')"
check_eq "runner next: custom change" "research" "$(printf '%s' "$out" | jq -r '.change')"
check_eq "runner next: state runner" "claude-opus" \
  "$(jq -r '.runner' "$RST/applies/$(run_lib sha1_hex "$P_RUN")-research.json")"
check_contains "runner next: claude kind" "--kind claude" "$(cat "$START")"
check_contains "runner next: opus args" "--model opus" "$(cat "$START")"

RST2="$TMP/runner-default-state"
START2="$TMP/runner-default-start.log"
P_DEF="$TMP/project-runner-default"
make_project "$P_DEF"
make_change "$P_DEF" defaulting '- [ ] 1.1 Code.'
make_mission "$P_DEF" v1 "- defaulting"
out="$(BOSS_CONFIG="$RCONF" HERDR_AGENT_START_LOG="$START2" \
  run_boss_state "$RST2" mission next v1 --project "$P_DEF")"
check_eq "runner default: change" "defaulting" "$(printf '%s' "$out" | jq -r '.change')"
check_eq "runner default: opencode" "opencode" \
  "$(jq -r '.runner' "$RST2/applies/$(run_lib sha1_hex "$P_DEF")-defaulting.json")"
check_contains "runner default: --auto" "--auto" "$(cat "$START2")"

P_BAD="$TMP/project-runner-bad"
make_project "$P_BAD"
make_change "$P_BAD" bad-runner '- [ ] 1.1 Code.'
make_mission "$P_BAD" v1 "- bad-runner (runner: no-such)"
BST="$TMP/runner-bad-state"
mkdir -p "$BST"
err="$(BOSS_CONFIG="$RCONF" run_boss_fail_state "$BST" mission next v1 --project "$P_BAD")"
check_contains "runner unknown: error" "unknown_runner" "$err"
check_contains "runner unknown: names runner" "no-such" "$err"
check_eq "runner unknown: no applies" "0" "$(find "$BST/applies" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"

# Resume keeps the original runner.
P_RES="$TMP/project-runner-resume"
make_project "$P_RES"
make_change "$P_RES" resume-runner '- [ ] 1.1 Code.'
RST3="$TMP/runner-resume-state"
mkdir -p "$RST3/applies"
jq -n --arg p "$P_RES" '{change:"resume-runner",project:$p,workspace_id:"ws-1",
  runner:"claude-opus",agent:"apply-resume-runner",pane_id:"p-res",tab_id:"t-res",
  boss:"boss-ws-1",boss_pane:"p-boss",boss_workspace:"ws-1",boss_cwd:"/tmp/other",
  boss_cross_workspace:false,boss_cross_project:true,waiter_pid:null,parked:true,
  parked_at:"2026-01-01T00:00:00+0000",apply_cmd:"/opsx:apply resume-runner"}' \
  >"$RST3/applies/$(run_lib sha1_hex "$P_RES")-resume-runner.json"
RSTART="$TMP/runner-resume-start.log"
out="$(BOSS_CONFIG="$RCONF" HERDR_AGENT_START_LOG="$RSTART" \
  run_boss_state "$RST3" resume resume-runner --project "$P_RES")"
check_eq "runner resume: started" "started" "$(printf '%s' "$out" | jq -r '.status')"
check_eq "runner resume: state runner" "claude-opus" \
  "$(jq -r '.runner' "$RST3/applies/$(run_lib sha1_hex "$P_RES")-resume-runner.json")"
check_contains "runner resume: opus args" "--model opus" "$(cat "$RSTART")"

# Retrigger keeps the stored runner and apply command.
P_RET="$TMP/project-runner-retrigger"
make_project "$P_RET"
make_change "$P_RET" retrigger-runner '- [ ] 1.1 Code.'
RST4="$TMP/runner-retrigger-state"
mkdir -p "$RST4/applies"
jq -n --arg p "$P_RET" '{change:"retrigger-runner",project:$p,workspace_id:"ws-1",
  runner:"claude-opus",agent:"apply-retrigger-runner",pane_id:"p-ret",tab_id:"t-ret",
  boss:"boss-ws-1",boss_pane:"p-boss",boss_workspace:"ws-1",boss_cwd:"/tmp/other",
  boss_cross_workspace:false,boss_cross_project:true,waiter_pid:null,
  apply_cmd:"/opsx:apply retrigger-runner",yield:"y",lessons:""}' \
  >"$RST4/applies/$(run_lib sha1_hex "$P_RET")-retrigger-runner.json"
out="$(BOSS_CONFIG="$RCONF" HERDR_LIVE_PANES=p-ret \
  run_boss_state "$RST4" retrigger retrigger-runner --project "$P_RET")"
check_eq "runner retrigger: status" "retriggered" "$(printf '%s' "$out" | jq -r '.status')"
check_eq "runner retrigger: keeps runner" "claude-opus" \
  "$(jq -r '.runner' "$RST4/applies/$(run_lib sha1_hex "$P_RET")-retrigger-runner.json")"
check_eq "runner retrigger: keeps apply" "/opsx:apply retrigger-runner" \
  "$(jq -r '.apply_cmd' "$RST4/applies/$(run_lib sha1_hex "$P_RET")-retrigger-runner.json")"

# Doctor reports unknown mission runners and accepts known ones.
DST="$TMP/runner-doctor-state"
doctor="$(BOSS_CONFIG="$RCONF" run_boss_state "$DST" doctor --project "$P_BAD" --json 2>/dev/null)"
check_eq "runner doctor: unknown warns" "warn" \
  "$(printf '%s' "$doctor" | jq -r '.checks[] | select(.id=="mission_runners") | .status')"
check_contains "runner doctor: names runner" "no-such" \
  "$(printf '%s' "$doctor" | jq -r '.checks[] | select(.id=="mission_runners") | .hint')"
doctor="$(BOSS_CONFIG="$RCONF" run_boss_state "$DST" doctor --project "$P" --json 2>/dev/null)"
check_eq "runner doctor: known ok" "ok" \
  "$(printf '%s' "$doctor" | jq -r '.checks[] | select(.id=="mission_runners") | .status')"

# Documentation names the runner syntax and assignment rule.
skill="$(cat "$ROOT/vision/SKILL.md")"
readme="$(cat "$ROOT/README.md")"
for doc in "$readme" "$skill"; do
  check_contains "runner docs: syntax" "runner: claude-opus" "$doc"
  check_contains "runner docs: assignment" "claude-sonnet" "$doc"
done
check_contains "runner readme: unknown error" "unknown_runner" "$readme"

# 38. Reconcile gate: dry-run, missing marker, reconcile --done and explicit
# skip. The first change is already done and has a finish boundary.
P="$TMP/project-reconcile"
make_project "$P"
make_change "$P" first '- [x] 1.1 Done.'
make_change "$P" second '- [ ] 1.1 Next.'
make_mission "$P" v1 $'- first\n- second'
run_lib append_event "$(run_lib events_file_for "$P" first)" finish '{}' >/dev/null
out="$(run_boss mission next v1 --project "$P" --dry-run)"
check_eq "reconcile dry: gate required" "reconcile_required" "$(printf '%s' "$out" | jq -r '.status')"
check_eq "reconcile dry: target" "second" "$(printf '%s' "$out" | jq -r '.change')"
check_eq "reconcile dry: no apply" "0" "$(find "$STATE/applies" -name '*-second.json' 2>/dev/null | wc -l | tr -d ' ')"
err="$(run_boss_fail mission next v1 --project "$P")"
check_contains "reconcile gate: error" "reconcile_required" "$err"
check_contains "reconcile gate: names command" "reconcile v1" "$err"
check_eq "reconcile gate: no apply" "0" "$(find "$STATE/applies" -name '*-second.json' 2>/dev/null | wc -l | tr -d ' ')"

out="$(run_boss reconcile v1 --project "$P" --done second --json)"
check_eq "reconcile done: change" "second" "$(printf '%s' "$out" | jq -r '.reconciled.change')"
check_contains "reconcile done: journal" "reconcile-done" "$(cat "$P/openspec/journal.md")"
out="$(run_boss mission next v1 --project "$P" --dry-run)"
check_eq "reconcile done: dry start" "dry_run" "$(printf '%s' "$out" | jq -r '.status')"
check_eq "reconcile done: would start" "true" "$(printf '%s' "$out" | jq -r '.would_start')"

err="$(run_boss_fail reconcile v1 --project "$P" --done not-in-mission)"
check_contains "reconcile unknown: error" "mission_change_unknown" "$err"

out="$(run_boss mission next v1 --project "$P" --skip-reconcile --dry-run)"
check_eq "reconcile skip dry: would start" "true" "$(printf '%s' "$out" | jq -r '.would_start')"

# A real skip writes the mission event and the journal entry.
P_SKIP="$TMP/project-reconcile-skip"
make_project "$P_SKIP"
make_change "$P_SKIP" first '- [x] 1.1 Done.'
make_change "$P_SKIP" second '- [ ] 1.1 Next.'
make_mission "$P_SKIP" v1 $'- first\n- second'
run_lib append_event "$(run_lib events_file_for "$P_SKIP" first)" finish '{}' >/dev/null
out="$(run_boss mission next v1 --project "$P_SKIP" --skip-reconcile)"
check_eq "reconcile skip: starts" "started" "$(printf '%s' "$out" | jq -r '.status')"
sf="$STATE/cycles/$(run_lib sha1_hex "$P_SKIP")-mission-v1.events.jsonl"
check_contains "reconcile skip: event" '"event":"reconcile_skipped"' "$(cat "$sf")"
check_contains "reconcile skip: journal" "reconcile-skipped" "$(cat "$P_SKIP/openspec/journal.md")"

# The first dispatch of a mission has no boundary and needs no marker.
P_FIRST="$TMP/project-reconcile-first"
make_project "$P_FIRST"
make_change "$P_FIRST" only '- [ ] 1.1 Work.'
make_mission "$P_FIRST" v1 "- only"
out="$(run_boss mission next v1 --project "$P_FIRST" --dry-run)"
check_eq "reconcile first: no boundary" "dry_run" "$(printf '%s' "$out" | jq -r '.status')"
check_eq "reconcile first: would start" "true" "$(printf '%s' "$out" | jq -r '.would_start')"

# 39. Strict validation blocks both dispatch paths before a tab or state file.
P_VAL="$TMP/project-validation"
make_project "$P_VAL"
make_change "$P_VAL" invalid-change '- [ ] 1.1 Work.'
make_mission "$P_VAL" v1 "- invalid-change"
VTAB="$TMP/validation-tab.log"
err="$(OPENSPEC_STUB_VALIDATE_FAIL=1 HERDR_TAB_CREATE_LOG="$VTAB" \
  run_boss_fail dispatch invalid-change --project "$P_VAL")"
check_contains "validation dispatch: error" "change_invalid" "$err"
check_contains "validation dispatch: validator output" "missing scenario" "$err"
check_eq "validation dispatch: no tab" "" "$(cat "$VTAB" 2>/dev/null)"
check_eq "validation dispatch: no state" "0" \
  "$(find "$STATE/applies" -name '*invalid-change.json' 2>/dev/null | wc -l | tr -d ' ')"
err="$(OPENSPEC_STUB_VALIDATE_FAIL=1 HERDR_TAB_CREATE_LOG="$VTAB" \
  run_boss_fail mission next v1 --project "$P_VAL")"
check_contains "validation next: error" "change_invalid" "$err"
check_eq "validation next: no state" "0" \
  "$(find "$STATE/applies" -name '*invalid-change.json' 2>/dev/null | wc -l | tr -d ' ')"
# A valid change still dispatches.
out="$(HERDR_TAB_CREATE_LOG="$VTAB" run_boss dispatch invalid-change --project "$P_VAL")"
check_eq "validation valid: started" "started" "$(printf '%s' "$out" | jq -r '.status')"

# 40. External verification markers: classification, prompt, park and status.
P_EXT="$TMP/project-external"
make_project "$P_EXT"
make_change "$P_EXT" mixed-tasks $'- [ ] 1.1 [Nutzer] Ask a person.\n- [ ] 1.2 [Mac] Build on the Mac. Prüfen: Mac log green.\n- [ ] 1.3 Write code.'
tasks="$(run_lib mission_tasks_json "$P_EXT" mixed-tasks)"
check_eq "external: human_open" "1" "$(printf '%s' "$tasks" | jq -r '.human_open')"
check_eq "external: external_open" "1" "$(printf '%s' "$tasks" | jq -r '.external_open')"
check_eq "external: agent_open" "1" "$(printf '%s' "$tasks" | jq -r '.agent_open')"
check_eq "external: task text" "1.2 [Mac] Build on the Mac. Prüfen: Mac log green." \
  "$(printf '%s' "$tasks" | jq -r '.external_tasks[0].text')"

P_EXT_ONLY="$TMP/project-external-only"
make_project "$P_EXT_ONLY"
make_change "$P_EXT_ONLY" ext-only '- [ ] 1.1 [Mac] Build on the Mac. Prüfen: Mac log green.'
make_mission "$P_EXT_ONLY" v1 "- ext-only"
out="$(run_boss park ext-only --project "$P_EXT_ONLY")"
check_eq "external park: status" "parked" "$(printf '%s' "$out" | jq -r '.status')"
check_eq "external park: task" "1.1 [Mac] Build on the Mac. Prüfen: Mac log green." \
  "$(printf '%s' "$out" | jq -r '.external_tasks[0].text')"
status="$(run_boss mission status v1 --project "$P_EXT_ONLY")"
check_eq "external status: waiting_human" "waiting_human" \
  "$(printf '%s' "$status" | jq -r '.changes[0].state')"
check_eq "external status: external list" "1" \
  "$(printf '%s' "$status" | jq -r '.changes[0].external_tasks | length')"

P_EXT_AGENT="$TMP/project-external-agent"
make_project "$P_EXT_AGENT"
make_change "$P_EXT_AGENT" ext-agent $'- [ ] 1.1 [Mac] Build on the Mac.\n- [ ] 1.2 Write code.'
err="$(run_boss_fail park ext-agent --project "$P_EXT_AGENT")"
check_contains "external park: agent refused" "agent_tasks_open" "$err"

P_EXT_PROMPT="$TMP/project-external-prompt"
make_project "$P_EXT_PROMPT"
make_change "$P_EXT_PROMPT" ext-prompt '- [ ] 1.1 [Mac] Build on the Mac. Prüfen: Mac log green.'
EPROMPT="$TMP/external-prompt.log"
out="$(HERDR_PROMPT_LOG="$EPROMPT" run_boss dispatch ext-prompt --project "$P_EXT_PROMPT")"
check_eq "external prompt: started" "started" "$(printf '%s' "$out" | jq -r '.status')"
check_contains "external prompt: instruction" "External verification tasks" "$(cat "$EPROMPT")"
check_contains "external prompt: leave open" "leave their checkboxes open" "$(cat "$EPROMPT")"

# 41. Runner commit policy and review of foreign authors.
P_COMMIT="$TMP/project-commit-policy"
make_project "$P_COMMIT"
make_change "$P_COMMIT" explorer-commit '- [ ] 1.1 Code.'
ECONF="$TMP/commit-explorer.toml"
cat >"$ECONF" <<'EOF'
default = "opencode"
[runners.opencode]
kind = "opencode"
args = []
apply = "/opsx-apply {change}"
EOF
ELOG="$TMP/commit-explorer-prompt.log"
out="$(BOSS_CONFIG="$ECONF" HERDR_PROMPT_LOG="$ELOG" \
  run_boss_state "$TMP/commit-explorer-state" dispatch explorer-commit --project "$P_COMMIT")"
check_eq "commit explorer: started" "started" "$(printf '%s' "$out" | jq -r '.status')"
check_contains "commit explorer: no commit" "do not commit" "$(cat "$ELOG")"

P_COMMIT_AGENT="$TMP/project-commit-agent"
make_project "$P_COMMIT_AGENT"
make_change "$P_COMMIT_AGENT" agent-commit '- [ ] 1.1 Code.'
ACONF="$TMP/commit-agent.toml"
cat >"$ACONF" <<'EOF'
default = "opencode"
[runners.opencode]
kind = "opencode"
args = []
commit = "agent"
apply = "/opsx-apply {change}"
EOF
ALOG="$TMP/commit-agent-prompt.log"
out="$(BOSS_CONFIG="$ACONF" HERDR_PROMPT_LOG="$ALOG" \
  run_boss_state "$TMP/commit-agent-state" dispatch agent-commit --project "$P_COMMIT_AGENT")"
check_eq "commit agent: started" "started" "$(printf '%s' "$out" | jq -r '.status')"
check_contains "commit agent: commits" "Commit policy: commit your work" "$(cat "$ALOG")"

ICONF="$TMP/commit-invalid.toml"
cat >"$ICONF" <<'EOF'
default = "opencode"
[runners.opencode]
kind = "opencode"
args = []
commit = "sometimes"
apply = "/opsx-apply {change}"
EOF
err="$(BOSS_CONFIG="$ICONF" run_boss_fail_state "$TMP/commit-invalid-state" dispatch explorer-commit --project "$P_COMMIT")"
check_contains "commit invalid: error" "invalid_runner_commit" "$err"

# Foreign-author review uses a real temporary git repo.
P_GIT="$TMP/project-foreign-git"
make_project "$P_GIT"
make_change "$P_GIT" review-git '- [ ] 1.1 Code.'
git -C "$P_GIT" init -q
git -C "$P_GIT" config user.name "Explorer"
git -C "$P_GIT" config user.email "explorer@example.com"
git -C "$P_GIT" add -A
git -C "$P_GIT" commit -qm "initial"
base="$(git -C "$P_GIT" rev-parse HEAD)"
printf 'foreign\n' >"$P_GIT/foreign.txt"
git -C "$P_GIT" add foreign.txt
git -C "$P_GIT" commit -qm "foreign commit" --author "Foreign Agent <agent@example.local>"
mkdir -p "$STATE/applies"
jq -n --arg p "$P_GIT" --arg b "$base" '{change:"review-git",project:$p,workspace_id:"ws-1",
  agent:"apply-review-git",pane_id:"p-review",tab_id:"t-review",boss:"boss-ws-1",
  boss_pane:"p-boss",boss_workspace:"ws-1",base_head:$b,waiter_pid:null}' \
  >"$STATE/applies/$(run_lib sha1_hex "$P_GIT")-review-git.json"
out="$(run_boss review review-git --project "$P_GIT" --json)"
check_eq "foreign review: count" "1" "$(printf '%s' "$out" | jq -r '.friction.foreign_commits')"
check_eq "foreign review: author" "Foreign Agent" \
  "$(printf '%s' "$out" | jq -r '.quality.git.foreign_commits[0] | split("\t")[1] | split(" <")[0]')"

# 42. Session-level identity: matching, inherited fork, no-session fallback and
# the explicit --as bypass.
AG_SESSION='[{"name":"boss-ws-1","pane_id":"p-boss","workspace_id":"ws-1","agent_session":{"value":"sess-good"}}]'
out="$(HERDR_ENV=1 HERDR_PANE_ID=p-boss HERDR_WORKSPACE_ID=ws-1 \
  HERDR_PANES_JSON="$PANES_MATCH" HERDR_AGENTS_JSON="$AG_SESSION" \
  OPENCODE_SESSION_ID=sess-good run_lib boss_caller_identity_json "")"
check_eq "session: matching" "ok" "$(printf '%s' "$out" | jq -r '.status')"
check_eq "session: match flag" "true" "$(printf '%s' "$out" | jq -r '.session_match')"
out="$(HERDR_ENV=1 HERDR_PANE_ID=p-boss HERDR_WORKSPACE_ID=ws-1 \
  HERDR_PANES_JSON="$PANES_MATCH" HERDR_AGENTS_JSON="$AG_SESSION" \
  OPENCODE_SESSION_ID=sess-fork run_lib boss_caller_identity_json "")"
check_eq "session: inherited mismatch" "mismatch" "$(printf '%s' "$out" | jq -r '.status')"
check_eq "session: mismatch code" "caller_session_mismatch" "$(printf '%s' "$out" | jq -r '.code')"
check_eq "session: mismatch flag" "false" "$(printf '%s' "$out" | jq -r '.session_match')"
out="$(HERDR_ENV=1 HERDR_PANE_ID=p-boss HERDR_WORKSPACE_ID=ws-1 \
  HERDR_PANES_JSON="$PANES_MATCH" HERDR_AGENTS_JSON="$AG_SESSION" \
  OPENCODE_SESSION_ID= run_lib boss_caller_identity_json "")"
check_eq "session: no session fallback" "ok" "$(printf '%s' "$out" | jq -r '.status')"
out="$(HERDR_ENV=1 HERDR_PANE_ID=p-boss HERDR_WORKSPACE_ID=ws-1 \
  HERDR_PANES_JSON="$PANES_MATCH" HERDR_AGENTS_JSON="$AG_SESSION" \
  OPENCODE_SESSION_ID=sess-fork run_lib boss_caller_identity_json "p-boss")"
check_eq "session: explicit bypass" "ok" "$(printf '%s' "$out" | jq -r '.status')"
doctor="$(HERDR_ENV=1 HERDR_PANE_ID=p-boss HERDR_WORKSPACE_ID=ws-1 \
  HERDR_PANES_JSON="$PANES_MATCH" HERDR_AGENTS_JSON="$AG_SESSION" \
  OPENCODE_SESSION_ID=sess-fork run_boss doctor --project "$TMP/project-doctor" --json 2>/dev/null)"
check_eq "session: doctor warns" "warn" \
  "$(printf '%s' "$doctor" | jq -r '.checks[] | select(.id=="caller_identity") | .status')"
check_contains "session: doctor retarget hint" "retarget" \
  "$(printf '%s' "$doctor" | jq -r '.checks[] | select(.id=="caller_identity") | .hint')"

# 43. wait --all is scoped to the caller's project or workspace by default.
P_WA="$TMP/project-wait-a"
P_WB="$TMP/project-wait-b"
make_project "$P_WA"
make_project "$P_WB"
WST="$TMP/wait-scope-state"
mkdir -p "$WST/applies"
jq -n --arg p "$P_WA" '{change:"wait-a",project:$p,workspace_id:"ws-a",agent:null,pane_id:null,waiter_pid:null,parked:true}' \
  >"$WST/applies/$(run_lib sha1_hex "$P_WA")-wait-a.json"
jq -n --arg p "$P_WB" '{change:"wait-b",project:$p,workspace_id:"ws-b",agent:null,pane_id:null,waiter_pid:null,parked:true}' \
  >"$WST/applies/$(run_lib sha1_hex "$P_WB")-wait-b.json"
out="$(BOSS_TEST_WORKSPACE=ws-a run_boss_state "$WST" wait --all --all-projects)"
check_eq "wait scope: all count" "2" "$(printf '%s' "$out" | jq 'length')"
out="$(BOSS_TEST_WORKSPACE=ws-a run_boss_state "$WST" wait --all --project "$P_WA")"
check_eq "wait scope: explicit project" "1" "$(printf '%s' "$out" | jq 'length')"
check_eq "wait scope: project change" "wait-a" "$(printf '%s' "$out" | jq -r '.[0].change')"
mkdir -p "$TMP/no-project"
out="$(cd "$TMP/no-project" && BOSS_TEST_WORKSPACE=ws-a run_boss_state "$WST" wait --all)"
check_eq "wait scope: workspace" "1" "$(printf '%s' "$out" | jq 'length')"
check_eq "wait scope: workspace change" "wait-a" "$(printf '%s' "$out" | jq -r '.[0].change')"
out="$(cd "$TMP/no-project" && BOSS_TEST_WORKSPACE=ws-a run_boss_state "$WST" wait --all --all-projects)"
check_eq "wait scope: all projects" "2" "$(printf '%s' "$out" | jq 'length')"
err="$(cd "$TMP/no-project" && BOSS_TEST_WORKSPACE=ws-a run_boss_fail_state "$WST" wait --all --project "$P_WA" --all-projects)"
check_contains "wait scope: conflict" "either --project or --all-projects" "$err"

# 44. Waiter checks the pane before reporting lost.
P_A7="$TMP/project-agent-liveness"
make_project "$P_A7"
A7ST="$TMP/agent-liveness-state"
mkdir -p "$A7ST/applies"
jq -n --arg p "$P_A7" '{change:"lost-check",project:$p,pane_id:"p-live",tab_id:"t",workspace_id:"ws-1",
  boss:"boss-ws-1",boss_pane:"p-boss",boss_pane:"p-boss",waiter_pid:null}' \
  >"$A7ST/applies/$(run_lib sha1_hex "$P_A7")-lost-check.json"
A7EV="$A7ST/cycles/$(run_lib sha1_hex "$P_A7")-lost-check.events.jsonl"
mkdir -p "$A7ST/cycles"
env PATH="$BIN:$PATH" HOME="$TMP" BOSS_CONFIG="$CONFIG" BOSS_STATE_DIR="$A7ST" \
  HERDR_ENV=1 HERDR_PANE_ID=p-live HERDR_WORKSPACE_ID=ws-1 HERDR_LIVE_PANES=p-live \
  HERDR_AGENTS_JSON='[{"name":"apply-lost-check","pane_id":"p-live","workspace_id":"ws-1"}]' \
  HERDR_AGENT_WAIT_FAIL=1 timeout 2 bash "$ROOT/runtime/bin/boss-waiter" \
  "$A7ST/applies/$(run_lib sha1_hex "$P_A7")-lost-check.json" >/dev/null 2>&1 || true
check_not_contains "liveness: alive no lost" '"event":"lost"' "$(cat "$A7EV" 2>/dev/null)"
env PATH="$BIN:$PATH" HOME="$TMP" BOSS_CONFIG="$CONFIG" BOSS_STATE_DIR="$A7ST" \
  HERDR_ENV=1 HERDR_PANE_ID=p-live HERDR_WORKSPACE_ID=ws-1 HERDR_LIVE_PANES= \
  HERDR_AGENTS_JSON='[]' HERDR_AGENT_WAIT_FAIL=1 timeout 2 bash "$ROOT/runtime/bin/boss-waiter" \
  "$A7ST/applies/$(run_lib sha1_hex "$P_A7")-lost-check.json" >/dev/null 2>&1 || true
check_contains "liveness: gone reports lost" '"event":"lost"' "$(cat "$A7EV" 2>/dev/null)"

# 45. JSON commands keep stdout clean; diagnostics go to stderr.
P_A8="$TMP/project-output-contract"
make_project "$P_A8"
make_change "$P_A8" output-check '- [ ] 1.1 [Nutzer] Human step.'
make_mission "$P_A8" v1 "- output-check"
A8OUT="$TMP/a8-park.out"
A8ERR="$TMP/a8-park.err"
run_boss park output-check --project "$P_A8" >"$A8OUT" 2>"$A8ERR"
jq -e . "$A8OUT" >/dev/null && ok || bad "output: park stdout is not JSON"
check_not_contains "output: stderr keeps no JSON" '"status":' "$(cat "$A8ERR")"
A8OUT2="$TMP/a8-dry.out"
A8ERR2="$TMP/a8-dry.err"
run_boss mission next v1 --project "$P_A8" --dry-run >"$A8OUT2" 2>"$A8ERR2"
jq -e . "$A8OUT2" >/dev/null && ok || bad "output: dry-run stdout is not JSON"
A8OUT3="$TMP/a8-rec.out"
A8ERR3="$TMP/a8-rec.err"
run_boss reconcile v1 --project "$P_A8" --json >"$A8OUT3" 2>"$A8ERR3"
jq -e . "$A8OUT3" >/dev/null && ok || bad "output: reconcile stdout is not JSON"
check_not_contains "output: no timestamp in stdout" "2026-" "$(cat "$A8OUT")"

# 46. Interrupt sends runner keys, marks the state and makes the next settle
# interrupted; retrigger clears it.
P_INT="$TMP/project-interrupt"
make_project "$P_INT"
make_change "$P_INT" interrupt-me '- [ ] 1.1 Work.'
IST="$TMP/interrupt-state"
mkdir -p "$IST/applies"
jq -n --arg p "$P_INT" '{change:"interrupt-me",project:$p,workspace_id:"ws-1",
  runner:"opencode",kind:"opencode",agent:"apply-interrupt-me",pane_id:"p-int",
  tab_id:"t-int",boss:"boss-ws-1",boss_pane:"p-boss",boss_workspace:"ws-1",
  apply_cmd:"/opsx-apply interrupt-me",yield:"y",lessons:"",waiter_pid:null}' \
  >"$IST/applies/$(run_lib sha1_hex "$P_INT")-interrupt-me.json"
ISTATE="$IST/applies/$(run_lib sha1_hex "$P_INT")-interrupt-me.json"
IKEYS="$TMP/interrupt-keys.log"
out="$(HERDR_LIVE_PANES=p-int HERDR_SEND_KEYS_LOG="$IKEYS" \
  run_boss_state "$IST" interrupt interrupt-me --project "$P_INT")"
check_eq "interrupt: status" "interrupted" "$(printf '%s' "$out" | jq -r '.status')"
check_eq "interrupt: keys" '["esc","esc"]' "$(printf '%s' "$out" | jq -c '.keys')"
check_contains "interrupt: sent esc twice" "esc esc" "$(cat "$IKEYS")"
check_eq "interrupt: state flag" "true" "$(jq -r '.interrupted' "$ISTATE")"
check_contains "interrupt: event" '"event":"interrupt"' \
  "$(cat "$IST/cycles/$(run_lib sha1_hex "$P_INT")-interrupt-me.events.jsonl")"
check_contains "interrupt: journal" "interrupt" "$(cat "$P_INT/openspec/journal.md")"
out="$(HERDR_LIVE_PANES=p-int run_boss_state "$IST" retrigger interrupt-me --project "$P_INT")"
check_eq "interrupt: retrigger clears" "false" \
  "$(jq -r '.interrupted // false' "$ISTATE")"

# A waiter that sees the interrupted flag reports 'interrupted', not 'idle'.
jq '.interrupted = true | .interrupted_at = "2026-01-01T00:00:00+0000"' "$ISTATE" >"$ISTATE.tmp" && mv "$ISTATE.tmp" "$ISTATE"
env PATH="$BIN:$PATH" HOME="$TMP" BOSS_CONFIG="$CONFIG" BOSS_STATE_DIR="$IST" \
  HERDR_ENV=1 HERDR_PANE_ID=p-int HERDR_WORKSPACE_ID=ws-1 HERDR_LIVE_PANES=p-int \
  HERDR_AGENTS_JSON='[{"name":"apply-interrupt-me","pane_id":"p-int","workspace_id":"ws-1"}]' \
  timeout 2 bash "$ROOT/runtime/bin/boss-waiter" "$ISTATE" >/dev/null 2>&1 || true
check_contains "interrupt: wake state" '"state":"interrupted"' \
  "$(cat "$IST/cycles/$(run_lib sha1_hex "$P_INT")-interrupt-me.events.jsonl")"

# 47. External review pass template and documentation.
EXT_REF="$ROOT/vision/references/external-review.md"
if [ -f "$EXT_REF" ]; then ok; else bad "external review: template missing"; fi
for needle in "git pull" "build" "test" "osv-scanner" "reset --hard" "Report"; do
  check_contains "external review: $needle" "$needle" "$(cat "$EXT_REF")"
done
skill="$(cat "$ROOT/vision/SKILL.md")"
readme="$(cat "$ROOT/README.md")"
for doc in "$skill" "$readme"; do
  check_contains "external review: tag" "external-pass" "$doc"
  check_contains "external review: status" "external_open" "$doc"
done

# 48. start_after stops a later mission until the prerequisite is done or
# waiting_human.
P_B3="$TMP/project-parallel"
make_project "$P_B3"
make_change "$P_B3" v1-change '- [x] 1.1 Done.'
make_change "$P_B3" v2-change '- [ ] 1.1 Next.'
make_mission "$P_B3" v1 "- v1-change"
# Give v1 a finish event so it is done.
run_lib append_event "$(run_lib events_file_for "$P_B3" v1-change)" finish '{}' >/dev/null
make_mission "$P_B3" v2 $'- v2-change'
# Add start_after to v2's Plan section.
python3 - "$P_B3/openspec/missions/v2.md" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read(); s=s.replace('planning: planned','planning: planned\nstart_after: v1 (waiting_human)',1); open(p,'w').write(s)
PY
out="$(run_boss mission next v2 --project "$P_B3" --dry-run)"
check_eq "start_after: done allows" "dry_run" "$(printf '%s' "$out" | jq -r '.status')"
check_eq "start_after: v2 change" "v2-change" "$(printf '%s' "$out" | jq -r '.change')"
status="$(run_boss mission status v2 --project "$P_B3")"
check_eq "start_after: status setting" "v1 (waiting_human)" "$(printf '%s' "$status" | jq -r '.start_after')"
check_eq "start_after: status state" "done" "$(printf '%s' "$status" | jq -r '.start_after_state')"

P_B3B="$TMP/project-parallel-blocked"
make_project "$P_B3B"
make_change "$P_B3B" v1-open '- [ ] 1.1 Open.'
make_change "$P_B3B" v2-open '- [ ] 1.1 Next.'
make_mission "$P_B3B" v1 "- v1-open"
make_mission "$P_B3B" v2 "- v2-open"
python3 - "$P_B3B/openspec/missions/v2.md" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read(); s=s.replace('planning: planned','planning: planned\nstart_after: v1 (waiting_human)',1); open(p,'w').write(s)
PY
out="$(run_boss mission next v2 --project "$P_B3B" --dry-run)"
check_eq "start_after: in progress blocks" "mission_waiting" "$(printf '%s' "$out" | jq -r '.status')"
check_eq "start_after: prerequisite state" "in_progress" "$(printf '%s' "$out" | jq -r '.prerequisite_state')"
check_eq "start_after: no apply" "0" \
  "$(find "$STATE/applies" -name '*v2-open.json' 2>/dev/null | wc -l | tr -d ' ')"

# 49. Reconcile shows approved, not-yet-adopted recommendations for the next
# change.
P_B4="$TMP/project-recommendations"
make_project "$P_B4"
make_change "$P_B4" target-change '- [ ] 1.1 Work.'
make_mission "$P_B4" v1 "- target-change"
cat >"$P_B4/openspec/recommendations.md" <<'EOF'
| ID | Target | Decision | Note |
| --- | --- | --- | --- |
| R1 | target-change | approved | adopt the threshold |
| R2 | target-change | rejected | no |
| R3 | other-change | approved | other target |
| R4 | target-change | approved | already adopted |
EOF
run_boss journal --project "$P_B4" --tag recommendation-adopted --change target-change "R4 adopted" >/dev/null
out="$(run_boss reconcile v1 --project "$P_B4" --json)"
check_eq "recommendations: next change" "target-change" "$(printf '%s' "$out" | jq -r '.next_change')"
check_eq "recommendations: pending count" "1" "$(printf '%s' "$out" | jq '.recommendations | length')"
check_eq "recommendations: pending id" "R1" "$(printf '%s' "$out" | jq -r '.recommendations[0].id')"
check_eq "recommendations: target" "target-change" "$(printf '%s' "$out" | jq -r '.recommendations[0].target')"
txt="$(run_boss reconcile v1 --project "$P_B4")"
check_contains "recommendations: text" "pending recommendations" "$txt"
check_contains "recommendations: text id" "R1" "$txt"

# 50. Spec-delta placement rule is documented.
skill="$(cat "$ROOT/vision/SKILL.md")"
check_contains "spec delta: insertion rule" "after the last scenario" "$skill"
check_contains "spec delta: 500 chars" "under 500 characters" "$skill"
check_contains "spec delta: design ranges" "value ranges" "$skill"

# 51. Mission skeleton carries the operational charter fields.
P_CT="$TMP/project-charter-template"
make_project "$P_CT"
run_boss mission start v1 --project "$P_CT" >/dev/null
for section in "## Build Environment" "## External Review" "## Marker Policy" "## Commit Policy" "## Runner Policy" "## Start"; do
  check_contains "charter template: $section" "$section" "$(cat "$P_CT/openspec/missions/v1.md")"
done
skill="$(cat "$ROOT/vision/SKILL.md")"
for field in "Build Environment" "External Review" "Marker Policy" "Commit Policy" "Runner Policy" "start_after"; do
  check_contains "charter skill: $field" "$field" "$skill"
done

# 52. doctor --fix removes only dead registry entries.
P_C3="$TMP/project-doctor-fix"
make_project "$P_C3"
C3ST="$TMP/doctor-fix-state"
mkdir -p "$C3ST/bosses"
printf '%s\n' '{"workspace_id":"dead","pane_id":"p-dead","agent":"boss-dead"}' >"$C3ST/bosses/dead.json"
printf '%s\n' '{"workspace_id":"ws-1","pane_id":"p-live","agent":"boss-live"}' >"$C3ST/bosses/live.json"
out="$(HERDR_AGENTS_JSON='[{"name":"boss-live","pane_id":"p-live","workspace_id":"ws-2"}]' \
  run_boss_state "$C3ST" doctor --project "$P_C3" --json 2>/dev/null)"
check_eq "doctor fix: read-only warns" "warn" \
  "$(printf '%s' "$out" | jq -r '.checks[] | select(.id=="boss_registry") | .status')"
[ -f "$C3ST/bosses/dead.json" ] && ok || bad "doctor fix: read-only removed dead"
out="$(HERDR_AGENTS_JSON='[{"name":"boss-live","pane_id":"p-live","workspace_id":"ws-2"}]' \
  run_boss_state "$C3ST" doctor --project "$P_C3" --json --fix 2>/dev/null)"
[ ! -f "$C3ST/bosses/dead.json" ] && ok || bad "doctor fix: dead entry remains"
[ -f "$C3ST/bosses/live.json" ] && ok || bad "doctor fix: moved entry removed"
check_contains "doctor fix: removal hint" "removed dead registry" \
  "$(printf '%s' "$out" | jq -r '.checks[] | select(.id=="boss_registry") | .hint')"

# 53. Installer leaves a running waiter untouched and reports it.
IWH="$TMP/install-waiter-home"
mkdir -p "$IWH"
bash -c 'exec -a /tmp/boss-waiter sleep 30' &
DUMMY_WAITER=$!
sleep 0.2
out="$(HOME="$IWH" PATH="$BIN:$PATH" bash "$ROOT/install.sh" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ]; then ok; else bad "installer waiter: install failed"; fi
if kill -0 "$DUMMY_WAITER" 2>/dev/null; then ok; else bad "installer waiter: dummy waiter was killed"; fi
check_contains "installer waiter: reports untouched" "running waiter(s) untouched" "$out"
kill "$DUMMY_WAITER" 2>/dev/null || true

# 48b. start_after mirrors mission next when the prerequisite has only parked
# changes and dependency-blocked changes.
P_B3C="$TMP/project-parallel-parked"
make_project "$P_B3C"
make_change "$P_B3C" v1-parked '- [ ] 1.1 [Nutzer] Human.'
make_change "$P_B3C" v1-blocked $'- [ ] 1.1 Blocked.'
make_change "$P_B3C" v2-parked '- [ ] 1.1 Next.'
make_mission "$P_B3C" v1 $'- v1-parked\n- v1-blocked (after: v1-parked)'
make_mission "$P_B3C" v2 "- v2-parked"
run_lib append_event "$(run_lib events_file_for "$P_B3C" v1-parked)" park '{}' >/dev/null
python3 - "$P_B3C/openspec/missions/v2.md" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read(); s=s.replace('planning: planned','planning: planned\nstart_after: v1 (waiting_human)',1); open(p,'w').write(s)
PY
v1out="$(run_boss mission next v1 --project "$P_B3C" --dry-run)"
check_eq "start_after: v1 next is waiting_human" "waiting_human" "$(printf '%s' "$v1out" | jq -r '.status')"
out="$(run_boss mission next v2 --project "$P_B3C" --dry-run)"
check_eq "start_after: parked prerequisite allows" "dry_run" "$(printf '%s' "$out" | jq -r '.status')"
check_eq "start_after: parked prerequisite state" "waiting_human" \
  "$(run_boss mission status v2 --project "$P_B3C" | jq -r '.start_after_state')"

P_B3D="$TMP/project-parallel-blocked-only"
make_project "$P_B3D"
make_change "$P_B3D" blocked-only '- [ ] 1.1 Blocked.'
make_change "$P_B3D" v2-only '- [ ] 1.1 Next.'
make_mission "$P_B3D" v1 "- blocked-only (after: missing-change)"
make_mission "$P_B3D" v2 "- v2-only"
python3 - "$P_B3D/openspec/missions/v2.md" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read(); s=s.replace('planning: planned','planning: planned\nstart_after: v1 (waiting_human)',1); open(p,'w').write(s)
PY
out="$(run_boss mission next v2 --project "$P_B3D" --dry-run)"
check_eq "start_after: blocked prerequisite" "mission_waiting" "$(printf '%s' "$out" | jq -r '.status')"
check_eq "start_after: blocked state" "blocked" "$(printf '%s' "$out" | jq -r '.prerequisite_state')"

# 54. answer --as sends keys to the apply pane under a stale environment and
# records the answer event.
P_ANS="$TMP/project-answer-as"
make_project "$P_ANS"
make_change "$P_ANS" answer-change '- [ ] 1.1 Work.'
ANST="$TMP/answer-as-state"
mkdir -p "$ANST/applies"
jq -n --arg p "$P_ANS" '{change:"answer-change",project:$p,workspace_id:"ws-1",
  agent:"apply-answer-change",pane_id:"apply-pane",tab_id:"t-answer",
  boss:"boss-ws-1",boss_pane:"p-boss",boss_workspace:"ws-1",waiter_pid:null}' \
  >"$ANST/applies/$(run_lib sha1_hex "$P_ANS")-answer-change.json"
AKEYS="$TMP/answer-as-keys.log"
PANES_ANS="$(jq -nc '[{pane_id:"p-wrong",workspace_id:"ws-wrong",cwd:"/wrong"},{pane_id:"p-boss",workspace_id:"ws-1",cwd:"/right"}]')"
out="$(BOSS_TEST_PANE=p-wrong BOSS_TEST_WORKSPACE=ws-wrong HERDR_PANES_JSON="$PANES_ANS" \
  HERDR_SEND_KEYS_LOG="$AKEYS" run_boss_state "$ANST" answer answer-change enter --as p-boss)"
check_eq "answer as: status" "sent" "$(printf '%s' "$out" | jq -r '.status')"
check_contains "answer as: apply pane" "apply-pane enter" "$(cat "$AKEYS")"
check_not_contains "answer as: wrong pane" "p-wrong" "$(cat "$AKEYS")"
check_contains "answer as: event" '"event":"answer"' \
  "$(cat "$ANST/cycles/$(run_lib sha1_hex "$P_ANS")-answer-change.events.jsonl")"

# 55. Review reports explorer commits as policy violations; finish warns on a
# dirty explorer tree.
ANS_STATE="$STATE/applies/$(run_lib sha1_hex "$P_GIT")-review-git.json"
jq '.commit_policy = "explorer"' "$ANS_STATE" >"$ANS_STATE.tmp" && mv "$ANS_STATE.tmp" "$ANS_STATE"
out="$(run_boss review review-git --project "$P_GIT" --json)"
check_eq "commit policy: review field" "explorer" "$(printf '%s' "$out" | jq -r '.quality.git.commit_policy')"
check_eq "commit policy: violation count" "1" \
  "$(printf '%s' "$out" | jq '.friction.commit_policy_violations | length')"
jq '.commit_policy = "agent"' "$ANS_STATE" >"$ANS_STATE.tmp" && mv "$ANS_STATE.tmp" "$ANS_STATE"
out="$(run_boss review review-git --project "$P_GIT" --json)"
check_eq "commit policy: agent no violation" "0" \
  "$(printf '%s' "$out" | jq '.friction.commit_policy_violations | length')"

P_FIN="$TMP/project-finish-warning"
make_project "$P_FIN"
make_change "$P_FIN" finish-warning '- [ ] 1.1 Work.'
git -C "$P_FIN" init -q
git -C "$P_FIN" config user.name "Explorer"
git -C "$P_FIN" config user.email "explorer@example.com"
git -C "$P_FIN" add -A
git -C "$P_FIN" commit -qm initial
printf 'dirty\n' >"$P_FIN/dirty.txt"
FINST="$TMP/finish-warning-state"
mkdir -p "$FINST/applies"
jq -n --arg p "$P_FIN" '{change:"finish-warning",project:$p,workspace_id:"ws-1",
  agent:"apply-finish-warning",pane_id:"p-fin",tab_id:"t-fin",boss:"boss-ws-1",
  boss_pane:"p-boss",boss_workspace:"ws-1",commit_policy:"explorer",waiter_pid:null}' \
  >"$FINST/applies/$(run_lib sha1_hex "$P_FIN")-finish-warning.json"
out="$(HERDR_LIVE_PANES=p-fin run_boss_state "$FINST" finish finish-warning --project "$P_FIN")"
check_eq "finish warning: field" "true" "$(printf '%s' "$out" | jq -r '.working_tree_warning')"
check_eq "finish warning: path listed" "dirty.txt" \
  "$(printf '%s' "$out" | jq -r '.changed_files[0] | split(" ")[-1]')"

# 56. The vision and boss skills share one run-procedure block byte for byte.
# A change to only one copy is drift and fails with the sync command.
shared_run_block() {
  awk '/<!-- shared:run:begin -->/{f=1;next} /<!-- shared:run:end -->/{f=0} f' "$1"
}
for f in "$ROOT/vision/SKILL.md" "$ROOT/boss/SKILL.md"; do
  name="$(basename "$(dirname "$f")")"
  check_eq "shared run: one begin marker in $name" "1" \
    "$(grep -c '<!-- shared:run:begin -->' "$f")"
  check_eq "shared run: one end marker in $name" "1" \
    "$(grep -c '<!-- shared:run:end -->' "$f")"
done
if [ ! -f "$ROOT/boss/SKILL.md" ]; then
  bad "shared run: boss/SKILL.md is missing"
elif diff -u <(shared_run_block "$ROOT/vision/SKILL.md") \
  <(shared_run_block "$ROOT/boss/SKILL.md") >"$TMP/shared-run.diff"; then
  ok
else
  bad "shared run: vision and boss blocks drifted (fix with the command below):
$(cat "$TMP/shared-run.diff")
  awk 'FNR==NR { if (\$0==\"<!-- shared:run:begin -->\") {inb=1; next} if (\$0==\"<!-- shared:run:end -->\") {inb=0; next} if (inb) block=block \$0 \"\\n\"; next } \$0==\"<!-- shared:run:begin -->\" {print; printf \"%s\", block; skip=1; next} \$0==\"<!-- shared:run:end -->\" {skip=0} !skip' vision/SKILL.md boss/SKILL.md > boss/SKILL.md.new && mv boss/SKILL.md.new boss/SKILL.md"
fi

# 58. Plan commit commits only the plan paths; clean and dirty-code cases.
P_WT="$TMP/project-worktree"
make_git_project "$P_WT"
make_change "$P_WT" wt-change '- [ ] 1.1 Code.'
printf 'code\n' >"$P_WT/code.txt"
git -C "$P_WT" add code.txt
git -C "$P_WT" commit -qm "code"
base_before="$(git -C "$P_WT" rev-parse HEAD)"
out="$(plan_commit "$P_WT" wt-change)"
check_eq "plan commit: status" "committed" "$(printf '%s' "$out" | jq -r '.status')"
check_contains "plan commit: names plan path" "openspec/changes/wt-change/tasks.md" \
  "$(printf '%s' "$out" | jq -r '.paths | join(" ")')"
check_eq "plan commit: commit id" "$(git -C "$P_WT" rev-parse HEAD)" \
  "$(printf '%s' "$out" | jq -r '.commit')"
plan_files="$(git -C "$P_WT" show --name-only --format= HEAD)"
check_contains "plan commit: includes change" "openspec/changes/wt-change/tasks.md" "$plan_files"
check_not_contains "plan commit: no code" "code.txt" "$plan_files"
head_after="$(git -C "$P_WT" rev-parse HEAD)"
out="$(plan_commit "$P_WT" wt-change)"
check_eq "plan commit: clean no-op" "clean" "$(printf '%s' "$out" | jq -r '.status')"
check_eq "plan commit: clean keeps head" "$head_after" "$(git -C "$P_WT" rev-parse HEAD)"
printf 'dirty\n' >"$P_WT/dirty.txt"
out="$(plan_commit "$P_WT" wt-change)"
check_eq "plan commit: dirty code ignored" "clean" "$(printf '%s' "$out" | jq -r '.status')"
check_eq "plan commit: dirty code stays" "dirty" "$(cat "$P_WT/dirty.txt")"
check_not_contains "plan commit: dirty code not committed" "dirty.txt" \
  "$(git -C "$P_WT" show --name-only --format= HEAD)"
rm -f "$P_WT/dirty.txt"

# 59. Worktree dispatch requires a committed plan and a clean base.
P_WTP="$TMP/project-worktree-plan"
make_git_project "$P_WTP"
make_change "$P_WTP" plan-dirty '- [ ] 1.1 Code.'
WTST_P="$TMP/worktree-plan-state"
mkdir -p "$WTST_P"
err="$(run_boss_fail_state "$WTST_P" dispatch plan-dirty --project "$P_WTP" --worktree)"
check_contains "worktree dispatch: plan_uncommitted" "plan_uncommitted" "$err"
check_eq "worktree dispatch: plan_uncommitted no state" "0" \
  "$(find "$WTST_P/applies" -name '*plan-dirty.json' 2>/dev/null | wc -l | tr -d ' ')"
plan_commit "$P_WTP" plan-dirty >/dev/null
printf 'dirty\n' >"$P_WTP/dirty.txt"
VTAB_P="$TMP/worktree-plan-tab.log"
err="$(HERDR_TAB_CREATE_LOG="$VTAB_P" run_boss_fail_state "$WTST_P" dispatch plan-dirty --project "$P_WTP" --worktree)"
check_contains "worktree dispatch: base_dirty" "base_dirty" "$err"
check_contains "worktree dispatch: names dirty path" "dirty.txt" "$err"
check_eq "worktree dispatch: base_dirty no tab" "" "$(cat "$VTAB_P" 2>/dev/null)"
check_eq "worktree dispatch: base_dirty no state" "0" \
  "$(find "$WTST_P/applies" -name '*plan-dirty.json' 2>/dev/null | wc -l | tr -d ' ')"
rm -f "$P_WTP/dirty.txt"

# A failed create leaves no tab, state, branch or worktree behind.
P_WTF="$TMP/project-worktree-fail"
make_git_project "$P_WTF"
make_change "$P_WTF" fail-create '- [ ] 1.1 Code.'
plan_commit "$P_WTF" fail-create >/dev/null
WTST_F="$TMP/worktree-fail-state"
mkdir -p "$WTST_F"
VTAB_F="$TMP/worktree-fail-tab.log"
err="$(HERDR_WORKTREE_CREATE_FAIL=after HERDR_TAB_CREATE_LOG="$VTAB_F" \
  run_boss_fail_state "$WTST_F" dispatch fail-create --project "$P_WTF" --worktree)"
check_contains "worktree create fail: error" "worktree_create_failed" "$err"
check_eq "worktree create fail: no tab" "" "$(cat "$VTAB_F" 2>/dev/null)"
check_eq "worktree create fail: no state" "0" \
  "$(find "$WTST_F/applies" -name '*fail-create.json' 2>/dev/null | wc -l | tr -d ' ')"
check_eq "worktree create fail: no branch" "0" \
  "$(git -C "$P_WTF" branch --list 'boss/fail-create' | wc -l | tr -d ' ')"
check_eq "worktree create fail: no worktree" "0" \
  "$(git -C "$P_WTF" worktree list --porcelain | grep -c 'worktrees/.*/fail-create' || true)"

# 60. Worktree dispatch, state, status and the base staying unchanged.
WTST="$TMP/worktree-state"
mkdir -p "$WTST"
WT_BASE_BRANCH="$(git -C "$P_WT" rev-parse --abbrev-ref HEAD)"
VTAB="$TMP/worktree-tab.log"
out="$(HERDR_TAB_CREATE_LOG="$VTAB" run_boss_state "$WTST" \
  dispatch wt-change --project "$P_WT" --worktree)"
check_eq "worktree dispatch: status" "started" "$(printf '%s' "$out" | jq -r '.status')"
WT="$(printf '%s' "$out" | jq -r '.worktree')"
if [ -z "$WT" ] || [ ! -d "$WT" ]; then bad "worktree dispatch produced no worktree"; WT="$TMP/missing-worktree"; fi
WT_EXPECTED="$WTST/worktrees/$(run_lib sha1_hex "$P_WT")/wt-change"
check_eq "worktree dispatch: path" "$WT_EXPECTED" "$WT"
check_eq "worktree dispatch: branch" "boss/wt-change" "$(printf '%s' "$out" | jq -r '.branch')"
WTSF="$WTST/applies/$(run_lib sha1_hex "$P_WT")-wt-change.json"
check_eq "worktree state: worktree" "$WT" "$(jq -r '.worktree' "$WTSF")"
check_eq "worktree state: branch" "boss/wt-change" "$(jq -r '.branch' "$WTSF")"
check_eq "worktree state: workspace" "ws-wt-wt-change" "$(jq -r '.worktree_workspace' "$WTSF")"
check_eq "worktree state: merge_state" "none" "$(jq -r '.merge_state' "$WTSF")"
check_eq "worktree state: merged" "false" "$(jq -r '.merged' "$WTSF")"
check_eq "worktree state: merge_test" "not_run" "$(jq -r '.merge_test' "$WTSF")"
check_eq "worktree state: kept" "false" "$(jq -r '.kept' "$WTSF")"
check_eq "worktree state: base commit" "$(git -C "$P_WT" rev-parse HEAD)" "$(jq -r '.base_head' "$WTSF")"
check_contains "worktree tab: uses worktree cwd" "--cwd $WT" "$(cat "$VTAB")"
check_contains "worktree tab: uses worktree workspace" "--workspace ws-wt-wt-change" "$(cat "$VTAB")"
check_eq "worktree dispatch: base clean" "" "$(git -C "$P_WT" status --porcelain)"
check_eq "worktree dispatch: base branch unchanged" "$WT_BASE_BRANCH" \
  "$(git -C "$P_WT" rev-parse --abbrev-ref HEAD)"
status="$(HERDR_LIVE_PANES=pane-wt-change run_boss_state "$WTST" \
  status wt-change --project "$P_WT" --json)"
check_eq "worktree status: worktree" "$WT" "$(printf '%s' "$status" | jq -r '.worktree')"
check_eq "worktree status: branch" "boss/wt-change" "$(printf '%s' "$status" | jq -r '.branch')"
check_eq "worktree status: merge state" "none" "$(printf '%s' "$status" | jq -r '.merge_state')"

# A create result without path/branch falls back to 'herdr worktree list'.
P_WTM="$TMP/project-worktree-minimal"
make_git_project "$P_WTM"
make_change "$P_WTM" wt-min '- [ ] 1.1 Code.'
plan_commit "$P_WTM" wt-min >/dev/null
WTST_M="$TMP/worktree-minimal-state"
mkdir -p "$WTST_M"
out="$(HERDR_WORKTREE_CREATE_MINIMAL=1 run_boss_state "$WTST_M" \
  dispatch wt-min --project "$P_WTM" --worktree)"
check_eq "worktree minimal: fallback path" \
  "$WTST_M/worktrees/$(run_lib sha1_hex "$P_WTM")/wt-min" \
  "$(printf '%s' "$out" | jq -r '.worktree')"
check_eq "worktree minimal: fallback branch" "boss/wt-min" \
  "$(printf '%s' "$out" | jq -r '.branch')"
check_eq "worktree minimal: fallback workspace" "ws-wt-wt-min" \
  "$(printf '%s' "$out" | jq -r '.workspace_id')"
WTM="$(jq -r '.worktree' "$WTST_M/applies/$(run_lib sha1_hex "$P_WTM")-wt-min.json")"
REMOVE_MIN="$TMP/worktree-minimal-remove.log"
HERDR_WORKTREE_REMOVE_LOG="$REMOVE_MIN" \
  run_lib herdr_worktree_remove "$P_WTM" "$WTM" >/dev/null
check_contains "worktree minimal: path lookup finds workspace" \
  "--workspace ws-wt-wt-min" "$(cat "$REMOVE_MIN" 2>/dev/null)"
check_eq "worktree minimal: path lookup removes" "0" \
  "$([ -e "$WTM" ] && printf 1 || printf 0)"

# 61. Review reads tasks, validation, tests and git from the worktree.
printf 'worktree\n' >"$WT/new.txt"
printf -- '- [x] 1.1 Code.\n' >"$WT/openspec/changes/wt-change/tasks.md"
base_status_before="$(git -C "$P_WT" status --porcelain)"
out="$(run_boss_state "$WTST" review wt-change --project "$P_WT" --json)"
check_eq "worktree review: worktree field" "$WT" "$(printf '%s' "$out" | jq -r '.worktree')"
check_eq "worktree review: project stays base" "$P_WT" "$(printf '%s' "$out" | jq -r '.project')"
check_eq "worktree review: tasks from worktree" "0" "$(printf '%s' "$out" | jq -r '.quality.tasks.open')"
check_contains "worktree review: worktree diff" "new.txt" \
  "$(printf '%s' "$out" | jq -r '.quality.git.changed_files | join(" ")')"
check_eq "worktree review: base untouched" "$base_status_before" "$(git -C "$P_WT" status --porcelain)"

# 62. Clean finish merges, tests the base and cleans up.
git -C "$WT" add -A
git -C "$WT" commit -qm "apply wt-change"
REMOVE_FIN="$TMP/worktree-finish-remove.log"
out="$(HERDR_LIVE_PANES=pane-wt-change HERDR_WORKTREE_REMOVE_LOG="$REMOVE_FIN" \
  run_boss_state "$WTST" finish wt-change --project "$P_WT")"
check_eq "worktree finish: status" "finished" "$(printf '%s' "$out" | jq -r '.status')"
check_contains "worktree finish: herdr removes by workspace" \
  "--workspace ws-wt-wt-change" "$(cat "$REMOVE_FIN" 2>/dev/null)"
check_not_contains "worktree finish: no --cwd" "--cwd" "$(cat "$REMOVE_FIN" 2>/dev/null)"
check_not_contains "worktree finish: no --path" "--path" "$(cat "$REMOVE_FIN" 2>/dev/null)"
check_eq "worktree finish: merged" "true" "$(printf '%s' "$out" | jq -r '.merged')"
check_eq "worktree finish: base has change" "worktree" "$(cat "$P_WT/new.txt")"
check_eq "worktree finish: worktree removed" "0" "$([ -e "$WT" ] && printf 1 || printf 0)"
check_eq "worktree finish: branch removed" "0" \
  "$(git -C "$P_WT" branch --list 'boss/wt-change' | wc -l | tr -d ' ')"
check_eq "worktree finish: state removed" "0" "$([ -f "$WTSF" ] && printf 1 || printf 0)"
check_eq "worktree finish: base clean" "" "$(git -C "$P_WT" status --porcelain)"
check_contains "worktree finish: event" '"event":"finish"' \
  "$(cat "$WTST/cycles/$(run_lib sha1_hex "$P_WT")-wt-change.events.jsonl")"

# 63. --no-merge and --keep-worktree preserve the worktree; a later finish cleans.
P_WTK="$TMP/project-worktree-keep"
make_git_project "$P_WTK"
make_change "$P_WTK" wt-keep '- [ ] 1.1 Code.'
printf 'code\n' >"$P_WTK/code.txt"
git -C "$P_WTK" add code.txt; git -C "$P_WTK" commit -qm code
plan_commit "$P_WTK" wt-keep >/dev/null
WTST_K="$TMP/worktree-keep-state"
mkdir -p "$WTST_K"
out="$(run_boss_state "$WTST_K" dispatch wt-keep --project "$P_WTK" --worktree)"
WTK="$(printf '%s' "$out" | jq -r '.worktree')"
if [ -z "$WTK" ] || [ ! -d "$WTK" ]; then bad "worktree keep: no worktree"; WTK="$TMP/missing-worktree"; fi
KSF="$WTST_K/applies/$(run_lib sha1_hex "$P_WTK")-wt-keep.json"
printf 'kept\n' >"$WTK/kept.txt"
git -C "$WTK" add -A; git -C "$WTK" commit -qm "kept work"
out="$(HERDR_LIVE_PANES=pane-wt-keep run_boss_state "$WTST_K" \
  finish wt-keep --project "$P_WTK" --no-merge)"
check_eq "no-merge: status" "kept" "$(printf '%s' "$out" | jq -r '.status')"
check_eq "no-merge: worktree kept" "1" "$([ -d "$WTK" ] && printf 1 || printf 0)"
check_eq "no-merge: branch kept" "1" \
  "$(git -C "$P_WTK" branch --list 'boss/wt-keep' | wc -l | tr -d ' ')"
check_eq "no-merge: state kept" "1" "$([ -f "$KSF" ] && printf 1 || printf 0)"
check_eq "no-merge: no finish event" "0" \
  "$(run_lib event_count "$WTST_K/cycles/$(run_lib sha1_hex "$P_WTK")-wt-keep.events.jsonl" finish)"
out="$(run_boss_state "$WTST_K" finish wt-keep --project "$P_WTK" --keep-worktree)"
check_eq "keep-worktree: status" "kept" "$(printf '%s' "$out" | jq -r '.status')"
check_eq "keep-worktree: state kept" "true" "$(jq -r '.kept' "$KSF")"
check_eq "keep-worktree: merge done" "done" "$(jq -r '.merge_state' "$KSF")"
check_eq "keep-worktree: worktree kept" "1" "$([ -d "$WTK" ] && printf 1 || printf 0)"
check_eq "keep-worktree: base has change" "kept" "$(cat "$P_WTK/kept.txt")"
out="$(run_boss_state "$WTST_K" finish wt-keep --project "$P_WTK")"
check_eq "keep-worktree: second finish" "finished" "$(printf '%s' "$out" | jq -r '.status')"
check_eq "keep-worktree: removed" "0" "$([ -e "$WTK" ] && printf 1 || printf 0)"
check_eq "keep-worktree: state removed" "0" "$([ -f "$KSF" ] && printf 1 || printf 0)"

# 64. A merge conflict aborts, keeps the worktree and names the path.
P_WTC="$TMP/project-worktree-conflict"
make_git_project "$P_WTC"
make_change "$P_WTC" wt-conflict '- [ ] 1.1 Code.'
plan_commit "$P_WTC" wt-conflict >/dev/null
WTST_C="$TMP/worktree-conflict-state"
mkdir -p "$WTST_C"
out="$(run_boss_state "$WTST_C" dispatch wt-conflict --project "$P_WTC" --worktree)"
WTC="$(printf '%s' "$out" | jq -r '.worktree')"
if [ -z "$WTC" ] || [ ! -d "$WTC" ]; then bad "worktree conflict: no worktree"; WTC="$TMP/missing-worktree"; fi
printf 'worktree\n' >"$WTC/README.md"
git -C "$WTC" add README.md; git -C "$WTC" commit -qm worktree
printf 'base-edit\n' >"$P_WTC/README.md"
git -C "$P_WTC" add README.md; git -C "$P_WTC" commit -qm base
CSF="$WTST_C/applies/$(run_lib sha1_hex "$P_WTC")-wt-conflict.json"
err="$(HERDR_LIVE_PANES=pane-wt-conflict run_boss_fail_state "$WTST_C" \
  finish wt-conflict --project "$P_WTC")"
check_contains "merge conflict: code" "merge_conflict" "$err"
check_contains "merge conflict: path" "README.md" "$err"
check_eq "merge conflict: state kept" "conflict" "$(jq -r '.merge_state' "$CSF")"
check_eq "merge conflict: worktree kept" "1" "$([ -d "$WTC" ] && printf 1 || printf 0)"
check_eq "merge conflict: branch kept" "1" \
  "$(git -C "$P_WTC" branch --list 'boss/wt-conflict' | wc -l | tr -d ' ')"
check_eq "merge conflict: base clean" "" "$(git -C "$P_WTC" status --porcelain)"
check_eq "merge conflict: base content" "base-edit" "$(cat "$P_WTC/README.md")"

# 65. A red integration test keeps the state; a second finish retries.
P_WTT="$TMP/project-worktree-test"
make_git_project "$P_WTT"
make_change "$P_WTT" wt-test '- [ ] 1.1 Code.'
printf 'code\n' >"$P_WTT/code.txt"
git -C "$P_WTT" add code.txt; git -C "$P_WTT" commit -qm code
plan_commit "$P_WTT" wt-test >/dev/null
WTCONF="$TMP/worktree-test.toml"
printf 'default = "opencode"\n[projects]\nwt-test = "%s"\n[tests]\nwt-test = "test ! -f \\"$FAIL_MARKER\\""\n[runners.opencode]\nkind = "opencode"\nargs = []\napply = "/opsx-apply {change}"\n[missions]\nworktrees = "auto"\n' "$P_WTT" >"$WTCONF"
WTST_T="$TMP/worktree-test-state"
mkdir -p "$WTST_T"
out="$(BOSS_CONFIG="$WTCONF" run_boss_state "$WTST_T" dispatch wt-test --project "$P_WTT" --worktree)"
WTT="$(printf '%s' "$out" | jq -r '.worktree')"
if [ -z "$WTT" ] || [ ! -d "$WTT" ]; then bad "worktree test: no worktree"; WTT="$TMP/missing-worktree"; fi
printf 'tested\n' >"$WTT/tested.txt"
git -C "$WTT" add -A; git -C "$WTT" commit -qm "tested work"
TSF="$WTST_T/applies/$(run_lib sha1_hex "$P_WTT")-wt-test.json"
FAIL_MARKER="$TMP/worktree-test-fail-marker"
touch "$FAIL_MARKER"
err="$(BOSS_CONFIG="$WTCONF" HERDR_LIVE_PANES=pane-wt-test run_boss_fail_state "$WTST_T" \
  finish wt-test --project "$P_WTT")"
check_contains "merge test: red code" "merge_test_failed" "$err"
check_eq "merge test: merged" "true" "$(jq -r '.merged' "$TSF")"
check_eq "merge test: state" "test_failed" "$(jq -r '.merge_state' "$TSF")"
check_eq "merge test: result" "fail" "$(jq -r '.merge_test' "$TSF")"
check_eq "merge test: base has change" "tested" "$(cat "$P_WTT/tested.txt")"
rm -f "$FAIL_MARKER"
out="$(BOSS_CONFIG="$WTCONF" run_boss_state "$WTST_T" finish wt-test --project "$P_WTT")"
check_eq "merge test: retry finishes" "finished" "$(printf '%s' "$out" | jq -r '.status')"
check_eq "merge test: retry removed worktree" "0" "$([ -e "$WTT" ] && printf 1 || printf 0)"
check_eq "merge test: retry removed state" "0" "$([ -f "$TSF" ] && printf 1 || printf 0)"

# 66. Park keeps the worktree; resume and retrigger reuse it.
P_WTPARK="$TMP/project-worktree-park"
make_git_project "$P_WTPARK"
make_change "$P_WTPARK" wt-park '- [ ] 1.1 [Nutzer] Konto verknüpfen.'
plan_commit "$P_WTPARK" wt-park >/dev/null
WTST_PA="$TMP/worktree-park-state"
mkdir -p "$WTST_PA"
TAB_PA="$TMP/worktree-park-tab.log"
PROMPT_PA="$TMP/worktree-park-prompt.log"
out="$(HERDR_TAB_CREATE_LOG="$TAB_PA" run_boss_state "$WTST_PA" \
  dispatch wt-park --project "$P_WTPARK" --worktree)"
WTPA="$(printf '%s' "$out" | jq -r '.worktree')"
if [ -z "$WTPA" ] || [ ! -d "$WTPA" ]; then bad "worktree park: no worktree"; WTPA="$TMP/missing-worktree"; fi
PSF="$WTST_PA/applies/$(run_lib sha1_hex "$P_WTPARK")-wt-park.json"
run_boss_state "$WTST_PA" park wt-park --project "$P_WTPARK" >/dev/null
check_eq "worktree park: parked" "true" "$(jq -r '.parked' "$PSF")"
check_eq "worktree park: worktree kept" "1" "$([ -d "$WTPA" ] && printf 1 || printf 0)"
out="$(HERDR_TAB_CREATE_LOG="$TAB_PA" run_boss_state "$WTST_PA" \
  resume wt-park --project "$P_WTPARK" --note "account linked")"
check_eq "worktree resume: status" "started" "$(printf '%s' "$out" | jq -r '.status')"
check_eq "worktree resume: same worktree" "$WTPA" "$(jq -r '.worktree' "$PSF")"
check_eq "worktree resume: same branch" "boss/wt-park" "$(jq -r '.branch' "$PSF")"
check_eq "worktree resume: one worktree" "1" \
  "$(git -C "$P_WTPARK" worktree list --porcelain | grep -c 'worktrees/.*/wt-park' || true)"
tabs_before="$(wc -l <"$TAB_PA" | tr -d ' ')"
out="$(HERDR_PROMPT_LOG="$PROMPT_PA" HERDR_LIVE_PANES=pane-wt-park \
  run_boss_state "$WTST_PA" retrigger wt-park --project "$P_WTPARK")"
check_eq "worktree retrigger: same agent" "retriggered" "$(printf '%s' "$out" | jq -r '.status')"
check_contains "worktree retrigger: prompt sent" "account linked" "$(cat "$PROMPT_PA")"
check_eq "worktree retrigger: no new tab" "$tabs_before" "$(wc -l <"$TAB_PA" | tr -d ' ')"

# A missing worktree fails instead of falling back to the base checkout.
P_WTMISS="$TMP/project-worktree-missing"
make_git_project "$P_WTMISS"
make_change "$P_WTMISS" wt-miss '- [ ] 1.1 Code.'
MST="$TMP/worktree-missing-state"
mkdir -p "$MST/applies"
jq -n --arg p "$P_WTMISS" --arg w "$TMP/does-not-exist-worktree" \
  '{change:"wt-miss",project:$p,runner:"opencode",agent:"apply-wt-miss",pane_id:null,
    tab_id:null,workspace_id:"ws-1",worktree:$w,branch:"boss/wt-miss",
    worktree_workspace:"ws-wt-wt-miss",base_head:null,waiter_pid:null,parked:true}' \
  >"$MST/applies/$(run_lib sha1_hex "$P_WTMISS")-wt-miss.json"
err="$(run_boss_fail_state "$MST" resume wt-miss --project "$P_WTMISS")"
check_contains "worktree missing: resume" "worktree_missing" "$err"
err="$(run_boss_fail_state "$MST" retrigger wt-miss --project "$P_WTMISS")"
check_contains "worktree missing: retrigger" "worktree_missing" "$err"

# 67. Worktree mode resolution and the mission path.
P_WTALWAYS="$TMP/project-worktree-always"
make_git_project "$P_WTALWAYS"
make_change "$P_WTALWAYS" wt-always '- [ ] 1.1 Code.'
plan_commit "$P_WTALWAYS" wt-always >/dev/null
ACONF2="$TMP/worktree-always.toml"
printf 'default = "opencode"\n[projects]\nwt-always = "%s"\n[runners.opencode]\nkind = "opencode"\nargs = []\napply = "/opsx-apply {change}"\n[missions]\nworktrees = "always"\n' "$P_WTALWAYS" >"$ACONF2"
WTST_A="$TMP/worktree-always-state"
mkdir -p "$WTST_A"
out="$(BOSS_CONFIG="$ACONF2" run_boss_state "$WTST_A" dispatch wt-always --project "$P_WTALWAYS")"
check_contains "worktree mode always: creates" "worktrees/" "$(printf '%s' "$out" | jq -r '.worktree')"
B_WTCHANGE="$TMP/project-worktree-never"
make_git_project "$B_WTCHANGE"
make_change "$B_WTCHANGE" wt-never '- [ ] 1.1 Code.'
plan_commit "$B_WTCHANGE" wt-never >/dev/null
out="$(BOSS_CONFIG="$ACONF2" run_boss_state "$WTST_A" dispatch wt-never --project "$B_WTCHANGE" --no-worktree)"
check_eq "worktree mode always: no-worktree flag wins" "null" "$(printf '%s' "$out" | jq -r '.worktree')"
ICONF2="$TMP/worktree-invalid.toml"
printf 'default = "opencode"\n[runners.opencode]\nkind = "opencode"\nargs = []\napply = "/opsx-apply {change}"\n[missions]\nworktrees = "sometimes"\n' >"$ICONF2"
err="$(BOSS_CONFIG="$ICONF2" run_boss_fail_state "$WTST_A" dispatch wt-never --project "$B_WTCHANGE")"
check_contains "worktree mode invalid" "invalid_worktrees" "$err"

P_WTMISSION="$TMP/project-worktree-mission"
make_git_project "$P_WTMISSION"
make_change "$P_WTMISSION" wt-mission '- [ ] 1.1 Code.'
make_mission "$P_WTMISSION" v1 "- wt-mission"
plan_commit "$P_WTMISSION" wt-mission >/dev/null
WTST_MI="$TMP/worktree-mission-state"
mkdir -p "$WTST_MI"
out="$(run_boss_state "$WTST_MI" mission next v1 --project "$P_WTMISSION" --worktree)"
check_eq "mission next worktree: status" "started" "$(printf '%s' "$out" | jq -r '.status')"
check_contains "mission next worktree: path" "worktrees/" "$(printf '%s' "$out" | jq -r '.worktree')"

# 68. Doctor reports worktree states, orphans, a dirty base and fixes only
# merged kept worktrees.
P_WTDOC="$TMP/project-worktree-doctor"
make_git_project "$P_WTDOC"
make_change "$P_WTDOC" wt-doc '- [ ] 1.1 Code.'
plan_commit "$P_WTDOC" wt-doc >/dev/null
WTST_D="$TMP/worktree-doctor-state"
mkdir -p "$WTST_D/applies" "$WTST_D/worktrees/$(run_lib sha1_hex "$P_WTDOC")/orphan"
jq -n --arg p "$P_WTDOC" --arg w "$TMP/doctor-missing-worktree" \
  '{change:"wt-doc",project:$p,runner:"opencode",agent:"apply-wt-doc",pane_id:"p-wt-doc",
    tab_id:"t-wt-doc",workspace_id:"ws-wt-wt-doc",worktree:$w,branch:"boss/wt-doc",
    worktree_workspace:"ws-wt-wt-doc",base_head:null,merge_state:"none",merged:false,
    merge_test:"not_run",kept:false,waiter_pid:null}' \
  >"$WTST_D/applies/$(run_lib sha1_hex "$P_WTDOC")-wt-doc.json"
printf 'dirty\n' >"$P_WTDOC/dirty.txt"
doctor="$(run_boss_state "$WTST_D" doctor --project "$P_WTDOC" --json 2>/dev/null)"
check_eq "doctor worktree: missing path" "warn" \
  "$(printf '%s' "$doctor" | jq -r '.checks[] | select(.id=="worktree_state") | .status')"
check_contains "doctor worktree: names path" "path missing" \
  "$(printf '%s' "$doctor" | jq -r '.checks[] | select(.id=="worktree_state") | .hint')"
check_eq "doctor worktree: orphan" "warn" \
  "$(printf '%s' "$doctor" | jq -r '.checks[] | select(.id=="worktree_orphans") | .status')"
check_eq "doctor worktree: dirty base" "warn" \
  "$(printf '%s' "$doctor" | jq -r '.checks[] | select(.id=="worktree_base") | .status')"
check_contains "doctor worktree: dirty path" "dirty.txt" \
  "$(printf '%s' "$doctor" | jq -r '.checks[] | select(.id=="worktree_base") | .hint')"
rm -f "$P_WTDOC/dirty.txt"
rm -rf "$WTST_D/worktrees/$(run_lib sha1_hex "$P_WTDOC")/orphan"

# --fix removes a merged, kept worktree but leaves an unmerged one.
WT_DOC="$WTST_D/worktrees/$(run_lib sha1_hex "$P_WTDOC")/wt-doc"
git -C "$P_WTDOC" worktree add -q -b boss/wt-doc "$WT_DOC" HEAD
DSF="$WTST_D/applies/$(run_lib sha1_hex "$P_WTDOC")-wt-doc.json"
jq --arg w "$WT_DOC" '.worktree=$w | .merged=true | .kept=true | .merge_state="done"' \
  "$DSF" >"$DSF.tmp" && mv "$DSF.tmp" "$DSF"
printf '{"workspace":"ws-wt-wt-doc","path":"%s","base":"%s"}\n' "$WT_DOC" "$P_WTDOC" \
  >>"$TMP/herdr-worktrees.jsonl"
REMOVE_DOC="$TMP/worktree-doctor-remove.log"
HERDR_WORKTREE_REMOVE_LOG="$REMOVE_DOC" \
  run_boss_state "$WTST_D" doctor --project "$P_WTDOC" --json --fix >/dev/null 2>&1
check_eq "doctor fix: merged worktree removed" "0" "$([ -e "$WT_DOC" ] && printf 1 || printf 0)"
check_contains "doctor fix: herdr removes by workspace" \
  "--workspace ws-wt-wt-doc" "$(cat "$REMOVE_DOC" 2>/dev/null)"
check_not_contains "doctor fix: no --cwd" "--cwd" "$(cat "$REMOVE_DOC" 2>/dev/null)"
check_not_contains "doctor fix: no --path" "--path" "$(cat "$REMOVE_DOC" 2>/dev/null)"
check_eq "doctor fix: merged state removed" "0" "$([ -f "$DSF" ] && printf 1 || printf 0)"
check_eq "doctor fix: branch removed" "0" \
  "$(git -C "$P_WTDOC" branch --list 'boss/wt-doc' | wc -l | tr -d ' ')"
WT_DOC2="$WTST_D/worktrees/$(run_lib sha1_hex "$P_WTDOC")/wt-unmerged"
mkdir -p "$(dirname "$WT_DOC2")"
git -C "$P_WTDOC" worktree add -q -b boss/wt-unmerged "$WT_DOC2" HEAD
jq -n --arg p "$P_WTDOC" --arg w "$WT_DOC2" \
  '{change:"wt-unmerged",project:$p,runner:"opencode",agent:"apply-wt-unmerged",
    pane_id:"p-wt-unmerged",tab_id:"t-wt-unmerged",workspace_id:"ws-1",worktree:$w,
    branch:"boss/wt-unmerged",worktree_workspace:"ws-1",base_head:null,
    merge_state:"none",merged:false,merge_test:"not_run",kept:true,waiter_pid:null}' \
  >"$WTST_D/applies/$(run_lib sha1_hex "$P_WTDOC")-wt-unmerged.json"
run_boss_state "$WTST_D" doctor --project "$P_WTDOC" --json --fix >/dev/null 2>&1
check_eq "doctor fix: unmerged worktree kept" "1" "$([ -d "$WT_DOC2" ] && printf 1 || printf 0)"

# 69. The documentation and both skills describe the worktree lifecycle.
readme="$(cat "$ROOT/README.md")"
skill="$(cat "$ROOT/vision/SKILL.md")"
for needle in "boss plan commit" "worktrees" "worktree" "merge_conflict" "merge_test_failed"; do
  check_contains "worktree readme: $needle" "$needle" "$readme"
done
for needle in "boss plan commit" "worktree" "merge" "resume"; do
  check_contains "worktree skill: $needle" "$needle" "$skill"
done

# 70. Parallel mission bullets parse touches; none is declared-empty and a
# missing annotation stays undeclared.
P_PAR="$TMP/project-parallel-parse"
make_project "$P_PAR"
make_change "$P_PAR" feat-a '- [ ] 1.1 Code.'
make_change "$P_PAR" feat-b '- [ ] 1.1 Code.'
make_change "$P_PAR" feat-c '- [ ] 1.1 Code.'
make_mission "$P_PAR" v1 $'- feat-a (touches: src/auth, deps)\n- feat-b (touches: none)\n- feat-c'
status="$(run_boss mission status v1 --project "$P_PAR")"
check_eq "touches: list" '["src/auth","deps"]' \
  "$(printf '%s' "$status" | jq -c '.changes[] | select(.change=="feat-a") | .touches')"
check_eq "touches: list declared" "true" \
  "$(printf '%s' "$status" | jq -r '.changes[] | select(.change=="feat-a") | .declared')"
check_eq "touches: none is empty" '[]' \
  "$(printf '%s' "$status" | jq -c '.changes[] | select(.change=="feat-b") | .touches')"
check_eq "touches: none declared" "true" \
  "$(printf '%s' "$status" | jq -r '.changes[] | select(.change=="feat-b") | .declared')"
check_eq "touches: missing undeclared" "false" \
  "$(printf '%s' "$status" | jq -r '.changes[] | select(.change=="feat-c") | .declared')"
check_eq "touches: dependency mirror" '["src/auth","deps"]' \
  "$(printf '%s' "$status" | jq -c '.dependencies[] | select(.name=="feat-a") | .touches')"
check_eq "touches: status still serial" "1" "$(printf '%s' "$status" | jq -r '.max_parallel')"

# 71. max_parallel resolution: config, env override, invalid input and the
# doctor checks for the limit and for missing lock declarations.
PCONF="$TMP/parallel.toml"
printf 'default = "opencode"\n[projects]\npar = "%s"\n[runners.opencode]\nkind = "opencode"\nargs = []\napply = "/opsx-apply {change}"\n[missions]\nmax_parallel = 2\n' "$P_PAR" >"$PCONF"
DST_PAR="$TMP/parallel-doctor-state"
doctor="$(BOSS_CONFIG="$PCONF" run_boss_state "$DST_PAR" doctor --project "$P_PAR" --json 2>/dev/null)"
check_eq "max_parallel: doctor ok" "ok" \
  "$(printf '%s' "$doctor" | jq -r '.checks[] | select(.id=="mission_parallel") | .status')"
check_contains "max_parallel: config value" "max_parallel = 2" \
  "$(printf '%s' "$doctor" | jq -r '.checks[] | select(.id=="mission_parallel") | .hint')"
doctor="$(BOSS_CONFIG="$PCONF" BOSS_MAX_PARALLEL=4 run_boss_state "$DST_PAR" doctor --project "$P_PAR" --json 2>/dev/null)"
check_contains "max_parallel: env override" "max_parallel = 4" \
  "$(printf '%s' "$doctor" | jq -r '.checks[] | select(.id=="mission_parallel") | .hint')"
check_contains "max_parallel: env named" "BOSS_MAX_PARALLEL" \
  "$(printf '%s' "$doctor" | jq -r '.checks[] | select(.id=="mission_parallel") | .hint')"
doctor="$(BOSS_CONFIG="$PCONF" run_boss_state "$DST_PAR" doctor --project "$P_PAR" --json 2>/dev/null)"
check_eq "parallel locks: missing warn" "warn" \
  "$(printf '%s' "$doctor" | jq -r '.checks[] | select(.id=="mission_parallel_locks") | .status')"
check_contains "parallel locks: names change" "feat-c" \
  "$(printf '%s' "$doctor" | jq -r '.checks[] | select(.id=="mission_parallel_locks") | .hint')"
make_mission "$P_PAR" v1 $'- feat-a (touches: src/auth, deps)\n- feat-b (touches: none)\n- feat-c (touches: none)'
doctor="$(BOSS_CONFIG="$PCONF" run_boss_state "$DST_PAR" doctor --project "$P_PAR" --json 2>/dev/null)"
check_eq "parallel locks: complete ok" "ok" \
  "$(printf '%s' "$doctor" | jq -r '.checks[] | select(.id=="mission_parallel_locks") | .status')"
ICONF_PAR="$TMP/parallel-invalid.toml"
printf 'default = "opencode"\n[projects]\npar = "%s"\n[runners.opencode]\nkind = "opencode"\nargs = []\napply = "/opsx-apply {change}"\n[missions]\nmax_parallel = 0\n' "$P_PAR" >"$ICONF_PAR"
doctor="$(BOSS_CONFIG="$ICONF_PAR" run_boss_state "$DST_PAR" doctor --project "$P_PAR" --json 2>/dev/null)"
check_eq "max_parallel: invalid fails" "fail" \
  "$(printf '%s' "$doctor" | jq -r '.checks[] | select(.id=="mission_parallel") | .status')"
err="$(BOSS_CONFIG="$ICONF_PAR" run_boss_fail_state "$DST_PAR" dispatch feat-a --project "$P_PAR")"
check_contains "max_parallel: invalid dispatch" "invalid_max_parallel" "$err"

# 72. open_apply_count excludes parked, merged/kept and stale states but keeps
# test-failed and conflict states.
CST="$TMP/parallel-count-state"
mkdir -p "$CST/applies"
jq -n --arg p "$P_PAR" '{change:"run",project:$p,pane_id:"p-run",parked:false,merge_state:"none"}' \
  >"$CST/applies/run.json"
jq -n --arg p "$P_PAR" '{change:"parked",project:$p,pane_id:"p-park",parked:true,merge_state:"none"}' \
  >"$CST/applies/parked.json"
jq -n --arg p "$P_PAR" '{change:"kept",project:$p,pane_id:"p-kept",parked:false,merge_state:"done",kept:true,merged:true}' \
  >"$CST/applies/kept.json"
jq -n --arg p "$P_PAR" '{change:"failed",project:$p,pane_id:null,merge_state:"test_failed",merged:true}' \
  >"$CST/applies/failed.json"
jq -n --arg p "$P_PAR" '{change:"conflict",project:$p,pane_id:null,merge_state:"conflict"}' \
  >"$CST/applies/conflict.json"
jq -n --arg p "$P_PAR" '{change:"stale",project:$p,pane_id:"p-stale",parked:false,merge_state:"none"}' \
  >"$CST/applies/stale.json"
AGENTS_COUNT='[{"name":"apply-run","pane_id":"p-run","workspace_id":"ws-1"},{"name":"apply-parked","pane_id":"p-park","workspace_id":"ws-1"},{"name":"apply-kept","pane_id":"p-kept","workspace_id":"ws-1"}]'
count="$(HERDR_AGENTS_JSON="$AGENTS_COUNT" run_lib_state "$CST" open_apply_count)"
check_eq "count: running + failed + conflict" "3" "$count"
count="$(HERDR_AGENTS_JSON="$AGENTS_COUNT" run_lib_state "$CST" open_apply_count "$CST/applies/run.json")"
check_eq "count: own state excluded" "2" "$count"
count="$(HERDR_AGENTS_JSON='[]' run_lib_state "$CST" open_apply_count)"
check_eq "count: dead panes do not hold slots" "2" "$count"

# 73. The hard limit starts two disjoint worktree applies, refuses the third,
# and a base-checkout dispatch is refused in parallel mode.
P_LIM="$TMP/project-parallel-limit"
make_git_project "$P_LIM"
make_change "$P_LIM" lim-a '- [ ] 1.1 Code.'
make_change "$P_LIM" lim-b '- [ ] 1.1 Code.'
make_change "$P_LIM" lim-c '- [ ] 1.1 Code.'
plan_commit "$P_LIM" lim-a >/dev/null
LST="$TMP/parallel-limit-state"
mkdir -p "$LST"
out="$(BOSS_MAX_PARALLEL=2 run_boss_state "$LST" dispatch lim-a --project "$P_LIM" --touches none)"
check_eq "limit: first started" "started" "$(printf '%s' "$out" | jq -r '.status')"
LIM_A_WT="$(printf '%s' "$out" | jq -r '.worktree')"
check_contains "limit: first worktree" "worktrees/" "$LIM_A_WT"
AG_A="$(jq -nc --arg p "pane-lim-a" --arg w "ws-wt-lim-a" '[{name:"apply-lim-a",pane_id:$p,workspace_id:$w}]')"
out="$(BOSS_MAX_PARALLEL=2 HERDR_AGENTS_JSON="$AG_A" run_boss_state "$LST" dispatch lim-b --project "$P_LIM" --touches none)"
check_eq "limit: second started" "started" "$(printf '%s' "$out" | jq -r '.status')"
AG_AB="$(jq -nc --arg a "pane-lim-a" --arg b "pane-lim-b" '[{name:"apply-lim-a",pane_id:$a,workspace_id:"ws-wt-lim-a"},{name:"apply-lim-b",pane_id:$b,workspace_id:"ws-wt-lim-b"}]')"
err="$(BOSS_MAX_PARALLEL=2 HERDR_AGENTS_JSON="$AG_AB" run_boss_fail_state "$LST" dispatch lim-c --project "$P_LIM" --touches none)"
check_contains "limit: third refused" "parallel_limit" "$err"
check_eq "limit: current" "2" "$(printf '%s' "$err" | tail -n 1 | jq -r '.current')"
check_eq "limit: max" "2" "$(printf '%s' "$err" | tail -n 1 | jq -r '.max')"
check_eq "limit: third no state" "0" \
  "$( [ -f "$LST/applies/$(run_lib sha1_hex "$P_LIM")-lim-c.json" ] && printf 1 || printf 0)"
check_eq "limit: base clean" "" "$(git -C "$P_LIM" status --porcelain)"
status="$(BOSS_MAX_PARALLEL=2 HERDR_AGENTS_JSON="$AG_A" run_boss_state "$LST" status lim-a --project "$P_LIM" --json)"
check_eq "limit: status declared" "true" "$(printf '%s' "$status" | jq -r '.declared')"
check_eq "limit: status touches" "[]" "$(printf '%s' "$status" | jq -c '.touches')"
LST_REQ="$TMP/parallel-limit-required-state"
mkdir -p "$LST_REQ"
err="$(BOSS_MAX_PARALLEL=2 run_boss_fail_state "$LST_REQ" dispatch lim-a --project "$P_LIM" --no-worktree --touches none)"
check_contains "limit: no-worktree refused" "worktree_required" "$err"
check_eq "limit: refused base clean" "" "$(git -C "$P_LIM" status --porcelain)"
P_SER="$TMP/project-parallel-serial"
make_project "$P_SER"
make_change "$P_SER" ser '- [ ] 1.1 Code.'
out="$(BOSS_MAX_PARALLEL=1 run_boss_state "$LST_REQ" dispatch ser --project "$P_SER")"
check_eq "limit: serial still base" "started" "$(printf '%s' "$out" | jq -r '.status')"
check_eq "limit: serial no worktree" "null" "$(printf '%s' "$out" | jq -r '.worktree')"

# 74. Lock comparison: exact key, path prefix, disjoint, none and a parked
# holder. The helper cases run without dispatch first.
if run_lib touches_overlap '["deps"]' '["deps"]'; then ok; else bad "locks: exact key did not overlap"; fi
if run_lib touches_overlap '["src/auth"]' '["src/auth/login"]'; then ok; else bad "locks: path prefix did not overlap"; fi
if run_lib touches_overlap '["src/auth/"]' '["src/auth"]'; then ok; else bad "locks: trailing slash not ignored"; fi
if run_lib touches_overlap '["deps"]' '["src/auth"]'; then bad "locks: unrelated keys overlapped"; else ok; fi
if run_lib touches_overlap '["deps"]' '["src/deps"]'; then bad "locks: key without slash prefix-matched"; else ok; fi
if run_lib touches_overlap '[]' '["deps"]'; then bad "locks: empty overlap"; else ok; fi

P_LCK="$TMP/project-parallel-locks"
make_git_project "$P_LCK"
make_change "$P_LCK" lock-a '- [ ] 1.1 Code.'
make_change "$P_LCK" lock-b '- [ ] 1.1 Code.'
make_change "$P_LCK" lock-c '- [ ] 1.1 Code.'
plan_commit "$P_LCK" lock-a >/dev/null
LCKST="$TMP/parallel-lock-state"
mkdir -p "$LCKST"
out="$(BOSS_MAX_PARALLEL=2 run_boss_state "$LCKST" dispatch lock-a --project "$P_LCK" --touches deps)"
check_eq "locks: holder started" "started" "$(printf '%s' "$out" | jq -r '.status')"
LCK_A="$(jq -nc '[{name:"apply-lock-a",pane_id:"pane-lock-a",workspace_id:"ws-wt-lock-a"}]')"
err="$(BOSS_MAX_PARALLEL=2 HERDR_AGENTS_JSON="$LCK_A" run_boss_fail_state "$LCKST" dispatch lock-b --project "$P_LCK" --touches deps)"
check_contains "locks: exact conflict" "lock_conflict" "$err"
check_contains "locks: names holder" "lock-a" "$err"
check_eq "locks: conflict no state" "0" \
  "$( [ -f "$LCKST/applies/$(run_lib sha1_hex "$P_LCK")-lock-b.json" ] && printf 1 || printf 0)"
err="$(BOSS_MAX_PARALLEL=2 HERDR_AGENTS_JSON="$LCK_A" run_boss_fail_state "$LCKST" dispatch lock-b --project "$P_LCK")"
check_contains "locks: undeclared candidate waits" "lock_conflict" "$err"
out="$(BOSS_MAX_PARALLEL=2 HERDR_AGENTS_JSON="$LCK_A" run_boss_state "$LCKST" dispatch lock-c --project "$P_LCK" --touches "src/ui, cache")"
check_eq "locks: disjoint starts" "started" "$(printf '%s' "$out" | jq -r '.status')"
check_eq "locks: comma list parsed" '["src/ui","cache"]' \
  "$(jq -c '.touches' "$LCKST/applies/$(run_lib sha1_hex "$P_LCK")-lock-c.json")"

P_LCP="$TMP/project-parallel-lock-prefix"
make_git_project "$P_LCP"
make_change "$P_LCP" pfx-a '- [ ] 1.1 Code.'
make_change "$P_LCP" pfx-b '- [ ] 1.1 Code.'
plan_commit "$P_LCP" pfx-a >/dev/null
LCPST="$TMP/parallel-lock-prefix-state"
mkdir -p "$LCPST"
run_boss_state "$LCPST" dispatch pfx-a --project "$P_LCP" --touches src/auth --worktree >/dev/null
LCP_A="$(jq -nc '[{name:"apply-pfx-a",pane_id:"pane-pfx-a",workspace_id:"ws-wt-pfx-a"}]')"
err="$(BOSS_MAX_PARALLEL=2 HERDR_AGENTS_JSON="$LCP_A" run_boss_fail_state "$LCPST" dispatch pfx-b --project "$P_LCP" --touches src/auth/login)"
check_contains "locks: path prefix conflict" "lock_conflict" "$err"

P_LPN="$TMP/project-parallel-lock-none"
make_git_project "$P_LPN"
make_change "$P_LPN" none-a '- [ ] 1.1 Code.'
make_change "$P_LPN" none-b '- [ ] 1.1 Code.'
plan_commit "$P_LPN" none-a >/dev/null
LPNST="$TMP/parallel-lock-none-state"
mkdir -p "$LPNST"
run_boss_state "$LPNST" dispatch none-a --project "$P_LPN" --touches none --worktree >/dev/null
LPN_A="$(jq -nc '[{name:"apply-none-a",pane_id:"pane-none-a",workspace_id:"ws-wt-none-a"}]')"
out="$(BOSS_MAX_PARALLEL=2 HERDR_AGENTS_JSON="$LPN_A" run_boss_state "$LPNST" dispatch none-b --project "$P_LPN" --touches none)"
check_eq "locks: none is disjoint" "started" "$(printf '%s' "$out" | jq -r '.status')"

P_LPK="$TMP/project-parallel-lock-parked"
make_git_project "$P_LPK"
make_change "$P_LPK" park-a '- [ ] 1.1 [Nutzer] Konto verknüpfen.'
make_change "$P_LPK" park-b '- [ ] 1.1 Code.'
plan_commit "$P_LPK" park-a >/dev/null
LPKST="$TMP/parallel-lock-parked-state"
mkdir -p "$LPKST"
out="$(BOSS_MAX_PARALLEL=2 run_boss_state "$LPKST" dispatch park-a --project "$P_LPK" --touches auth)"
check_eq "locks: parked holder started" "started" "$(printf '%s' "$out" | jq -r '.status')"
run_boss_state "$LPKST" park park-a --project "$P_LPK" >/dev/null
err="$(BOSS_MAX_PARALLEL=2 run_boss_fail_state "$LPKST" dispatch park-b --project "$P_LPK" --touches auth)"
check_contains "locks: parked holder blocks" "lock_conflict" "$err"
check_contains "locks: parked holder named" "park-a" "$err"

# 75. Mission fill: two disjoint slots start, the third hits the limit, and
# status exposes the slots.
P_FILL="$TMP/project-parallel-fill"
make_git_project "$P_FILL"
make_change "$P_FILL" fill-a '- [ ] 1.1 Code.'
make_change "$P_FILL" fill-b '- [ ] 1.1 Code.'
make_change "$P_FILL" fill-c '- [ ] 1.1 Code.'
make_mission "$P_FILL" v1 $'- fill-a (touches: none)\n- fill-b (touches: none)\n- fill-c (touches: none)'
plan_commit "$P_FILL" fill-a >/dev/null
FST="$TMP/parallel-fill-state"
mkdir -p "$FST"
out="$(BOSS_MAX_PARALLEL=2 run_boss_state "$FST" mission next v1 --project "$P_FILL")"
check_eq "fill: first" "started" "$(printf '%s' "$out" | jq -r '.status')"
check_eq "fill: first change" "fill-a" "$(printf '%s' "$out" | jq -r '.change')"
AG_FA="$(jq -nc '[{name:"apply-fill-a",pane_id:"pane-fill-a",workspace_id:"ws-wt-fill-a"}]')"
out="$(BOSS_MAX_PARALLEL=2 HERDR_AGENTS_JSON="$AG_FA" run_boss_state "$FST" mission next v1 --project "$P_FILL")"
check_eq "fill: second" "started" "$(printf '%s' "$out" | jq -r '.status')"
check_eq "fill: second change" "fill-b" "$(printf '%s' "$out" | jq -r '.change')"
AG_FAB="$(jq -nc '[{name:"apply-fill-a",pane_id:"pane-fill-a",workspace_id:"ws-wt-fill-a"},{name:"apply-fill-b",pane_id:"pane-fill-b",workspace_id:"ws-wt-fill-b"}]')"
out="$(BOSS_MAX_PARALLEL=2 HERDR_AGENTS_JSON="$AG_FAB" run_boss_state "$FST" mission next v1 --project "$P_FILL")"
check_eq "fill: third limited" "parallel_limit" "$(printf '%s' "$out" | jq -r '.status')"
check_eq "fill: third no state" "0" \
  "$( [ -f "$FST/applies/$(run_lib sha1_hex "$P_FILL")-fill-c.json" ] && printf 1 || printf 0)"
status="$(BOSS_MAX_PARALLEL=2 HERDR_AGENTS_JSON="$AG_FAB" run_boss_state "$FST" mission status v1 --project "$P_FILL")"
check_eq "fill: status max" "2" "$(printf '%s' "$status" | jq -r '.max_parallel')"
check_eq "fill: status running" "2" "$(printf '%s' "$status" | jq -r '.running')"
check_eq "fill: status slots used" "2" "$(printf '%s' "$status" | jq -r '.slots_used')"
check_eq "fill: status slots free" "0" "$(printf '%s' "$status" | jq -r '.slots_free')"
check_eq "fill: status per-change running" "true" \
  "$(printf '%s' "$status" | jq -r '.changes[] | select(.change=="fill-a") | .running')"
check_eq "fill: status per-change none" "true" \
  "$(printf '%s' "$status" | jq -r '.changes[] | select(.change=="fill-b") | .declared')"

# A single slot still dispatches once on the base checkout.
P_SINGLE="$TMP/project-parallel-single"
make_project "$P_SINGLE"
make_change "$P_SINGLE" single '- [ ] 1.1 Code.'
make_mission "$P_SINGLE" v1 "- single"
SST="$TMP/parallel-single-state"
mkdir -p "$SST"
out="$(BOSS_MAX_PARALLEL=1 run_boss_state "$SST" mission next v1 --project "$P_SINGLE")"
check_eq "fill: single started" "started" "$(printf '%s' "$out" | jq -r '.status')"
check_eq "fill: single no worktree" "null" "$(printf '%s' "$out" | jq -r '.worktree')"

# 76. A lock conflict during selection is no_startable and names the holder.
P_NS="$TMP/project-parallel-no-startable"
make_git_project "$P_NS"
make_change "$P_NS" ns-a '- [ ] 1.1 Code.'
make_change "$P_NS" ns-b '- [ ] 1.1 Code.'
make_mission "$P_NS" v1 "- ns-b (touches: deps)"
plan_commit "$P_NS" ns-a >/dev/null
NSST="$TMP/parallel-no-startable-state"
mkdir -p "$NSST"
run_boss_state "$NSST" dispatch ns-a --project "$P_NS" --touches deps >/dev/null
NS_A="$(jq -nc '[{name:"apply-ns-a",pane_id:"pane-ns-a",workspace_id:"ws-wt-ns-a"}]')"
out="$(BOSS_MAX_PARALLEL=2 HERDR_AGENTS_JSON="$NS_A" run_boss_state "$NSST" mission next v1 --project "$P_NS")"
check_eq "no_startable: status" "no_startable" "$(printf '%s' "$out" | jq -r '.status')"
check_eq "no_startable: holder" "ns-a" "$(printf '%s' "$out" | jq -r '.holders[0].change')"
check_eq "no_startable: reason" "lock_conflict" "$(printf '%s' "$out" | jq -r '.skipped[0].reason')"

# 77. Review reports overlapping changed files and stays silent for a disjoint
# pair.
P_OV="$TMP/project-parallel-overlap"
make_git_project "$P_OV"
make_change "$P_OV" ov-a '- [ ] 1.1 Code.'
make_change "$P_OV" ov-b '- [ ] 1.1 Code.'
plan_commit "$P_OV" ov-a >/dev/null
OVST="$TMP/parallel-overlap-state"
mkdir -p "$OVST"
out="$(BOSS_MAX_PARALLEL=2 run_boss_state "$OVST" dispatch ov-a --project "$P_OV" --touches none)"
OV_A="$(printf '%s' "$out" | jq -r '.worktree')"
OV_AG="$(jq -nc '[{name:"apply-ov-a",pane_id:"pane-ov-a",workspace_id:"ws-wt-ov-a"}]')"
out="$(BOSS_MAX_PARALLEL=2 HERDR_AGENTS_JSON="$OV_AG" run_boss_state "$OVST" dispatch ov-b --project "$P_OV" --touches none)"
OV_B="$(printf '%s' "$out" | jq -r '.worktree')"
if [ -z "$OV_A" ] || [ ! -d "$OV_A" ] || [ -z "$OV_B" ] || [ ! -d "$OV_B" ]; then
  bad "overlap: dispatch produced no worktrees"
else
  printf 'shared\n' >"$OV_A/shared.txt"
  git -C "$OV_A" add shared.txt; git -C "$OV_A" commit -qm "a shared"
  printf 'shared b\n' >"$OV_B/shared.txt"
  git -C "$OV_B" add shared.txt; git -C "$OV_B" commit -qm "b shared"
  out="$(run_boss_state "$OVST" review ov-a --project "$P_OV" --json)"
  check_eq "overlap: file" "shared.txt" "$(printf '%s' "$out" | jq -r '.overlaps[0].file')"
  check_contains "overlap: both changes" "ov-b" \
    "$(printf '%s' "$out" | jq -r '.overlaps[0].changes | join(",")')"
fi
P_OD="$TMP/project-parallel-overlap-disjoint"
make_git_project "$P_OD"
make_change "$P_OD" od-a '- [ ] 1.1 Code.'
make_change "$P_OD" od-b '- [ ] 1.1 Code.'
plan_commit "$P_OD" od-a >/dev/null
ODST="$TMP/parallel-overlap-disjoint-state"
mkdir -p "$ODST"
out="$(BOSS_MAX_PARALLEL=2 run_boss_state "$ODST" dispatch od-a --project "$P_OD" --touches none)"
OD_A="$(printf '%s' "$out" | jq -r '.worktree')"
OD_AG="$(jq -nc '[{name:"apply-od-a",pane_id:"pane-od-a",workspace_id:"ws-wt-od-a"}]')"
out="$(BOSS_MAX_PARALLEL=2 HERDR_AGENTS_JSON="$OD_AG" run_boss_state "$ODST" dispatch od-b --project "$P_OD" --touches none)"
OD_B="$(printf '%s' "$out" | jq -r '.worktree')"
if [ -z "$OD_A" ] || [ ! -d "$OD_A" ] || [ -z "$OD_B" ] || [ ! -d "$OD_B" ]; then
  bad "overlap disjoint: dispatch produced no worktrees"
else
  printf 'a\n' >"$OD_A/a.txt"; git -C "$OD_A" add a.txt; git -C "$OD_A" commit -qm a
  printf 'b\n' >"$OD_B/b.txt"; git -C "$OD_B" add b.txt; git -C "$OD_B" commit -qm b
  out="$(run_boss_state "$ODST" review od-a --project "$P_OD" --json)"
  check_eq "overlap disjoint: none" "0" "$(printf '%s' "$out" | jq '.overlaps | length')"
fi

# 78. Resource warnings are returned by dispatch and do not stop or interrupt
# an apply; the fill loop's soft stop is part of the skill contract.
MEM_LOW="$TMP/parallel-meminfo"
LOAD_HIGH="$TMP/parallel-loadavg"
printf 'MemAvailable: 100000 kB\n' >"$MEM_LOW"
printf '100.0 1.0 1.0 1/1 1\n' >"$LOAD_HIGH"
P_RES="$TMP/project-parallel-resource"
make_project "$P_RES"
make_change "$P_RES" res-a '- [ ] 1.1 Code.'
make_change "$P_RES" res-b '- [ ] 1.1 Code.'
RST_RES="$TMP/parallel-resource-state"
mkdir -p "$RST_RES"
out="$(BOSS_MEMINFO_FILE="$MEM_LOW" BOSS_LOADAVG_FILE="$LOAD_HIGH" BOSS_DISPATCH_MIN_FREE_MB=1024 BOSS_DISPATCH_MAX_LOAD=1 \
  run_boss_state "$RST_RES" dispatch res-a --project "$P_RES" --touches none)"
check_eq "resource: first starts" "started" "$(printf '%s' "$out" | jq -r '.status')"
check_contains "resource: warning names memory" "free memory" "$(printf '%s' "$out" | jq -r '.resource_warning')"
check_contains "resource: warning names load" "1-min load" "$(printf '%s' "$out" | jq -r '.resource_warning')"
out="$(BOSS_MEMINFO_FILE="$MEM_LOW" BOSS_LOADAVG_FILE="$LOAD_HIGH" BOSS_DISPATCH_MIN_FREE_MB=1024 BOSS_DISPATCH_MAX_LOAD=1 \
  run_boss_state "$RST_RES" dispatch res-b --project "$P_RES" --touches none)"
check_eq "resource: second starts" "started" "$(printf '%s' "$out" | jq -r '.status')"
check_eq "resource: first still recorded" "1" \
  "$( [ -f "$RST_RES/applies/$(run_lib sha1_hex "$P_RES")-res-a.json" ] && printf 1 || printf 0)"
out="$(run_boss_state "$RST_RES" status res-a --project "$P_RES" --json)"
check_eq "resource: first still running" "res-a" "$(printf '%s' "$out" | jq -r '.change')"
check_eq "resource: first merge state" "none" "$(printf '%s' "$out" | jq -r '.merge_state')"

# 79. Documentation and both skills describe the parallel rules.
readme="$(cat "$ROOT/README.md")"
skill="$(cat "$ROOT/vision/SKILL.md")"
boss_skill="$(cat "$ROOT/boss/SKILL.md")"
for needle in "max_parallel" "BOSS_MAX_PARALLEL" "touches:" "touches: none" "worktree_required" "parallel_limit" "no_startable" "overlaps"; do
  check_contains "parallel readme: $needle" "$needle" "$readme"
done
for doc in "$skill" "$boss_skill"; do
  for needle in "BOSS_MAX_PARALLEL" "touches:" "touches: none" "parallel_limit" "no_startable"; do
    check_contains "parallel skill: $needle" "$needle" "$doc"
  done
done

# 57. The installer bundles the boss skill, keeps foreign directories and
# removes only what it owns.
check_regular_file() {
  local name="$1" path="$2"
  if [ -f "$path" ] && [ ! -L "$path" ]; then ok; else bad "$name: $path is not a regular file"; fi
}
install_in() {
  local home="$1"
  shift
  HOME="$home" PATH="$BIN:$PATH" bash "$ROOT/install.sh" "$@" 2>&1
}

IB="$TMP/install-boss-home"
mkdir -p "$IB"
if out="$(install_in "$IB")"; then ok; else bad "installer boss: default run failed: $out"; fi
for tool in opencode claude; do
  if [ "$tool" = opencode ]; then dir="$IB/.config/opencode/skills/boss"; else dir="$IB/.claude/skills/boss"; fi
  check_regular_file "installer boss: $tool SKILL.md" "$dir/SKILL.md"
  check_contains "installer boss: $tool skill name" "name: boss" "$(cat "$dir/SKILL.md" 2>/dev/null)"
  check_regular_file "installer boss: $tool marker" "$dir/.vision-managed"
  check_regular_file "installer boss: $tool vision SKILL.md" \
    "$(dirname "$dir")/vision/SKILL.md"
done
before="$(cat "$IB/.config/opencode/skills/boss/SKILL.md")"
if out="$(install_in "$IB")"; then ok; else bad "installer boss: second run failed: $out"; fi
check_eq "installer boss: idempotent" "$before" "$(cat "$IB/.config/opencode/skills/boss/SKILL.md")"
check_contains "installer boss: second run keeps marker" "vision-skill installer" \
  "$(cat "$IB/.config/opencode/skills/boss/.vision-managed")"

# --no-boss-skill: vision only, an existing boss directory is untouched.
IN="$TMP/install-noboss-home"
mkdir -p "$IN/.config/opencode/skills/boss"
printf 'foreign\n' >"$IN/.config/opencode/skills/boss/SKILL.md"
if out="$(install_in "$IN" --no-boss-skill)"; then ok; else bad "installer noboss: run failed: $out"; fi
check_regular_file "installer noboss: vision installed" \
  "$IN/.config/opencode/skills/vision/SKILL.md"
check_eq "installer noboss: foreign boss untouched" "foreign" \
  "$(cat "$IN/.config/opencode/skills/boss/SKILL.md")"
if [ ! -f "$IN/.config/opencode/skills/boss/.vision-managed" ]; then ok; else bad "installer noboss: wrote marker"; fi
IN2="$TMP/install-noboss-fresh-home"
mkdir -p "$IN2"
if out="$(install_in "$IN2" --no-boss-skill)"; then ok; else bad "installer noboss fresh: run failed: $out"; fi
if [ ! -e "$IN2/.config/opencode/skills/boss" ] && [ ! -e "$IN2/.claude/skills/boss" ]; then ok; else
  bad "installer noboss fresh: created a boss directory"
fi

# Both flags together are rejected.
out="$(install_in "$IN" --no-boss-skill --force-boss-skill)"; rc=$?
if [ "$rc" -ne 0 ]; then ok; else bad "installer flags: accepted --no-boss-skill --force-boss-skill"; fi
check_contains "installer flags: combined error" "cannot be combined" "$out"
out="$(bash "$ROOT/install.sh" --help 2>&1)"; rc=$?
check_eq "installer help: exit" "0" "$rc"
check_contains "installer help: no-boss flag" "--no-boss-skill" "$out"
check_contains "installer help: force flag" "--force-boss-skill" "$out"

# A foreign real directory is kept and reported; --force-boss-skill replaces it.
IF="$TMP/install-foreign-home"
mkdir -p "$IF/.config/opencode/skills/boss"
printf 'hand copied\n' >"$IF/.config/opencode/skills/boss/SKILL.md"
if out="$(install_in "$IF")"; then ok; else bad "installer foreign: run failed: $out"; fi
check_contains "installer foreign: warned" "left foreign boss skill directory in place" "$out"
check_eq "installer foreign: content kept" "hand copied" \
  "$(cat "$IF/.config/opencode/skills/boss/SKILL.md")"
if [ ! -f "$IF/.config/opencode/skills/boss/.vision-managed" ]; then ok; else bad "installer foreign: wrote marker"; fi
if out="$(install_in "$IF" --force-boss-skill)"; then ok; else bad "installer force: run failed: $out"; fi
check_contains "installer force: bundled skill installed" "name: boss" \
  "$(cat "$IF/.config/opencode/skills/boss/SKILL.md")"
check_regular_file "installer force: marker" "$IF/.config/opencode/skills/boss/.vision-managed"

# An old boss skill symlink is replaced by the bundled copy.
IL="$TMP/install-link-home"
OLD="$TMP/old-boss-skill"
mkdir -p "$IL/.config/opencode/skills" "$OLD"
printf 'old boss skill\n' >"$OLD/SKILL.md"
ln -s "$OLD" "$IL/.config/opencode/skills/boss"
if out="$(install_in "$IL")"; then ok; else bad "installer link: run failed: $out"; fi
check_contains "installer link: symlink reported" "removed old boss skill symlink" "$out"
if [ ! -L "$IL/.config/opencode/skills/boss" ]; then ok; else bad "installer link: symlink survived"; fi
check_contains "installer link: bundled skill installed" "name: boss" \
  "$(cat "$IL/.config/opencode/skills/boss/SKILL.md" 2>/dev/null)"

# verify_install fails when a boss SKILL.md is missing (foreign dir kept).
IV="$TMP/install-verify-home"
mkdir -p "$IV/.config/opencode/skills/boss"
printf 'notes\n' >"$IV/.config/opencode/skills/boss/notes.txt"
out="$(install_in "$IV")"; rc=$?
if [ "$rc" -ne 0 ]; then ok; else bad "installer verify: missing boss SKILL.md did not fail"; fi
check_contains "installer verify: names boss SKILL.md" "verification failed" "$out"
check_contains "installer verify: names path" "skills/boss/SKILL.md" "$out"

# --uninstall removes owned skills, keeps a foreign boss directory and data.
IU="$TMP/install-uninstall-home"
mkdir -p "$IU/.config/openspec-boss" "$IU/.local/state/openspec-boss"
if out="$(install_in "$IU")"; then ok; else bad "installer uninstall: install failed: $out"; fi
rm -rf "$IU/.claude/skills/boss"
mkdir -p "$IU/.claude/skills/boss"
printf 'foreign\n' >"$IU/.claude/skills/boss/SKILL.md"
if out="$(install_in "$IU" --uninstall)"; then ok; else bad "installer uninstall: run failed: $out"; fi
if [ ! -e "$IU/.config/opencode/skills/vision" ] && [ ! -e "$IU/.claude/skills/vision" ]; then ok; else
  bad "installer uninstall: vision skill remains"
fi
if [ ! -e "$IU/.config/opencode/skills/boss" ]; then ok; else bad "installer uninstall: owned boss skill remains"; fi
check_eq "installer uninstall: foreign boss kept" "foreign" \
  "$(cat "$IU/.claude/skills/boss/SKILL.md")"
check_contains "installer uninstall: foreign reported" "left foreign boss skill directory in place" "$out"
if [ ! -e "$IU/.local/bin/boss" ]; then ok; else bad "installer uninstall: runtime remains"; fi
if [ -d "$IU/.config/openspec-boss" ] && [ -d "$IU/.local/state/openspec-boss" ]; then ok; else
  bad "installer uninstall: removed config or state"
fi

# --------------------------------------------------------------- result ---

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
