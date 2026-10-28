#!/usr/bin/env bash
# Shared helpers for the openspec-boss scripts (bin/boss, bin/boss-waiter).
# Sourced, never executed directly. Comments and messages are in English.

set -u

# --- Paths (overridable via environment) ---
BOSS_CONFIG="${BOSS_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/openspec-boss/boss.toml}"
BOSS_STATE_DIR="${BOSS_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/openspec-boss}"
BOSS_APPLIES_DIR="$BOSS_STATE_DIR/applies"
BOSS_LOGS_DIR="$BOSS_STATE_DIR/logs"
BOSS_CYCLES_DIR="$BOSS_STATE_DIR/cycles"
BOSS_BOSSES_DIR="$BOSS_STATE_DIR/bosses"
BOSS_INBOX_DIR="$BOSS_STATE_DIR/inbox"
BOSS_WORKTREES_DIR="$BOSS_STATE_DIR/worktrees"

# cpu_count -- number of online CPUs, or 1 when it cannot be determined.
cpu_count() {
  local n
  n="$(nproc 2>/dev/null || true)"
  [ -n "$n" ] || n="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
  [ -n "$n" ] || n=1
  printf '%s\n' "$n"
}

# --- Tunables ---
BOSS_AGENT_NAME="${BOSS_AGENT_NAME:-boss}"
BOSS_WAITER_MAX_S="${BOSS_WAITER_MAX_S:-7200}"
BOSS_AGENT_START_TIMEOUT_MS="${BOSS_AGENT_START_TIMEOUT_MS:-120000}"
BOSS_AGENT_BUSY_RETRY_MS="${BOSS_AGENT_BUSY_RETRY_MS:-30000}"
BOSS_AGENT_TUI_TIMEOUT_MS="${BOSS_AGENT_TUI_TIMEOUT_MS:-60000}"
BOSS_AGENT_PROMPT_TIMEOUT_MS="${BOSS_AGENT_PROMPT_TIMEOUT_MS:-90000}"
BOSS_RUNNER_READY_TIMEOUT_MS="${BOSS_RUNNER_READY_TIMEOUT_MS:-90000}"
BOSS_REVIEW_TEST_TIMEOUT_S="${BOSS_REVIEW_TEST_TIMEOUT_S:-300}"
BOSS_WAITER_STALL_MS="${BOSS_WAITER_STALL_MS:-2700000}"
# After dispatch/retrigger/answer the apply may still sit at its old settled
# state for a moment (the prompt has not been taken yet). Before the first
# settle is reported, the waiter waits up to this many milliseconds for the
# apply to become active, so a stale 'idle' is not reported as a completion.
# 0 disables the gate.
BOSS_WAITER_SETTLE_GRACE_MS="${BOSS_WAITER_SETTLE_GRACE_MS:-5000}"
# Resource notice before 'boss dispatch': warn (never block) when the number of
# open applies, the free memory or the 1-minute load reaches a threshold.
# BOSS_DISPATCH_MAX_LOAD defaults to the number of CPUs.
BOSS_DISPATCH_MAX_APPLIES="${BOSS_DISPATCH_MAX_APPLIES:-3}"
BOSS_DISPATCH_MIN_FREE_MB="${BOSS_DISPATCH_MIN_FREE_MB:-1024}"
BOSS_DISPATCH_MAX_LOAD="${BOSS_DISPATCH_MAX_LOAD:-$(cpu_count)}"
# The resource helpers read these files; overridable so a system without /proc
# (macOS) or a test can point them elsewhere. A missing or unreadable file drops
# the respective check instead of failing.
BOSS_MEMINFO_FILE="${BOSS_MEMINFO_FILE:-/proc/meminfo}"
BOSS_LOADAVG_FILE="${BOSS_LOADAVG_FILE:-/proc/loadavg}"
# Caps for the lessons block injected into an apply prompt: at most this many
# active lesson lines and this many characters, taken global-first.
BOSS_LESSONS_MAX="${BOSS_LESSONS_MAX:-20}"
BOSS_LESSONS_MAX_CHARS="${BOSS_LESSONS_MAX_CHARS:-2000}"
# How many retriggers the Explorer allows a change before it gives up on it and
# turns the remaining work into a follow-up change (see the skill).
BOSS_MAX_RETRIGGERS="${BOSS_MAX_RETRIGGERS:-3}"

# Appended to every apply prompt unless the runner overrides or disables it:
# the apply must end its turn, the boss is woken by the waiter and retriggers.
BOSS_APPLY_YIELD_DEFAULT="When done or paused, end your turn and stop. Do not wait or poll for a review - the boss is woken automatically and will retrigger you."

# Env for an opencode V1 runner without an explicit 'env' field: inline config
# with the highest standard precedence, so only tabs started by boss get it.
# OpenCode V2 reads this from its shared background server, not per tab, so the
# V2 path uses '--auto' instead and never injects this default.
BOSS_OPENCODE_ENV_DEFAULT='OPENCODE_CONFIG_CONTENT={"permission":"allow"}'

# Cached result of the OpenCode major-version probe: "2", "1" or "unknown".
# Empty means the probe has not run yet in this process.
BOSS_OPENCODE_MAJOR="${BOSS_OPENCODE_MAJOR:-}"

# When set (by bin/boss-waiter), log() appends to this file instead of stderr.
BOSS_LOG_FILE="${BOSS_LOG_FILE:-}"

now_iso() {
  date '+%Y-%m-%dT%H:%M:%S%z'
}

# epoch_of_iso <iso> -- epoch seconds for a timestamp in the format now_iso
# emits (YYYY-MM-DDTHH:MM:SS+ZZZZ). Tries GNU 'date -d' first and falls back
# to BSD 'date -j -f' (macOS), which has no '-d'. Prints nothing when neither
# parser understands the value, so callers keep a missing/odd timestamp neutral.
epoch_of_iso() {
  local iso="${1:-}" out
  [ -n "$iso" ] || return 0
  out="$(date -d "$iso" +%s 2>/dev/null || true)"
  if [ -z "$out" ]; then
    out="$(date -j -f '%Y-%m-%dT%H:%M:%S%z' "$iso" +%s 2>/dev/null || true)"
  fi
  [ -n "$out" ] && printf '%s' "$out"
}

# now_ms -- current time in milliseconds since the epoch. BSD/macOS 'date' has
# no '%N', so this multiplies whole seconds by 1000 instead. Every deadline and
# every comparison uses this same helper, so the coarser resolution is
# consistent and timeouts keep working.
now_ms() {
  printf '%s\n' "$(( $(date +%s) * 1000 ))"
}

log() {
  local line
  line="$(now_iso) $*"
  if [ -n "$BOSS_LOG_FILE" ]; then
    printf '%s\n' "$line" >>"$BOSS_LOG_FILE"
  else
    printf '%s\n' "$line" >&2
  fi
}

# die_json <code> <message> -- error JSON on stderr, exit 1.
# When BOSS_FAILED_TAB/BOSS_FAILED_PANE are set (dispatch after tab create),
# the tab is closed again and the pane's last visible lines are attached as
# pane_tail, unless BOSS_KEEP_FAILED_TAB=1.
die_json() {
  local code="$1" msg="$2" tail_json="null"
  # A worktree dispatch that fails after creating its worktree must not leave a
  # half-created apply behind. Cleanup never masks the original error.
  if [ -n "${BOSS_FAILED_WORKTREE:-}" ]; then
    worktree_cleanup_failed || true
  fi
  if [ -n "${BOSS_FAILED_TAB:-}" ]; then
    local tail
    tail="$(herdr pane read "${BOSS_FAILED_PANE:-}" --source visible --lines 15 2>/dev/null \
      | grep -v '^[[:space:]]*$' | tail -n 15 || true)"
    tail_json="$(printf '%s' "$tail" | jq -Rs . 2>/dev/null || printf 'null')"
    if [ "${BOSS_KEEP_FAILED_TAB:-0}" != "1" ]; then
      herdr tab close "$BOSS_FAILED_TAB" >/dev/null 2>&1 || true
      log "closed tab $BOSS_FAILED_TAB after failed dispatch ($code)"
    fi
    BOSS_FAILED_TAB=""
  fi
  jq -nc --arg code "$code" --arg msg "$msg" --argjson tail "$tail_json" \
    '{error: $code, message: $msg} + (if $tail == null then {} else {pane_tail: $tail} end)' >&2
  exit 1
}

# usage_error <message> -- usage JSON on stderr, exit 2 (same convention as herdr)
usage_error() {
  local msg="$1"
  printf '{"error":"usage","message":"%s"}\n' "$msg" >&2
  exit 2
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die_json "missing_dependency" "required command '$1' not found in PATH"
}

# herdr_json <args...> -- run herdr, print the .result payload as compact JSON.
# Dies with a JSON error on stderr (exit 1) when herdr fails or .result is null.
herdr_json() {
  local out rc
  out="$(herdr "$@" 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ] || ! printf '%s' "$out" | jq -e '.result != null' >/dev/null 2>&1; then
    local code msg
    code="$(printf '%s' "$out" | jq -r '.error.code // "herdr_error"' 2>/dev/null || printf 'herdr_error')"
    msg="$(printf '%s' "$out" | jq -r '.error.message // empty' 2>/dev/null || true)"
    die_json "$code" "herdr ${*:-}: ${msg:-call failed with exit $rc}"
  fi
  printf '%s' "$out" | jq -c '.result'
}

# normalize_name <s> -- lower-case, keep only [a-z0-9_-] (herdr-safe names)
normalize_name() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9_-]/-/g' -e 's/-\{2,\}/-/g' -e 's/^-//' -e 's/-$//'
}

# sha1_hex <text> -- lowercase hex SHA1 of <text>. Tries GNU 'sha1sum', then
# BSD/macOS 'shasum -a 1', then 'python3' (hashlib) and 'openssl dgst -sha1',
# so no single tool is required. Aborts with a clear error when none exists:
# an empty hash would collapse the state key and let two projects collide.
sha1_hex() {
  local text="${1:-}" h=""
  if command -v sha1sum >/dev/null 2>&1; then
    h="$(printf '%s' "$text" | sha1sum | cut -d' ' -f1)"
  elif command -v shasum >/dev/null 2>&1; then
    h="$(printf '%s' "$text" | shasum -a 1 | cut -d' ' -f1)"
  elif command -v python3 >/dev/null 2>&1; then
    h="$(printf '%s' "$text" | python3 -c 'import sys, hashlib; sys.stdout.write(hashlib.sha1(sys.stdin.buffer.read()).hexdigest())' 2>/dev/null || true)"
  elif command -v openssl >/dev/null 2>&1; then
    h="$(printf '%s' "$text" | openssl dgst -sha1 | sed 's/^.*= //')"
  fi
  if [ -z "$h" ]; then
    die_json "missing_dependency" "no SHA1 tool available (need one of: sha1sum, shasum, python3, openssl)"
  fi
  printf '%s' "$h"
}

# apply_agent_name <change> -- herdr agent name for a change's apply.
# Herdr allows [a-z][a-z0-9_-]{0,31}; "apply-<change>" is used when it fits,
# otherwise "apply-" + the first 19 characters + "-" + 6 hex of sha1(change)
# so two long names with the same beginning still differ.
apply_agent_name() {
  local norm full head hash
  norm="$(normalize_name "$1")"
  full="apply-$norm"
  if [ "${#full}" -le 32 ]; then
    printf '%s\n' "$full"
    return 0
  fi
  head="$(printf '%s' "$norm" | cut -c1-19 | sed -e 's/[-_]*$//')"
  hash="$(sha1_hex "$norm" | cut -c1-6)"
  printf 'apply-%s-%s\n' "$head" "$hash"
}

# worktree_path_for <base-project> <change> -- state-owned worktree path. Kept
# outside the project tree on purpose: an in-tree path would match
# find_workspace_for_repo and share the base workspace.
worktree_path_for() {
  local project="$1" change="$2"
  printf '%s/%s/%s\n' "$BOSS_WORKTREES_DIR" "$(sha1_hex "$project")" "$(normalize_name "$change")"
}

# worktree_branch_for <change> -- branch a worktree apply runs on.
worktree_branch_for() {
  printf 'boss/%s\n' "$(normalize_name "$1")"
}

# herdr_worktree_list <base> -- worktrees Herdr knows for the repository as a
# compact JSON array of {path, branch, workspace_id}. Tolerant about the exact
# nested shape; an unavailable Herdr yields an empty array.
herdr_worktree_list() {
  local base="$1" out
  out="$(herdr worktree list --cwd "$base" 2>/dev/null || true)"
  [ -n "$out" ] || { printf '[]\n'; return 0; }
  printf '%s' "$out" | jq -c '
    (.result.worktrees // .result.worktree // .worktrees // .worktree // [])
    | (if type == "array" then . else [.] end)
    | map(select(type == "object"))
    | map({path: (.path // .worktree.path // .worktree // empty),
           branch: (.branch // .worktree.branch // empty),
           workspace_id: (.open_workspace_id // .workspace_id // .workspace.workspace_id
                          // .worktree.open_workspace_id // .worktree.workspace_id
                          // .workspace.id // .worktree.workspace.id // empty)})' \
    2>/dev/null || printf '[]\n'
}

# herdr_worktree_create <base> <branch> <base-head> <path> <label> -- create a
# worktree through Herdr and print {path,branch,workspace_id}. Falls back to
# 'herdr worktree list' when the create result omits path, branch or workspace.
herdr_worktree_create() {
  local base="$1" branch="$2" base_head="$3" path="$4" label="$5" out rc parsed
  out="$(herdr worktree create --cwd "$base" --branch "$branch" --base "$base_head" \
    --path "$path" --label "$label" --no-focus 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ] || ! printf '%s' "$out" | jq -e '.result != null' >/dev/null 2>&1; then
    local code msg
    code="$(printf '%s' "$out" | jq -r '.error.code // "worktree_create_failed"' 2>/dev/null || printf 'worktree_create_failed')"
    msg="$(printf '%s' "$out" | jq -r '.error.message // empty' 2>/dev/null || true)"
    die_json "$code" "herdr worktree create for $path failed: ${msg:-exit $rc}"
  fi
  parsed="$(printf '%s' "$out" | jq -c '
    (.result // {}) as $r
    | {path: ($r.worktree.path // $r.path // $r.worktree // empty),
       branch: ($r.worktree.branch // $r.branch // empty),
       workspace_id: ($r.worktree.open_workspace_id // $r.open_workspace_id
                      // $r.worktree.workspace_id // $r.workspace_id
                      // $r.workspace.workspace_id // $r.worktree.workspace.id
                      // $r.workspace.id // empty)}' 2>/dev/null || true)"
  [ -n "$parsed" ] || parsed='{"path":"","branch":"","workspace_id":""}'
  if [ -z "$(printf '%s' "$parsed" | jq -r '.path // empty')" ] \
     || [ -z "$(printf '%s' "$parsed" | jq -r '.branch // empty')" ] \
     || [ -z "$(printf '%s' "$parsed" | jq -r '.workspace_id // empty')" ]; then
    local row
    row="$(herdr_worktree_list "$base" | jq -c --arg p "$path" --arg b "$branch" '
      map(select((.path // "") == $p or (.branch // "") == $b)) | .[0] // {}')"
    parsed="$(jq -nc --argjson p "$parsed" --argjson r "$row" --arg path "$path" --arg branch "$branch" '
      {path: (if ($p.path // "") == "" then ($r.path // $path) else $p.path end),
       branch: (if ($p.branch // "") == "" then ($r.branch // $branch) else $p.branch end),
       workspace_id: (if ($p.workspace_id // "") == "" then ($r.workspace_id // "") else $p.workspace_id end)}')"
  fi
  printf '%s\n' "$parsed"
}

# herdr_worktree_open <base> <path> -- open an existing worktree through Herdr,
# printing the same shape as herdr_worktree_create. An unsupported command is
# not fatal here; the caller falls back to a normal workspace.
herdr_worktree_open() {
  local base="$1" path="$2" out
  out="$(herdr worktree open --cwd "$base" --path "$path" 2>/dev/null || true)"
  if [ -n "$out" ] && printf '%s' "$out" | jq -e '.result != null' >/dev/null 2>&1; then
    printf '%s' "$out" | jq -c '
      (.result // {}) as $r
      | {path: ($r.worktree.path // $r.path // empty),
         branch: ($r.worktree.branch // $r.branch // empty),
         workspace_id: ($r.worktree.open_workspace_id // $r.open_workspace_id
                        // $r.worktree.workspace_id // $r.workspace_id
                        // $r.workspace.workspace_id // empty)}'
    return 0
  fi
  return 1
}

# herdr_worktree_remove <base> <path> [<workspace>] -- remove a worktree through
# Herdr. Herdr addresses a worktree by its open workspace, not by --cwd/--path;
# when the recorded workspace is unknown, look it up by path in
# 'herdr worktree list'. Never fails; the caller has a git fallback.
herdr_worktree_remove() {
  local base="$1" path="$2" workspace="${3:-}"
  if [ -z "$workspace" ] && [ -n "$path" ]; then
    workspace="$(herdr_worktree_list "$base" | jq -r --arg p "$path" \
      'map(select((.path // "") == $p)) | .[0].workspace_id // empty' 2>/dev/null || true)"
  fi
  [ -n "$workspace" ] || return 0
  herdr worktree remove --workspace "$workspace" --force >/dev/null 2>&1 || true
}

# worktree_cleanup_failed -- undo a half-created worktree dispatch. Removes the
# tab when one was created, the worktree and the branch. Intentionally quiet and
# idempotent; die_json calls it before printing the original error.
worktree_cleanup_failed() {
  local project="${BOSS_FAILED_WORKTREE_PROJECT:-}" path="${BOSS_FAILED_WORKTREE:-}"
  local branch="${BOSS_FAILED_WORKTREE_BRANCH:-}" tab="${BOSS_FAILED_TAB:-}"
  local workspace="${BOSS_FAILED_WORKTREE_WS:-}"
  BOSS_FAILED_WORKTREE=""
  BOSS_FAILED_WORKTREE_WS=""
  if [ -n "$tab" ]; then
    herdr tab close "$tab" >/dev/null 2>&1 || true
  fi
  if [ -n "$path" ]; then
    herdr_worktree_remove "$project" "$path" "$workspace"
    if [ -n "$project" ]; then
      git -C "$project" worktree remove --force "$path" >/dev/null 2>&1 || true
      git -C "$project" worktree prune >/dev/null 2>&1 || true
      [ -n "$branch" ] && git -C "$project" branch -D "$branch" >/dev/null 2>&1 || true
      [ -d "$path" ] && rm -rf "$path" 2>/dev/null || true
      rmdir "$(dirname "$path")" 2>/dev/null || true
    fi
  fi
  log "cleaned up a failed worktree dispatch${path:+ for $path}"
}

# boss_registry_file_for <workspace-id> -- registry file for the workspace's boss
boss_registry_file_for() {
  printf '%s/%s.json\n' "$BOSS_BOSSES_DIR" "$(normalize_name "$1")"
}

# boss_name_for <workspace-id> -- default herdr agent name of a workspace boss.
# Herdr allows [a-z][a-z0-9_-]{0,31}; "boss-<workspace>" is used when it fits,
# otherwise "boss-" + the first 19 characters + "-" + 6 hex of sha1(workspace)
# so two long ids with the same beginning still differ.
boss_name_for() {
  local norm full head hash
  norm="$(normalize_name "$1")"
  full="boss-$norm"
  if [ "${#full}" -le 32 ]; then
    printf '%s\n' "$full"
    return 0
  fi
  head="$(printf '%s' "$norm" | cut -c1-19 | sed -e 's/[-_]*$//')"
  hash="$(sha1_hex "$norm" | cut -c1-6)"
  printf 'boss-%s-%s\n' "$head" "$hash"
}

# opencode_major_version -- the installed OpenCode major version: 2, 1 or
# unknown. The answer is cached for the process. Only call this for an
# opencode runner: a missing or unparsable 'opencode --version' warns and
# returns unknown, so callers keep the conservative legacy path instead of
# guessing V2.
opencode_major_version() {
  if [ -n "${BOSS_OPENCODE_MAJOR:-}" ]; then
    printf '%s\n' "$BOSS_OPENCODE_MAJOR"
    return 0
  fi
  local out major
  out="$(opencode --version 2>/dev/null || true)"
  major="$(printf '%s' "$out" | sed -nE 's/^[^0-9]*([0-9]+).*/\1/p' | sed -n '1p')"
  case "${major:-}" in
    1|2) : ;;
    *)
      log "warning: cannot determine the OpenCode major version from 'opencode --version' (${out:-no output}); using the legacy inline permission path"
      major="unknown"
      ;;
  esac
  BOSS_OPENCODE_MAJOR="$major"
  printf '%s\n' "$major"
}

# runner_args_of <runner-json> -- the runner's resolved start arguments, one per
# line. Explicit non-empty args are passed through unchanged. An opencode
# runner with absent or empty args gets '--auto' on OpenCode V2; V1 and an
# unknown version get no extra argument and keep their legacy behavior.
runner_args_of() {
  local runner="$1" args kind version
  args="$(printf '%s' "$runner" | jq -r '.args[]? // empty')"
  if [ -n "$args" ]; then
    printf '%s\n' "$args"
    return 0
  fi
  kind="$(printf '%s' "$runner" | jq -r '.kind // empty')"
  [ "$kind" = "opencode" ] || return 0
  version="$(opencode_major_version)"
  [ "$version" = "2" ] && printf '%s\n' '--auto'
  return 0
}

# runner_env_of <runner-json> -- the runner's resolved env entries, one per
# line. An explicit 'env' field always wins, including an empty array. Without
# one, an OpenCode V1 (or unknown-version) runner gets the legacy inline
# permission default; an OpenCode V2 runner gets nothing, because its shared
# background server would apply an inline allow-all beyond the current tab.
runner_env_of() {
  local runner="$1" kind version
  if printf '%s' "$runner" | jq -e 'has("env")' >/dev/null 2>&1; then
    printf '%s' "$runner" | jq -r '.env[]? // empty'
    return 0
  fi
  kind="$(printf '%s' "$runner" | jq -r '.kind // empty')"
  [ "$kind" = "opencode" ] || return 0
  version="$(opencode_major_version)"
  [ "$version" = "2" ] && return 0
  printf '%s\n' "$BOSS_OPENCODE_ENV_DEFAULT"
}

# runner_mode_of <runner-json> -- compact JSON with the detected OpenCode major
# version and the permission mode boss will use: {opencode_version,
# permission_mode}. Both are null for a non-opencode runner. An opencode
# runner reports auto on V2 and inline on V1 or when the version is unknown.
runner_mode_of() {
  local runner="$1" kind version
  kind="$(printf '%s' "$runner" | jq -r '.kind // empty')"
  if [ "$kind" != "opencode" ]; then
    jq -nc '{opencode_version: null, permission_mode: null}'
    return 0
  fi
  version="$(opencode_major_version)"
  case "$version" in
    1) jq -nc '{opencode_version: 1, permission_mode: "inline"}' ;;
    2) jq -nc '{opencode_version: 2, permission_mode: "auto"}' ;;
    *) jq -nc '{opencode_version: null, permission_mode: "inline"}' ;;
  esac
}

# _opencode_in_dir <dir> <command...> -- run an opencode query in the target
# project directory, or in the current directory when none is given. The
# effective config depends on the project's .opencode directory, so a probe
# must not inherit the caller's cwd.
_opencode_in_dir() {
  local dir="$1"
  shift
  if [ -n "$dir" ]; then
    (cd "$dir" && "$@")
  else
    "$@"
  fi
}

# opencode_effective_permissions [<project-dir>] -- the effective OpenCode V2
# permission rules as compact JSON: {status, source, permissions, error}. The
# primary query is 'opencode debug config'; 'opencode api get /api/config' is
# the fallback. Both run in <project-dir> when given, because the effective
# config includes that project's .opencode directory. The permission rules are
# the union of every document's .info.permissions[].
opencode_effective_permissions() {
  local dir="${1:-}" out source="" rc
  out="$(_opencode_in_dir "$dir" opencode debug config 2>/dev/null)"
  rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | jq -e '
      type == "array"
      or (type == "object" and ((.info? | type) == "object" or has("permissions")))' \
      >/dev/null 2>&1; then
    source="debug_config"
  else
    out="$(_opencode_in_dir "$dir" opencode api get /api/config 2>/dev/null)"
    rc=$?
    if [ "$rc" -eq 0 ] && printf '%s' "$out" | jq -e '
        type == "array"
        or (type == "object" and ((.info? | type) == "object" or has("permissions")))' \
        >/dev/null 2>&1; then
      source="api_config"
    else
      jq -nc '{status: "unavailable", source: null, permissions: [],
        error: "opencode debug config and opencode api get /api/config both failed"}'
      return 0
    fi
  fi
  printf '%s' "$out" | jq -c --arg src "$source" '
    {status: "ok", source: $src,
     permissions: [ (if type == "array" then .[]? else . end)
                    | select(type == "object")
                    | ((.info.permissions // .permissions) // [])[]?
                    | select(type == "object") ]}'
}

# opencode_broad_denials <permissions-array-json> -- the permission categories
# with a broad deny rule: shell, edit, read and external_directory. A rule is
# broad when its resource is '*' or empty; action '*' denies every category.
# Narrow deny rules (a specific path or command) are intentionally ignored.
opencode_broad_denials() {
  printf '%s' "$1" | jq -c '
    def categories($a):
      ($a | tostring | ascii_downcase) as $x
      | if $x == "*" then ["shell", "edit", "read", "external_directory"]
        elif ($x | test("^(shell|bash|command)")) then ["shell"]
        elif ($x | test("^(edit|write|patch)")) then ["edit"]
        elif ($x | test("^read")) then ["read"]
        elif ($x | test("^external[-_]?director")) then ["external_directory"]
        else [] end;
    [ .[]?
      | select(type == "object")
      | select(((.effect // "") | tostring | ascii_downcase) == "deny")
      | (.resource // "*") as $r
      | select($r == "*" or $r == "**" or $r == "")
      | categories(.action // "*")[]
    ] | unique'
}

# opencode_permission_probe [<project-dir>] -- the V2 effective-permission
# check as compact JSON: {status, source, permissions, denied, message}. status
# is ok when the config was read and no broad deny blocks shell/edit/read/
# external directory, deny when one does, and unavailable when neither query
# worked. The queries run in <project-dir> when given.
opencode_permission_probe() {
  local dir="${1:-}" effective denied
  effective="$(opencode_effective_permissions "$dir")"
  if [ "$(printf '%s' "$effective" | jq -r '.status')" != "ok" ]; then
    printf '%s' "$effective" | jq -c \
      '{status: "unavailable", source: null, permissions: [], denied: [], message: .error}'
    return 0
  fi
  denied="$(opencode_broad_denials "$(printf '%s' "$effective" | jq -c '.permissions')")"
  printf '%s' "$effective" | jq -c --argjson denied "$denied" '
    . + {status: (if ($denied | length) > 0 then "deny" else "ok" end),
         denied: $denied,
         message: (if ($denied | length) > 0
                   then "broad deny for " + ($denied | join(", "))
                   else "no broad deny for shell, edit, read or external directory" end)}'
}

# boss_agents -- compact '.agents' array from 'herdr agent list', or '[]' when
# Herdr is unavailable. Tolerant on purpose: callers use it only for liveness.
boss_agents() {
  local out
  out="$(herdr agent list 2>/dev/null || true)"
  printf '%s' "$out" | jq -c '.result.agents // .agents // []' 2>/dev/null || printf '[]'
}

# boss_agent_alive_name <agents-json> <name> -- 0 when an agent has that name
boss_agent_alive_name() {
  printf '%s' "$1" | jq -e --arg n "$2" \
    'map(select(type == "object" and .name == $n)) | length > 0' >/dev/null 2>&1
}

# boss_agent_alive_pane <agents-json> <pane-id> -- 0 when an agent sits on that pane
boss_agent_alive_pane() {
  printf '%s' "$1" | jq -e --arg p "$2" \
    'map(select(type == "object" and .pane_id == $p)) | length > 0' >/dev/null 2>&1
}

# boss_agent_name_on_pane <agents-json> <pane-id> -- the real Herdr name of the
# agent on that pane, or empty when no agent sits there or it carries no name.
# A pane can lose its name while still hosting the agent, so the pane id is the
# only stable handle then.
boss_agent_name_on_pane() {
  printf '%s' "$1" | jq -r --arg p "$2" \
    'map(select(type == "object" and .pane_id == $p)) | .[0].name // empty' 2>/dev/null || true
}

# boss_agent_meta <agents-json> <name-or-pane> -- compact agent object
# {name,pane_id,workspace_id,cwd} for that name or pane, or empty.
boss_agent_meta() {
  printf '%s' "$1" | jq -c --arg t "$2" \
    'map(select(type == "object" and (.name == $t or .pane_id == $t))) | .[0] // empty' \
    2>/dev/null || true
}

# boss_panes -- compact '.panes' array from 'herdr pane list', or '[]' when
# Herdr is unavailable. Tolerant on purpose: callers use it for identity data.
boss_panes() {
  local out
  out="$(herdr pane list 2>/dev/null || true)"
  printf '%s' "$out" | jq -c '.result.panes // .panes // []' 2>/dev/null || printf '[]'
}

# boss_pane_meta <panes-json> <pane-id> -- the pane object, or empty
boss_pane_meta() {
  printf '%s' "$1" | jq -c --arg p "$2" \
    'map(select(type == "object" and .pane_id == $p)) | .[0] // empty' 2>/dev/null || true
}

# boss_cwd_related <a> <b> -- 0 when the paths are equal or one contains the other.
boss_cwd_related() {
  local a="${1:-}" b="${2:-}"
  [ -n "$a" ] && [ -n "$b" ] || return 1
  [ "$a" = "$b" ] && return 0
  case "$a/" in "$b"/*) return 0 ;; esac
  case "$b/" in "$a"/*) return 0 ;; esac
  return 1
}

# boss_pane_process_pids <pane-id> -- shell and foreground pids Herdr reports
# for a pane, one per line. The real Herdr response nests them under
# result.process_info (shell_pid and foreground_processes[].pid); older or
# stubbed responses use flat result fields. A missing or failing process-info
# call yields nothing, so ancestry detection simply finds no match.
boss_pane_process_pids() {
  local pane="$1" out
  out="$(herdr pane process-info --pane "$pane" 2>/dev/null || true)"
  [ -n "$out" ] || return 0
  printf '%s' "$out" | jq -r '
    (.result.process_info // .result // .) as $r
    | [ $r.shell_pid?, $r.foreground_pid?,
        ($r.foreground_pids[]?),
        ($r.foreground_processes[]? | if type == "object" then .pid else . end),
        ($r.processes[]? | if type == "object" then .pid else . end),
        ($r.pids[]?) ]
    | map(select(. != null and . != "") | tostring) | unique | .[]' 2>/dev/null || true
}

# boss_caller_ancestry_pids -- $$ and its parents, one pid per line.
boss_caller_ancestry_pids() {
  local pid="$$" parent i=0
  while [ -n "$pid" ] && [ "$pid" != "0" ] && [ "$i" -lt 64 ]; do
    printf '%s\n' "$pid"
    parent="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
    [ -n "$parent" ] || break
    pid="$parent"
    i=$((i + 1))
  done
}

# boss_caller_session_id -- the calling agent session id, if one is exposed.
# Checks the known environment variables first, then the ancestor command line
# for --session-id/--resume. Prints nothing when no source is available.
boss_caller_session_id() {
  local var value pid cmd flag rest
  for var in CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID OPENCODE_SESSION_ID \
             CODEX_THREAD_ID GEMINI_SESSION_ID HERDR_AGENT_SESSION_ID; do
    eval "value=\${$var:-}"
    [ -n "$value" ] && { printf '%s' "$value"; return 0; }
  done
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    if [ -r "/proc/$pid/cmdline" ]; then
      cmd="$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true)"
    else
      cmd="$(ps -o command= -p "$pid" 2>/dev/null || true)"
    fi
    for flag in --session-id --resume; do
      case "$cmd" in
        *"$flag="*)
          rest="${cmd#*$flag=}"
          value="${rest%% *}"
          [ -n "$value" ] && { printf '%s' "$value"; return 0; }
          ;;
        *"$flag "*)
          rest="${cmd#*$flag }"
          value="${rest%% *}"
          [ -n "$value" ] && { printf '%s' "$value"; return 0; }
          ;;
      esac
    done
  done <<<"$(boss_caller_ancestry_pids)"
  return 0
}

# boss_detect_caller_pane -- compact {pane_id,workspace_id,cwd,agent} of the
# Herdr pane whose shell or foreground process is an ancestor of $$, or empty.
# Only called on a mismatch, never on the correct fast path.
boss_detect_caller_pane() {
  local panes ancestry pane pids hit agents ameta
  panes="$(boss_panes)"
  ancestry="$(boss_caller_ancestry_pids)"
  [ -n "$ancestry" ] || return 0
  while IFS= read -r pane; do
    [ -n "$pane" ] || continue
    pids="$(boss_pane_process_pids "$pane")"
    [ -n "$pids" ] || continue
    hit="$(printf '%s\n%s\n' "$ancestry" "$pids" | sort | uniq -d | sed -n '1p')"
    [ -n "$hit" ] || continue
    agents="$(boss_agents)"
    ameta="$(boss_agent_meta "$agents" "$pane")"
    [ -n "$ameta" ] || ameta="null"
    printf '%s' "$panes" | jq -c --arg p "$pane" --argjson a "$ameta" \
      'map(select(type == "object" and .pane_id == $p)) | .[0]
       | {pane_id: (.pane_id // $p), workspace_id: (.workspace_id // $a.workspace_id // null),
          cwd: ((.foreground_cwd // .cwd) // $a.cwd // null),
          agent: (if $a == null then null else ($a.name // null) end)}'
    return 0
  done < <(printf '%s' "$panes" | jq -r '.[] | select(type == "object") | .pane_id // empty' 2>/dev/null)
}

# boss_caller_identity_json [<as-pane-or-agent>] -- resolve the caller identity
# without dying. Prints {status, code, message, pane_id, workspace_id, cwd,
# agent, source, env_mismatch, detected_pane}. status is ok, mismatch, missing,
# invalid_override or not_in_herdr. An explicit --as target skips the workspace
# and cwd checks: an intentional cross-workspace caller is allowed.
boss_caller_identity_json() {
  local as_target="${1:-}" caller_cwd panes agents env_pane env_ws source
  local pane_json pane_id workspace_id cwd agent="" status message detected="null"
  local caller_session="" pane_session="" session_match="null" mismatch_code="caller_pane_mismatch"
  caller_cwd="$(pwd -P 2>/dev/null || pwd)"

  if [ "${HERDR_ENV:-}" != "1" ]; then
    jq -nc --arg m "boss write commands require a Herdr pane (HERDR_ENV is not set); run them inside Herdr" \
      '{status: "not_in_herdr", code: "not_in_herdr", message: $m,
        pane_id: null, workspace_id: null, cwd: null, agent: null,
        source: "env", env_mismatch: false, detected_pane: null}'
    return 0
  fi

  panes="$(boss_panes)"
  agents="$(boss_agents)"

  if [ -n "$as_target" ]; then
    source="as"
    pane_json="$(boss_pane_meta "$panes" "$as_target")"
    if [ -z "$pane_json" ] || [ "$pane_json" = "null" ]; then
      local ameta ameta_pane
      ameta="$(boss_agent_meta "$agents" "$as_target")"
      ameta_pane="$(printf '%s' "$ameta" | jq -r '.pane_id // empty' 2>/dev/null || true)"
      [ -n "$ameta_pane" ] && pane_json="$(boss_pane_meta "$panes" "$ameta_pane")"
      if [ -z "$pane_json" ] || [ "$pane_json" = "null" ]; then
        # An agent may be listed without a pane entry; use its own fields.
        [ -n "$ameta" ] && pane_json="$ameta"
      fi
    fi
    if [ -z "$pane_json" ] || [ "$pane_json" = "null" ]; then
      jq -nc --arg t "$as_target" \
        --arg m "--as '$as_target' names no living Herdr pane or agent" \
        '{status: "invalid_override", code: "invalid_override", message: $m,
          pane_id: null, workspace_id: null, cwd: null, agent: null,
          source: "as", env_mismatch: false, detected_pane: null}'
      return 0
    fi
    pane_id="$(printf '%s' "$pane_json" | jq -r '.pane_id // empty')"
    workspace_id="$(printf '%s' "$pane_json" | jq -r '.workspace_id // empty')"
    cwd="$(printf '%s' "$pane_json" | jq -r '.foreground_cwd // .cwd // empty')"
    agent="$(printf '%s' "$pane_json" | jq -r '.name // empty')"
    [ -n "$agent" ] || agent="$(printf '%s' "$agents" | jq -r --arg p "$pane_id" \
      'map(select(type == "object" and .pane_id == $p)) | .[0].name // empty' 2>/dev/null || true)"
    jq -nc --arg p "$pane_id" --arg w "$workspace_id" --arg c "$cwd" --arg a "$agent" \
      --arg src "$source" \
      '{status: "ok", code: null, message: null,
        pane_id: (if $p == "" then null else $p end),
        workspace_id: (if $w == "" then null else $w end),
        cwd: (if $c == "" then null else $c end),
        agent: (if $a == "" then null else $a end),
        source: $src, env_mismatch: false, detected_pane: null,
        session_id: null, pane_session_id: null, session_match: null}'
    return 0
  fi

  source="env"
  env_pane="${HERDR_PANE_ID:-}"
  env_ws="${HERDR_WORKSPACE_ID:-}"
  if [ -z "$env_pane" ]; then
    jq -nc --arg m "HERDR_PANE_ID is not set; cannot verify the caller identity" \
      '{status: "missing", code: "caller_pane_missing", message: $m,
        pane_id: null, workspace_id: null, cwd: null, agent: null,
        source: "env", env_mismatch: false, detected_pane: null}'
    return 0
  fi
  if [ -z "$env_ws" ]; then
    jq -nc --arg p "$env_pane" \
      --arg m "HERDR_PANE_ID '$env_pane' is set but HERDR_WORKSPACE_ID is empty; a pane id alone is not a verified caller identity" \
      '{status: "missing", code: "caller_pane_missing", message: $m,
        pane_id: null, workspace_id: null, cwd: null, agent: null,
        source: "env", env_mismatch: false, detected_pane: null}'
    return 0
  fi
  pane_json="$(boss_pane_meta "$panes" "$env_pane")"
  if [ -z "$pane_json" ] || [ "$pane_json" = "null" ]; then
    jq -nc --arg p "$env_pane" \
      --arg m "HERDR_PANE_ID '$env_pane' names no living Herdr pane; pass --as <pane|agent> or start the session in the right pane" \
      '{status: "missing", code: "caller_pane_missing", message: $m,
        pane_id: null, workspace_id: null, cwd: null, agent: null,
        source: "env", env_mismatch: false, detected_pane: null}'
    return 0
  fi
  pane_id="$env_pane"
  workspace_id="$(printf '%s' "$pane_json" | jq -r '.workspace_id // empty')"
  cwd="$(printf '%s' "$pane_json" | jq -r '.foreground_cwd // .cwd // empty')"
  agent="$(printf '%s' "$agents" | jq -r --arg p "$pane_id" \
    'map(select(type == "object" and .pane_id == $p)) | .[0].name // empty' 2>/dev/null || true)"

  status="ok"
  message=""
  if [ -n "$env_ws" ] && [ "$workspace_id" != "$env_ws" ]; then
    status="mismatch"
    message="caller identity mismatch: environment pane $pane_id is in workspace ${workspace_id:-unknown} but HERDR_WORKSPACE_ID is $env_ws"
  elif ! boss_cwd_related "$cwd" "$caller_cwd"; then
    status="mismatch"
    message="caller identity mismatch: environment pane $pane_id has cwd ${cwd:-unknown} but the calling process runs in $caller_cwd"
  else
    pane_session="$(printf '%s' "$agents" | jq -r --arg p "$pane_id" \
      'map(select(type == "object" and .pane_id == $p)) | .[0].agent_session.value // empty' 2>/dev/null || true)"
    caller_session="$(boss_caller_session_id)"
    if [ -n "$caller_session" ] && [ -n "$pane_session" ]; then
      if [ "$caller_session" = "$pane_session" ]; then
        session_match=true
      else
        session_match=false
        status="mismatch"
        mismatch_code="caller_session_mismatch"
        message="caller session mismatch: this process is session $caller_session but pane $pane_id hosts session $pane_session"
      fi
    fi
  fi

  if [ "$status" = "mismatch" ]; then
    detected="$(boss_detect_caller_pane)"
    [ -n "$detected" ] || detected="null"
    if [ "$detected" != "null" ]; then
      message="$message; likely calling pane: $(printf '%s' "$detected" | jq -r '"\(.pane_id) in workspace \(.workspace_id // "unknown") (cwd \(.cwd // "unknown"))"')"
    else
      message="$message; process ancestry matched no Herdr pane, so the caller identity is unverified"
    fi
    message="$message. Pass --as <pane|agent> or run 'boss retarget <change>' from the right pane"
  fi

  jq -nc --arg status "$status" --arg m "$message" \
    --arg p "$pane_id" --arg w "$workspace_id" --arg c "$cwd" --arg a "$agent" \
    --arg cs "$caller_session" --arg ps "$pane_session" --argjson sm "$session_match" \
    --arg mc "$mismatch_code" --argjson detected "$detected" \
    '{status: $status,
      code: (if $status == "ok" then null elif $status == "mismatch" then $mc else "caller_pane_missing" end),
      message: (if $m == "" then null else $m end),
      pane_id: (if $p == "" then null else $p end),
      workspace_id: (if $w == "" then null else $w end),
      cwd: (if $c == "" then null else $c end),
      agent: (if $a == "" then null else $a end),
      source: "env", env_mismatch: ($status == "mismatch"), detected_pane: $detected,
      session_id: (if $cs == "" then null else $cs end),
      pane_session_id: (if $ps == "" then null else $ps end),
      session_match: $sm}'
}

# boss_caller_identity [<as-pane-or-agent>] -- the verified caller identity as
# compact JSON, or a JSON error on stderr (exit 1). Fail-closed: a stale
# environment never falls back to the detected pane without an explicit --as.
boss_caller_identity() {
  local resp status
  resp="$(boss_caller_identity_json "${1:-}")" || exit 1
  status="$(printf '%s' "$resp" | jq -r '.status')"
  case "$status" in
    ok) printf '%s\n' "$resp" ;;
    mismatch) die_json "caller_pane_mismatch" "$(printf '%s' "$resp" | jq -r '.message')" ;;
    missing) die_json "caller_pane_missing" "$(printf '%s' "$resp" | jq -r '.message')" ;;
    invalid_override) die_json "invalid_override" "$(printf '%s' "$resp" | jq -r '.message')" ;;
    not_in_herdr) die_json "not_in_herdr" "$(printf '%s' "$resp" | jq -r '.message')" ;;
    *) die_json "caller_pane_mismatch" "$(printf '%s' "$resp" | jq -r '.message // "caller identity is unverified"')" ;;
  esac
}

# boss_use_caller [<as-pane-or-agent>] -- resolve and export the caller in the
# BOSS_CALLER_* globals used by ensure_boss_claim and dispatch_change. Dies
# with the resolver error, before any claim or state write.
boss_use_caller() {
  local resp
  resp="$(boss_caller_identity "${1:-}")" || exit 1
  BOSS_CALLER_JSON="$resp"
  BOSS_CALLER_PANE="$(printf '%s' "$resp" | jq -r '.pane_id // empty')"
  BOSS_CALLER_WORKSPACE="$(printf '%s' "$resp" | jq -r '.workspace_id // empty')"
  BOSS_CALLER_CWD="$(printf '%s' "$resp" | jq -r '.cwd // empty')"
  BOSS_CALLER_AGENT="$(printf '%s' "$resp" | jq -r '.agent // empty')"
  BOSS_CALLER_SOURCE="$(printf '%s' "$resp" | jq -r '.source // "env"')"
}

# boss_target_meta <name-or-pane> -- compact {name,pane_id,workspace_id,cwd} of
# a wake target from the current agent list, or an object with the target name
# and nulls when Herdr no longer knows it.
boss_target_meta() {
  local target="$1" meta
  meta="$(boss_agent_meta "$(boss_agents)" "$target")"
  if [ -n "$meta" ]; then
    printf '%s' "$meta" | jq -c '{name: (.name // empty), pane_id: (.pane_id // null),
      workspace_id: (.workspace_id // null), cwd: (.cwd // null)}'
  else
    jq -nc --arg t "$target" '{name: $t, pane_id: null, workspace_id: null, cwd: null}'
  fi
}

# boss_write_registry <file> <workspace-id> <pane-id> <agent> -- write the entry
boss_write_registry() {
  local file="$1" workspace_id="$2" pane_id="$3" agent="$4"
  mkdir -p "$BOSS_BOSSES_DIR" || die_json "state_write" "cannot create boss registry dir $BOSS_BOSSES_DIR"
  jq -n --arg w "$workspace_id" --arg p "$pane_id" --arg a "$agent" --arg t "$(now_iso)" \
    '{workspace_id: $w, pane_id: $p, agent: $a, claimed_at: $t}' >"$file" \
    || die_json "state_write" "cannot write boss registry $file"
}

# boss_registered_pane_ids -- pane ids of every registered boss, one per line
boss_registered_pane_ids() {
  local f
  [ -d "$BOSS_BOSSES_DIR" ] || return 0
  for f in "$BOSS_BOSSES_DIR"/*.json; do
    [ -f "$f" ] || continue
    jq -r '.pane_id // empty' "$f" 2>/dev/null || true
  done
}

# boss_agent_name <workspace-id> -- registered agent of the workspace's boss, or empty
boss_agent_name() {
  local reg
  [ -n "${1:-}" ] || return 0
  reg="$(boss_registry_file_for "$1")"
  [ -f "$reg" ] || return 0
  jq -r '.agent // empty' "$reg" 2>/dev/null || true
}

# boss_workspace_boss_pane <workspace-id> -- pane id of the workspace's living
# boss, or empty (no entry, no pane, or the pane is gone).
boss_workspace_boss_pane() {
  local workspace_id="${1:-}" reg reg_pane
  [ -n "$workspace_id" ] || return 0
  reg="$(boss_registry_file_for "$workspace_id")"
  [ -f "$reg" ] || return 0
  reg_pane="$(jq -r '.pane_id // empty' "$reg" 2>/dev/null || true)"
  [ -n "$reg_pane" ] || return 0
  if boss_agent_alive_pane "$(boss_agents)" "$reg_pane"; then
    printf '%s' "$reg_pane"
  fi
}

# boss_guard_foreign_name <agents-json> <pane-id> <requested-name> [<force>] --
# refuse to rename a pane that already carries a different living boss name
# registered in bosses/*.json. The explicit 'boss claim --force' is the only
# caller that passes force=1; auto-claiming commands never do. Dies with
# boss_exists before any rename or registry write.
boss_guard_foreign_name() {
  local agents="$1" pane_id="$2" name="$3" force="${4:-0}"
  local current f entry_agent entry_pane entry_ws
  [ "$force" = "1" ] && return 0
  current="$(boss_agent_name_on_pane "$agents" "$pane_id")"
  [ -n "$current" ] && [ "$current" != "$name" ] || return 0
  [ -d "$BOSS_BOSSES_DIR" ] || return 0
  for f in "$BOSS_BOSSES_DIR"/*.json; do
    [ -f "$f" ] || continue
    entry_agent="$(jq -r '.agent // empty' "$f" 2>/dev/null || true)"
    [ "$entry_agent" = "$current" ] || continue
    entry_pane="$(jq -r '.pane_id // empty' "$f" 2>/dev/null || true)"
    [ -n "$entry_pane" ] || continue
    if boss_agent_alive_pane "$agents" "$entry_pane"; then
      entry_ws="$(jq -r '.workspace_id // "unknown"' "$f" 2>/dev/null || true)"
      die_json "boss_exists" "pane $pane_id already carries the living boss name '$current' (registered for workspace ${entry_ws:-unknown} on pane $entry_pane); refusing to rename it to '$name' (pass --force to override)"
    fi
  done
  return 0
}

# boss_claim_pane <workspace-id> <pane-id> [<name>] [<force>] -- register an
# existing pane as the boss of its workspace, keeping one registry entry per
# workspace and following the same rules as 'boss claim'. Prints the claim JSON
# (status claimed/already_claimed/renamed). Dies with boss_exists when another
# living pane owns the workspace or the derived name, or when the pane already
# carries a different registered living boss name and force is not set. Used by
# 'boss claim' (caller pane) and 'boss session' (the newly created pane).
boss_claim_pane() {
  local workspace_id="${1:-}" pane_id="${2:-}" name="${3:-}" force="${4:-0}"
  [ -n "$pane_id" ] || die_json "not_in_herdr" "cannot claim the boss role without a pane id"
  [ -n "$workspace_id" ] || die_json "not_in_herdr" "cannot claim the boss role without a workspace id"

  local reg
  reg="$(boss_registry_file_for "$workspace_id")"

  if [ -z "$name" ]; then
    name="$(boss_name_for "$workspace_id")"
  else
    name="$(normalize_name "$name")"
    [ -n "$name" ] || usage_error "--name must contain a usable name (letters, digits, - or _)"
  fi

  local agents current reg_pane reg_agent status
  agents="$(boss_agents)"
  current="$(boss_agent_name_on_pane "$agents" "$pane_id")"
  boss_guard_foreign_name "$agents" "$pane_id" "$name" "$force"

  if [ -f "$reg" ]; then
    reg_pane="$(jq -r '.pane_id // empty' "$reg" 2>/dev/null || true)"
    reg_agent="$(jq -r '.agent // empty' "$reg" 2>/dev/null || true)"
    if [ -n "$reg_pane" ]; then
      if [ "$reg_pane" = "$pane_id" ]; then
        # The registry compares wishes; the pane's real name is the reality.
        # Heal a lost or renamed pane so the wake path works again, and report
        # a real change as 'renamed' rather than 'already_claimed'.
        if [ "$current" = "$name" ] && [ "$reg_agent" = "$name" ]; then
          printf '%s\n' "$(jq -n --arg w "$workspace_id" --arg p "$pane_id" --arg a "$reg_agent" \
            '{workspace_id: $w, pane_id: $p, agent: $a, status: "already_claimed"}')"
          return 0
        fi
        if [ "$current" != "$name" ]; then
          herdr_json agent rename "$pane_id" "$name" >/dev/null || exit 1
        fi
        boss_write_registry "$reg" "$workspace_id" "$pane_id" "$name"
        printf '%s\n' "$(jq -n --arg w "$workspace_id" --arg p "$pane_id" --arg a "$name" \
          '{workspace_id: $w, pane_id: $p, agent: $a, status: "renamed"}')"
        return 0
      fi
      if boss_agent_alive_pane "$agents" "$reg_pane"; then
        die_json "boss_exists" "workspace $workspace_id already has a boss on pane $reg_pane (agent ${reg_agent:-unknown})"
      fi
    fi
  fi

  local owner
  owner="$(printf '%s' "$agents" | jq -r --arg n "$name" \
    'map(select(type == "object" and .name == $n)) | .[0].pane_id // empty')"
  if [ -n "$owner" ] && [ "$owner" != "$pane_id" ]; then
    die_json "boss_exists" "agent '$name' already belongs to pane $owner; choose another name with --name"
  fi

  if [ -n "$current" ] && [ "$current" != "$name" ]; then
    status="renamed"
    herdr_json agent rename "$pane_id" "$name" >/dev/null || exit 1
  else
    status="claimed"
  fi
  boss_write_registry "$reg" "$workspace_id" "$pane_id" "$name"
  log "claimed boss of workspace $workspace_id as agent '$name' (pane $pane_id, $status)"
  printf '%s\n' "$(jq -n --arg w "$workspace_id" --arg p "$pane_id" --arg a "$name" --arg s "$status" \
    '{workspace_id: $w, pane_id: $p, agent: $a, status: $s}')"
}

# boss_wake_plan <state-file> -- ordered wake candidates and the candidates
# that were filtered, as compact JSON:
#   {candidates: [{target, source, pane, workspace, status:"ok"}],
#    skipped:    [{target, source, pane, workspace, reason}],
#    next: <first candidate or null>}
# Order: dispatcher -> workspace boss -> global BOSS_AGENT_NAME. The dispatcher
# is used only when it is alive and either in the apply's workspace or marked
# boss_cross_workspace; a missing flag means false, so an old cross-workspace
# state is skipped. It is also skipped as cross_project when its recorded
# boss_cwd is unrelated to the apply project and boss_cross_project is not set.
# The workspace registry pane must still be in its workspace; when its cwd is
# known it gets the same project check. A legacy state without boss_cwd keeps
# the workspace-only rule.
boss_wake_plan() {
  local state_file="$1" agents ws project state_boss state_pane boss_ws cross
  local state_cwd cross_project
  local reg reg_pane reg_ws target target_pane target_ws target_cwd meta reason
  local -a c_target=() c_source=() c_pane=() c_ws=()
  local -a s_target=() s_source=() s_pane=() s_ws=() s_reason=()
  local candidates_json="[]" skipped_json="[]" i

  agents="$(boss_agents)"
  ws="$(jq -r '.workspace_id // empty' "$state_file" 2>/dev/null || true)"
  project="$(jq -r '.project // empty' "$state_file" 2>/dev/null || true)"
  state_boss="$(jq -r '.boss // empty' "$state_file" 2>/dev/null || true)"
  state_pane="$(jq -r '.boss_pane // empty' "$state_file" 2>/dev/null || true)"
  boss_ws="$(jq -r '.boss_workspace // empty' "$state_file" 2>/dev/null || true)"
  state_cwd="$(jq -r '.boss_cwd // empty' "$state_file" 2>/dev/null || true)"
  cross="$(jq -r 'if (.boss_cross_workspace // false) == true then "true" else "false" end' \
    "$state_file" 2>/dev/null || printf 'false')"
  cross_project="$(jq -r 'if (.boss_cross_project // false) == true then "true" else "false" end' \
    "$state_file" 2>/dev/null || printf 'false')"

  # Stage 1: the boss that dispatched the apply. Prefer its name; fall back to
  # the pane id recorded at dispatch when the name was lost.
  target=""
  target_pane=""
  meta=""
  if [ -n "$state_boss" ] && boss_agent_alive_name "$agents" "$state_boss"; then
    target="$state_boss"
    meta="$(boss_agent_meta "$agents" "$state_boss")"
  elif [ -n "$state_pane" ] && boss_agent_alive_pane "$agents" "$state_pane"; then
    meta="$(boss_agent_meta "$agents" "$state_pane")"
    target="$(printf '%s' "$meta" | jq -r '.name // empty' 2>/dev/null || true)"
    [ -n "$target" ] || target="$state_pane"
  fi
  if [ -n "$target" ]; then
    target_pane="$(printf '%s' "$meta" | jq -r '.pane_id // empty' 2>/dev/null || true)"
    [ -n "$target_pane" ] || target_pane="$state_pane"
    target_ws="$(printf '%s' "$meta" | jq -r '.workspace_id // empty' 2>/dev/null || true)"
    [ -n "$target_ws" ] || target_ws="$boss_ws"
    reason=""
    if [ "$cross" = "true" ]; then
      :
    elif [ -n "$ws" ] && [ "$target_ws" = "$ws" ]; then
      :
    elif [ -z "$ws" ] && [ -z "$target_ws" ]; then
      # Without any workspace to compare against there is no unsafe claim.
      :
    else
      reason="cross_workspace"
    fi
    # Only the recorded boss_cwd is used here, so a legacy state without it
    # keeps the workspace-only rule even when Herdr reports a current cwd.
    if [ -z "$reason" ] && [ "$cross_project" != "true" ] \
       && [ -n "$state_cwd" ] && [ -n "$project" ] \
       && ! boss_cwd_related "$state_cwd" "$project"; then
      reason="cross_project"
    fi
    if [ -z "$reason" ]; then
      c_target+=("$target"); c_source+=("dispatcher"); c_pane+=("$target_pane"); c_ws+=("$target_ws")
    else
      s_target+=("$target"); s_source+=("dispatcher"); s_pane+=("$target_pane")
      s_ws+=("$target_ws"); s_reason+=("$reason")
    fi
  elif [ -n "$state_boss" ] || [ -n "$state_pane" ]; then
    s_target+=("${state_boss:-$state_pane}"); s_source+=("dispatcher")
    s_pane+=("$state_pane"); s_ws+=("$boss_ws"); s_reason+=("dead")
  fi

  # Stage 2: the boss registered for the apply's workspace.
  if [ -n "$ws" ]; then
    reg="$(boss_registry_file_for "$ws")"
    if [ -f "$reg" ]; then
      reg_pane="$(jq -r '.pane_id // empty' "$reg" 2>/dev/null || true)"
      if [ -n "$reg_pane" ] && boss_agent_alive_pane "$agents" "$reg_pane"; then
        meta="$(boss_agent_meta "$agents" "$reg_pane")"
        target="$(printf '%s' "$meta" | jq -r '.name // empty' 2>/dev/null || true)"
        [ -n "$target" ] || target="$reg_pane"
        reg_ws="$(printf '%s' "$meta" | jq -r '.workspace_id // empty' 2>/dev/null || true)"
        target_cwd="$(printf '%s' "$meta" | jq -r '.cwd // empty' 2>/dev/null || true)"
        reason=""
        if [ "$reg_ws" != "$ws" ]; then
          reason="moved"
        elif [ "$cross_project" != "true" ] \
             && [ -n "$target_cwd" ] && [ -n "$project" ] \
             && ! boss_cwd_related "$target_cwd" "$project"; then
          reason="cross_project"
        fi
        if [ -z "$reason" ]; then
          c_target+=("$target"); c_source+=("workspace_boss"); c_pane+=("$reg_pane"); c_ws+=("$reg_ws")
        else
          s_target+=("$target"); s_source+=("workspace_boss"); s_pane+=("$reg_pane")
          s_ws+=("$reg_ws"); s_reason+=("$reason")
        fi
      fi
    fi
  fi

  # Stage 3: the global boss agent.
  if [ -n "${BOSS_AGENT_NAME:-}" ] && boss_agent_alive_name "$agents" "$BOSS_AGENT_NAME"; then
    meta="$(boss_agent_meta "$agents" "$BOSS_AGENT_NAME")"
    target_pane="$(printf '%s' "$meta" | jq -r '.pane_id // empty' 2>/dev/null || true)"
    target_ws="$(printf '%s' "$meta" | jq -r '.workspace_id // empty' 2>/dev/null || true)"
    c_target+=("$BOSS_AGENT_NAME"); c_source+=("global"); c_pane+=("$target_pane"); c_ws+=("$target_ws")
  fi

  # Deduplicate the ordered candidates; a later duplicate is silent.
  i=0
  while [ "$i" -lt "${#c_target[@]}" ]; do
    local seen=0 j=0
    while [ "$j" -lt "$i" ]; do
      if [ "${c_target[$j]}" = "${c_target[$i]}" ]; then seen=1; break; fi
      j=$((j + 1))
    done
    if [ "$seen" -eq 0 ] && [ -n "${c_target[$i]}" ]; then
      candidates_json="$(printf '%s' "$candidates_json" | jq -c \
        --arg t "${c_target[$i]}" --arg s "${c_source[$i]}" \
        --arg p "${c_pane[$i]}" --arg w "${c_ws[$i]}" \
        '. + [{target: $t, source: $s,
               pane: (if $p == "" then null else $p end),
               workspace: (if $w == "" then null else $w end),
               status: "ok"}]')"
    fi
    i=$((i + 1))
  done

  i=0
  while [ "$i" -lt "${#s_target[@]}" ]; do
    skipped_json="$(printf '%s' "$skipped_json" | jq -c \
      --arg t "${s_target[$i]}" --arg s "${s_source[$i]}" \
      --arg p "${s_pane[$i]}" --arg w "${s_ws[$i]}" --arg r "${s_reason[$i]}" \
      '. + [{target: $t, source: $s,
             pane: (if $p == "" then null else $p end),
             workspace: (if $w == "" then null else $w end),
             reason: $r}]')"
    i=$((i + 1))
  done

  jq -nc --argjson candidates "$candidates_json" --argjson skipped "$skipped_json" \
    '{candidates: $candidates, skipped: $skipped, next: ($candidates[0] // null)}'
}

# boss_resolve_agent <state-file> -- ordered wake targets, one per line, from
# boss_wake_plan. Prints nothing when no safe boss is reachable.
boss_resolve_agent() {
  boss_wake_plan "$1" | jq -r '.candidates[].target'
}

# boss_wakeup_check <workspace-id> [<dispatcher-name>] -- visible state of the
# wake path for a workspace's apply, as compact JSON: 'state' is one of
# ok/name_stale/not_reachable, 'boss' the registered name, 'boss_pane' the
# registered pane, 'boss_reachable' true when any candidate (workspace boss,
# dispatcher, global) is alive and 'boss_name_ok' false when the living boss
# pane no longer carries the registered name. A missing workspace id, or an
# unreachable Herdr, makes no claim: state 'ok' and boss_reachable true, so a
# finished apply's review stays silent.
boss_wakeup_check() {
  local workspace_id="${1:-}" dispatcher="${2:-}"
  local out agents reg reg_agent="" reg_pane="" real="" reachable=false name_ok=true state="ok"

  out="$(herdr agent list 2>/dev/null || true)"
  if ! printf '%s' "$out" | jq -e '(.result.agents // .agents) | type == "array"' >/dev/null 2>&1; then
    jq -nc '{state: "ok", boss: null, boss_pane: null, boss_reachable: true, boss_name_ok: true}'
    return 0
  fi
  agents="$(printf '%s' "$out" | jq -c '.result.agents // .agents // []')"

  if [ -n "$workspace_id" ]; then
    reg="$(boss_registry_file_for "$workspace_id")"
    if [ -f "$reg" ]; then
      reg_agent="$(jq -r '.agent // empty' "$reg" 2>/dev/null || true)"
      reg_pane="$(jq -r '.pane_id // empty' "$reg" 2>/dev/null || true)"
    fi
    if [ -n "$reg_pane" ] && boss_agent_alive_pane "$agents" "$reg_pane"; then
      reachable=true
      real="$(boss_agent_name_on_pane "$agents" "$reg_pane")"
      if [ -z "$reg_agent" ] || [ "$real" != "$reg_agent" ]; then
        name_ok=false
      fi
    fi
    # The fallback stages mirror boss_resolve_agent, so a reachable dispatcher
    # or global boss is not reported as a broken wake path.
    if [ "$reachable" != true ] && [ -n "$dispatcher" ] && boss_agent_alive_name "$agents" "$dispatcher"; then
      reachable=true
    fi
    if [ "$reachable" != true ] && [ -n "${BOSS_AGENT_NAME:-}" ] && boss_agent_alive_name "$agents" "$BOSS_AGENT_NAME"; then
      reachable=true
    fi
    if [ "$reachable" != true ]; then
      state="not_reachable"
    elif [ "$name_ok" != true ]; then
      state="name_stale"
    fi
  fi

  jq -nc --arg state "$state" --arg boss "$reg_agent" --arg pane "$reg_pane" \
    --argjson reachable "$reachable" --argjson name_ok "$name_ok" \
    '{state: $state, boss: (if $boss == "" then null else $boss end),
      boss_pane: (if $pane == "" then null else $pane end),
      boss_reachable: $reachable, boss_name_ok: $name_ok}'
}

# one_line <text> -- collapse newlines/tabs into single spaces, trim
one_line() {
  printf '%s' "$1" | tr '\n\r\t' '   ' | sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//'
}

# lessons_read_active <file> -- the active lesson lines (each starting with
# '- ') under the '## Active' heading, one per line and in file order. A
# missing file or a missing '## Active' section yields nothing; a file that
# exists but cannot be read returns 1 so the caller can warn.
lessons_read_active() {
  local file="$1"
  [ -e "$file" ] || return 0
  [ -r "$file" ] || return 1
  awk '
    /^## Active[[:space:]]*$/ { active = 1; next }
    /^## / { active = 0 }
    active && /^- / { print }
  ' "$file" || return 1
  return 0
}

# lesson_append <file> <text> -- append <text> as an active lesson under
# '## Active' and as a dated entry under '## Log', creating the file and the
# sections as needed. The active list is never shortened or reordered. The
# write goes through mktemp + mv in the target directory, so a reader never
# sees a half-written file.
lesson_append() {
  local file="$1" text="$2" stamp tmp
  [ -n "$file" ] || return 1
  mkdir -p "$(dirname "$file")" || return 1
  stamp="$(now_iso)"
  tmp="$(mktemp "${file}.XXXXXX" 2>/dev/null)" || return 1
  if [ ! -f "$file" ]; then
    printf '## Active\n\n- %s\n\n## Log\n\n- %s %s\n' "$text" "$stamp" "$text" >"$tmp" || { rm -f "$tmp"; return 1; }
  else
    awk -v text="$text" -v stamp="$stamp" '
      BEGIN { active = 0; log_seen = 0; inserted = 0 }
      /^## Active[[:space:]]*$/ { active = 1 }
      /^## Log[[:space:]]*$/ {
        if (!inserted) {
          if (!active) printf "## Active\n\n"
          printf "- %s\n\n", text
          inserted = 1
        }
        log_seen = 1
        print
        next
      }
      { print }
      END {
        if (!inserted) {
          if (!active) printf "\n## Active\n"
          printf "\n- %s\n", text
        }
        if (!log_seen) printf "\n## Log\n"
        printf "\n- %s %s\n", stamp, text
      }
    ' "$file" >"$tmp" || { rm -f "$tmp"; return 1; }
  fi
  mv "$tmp" "$file" || { rm -f "$tmp"; return 1; }
  return 0
}

# journal_append <file> <text> [<tag>] -- append a dated entry to the project's
# journal under '## Log', creating the file and the section as needed. The
# entry is '- <iso> [<tag>] <text>'; an existing log is never reordered, the
# new entry goes last. The write goes through mktemp + mv, so a reader never
# sees a half-written file.
journal_append() {
  local file="$1" text="$2" tag="${3:-}" stamp tmp line
  [ -n "$file" ] || return 1
  mkdir -p "$(dirname "$file")" || return 1
  stamp="$(now_iso)"
  line="- $stamp"
  [ -n "$tag" ] && line="$line [$tag]"
  line="$line $text"
  tmp="$(mktemp "${file}.XXXXXX" 2>/dev/null)" || return 1
  if [ ! -f "$file" ]; then
    printf '## Log\n\n%s\n' "$line" >"$tmp" || { rm -f "$tmp"; return 1; }
  else
    awk -v line="$line" '
      BEGIN { log_seen = 0 }
      /^## Log[[:space:]]*$/ { log_seen = 1 }
      { print }
      END {
        if (!log_seen) printf "\n## Log\n"
        printf "\n%s\n", line
      }
    ' "$file" >"$tmp" || { rm -f "$tmp"; return 1; }
  fi
  mv "$tmp" "$file" || { rm -f "$tmp"; return 1; }
  return 0
}

# compose_apply_prompt <apply-cmd> <note> <lessons> <external> <commit> <yield>
# -- the text sent to the apply agent: command, note, lessons,
# external-verification instructions, commit policy, then the yield. The yield
# ends the prompt on purpose.
compose_apply_prompt() {
  local out="$1"
  [ -n "${2:-}" ] && out="$out $2"
  [ -n "${3:-}" ] && out="$out $3"
  [ -n "${4:-}" ] && out="$out $4"
  [ -n "${5:-}" ] && out="$out $5"
  [ -n "${6:-}" ] && out="$out $6"
  printf '%s' "$out"
}

# write_state_field <state-file> <key> <string-value> -- atomic update
write_state_field() {
  local f="$1" k="$2" v="$3" t
  t="$(mktemp)"
  if jq --arg k "$k" --arg v "$v" '.[$k] = $v' "$f" >"$t" 2>/dev/null; then
    mv "$t" "$f"
  else
    rm -f "$t"
    return 1
  fi
}

# state_file_for <project-path> <change> -- path of the state file for an apply
state_file_for() {
  local project="$1" change="$2" hash
  hash="$(sha1_hex "$project")"
  printf '%s/%s-%s.json\n' "$BOSS_APPLIES_DIR" "$hash" "$(normalize_name "$change")"
}

# events_file_for <project-path> <change> -- append-only event log for the
# applies of this change in this project (same keying as state_file_for).
events_file_for() {
  local project="$1" change="$2" hash
  hash="$(sha1_hex "$project")"
  printf '%s/%s-%s.events.jsonl\n' "$BOSS_CYCLES_DIR" "$hash" "$(normalize_name "$change")"
}

# --- Inbox: durable wake items -------------------------------------------
# One JSON file per wake under $BOSS_INBOX_DIR. The waiter writes an item
# before it prompts, so a lost prompt can be recovered by draining the inbox
# on any later wake. Files are written atomically (mktemp + mv).

# inbox_write <state-file> <state> [<summary>] -- write one inbox item
# atomically and print its id (the file name). Fields: id, ts, change, project,
# state, summary, summary_at, workspace_id, dispatcher, boss_pane. A non-empty
# <summary> overrides the state file's summary (used by 'boss park'). Returns 1
# when it cannot write; the caller treats that as non-fatal.
inbox_write() {
  local state_file="$1" st="$2" summary_override="${3:-}" id ts tmp
  [ -n "$state_file" ] && [ -f "$state_file" ] || return 1
  mkdir -p "$BOSS_INBOX_DIR" || return 1
  ts="$(now_iso)"
  # Sortable and unique: second resolution plus the waiter pid and $RANDOM.
  id="$(date '+%Y%m%dT%H%M%S')-$$-${RANDOM}.json"
  tmp="$BOSS_INBOX_DIR/.$id.tmp"
  if jq --arg id "$id" --arg ts "$ts" --arg st "$st" --arg sum "$summary_override" \
      '{id: $id, ts: $ts, change: (.change // null), project: (.project // null),
        state: $st, summary: (if $sum == "" then (.summary // null) else $sum end),
        summary_at: (.summary_at // null),
        workspace_id: (.workspace_id // null), dispatcher: (.boss // null),
        boss_pane: (.boss_pane // null)}' \
      "$state_file" >"$tmp" 2>/dev/null; then
    mv "$tmp" "$BOSS_INBOX_DIR/$id" || { rm -f "$tmp"; return 1; }
    printf '%s\n' "$id"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# inbox_item_path <id> -- path of an inbox item; rejects ids with a path
# separator so --ack cannot escape the inbox directory.
inbox_item_path() {
  local id="${1:-}"
  case "$id" in
    ""|*/*|*..*) return 1 ;;
  esac
  printf '%s/%s\n' "$BOSS_INBOX_DIR" "$id"
}

# inbox_remove <project> <change> -- remove every inbox item of an apply.
# Never fails; used by 'boss finish'.
inbox_remove() {
  local project="$1" change="$2" f
  [ -d "$BOSS_INBOX_DIR" ] || return 0
  for f in "$BOSS_INBOX_DIR"/*.json; do
    [ -f "$f" ] || continue
    if [ "$(jq -r '.project // empty' "$f" 2>/dev/null || true)" = "$project" ] \
       && [ "$(jq -r '.change // empty' "$f" 2>/dev/null || true)" = "$change" ]; then
      rm -f "$f"
    fi
  done
  return 0
}

# inbox_count <project> <change> -- pending inbox items for one apply.
inbox_count() {
  local project="$1" change="$2" f n=0
  [ -d "$BOSS_INBOX_DIR" ] || { printf '0\n'; return 0; }
  for f in "$BOSS_INBOX_DIR"/*.json; do
    [ -f "$f" ] || continue
    if [ "$(jq -r '.project // empty' "$f" 2>/dev/null || true)" = "$project" ] \
       && [ "$(jq -r '.change // empty' "$f" 2>/dev/null || true)" = "$change" ]; then
      n=$((n + 1))
    fi
  done
  printf '%s\n' "$n"
}

# inbox_pending_count -- pending inbox items across all applies.
inbox_pending_count() {
  local f n=0
  [ -d "$BOSS_INBOX_DIR" ] || { printf '0\n'; return 0; }
  for f in "$BOSS_INBOX_DIR"/*.json; do
    [ -f "$f" ] && n=$((n + 1))
  done
  printf '%s\n' "$n"
}

# append_event <file> <event> <json-object> -- append one JSONL event line.
# Adds the timestamp 't'; the object carries change/project and the
# event-specific fields. The append is a single O_APPEND write, so parallel
# writers (boss commands and the detached waiter) do not interleave.
append_event() {
  local file="$1" event="$2" extra="${3:-{\}}" line
  [ -n "$file" ] || return 1
  mkdir -p "$(dirname "$file")" || return 1
  line="$(jq -nc --arg t "$(now_iso)" --arg event "$event" --argjson extra "$extra" \
    '{t: $t, event: $event} + $extra')" || return 1
  printf '%s\n' "$line" >>"$file"
}

# boss_record_wake_event <events-file> <change> <project> <target> <state>
# Append a successful wake with the target's pane and workspace (when known).
boss_record_wake_event() {
  local file="$1" change="$2" project="$3" target="$4" state="$5" meta
  meta="$(boss_target_meta "$target")"
  append_event "$file" wake "$(jq -nc --arg c "$change" --arg p "$project" \
    --arg t "$target" --arg s "$state" --argjson m "$meta" \
    '{change: $c, project: $p, target: $t, pane: ($m.pane_id // null),
      workspace: ($m.workspace_id // null), state: $s}')"
}

# boss_record_wake_failed_event <events-file> <change> <project> <state> <reason> <plan-json>
# Append a failed wake with the candidates that were tried and the filtered ones.
boss_record_wake_failed_event() {
  local file="$1" change="$2" project="$3" state="$4" reason="$5" plan="$6"
  append_event "$file" wake_failed "$(jq -nc --arg c "$change" --arg p "$project" \
    --arg s "$state" --arg r "$reason" --argjson plan "$plan" \
    '{change: $c, project: $p, state: $s, reason: $r,
      tried: [($plan.candidates[]?.target)],
      skipped: [($plan.skipped[]? | {target, source, reason})]}')"
}

# event_count <file> <event> -- number of events of that name in the log.
event_count() {
  local file="$1" name="$2"
  [ -f "$file" ] || { printf '0\n'; return 0; }
  jq -Rc --arg e "$name" \
    'select(length > 0) | (fromjson? | select(type == "object")) | select(.event == $e)' \
    "$file" 2>/dev/null | wc -l | tr -d ' '
}

# git_range_base <project> <base-head> -- print <base-head> when it is a commit
# in <project> and an ancestor of HEAD, otherwise nothing. Used to guard the
# apply's commit range.
git_range_base() {
  local project="$1" base="${2:-}"
  [ -n "$base" ] || return 0
  git -C "$project" cat-file -e "${base}^{commit}" 2>/dev/null || return 0
  git -C "$project" merge-base --is-ancestor "$base" HEAD 2>/dev/null || return 0
  printf '%s' "$base"
}

# event_count_since_dispatch <file> <event> -- number of events of that name
# that belong to the current apply run, i.e. occurred at or after the last
# 'dispatch' event. Without a dispatch event the whole log is counted (same as
# event_count), so logs from before the event log keep working.
event_count_since_dispatch() {
  local file="$1" name="$2"
  [ -f "$file" ] || { printf '0\n'; return 0; }
  jq -Rsc --arg e "$name" \
    'split("\n")
     | map(select(length > 0) | (fromjson? | select(type == "object")))
     | (map(select(.event == "dispatch")) | last) as $d
     | [ .[] | select(.event == $e) | select($d == null or (.t // "") >= ($d.t // "")) ] | length' \
    "$file" 2>/dev/null || printf '0\n'
}

# last_event_field <file> <event> <field> -- value of <field> in the last event
# of that name (may be multi-line), or nothing. Skips malformed lines.
last_event_field() {
  local file="$1" event="$2" field="$3"
  [ -f "$file" ] || return 0
  jq -Rrc --arg e "$event" --arg f "$field" \
    'split("\n")
     | map(select(length > 0) | (fromjson? | select(type == "object" and .event == $e)))
     | map(.[$f] // empty)
     | last // empty' "$file" 2>/dev/null || true
}

# last_wake_event <events-file> -- the last wake or wake_failed event as compact
# JSON, or null when none was recorded.
last_wake_event() {
  local file="$1"
  if [ ! -f "$file" ]; then
    printf 'null\n'
    return 0
  fi
  jq -Rsc '
    split("\n")
    | map(select(length > 0) | (fromjson? | select(type == "object"))
          | select(.event == "wake" or .event == "wake_failed"))
    | last // null' "$file" 2>/dev/null || printf 'null\n'
}

# mission_human_markers -- the configured human-task markers, one per line.
# Reads '[missions] human_markers' from boss.toml and falls back to [Nutzer]
# and [human]. Read directly instead of through config_json, because this
# helper is also available to the waiter, which does not load the boss command
# layer.
mission_human_markers() {
  local out=""
  if [ -f "$BOSS_CONFIG" ] && command -v python3 >/dev/null 2>&1; then
    out="$(python3 - "$BOSS_CONFIG" 2>/dev/null <<'PY'
import sys
try:
    import tomllib
except ModuleNotFoundError:
    sys.exit(0)
try:
    with open(sys.argv[1], "rb") as f:
        cfg = tomllib.load(f)
except Exception:
    sys.exit(0)
markers = (cfg.get("missions") or {}).get("human_markers")
if isinstance(markers, list):
    for marker in markers:
        if isinstance(marker, str) and marker:
            print(marker)
PY
)"
  fi
  if [ -n "$out" ]; then
    printf '%s\n' "$out"
  else
    printf '%s\n' '[Nutzer]' '[human]'
  fi
}

# mission_external_markers -- the configured external-verification markers, one
# per line. These tasks are agent work whose proof comes from outside (Mac build,
# real data). Reads '[missions] external_verify_markers' and defaults to [Mac]
# and [Daten]; external wins over human when a task carries both.
mission_external_markers() {
  local out=""
  if [ -f "$BOSS_CONFIG" ] && command -v python3 >/dev/null 2>&1; then
    out="$(python3 - "$BOSS_CONFIG" 2>/dev/null <<'PY'
import sys
try:
    import tomllib
except ModuleNotFoundError:
    sys.exit(0)
try:
    with open(sys.argv[1], "rb") as f:
        cfg = tomllib.load(f)
except Exception:
    sys.exit(0)
markers = (cfg.get("missions") or {}).get("external_verify_markers")
if isinstance(markers, list):
    for marker in markers:
        if isinstance(marker, str) and marker:
            print(marker)
PY
)"
  fi
  if [ -n "$out" ]; then
    printf '%s\n' "$out"
  else
    printf '%s\n' '[Mac]' '[Daten]'
  fi
}

# mission_task_has_marker <text> <markers> -- 0 when the task text contains one
# of the newline-separated markers. Matching is a literal substring test.
mission_task_has_marker() {
  local text="$1" markers="$2" marker
  while IFS= read -r marker; do
    [ -n "$marker" ] || continue
    case "$text" in
      *"$marker"*) return 0 ;;
    esac
  done <<<"$markers"
  return 1
}

# mission_tasks_json <project> <change> -- tasks.md as compact JSON:
# {missing, open, done, total, human_open, agent_open, human_tasks, agent_tasks}.
# A task is human when its text contains a configured marker. 'criterion' is
# the text after 'Prüfen:' when present, otherwise the whole task text.
mission_tasks_json() {
  local project="$1" change="$2"
  local active_dir="$project/openspec/changes/$change" archive_dir tf
  archive_dir="$(ls -d "$project"/openspec/changes/archive/*-"$change" 2>/dev/null | sed -n '1p')"
  tf=""
  [ -f "$active_dir/tasks.md" ] && tf="$active_dir/tasks.md"
  if [ -z "$tf" ] && [ -n "$archive_dir" ] && [ -f "$archive_dir/tasks.md" ]; then
    tf="$archive_dir/tasks.md"
  fi
  if [ -z "$tf" ]; then
    jq -nc '{missing: true, open: null, done: null, total: null, human_open: null, external_open: null, agent_open: null, human_tasks: [], external_tasks: [], agent_tasks: []}'
    return 0
  fi

  local markers external_markers line text criterion
  local open=0 done=0 human_open=0 agent_open=0 external_open=0
  local human_json="[]" agent_json="[]" external_json="[]"
  markers="$(mission_human_markers)"
  external_markers="$(mission_external_markers)"
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*\[[[:space:]]\](.*)$ ]]; then
      text="${BASH_REMATCH[1]}"
      text="${text#"${text%%[![:space:]]*}"}"
      text="${text%"${text##*[![:space:]]}"}"
      open=$((open + 1))
      criterion="$text"
      case "$text" in
        *"Prüfen:"*) criterion="${text#*Prüfen:}"; criterion="${criterion# }" ;;
      esac
      if mission_task_has_marker "$text" "$external_markers"; then
        external_open=$((external_open + 1))
        external_json="$(printf '%s' "$external_json" | jq -c --arg t "$text" --arg c "$criterion" \
          '. + [{text: $t, criterion: $c}]')"
      elif mission_task_has_marker "$text" "$markers"; then
        human_open=$((human_open + 1))
        human_json="$(printf '%s' "$human_json" | jq -c --arg t "$text" --arg c "$criterion" \
          '. + [{text: $t, criterion: $c}]')"
      else
        agent_open=$((agent_open + 1))
        agent_json="$(printf '%s' "$agent_json" | jq -c --arg t "$text" '. + [{text: $t}]')"
      fi
    elif [[ "$line" =~ ^[[:space:]]*-[[:space:]]*\[[xX]\](.*)$ ]]; then
      done=$((done + 1))
    fi
  done <"$tf"

  jq -nc --argjson o "$open" --argjson d "$done" --argjson ho "$human_open" \
    --argjson eo "$external_open" --argjson ao "$agent_open" \
    --argjson ht "$human_json" --argjson et "$external_json" --argjson at "$agent_json" \
    '{missing: false, open: $o, done: $d, total: ($o + $d),
      human_open: $ho, external_open: $eo, agent_open: $ao,
      human_tasks: $ht, external_tasks: $et, agent_tasks: $at}'
}

# mission_park_event <project> <change> -- the last event among park, resume
# and dispatch for that change, or empty. Only 'park' means parked: resume and
# a fresh dispatch clear a park, and all three survive 'boss finish'.
mission_park_event() {
  local file
  file="$(events_file_for "$1" "$2")"
  [ -f "$file" ] || return 0
  jq -Rrsc '
    split("\n")
    | map(select(length > 0) | (fromjson? | select(type == "object")))
    | map(select(.event == "park" or .event == "resume" or .event == "dispatch"))
    | last | .event // empty
  ' "$file" 2>/dev/null || true
}

# mission_is_parked <project> <change> -- 0 when the last park marker is a park
mission_is_parked() {
  [ "$(mission_park_event "$1" "$2")" = "park" ]
}

# mission_done_state <project> <change> -- derived mission state for one change
# as compact JSON: {change, proposal, tasks:{...}, validate, finished, archived,
# parked, human_tasks, state}. A mission stores no status; everything is read
# live: the change dir (proposal), tasks.md, 'openspec validate --strict', the
# park/finish events in the apply's event log and the archive folder. 'state' is
# change_not_ready (no proposal), in_progress, waiting_human (parked and only
# marked human tasks remain open), or done = finished + no open tasks +
# validate pass. An archived change counts as validated, because validation can
# no longer be re-run once the change left the active folder.
mission_done_state() {
  local project="$1" change="$2"
  local active_dir="$project/openspec/changes/$change"
  local archive_dir proposal=false archived=false tf validate="not_run"
  archive_dir="$(ls -d "$project"/openspec/changes/archive/*-"$change" 2>/dev/null | sed -n '1p')"
  [ -n "$archive_dir" ] && archived=true
  if [ -f "$active_dir/proposal.md" ] || { [ -n "$archive_dir" ] && [ -f "$archive_dir/proposal.md" ]; }; then
    proposal=true
  fi

  local tasks_json tasks_open tasks_done tasks_total human_open external_open agent_open human_tasks external_tasks parked=false
  tasks_json="$(mission_tasks_json "$project" "$change")"
  tasks_open="$(printf '%s' "$tasks_json" | jq -r '.open')"
  tasks_done="$(printf '%s' "$tasks_json" | jq -r '.done')"
  tasks_total="$(printf '%s' "$tasks_json" | jq -r '.total')"
  human_open="$(printf '%s' "$tasks_json" | jq -r '.human_open')"
  external_open="$(printf '%s' "$tasks_json" | jq -r '.external_open')"
  agent_open="$(printf '%s' "$tasks_json" | jq -r '.agent_open')"
  human_tasks="$(printf '%s' "$tasks_json" | jq -c '.human_tasks')"
  external_tasks="$(printf '%s' "$tasks_json" | jq -c '.external_tasks')"
  mission_is_parked "$project" "$change" && parked=true

  if [ "$proposal" = true ] && command -v openspec >/dev/null 2>&1; then
    if [ ! -d "$active_dir" ] && [ -n "$archive_dir" ]; then
      validate="pass"
    elif (cd "$project" && openspec validate "$change" --strict >/dev/null 2>&1); then
      validate="pass"
    else
      validate="fail"
    fi
  fi

  local finished=false
  [ "$(event_count "$(events_file_for "$project" "$change")" finish)" -gt 0 ] && finished=true

  local state="in_progress"
  if [ "$proposal" != true ]; then
    state="change_not_ready"
  elif [ "$finished" = true ] && [ "$tasks_open" = "0" ] && [ "$validate" = "pass" ]; then
    state="done"
  elif [ "$parked" = true ] && [ "$tasks_open" != "null" ] && [ "$tasks_open" -gt 0 ] \
       && [ "$agent_open" = "0" ] && [ $(( ${human_open:-0} + ${external_open:-0} )) -gt 0 ]; then
    state="waiting_human"
  fi

  # Readiness: which required artifacts are still missing, so 'mission next'
  # can name them instead of failing only at dispatch. 'design' is optional in
  # the spec-driven schema (a change may omit design.md), so it is not required
  # here; proposal/specs/tasks are. An archived or proposal-less change keeps
  # ready=true; its state already tells the whole story.
  local ready=true missing_json="[]"
  if [ "$proposal" = true ] && [ -d "$active_dir" ] && command -v openspec >/dev/null 2>&1; then
    local st_json
    st_json="$(cd "$project" && openspec status --change "$change" --json 2>/dev/null || true)"
    if [ -n "$st_json" ]; then
      missing_json="$(printf '%s' "$st_json" | jq -c \
        '[ (.artifacts // [])[] | select((.status != "done") and (.status != "skipped") and (.id != "design")) | .id ]' 2>/dev/null || printf '[]')"
      [ "$(printf '%s' "$missing_json" | jq 'length')" -gt 0 ] && ready=false
    fi
  fi

  jq -nc --arg change "$change" --argjson proposal "$proposal" \
    --argjson tasks "$tasks_json" --arg validate "$validate" \
    --argjson finished "$finished" --argjson archived "$archived" --arg state "$state" \
    --argjson ready "$ready" --argjson missing "$missing_json" \
    --argjson parked "$parked" --argjson human_tasks "$human_tasks" --argjson external_tasks "$external_tasks" \
    '{change: $change, proposal: $proposal, tasks: $tasks, validate: $validate, finished: $finished, archived: $archived, parked: $parked, human_tasks: $human_tasks, external_tasks: $external_tasks, state: $state, ready: $ready, missing_artifacts: $missing}'
}

# expand_home <path> -- expand a leading ~
expand_home() {
  case "$1" in
    "~") printf '%s' "$HOME" ;;
    "~/"*) printf '%s/%s' "$HOME" "${1#\~/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# resolve_path <path> -- print the absolute, symlink-resolved path without
# relying on 'readlink -f' (macOS has no -f). The symlink chain is walked by
# hand: a relative target is taken relative to the link's directory, and the
# final directory is made physical with 'pwd -P'. A path that does not exist is
# returned expanded but unresolved, so error messages can still show it.
resolve_path() {
  local p resolved target dir hops=0
  p="$(expand_home "$1")"
  case "$p" in
    /*) ;;
    *) p="$PWD/$p" ;;
  esac
  while [ -L "$p" ] && [ "$hops" -lt 40 ]; do
    hops=$((hops + 1))
    target="$(readlink "$p" 2>/dev/null)" || break
    case "$target" in
      /*) p="$target" ;;
      *) p="$(dirname "$p")/$target" ;;
    esac
  done
  if [ -d "$p" ]; then
    resolved="$(cd "$p" 2>/dev/null && pwd -P)" && {
      printf '%s' "$resolved"
      return 0
    }
  fi
  dir="$(dirname "$p")"
  if resolved="$(cd "$dir" 2>/dev/null && pwd -P)"; then
    printf '%s/%s' "$resolved" "$(basename "$p")"
  else
    printf '%s' "$p"
  fi
}

# canonical_path <path> -- absolute, resolved path (no symlink components).
# A path that does not exist is returned expanded but unresolved, so error
# messages can still show it.
canonical_path() {
  resolve_path "$1"
}

# herdr_raw <method> <params-json> -- call the Herdr socket API directly.
# Used where the herdr CLI cannot express a call (e.g. pane.report_metadata).
# Prints the .result payload as compact JSON, dies on error.
herdr_raw() {
  local method="$1" params sock out rc code msg
  method="${1:-}"
  params="${2:-}"
  [ -n "$params" ] || params='{}'
  sock="${HERDR_SOCKET_PATH:-}"
  [ -n "$sock" ] || die_json "herdr_socket" "HERDR_SOCKET_PATH is not set; cannot reach the Herdr socket"
  out="$(python3 - "$sock" "$method" "$params" 2>&1 <<'PY'
import json, socket, sys
sock_path, method, params = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    params = json.loads(params)
except ValueError:
    params = {}
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    s.connect(sock_path)
    s.sendall(json.dumps({"id": "boss", "method": method, "params": params}).encode() + b"\n")
    f = s.makefile("r")
    sys.stdout.write(f.readline())
finally:
    s.close()
PY
)"
  rc=$?
  if [ "$rc" -ne 0 ] || ! printf '%s' "$out" | jq -e '.result != null' >/dev/null 2>&1; then
    code="$(printf '%s' "$out" | jq -r '.error.code // "herdr_error"' 2>/dev/null || printf 'herdr_error')"
    msg="$(printf '%s' "$out" | jq -r '.error.message // empty' 2>/dev/null || true)"
    die_json "$code" "herdr ${method}: ${msg:-socket call failed (exit $rc)}"
  fi
  printf '%s' "$out" | jq -c '.result'
}

# ------------------------------------------------------------- resources ---

# open_apply_count -- number of state files in $BOSS_APPLIES_DIR for applies
# that are still running. A parked change keeps its state file for 'boss
# status' but holds no executer, so it is not counted.
open_apply_count() {
  local f n=0
  [ -d "$BOSS_APPLIES_DIR" ] || { printf '0\n'; return 0; }
  for f in "$BOSS_APPLIES_DIR"/*.json; do
    [ -f "$f" ] || continue
    [ "$(jq -r '.parked // false' "$f" 2>/dev/null || printf false)" = "true" ] && continue
    n=$((n + 1))
  done
  printf '%s\n' "$n"
}

# free_mem_mb -- MemAvailable from BOSS_MEMINFO_FILE (/proc/meminfo) in MB, or
# nothing when the file is missing/unreadable or carries no MemAvailable line.
free_mem_mb() {
  local kb
  [ -r "$BOSS_MEMINFO_FILE" ] || return 0
  kb="$(awk '/^MemAvailable:/ {print $2; exit}' "$BOSS_MEMINFO_FILE" 2>/dev/null || true)"
  [ -n "$kb" ] || return 0
  printf '%s\n' "$(( kb / 1024 ))"
}

# load_1min -- the 1-minute load average as a decimal, read from
# BOSS_LOADAVG_FILE (/proc/loadavg) and otherwise from 'uptime'; nothing when
# neither source yields a value.
load_1min() {
  local first up
  if [ -r "$BOSS_LOADAVG_FILE" ]; then
    read -r first _ <"$BOSS_LOADAVG_FILE" 2>/dev/null || true
    if [ -n "${first:-}" ]; then
      printf '%s\n' "$first"
      return 0
    fi
  fi
  command -v uptime >/dev/null 2>&1 || return 0
  up="$(uptime 2>/dev/null || true)"
  first="$(printf '%s' "$up" | sed -n 's/.*load average[s]*:[[:space:]]*\([0-9.][0-9.]*\).*/\1/p')"
  [ -n "$first" ] && printf '%s\n' "$first"
  return 0
}

# resource_warning -- one-line, non-blocking notice for 'boss dispatch' naming
# every resource whose threshold is reached: open applies >=
# BOSS_DISPATCH_MAX_APPLIES, free memory < BOSS_DISPATCH_MIN_FREE_MB, 1-minute
# load >= BOSS_DISPATCH_MAX_LOAD. Prints nothing when every value is within
# budget or cannot be measured. Never fails.
resource_warning() {
  local parts="" n free load
  n="$(open_apply_count)"
  if [ -n "$n" ] && [ "$n" -ge "$BOSS_DISPATCH_MAX_APPLIES" ] 2>/dev/null; then
    parts="open applies: $n (threshold $BOSS_DISPATCH_MAX_APPLIES)"
  fi
  free="$(free_mem_mb)"
  if [ -n "$free" ] && [ "$free" -lt "$BOSS_DISPATCH_MIN_FREE_MB" ] 2>/dev/null; then
    parts="${parts:+$parts; }free memory: ${free}MB below ${BOSS_DISPATCH_MIN_FREE_MB}MB"
  fi
  load="$(load_1min)"
  if [ -n "$load" ] && awk -v l="$load" -v m="$BOSS_DISPATCH_MAX_LOAD" 'BEGIN { exit !(l >= m) }' 2>/dev/null; then
    parts="${parts:+$parts; }1-min load: $load at or above $BOSS_DISPATCH_MAX_LOAD"
  fi
  [ -n "$parts" ] && printf 'resource warning: %s\n' "$parts"
  return 0
}

# waiter_alive <pid> -- 0 when pid is a running boss-waiter. The script runs
# under bash, so comm= is "bash"; the command line carries the script name.
# Prefers 'ps'; without it (slim container) it falls back to a live pid plus a
# matching command line in /proc, so a reused pid is still not accepted.
waiter_alive() {
  local pid="$1" args
  [ -n "$pid" ] && [ "$pid" != "null" ] || return 1
  if command -v ps >/dev/null 2>&1; then
    ps -p "$pid" -o args= 2>/dev/null | grep -q 'boss-waiter' && return 0
    return 1
  fi
  kill -0 "$pid" 2>/dev/null || return 1
  [ -r "/proc/$pid/cmdline" ] || return 1
  args="$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true)"
  printf '%s' "$args" | grep -q 'boss-waiter'
}

# kill_waiter <pid> -- stop a running waiter, if the pid really is a boss-waiter
kill_waiter() {
  local pid="$1"
  [ -n "$pid" ] && [ "$pid" != "null" ] || return 0
  if waiter_alive "$pid"; then
    kill "$pid" 2>/dev/null || true
    return 0
  fi
  return 1
}

# detach_waiter <state-file> -- start the waiter detached from this process so
# it survives the dispatch command. Uses setsid (own session) when available,
# then nohup (macOS), and as a last resort a plain background process with a
# warning (a slim container should run with an init that reaps it).
# BIN_DIR is set by the caller (bin/boss).
detach_waiter() {
  local state_file="$1"
  if command -v setsid >/dev/null 2>&1; then
    setsid -f "$BIN_DIR/boss-waiter" "$state_file" >/dev/null 2>&1
  elif command -v nohup >/dev/null 2>&1; then
    nohup "$BIN_DIR/boss-waiter" "$state_file" >/dev/null 2>&1 &
  else
    log "warning: neither setsid nor nohup available; starting the waiter as a background process"
    "$BIN_DIR/boss-waiter" "$state_file" >/dev/null 2>&1 &
    disown 2>/dev/null || true
  fi
}
