#!/usr/bin/env bash
# shellcheck disable=SC2034  # this file defines globals that the other
# runtime files read; a per-line directive cannot cover a cross-file use.
# boss-apply -- part of the boss runtime, sourced by bin/boss after boss-lib.sh.
# Contains only function definitions; nothing runs when this file is sourced.

runner_commit_block() {
  local policy
  policy="$(printf '%s' "$1" | jq -r '.commit // "explorer"')"
  case "$policy" in
    agent)
      printf '%s' 'Commit policy: commit your work when the change is complete and tested.'
      ;;
    *)
      printf '%s' 'Commit policy: do not commit. Leave the working tree for the Explorer to review and commit.'
      ;;
  esac
}

# runner_interrupt_keys <runner-json> -- keys used by 'boss interrupt', one per
# line. Explicit .interrupt_keys wins; opencode needs two Esc, Claude one.
runner_interrupt_keys() {
  local runner="$1" kind explicit
  explicit="$(printf '%s' "$runner" | jq -r '.interrupt_keys[]? // empty' 2>/dev/null || true)"
  if [ -n "$explicit" ]; then
    printf '%s\n' "$explicit"
    return 0
  fi
  kind="$(printf '%s' "$runner" | jq -r '.kind // empty' 2>/dev/null || true)"
  if [ "$kind" = "opencode" ]; then
    printf '%s\n' 'esc' 'esc'
  else
    printf '%s\n' 'esc'
  fi
}

# ---------------------------------------------------------------- lessons ---

# lessons_global_path -- absolute path of the global lessons store: the
# BOSS_LESSONS_GLOBAL override, else '[lessons] global', else the default. A
# leading ~ is expanded.
mission_worktree_mode() {
  local cfg mode
  cfg="$(config_json)" || exit 1
  mode="$(printf '%s' "$cfg" | jq -r '.missions.worktrees // "auto"')"
  case "$mode" in
    auto|always|never) ;;
    *) die_json "invalid_worktrees" "invalid [missions] worktrees value '$mode'; use 'auto', 'always' or 'never'" ;;
  esac
  printf '%s\n' "$mode"
}

# resolve_worktree_flag <mode> <worktree-flag> <no-worktree-flag> [<max-parallel>]
# -- 1 when the apply runs in a worktree. An explicit flag wins over the
# configured mode at a serial limit; above one the run is worktree-only, so a
# base-checkout dispatch is refused with worktree_required.
resolve_worktree_flag() {
  local mode="$1" want="${2:-}" never="${3:-}" max="${4:-1}"
  if [ "$want" = "1" ] && [ "$never" = "1" ]; then
    usage_error "--worktree and --no-worktree are mutually exclusive"
  fi
  if [ "$max" -gt 1 ] 2>/dev/null; then
    if [ "$never" = "1" ]; then
      die_json "worktree_required" "max_parallel=$max runs applies in worktrees only; --no-worktree is refused so the base checkout stays clean"
    fi
    case "$mode" in
      never) die_json "worktree_required" "max_parallel=$max runs applies in worktrees only; [missions] worktrees = \"never\" is refused so the base checkout stays clean" ;;
    esac
    printf '1\n'
    return 0
  fi
  if [ "$want" = "1" ]; then printf '1\n'; return 0; fi
  if [ "$never" = "1" ]; then printf '0\n'; return 0; fi
  case "$mode" in
    always) printf '1\n' ;;
    *) printf '0\n' ;;
  esac
}

# mission_max_parallel -- effective hard concurrency limit: BOSS_MAX_PARALLEL
# when set for this process, otherwise [missions] max_parallel (default 1). A
# missing, non-integer or below-one value is a config error, never a silent
# fallback.
mission_max_parallel() {
  local cfg value source="[missions] max_parallel"
  cfg="$(config_json)" || exit 1
  value="$(printf '%s' "$cfg" | jq -r '.missions.max_parallel // 1')"
  if [ -n "${BOSS_MAX_PARALLEL:-}" ]; then
    value="$BOSS_MAX_PARALLEL"
    source="BOSS_MAX_PARALLEL"
  fi
  case "$value" in
    ''|*[!0-9]*)
      die_json "invalid_max_parallel" "invalid max_parallel value '$value' from $source; use an integer >= 1"
      ;;
  esac
  if [ "$value" -lt 1 ] 2>/dev/null; then
    die_json "invalid_max_parallel" "invalid max_parallel value '$value' from $source; use an integer >= 1"
  fi
  printf '%s\n' "$value"
}

# git_dirty_paths <dir> <all|plan|code> -- changed paths from git status, one
# per line. 'plan' selects openspec/ paths, 'code' everything outside it.
git_dirty_paths() {
  local dir="$1" mode="${2:-all}" out line path
  out="$(git -C "$dir" status --porcelain --untracked-files=all 2>/dev/null || true)"
  [ -n "$out" ] || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    path="${line:3}"
    case "$path" in
      *" -> "*) path="${path#* -> }" ;;
    esac
    case "$mode" in
      plan)
        case "$path" in openspec/*) printf '%s\n' "$path" ;; esac
        ;;
      code)
        case "$path" in openspec/*) ;; *) printf '%s\n' "$path" ;; esac
        ;;
      *)
        printf '%s\n' "$path"
        ;;
    esac
  done <<<"$out"
}

# plan_paths_for <project> -- existing plan pathspecs, one per line.
plan_paths_for() {
  local project="$1" path
  for path in openspec/vision.md openspec/missions openspec/changes; do
    [ -e "$project/$path" ] && printf '%s\n' "$path"
  done
}

# cmd_plan commit <change> [--project <name|path>] -- commit only the planning
# artifacts. Code and runtime paths are never added or committed.
cmd_plan() {
  local action="" change="" project_name="" arg
  while [ $# -gt 0 ]; do
    arg="$1"; shift
    case "$arg" in
      --project) project_name="${1:-}"; shift ;;
      -h|--help) usage ;;
      --*) usage_error "unknown option: $arg" ;;
      *)
        if [ -z "$action" ]; then action="$arg"
        elif [ -z "$change" ]; then change="$arg"
        else usage_error "unexpected argument: $arg"; fi ;;
    esac
  done
  [ -n "$action" ] || usage_error "usage: boss plan commit <change> [--project <name|path>]"
  case "$action" in
    commit) ;;
    *) usage_error "unknown plan action: $action" ;;
  esac
  [ -n "$change" ] || usage_error "usage: boss plan commit <change> [--project <name|path>]"

  ensure_config
  local project
  project="$(resolve_project "$project_name")" || exit 1
  [ -d "$project/openspec/changes/$change" ] \
    || die_json "change_not_found" "change '$change' not found in $project"
  git -C "$project" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die_json "not_a_git_repo" "$project is not a git repository; a worktree apply needs one"

  local -a paths=()
  while IFS= read -r p; do [ -n "$p" ] && paths+=("$p"); done < <(plan_paths_for "$project")
  [ "${#paths[@]}" -gt 0 ] || die_json "no_plan_paths" "$project has no openspec plan paths to commit"

  git -C "$project" add -A -- "${paths[@]}" >/dev/null 2>&1 \
    || die_json "git_add_failed" "cannot stage the plan paths in $project"
  local staged commit="" status="clean"
  staged="$(git -C "$project" diff --cached --name-only -- "${paths[@]}" 2>/dev/null || true)"
  if [ -n "$staged" ]; then
    # Commit the staged plan files explicitly. Passing the directories would
    # fail for an existing but empty openspec/missions/ directory.
    local -a staged_paths=()
    while IFS= read -r p; do [ -n "$p" ] && staged_paths+=("$p"); done <<<"$staged"
    git -C "$project" commit -m "plan: $change artifacts" -- "${staged_paths[@]}" >/dev/null 2>&1 \
      || die_json "git_commit_failed" "cannot commit the plan paths in $project"
    commit="$(git -C "$project" rev-parse HEAD 2>/dev/null || true)"
    status="committed"
  fi
  local paths_json
  paths_json="$(printf '%s\n' "$staged" | jq -Rsc 'split("\n") | map(select(length > 0))')"
  printf '%s\n' "$(jq -n --arg change "$change" --arg project "$project" \
    --arg status "$status" --arg commit "$commit" --argjson paths "$paths_json" \
    '{change: $change, project: $project, status: $status,
      commit: (if $commit == "" then null else $commit end), paths: $paths}')"
}

# ------------------------------------------------------- boss identity (D5) ---

# cmd_claim [--name <name>] [--release] [--force] -- register (or release) this
# pane as the boss of its Herdr workspace and keep one registry entry per
# workspace. --force is the explicit exception for renaming a pane that already
# carries another registered living boss name.
cmd_claim() {
  local name="" want_release=0 as_target="" force=0 arg
  while [ $# -gt 0 ]; do
    arg="$1"; shift
    case "$arg" in
      --name) name="${1:-}"; shift ;;
      --as) as_target="${1:-}"; shift ;;
      --release) want_release=1 ;;
      --force) force=1 ;;
      -h|--help) usage ;;
      --*) usage_error "unknown option: $arg" ;;
      *) usage_error "unexpected argument: $arg" ;;
    esac
  done

  # Verify the caller before the registry is read or written. An explicit
  # --as lets a session with an inherited environment name its real pane.
  boss_use_caller "$as_target"
  local pane_id workspace_id
  pane_id="${BOSS_CALLER_PANE:-}"
  workspace_id="${BOSS_CALLER_WORKSPACE:-}"
  [ -n "$pane_id" ] || die_json "not_in_herdr" "cannot claim the boss role without a pane id"
  [ -n "$workspace_id" ] || die_json "not_in_herdr" "cannot claim the boss role without a workspace id"

  local reg
  reg="$(boss_registry_file_for "$workspace_id")"

  if [ "$want_release" -eq 1 ]; then
    local reg_pane
    reg_pane="$(jq -r '.pane_id // empty' "$reg" 2>/dev/null || true)"
    if [ -z "$reg_pane" ] || [ "$reg_pane" != "$pane_id" ]; then
      die_json "not_boss" "this pane ($pane_id) is not the boss of workspace $workspace_id"
    fi
    rm -f "$reg"
    log "released boss claim for workspace $workspace_id (pane $pane_id)"
    printf '%s\n' "$(jq -n --arg w "$workspace_id" --arg p "$pane_id" \
      '{workspace_id: $w, pane_id: $p, status: "released"}')"
    return 0
  fi

  boss_claim_pane "$workspace_id" "$pane_id" "$name" "$force"
}

# ensure_boss_claim <mode> -- make sure the calling pane is the boss of its
# Herdr workspace. The writing commands (dispatch/retrigger/finish/answer)
# claim a free workspace automatically and abort when another living pane owns
# it. Read-only modes (status/wait/review) never claim and never abort for a
# foreign boss.
ensure_boss_claim() {
  local mode="${1:-status}"
  if [ "${HERDR_ENV:-}" != "1" ]; then
    case "$mode" in
      dispatch|retrigger|finish|answer|park|resume|retarget|interrupt)
        die_json "not_in_herdr" "boss $mode requires a Herdr pane (HERDR_ENV is not set); run the boss session inside Herdr"
        ;;
      *)
        log "warning: not running inside Herdr; the boss agent identity is unavailable"
        ;;
    esac
    return 0
  fi

  local pane_id workspace_id reg reg_pane reg_agent agents
  # A write command resolved the verified caller before calling this; read-only
  # commands fall back to the environment and never claim.
  if [ -n "${BOSS_CALLER_PANE:-}" ]; then
    pane_id="$BOSS_CALLER_PANE"
    workspace_id="${BOSS_CALLER_WORKSPACE:-}"
  else
    pane_id="${HERDR_PANE_ID:-}"
    workspace_id="${HERDR_WORKSPACE_ID:-}"
  fi
  [ -n "$pane_id" ] || die_json "not_in_herdr" "HERDR_PANE_ID is not set; cannot establish the boss identity"
  [ -n "$workspace_id" ] || die_json "not_in_herdr" "HERDR_WORKSPACE_ID is not set; cannot establish the boss identity"

  agents=""
  reg="$(boss_registry_file_for "$workspace_id")"
  if [ -f "$reg" ]; then
    reg_pane="$(jq -r '.pane_id // empty' "$reg" 2>/dev/null || true)"
    reg_agent="$(jq -r '.agent // empty' "$reg" 2>/dev/null || true)"
    if [ -n "$reg_pane" ]; then
      if [ "$reg_pane" = "$pane_id" ]; then
        return 0
      fi
      agents="$(boss_agents)"
      if boss_agent_alive_pane "$agents" "$reg_pane"; then
        case "$mode" in
          dispatch|retrigger|finish|answer|park|resume|retarget|interrupt)
            die_json "boss_exists" "workspace $workspace_id already has a boss on pane $reg_pane (agent ${reg_agent:-unknown}); run boss commands there"
            ;;
          *)
            log "warning: workspace $workspace_id belongs to boss pane $reg_pane; continuing read-only"
            ;;
        esac
        return 0
      fi
    fi
  fi

  case "$mode" in
    dispatch|retrigger|finish|answer|park|resume|retarget|interrupt) ;;
    *) return 0 ;;
  esac

  local name owner
  name="$(boss_name_for "$workspace_id")"
  [ -n "$agents" ] || agents="$(boss_agents)"
  # Auto-claiming never forces: a pane that already carries another registered
  # living boss name is left alone.
  boss_guard_foreign_name "$agents" "$pane_id" "$name" 0
  owner="$(printf '%s' "$agents" | jq -r --arg n "$name" \
    'map(select(type == "object" and .name == $n)) | .[0].pane_id // empty')"
  if [ -n "$owner" ] && [ "$owner" != "$pane_id" ]; then
    die_json "boss_exists" "agent '$name' already belongs to pane $owner; claim a name with 'boss claim --name'"
  fi
  herdr_json agent rename "$pane_id" "$name" >/dev/null || exit 1
  boss_write_registry "$reg" "$workspace_id" "$pane_id" "$name"
  log "auto-claimed boss of workspace $workspace_id as agent '$name' (pane $pane_id)"
  return 0
}

# ---------------------------------------------------------------- session ---

# cmd_session [--project <name|path>] [--runner <name>] -- start a boss tab in
# the target project's Herdr workspace with the runner's scoped env and register
# the new pane as that workspace's boss. The calling pane is left untouched.
cmd_session() {
  if [ "${HERDR_ENV:-}" != "1" ]; then
    die_json "not_in_herdr" "boss session requires a Herdr pane (HERDR_ENV is not set)"
  fi
  ensure_config

  local project_name="" runner_name="" arg
  while [ $# -gt 0 ]; do
    arg="$1"; shift
    case "$arg" in
      --project) project_name="${1:-}"; shift ;;
      --runner) runner_name="${1:-}"; shift ;;
      -h|--help) usage ;;
      --*) usage_error "unknown option: $arg" ;;
      *) usage_error "unexpected argument: $arg" ;;
    esac
  done

  local runner project workspace_id agent_name kind start
  runner="$(resolve_runner "$runner_name")" || exit 1
  start="$(runner_start_of "$runner")"
  project="$(resolve_project "$project_name")" || exit 1
  workspace_id="$(ensure_workspace "$project" "$(basename "$project")")"
  agent_name="$(boss_name_for "$workspace_id")"

  local existing_boss
  existing_boss="$(boss_workspace_boss_pane "$workspace_id")"
  if [ -n "$existing_boss" ]; then
    die_json "boss_exists" "workspace $workspace_id already has a boss on pane $existing_boss; no second boss tab was created"
  fi

  kind="$(printf '%s' "$runner" | jq -r '.kind // "acp"')"
  local mode_json
  mode_json="$(runner_mode_of "$runner")"
  local -a agent_args=()
  # 0: the boss session is not the apply agent; its grants may include a
  # force-push of its own branch.
  while IFS= read -r a; do agent_args+=("$a"); done < <(runner_args_of "$runner" 0)
  local -a env_args=()
  while IFS= read -r e; do [ -n "$e" ] && env_args+=(--env "$e"); done < <(runner_env_of "$runner")

  local created pane_id tab_id
  if [ "${#env_args[@]}" -gt 0 ]; then
    created="$(herdr_json tab create --workspace "$workspace_id" --cwd "$project" --label "boss" --no-focus "${env_args[@]}")" || exit 1
  else
    created="$(herdr_json tab create --workspace "$workspace_id" --cwd "$project" --label "boss" --no-focus)" || exit 1
  fi
  pane_id="$(printf '%s' "$created" | jq -r '.root_pane.pane_id // empty')"
  tab_id="$(printf '%s' "$created" | jq -r '.tab.tab_id // .root_pane.tab_id // empty')"
  [ -n "$pane_id" ] && [ -n "$tab_id" ] || die_json "tab_create_failed" "herdr tab create returned no pane/tab for $project"
  # From here on a failure must not leave the tab behind (see die_json).
  BOSS_FAILED_TAB="$tab_id"
  BOSS_FAILED_PANE="$pane_id"

  # The boss session must be a Herdr-native agent; start_runner rejects an ACP
  # runner here with acp_session_unsupported.
  start_runner "$start" "$agent_name" "$pane_id" "$kind" - "${agent_args[@]}"

  # Same readiness rule as dispatch, so a first-run dialog cannot wedge the tab.
  await_runner_ready "$agent_name" "$pane_id" "$runner"

  local claim
  claim="$(boss_claim_pane "$workspace_id" "$pane_id" "$agent_name")" || exit 1
  agent_name="$(printf '%s' "$claim" | jq -r '.agent // empty')"
  BOSS_FAILED_TAB=""

  log "session: project=$project runner=$(printf '%s' "$runner" | jq -r '.name') agent=$agent_name tab=$tab_id pane=$pane_id workspace=$workspace_id"

  printf '%s\n' "$(jq -n \
    --arg project "$project" --arg workspace_id "$workspace_id" --arg agent "$agent_name" \
    --arg pane_id "$pane_id" --arg tab_id "$tab_id" --arg status "started" \
    --argjson mode "$mode_json" \
    '{project: $project, workspace_id: $workspace_id, agent: $agent, pane_id: $pane_id, tab_id: $tab_id, status: $status, opencode_version: $mode.opencode_version, permission_mode: $mode.permission_mode}')"
}

# ------------------------------------------------------ workspace mapping ---

# find_workspace_for_repo <path> -- workspace of a pane whose cwd is the repo
# or a subdirectory of it (exact match preferred), or empty.
find_workspace_for_repo() {
  local repo="$1" panes ws_id
  panes="$(herdr_json pane list)" || exit 1
  ws_id="$(printf '%s' "$panes" | jq -r --arg r "$repo" '[.panes[] | select(.cwd == $r) | .workspace_id] | .[0] // empty')"
  if [ -z "$ws_id" ]; then
    ws_id="$(printf '%s' "$panes" | jq -r --arg r "$repo/" '[.panes[] | select((.cwd // "") | startswith($r)) | .workspace_id] | .[0] // empty')"
  fi
  printf '%s' "$ws_id"
}

# ensure_workspace <path> <label> -- existing workspace for the repo or a new one
ensure_workspace() {
  local repo="$1" label="$2" ws_id created
  ws_id="$(find_workspace_for_repo "$repo")"
  if [ -n "$ws_id" ]; then
    printf '%s' "$ws_id"
    return 0
  fi
  created="$(herdr_json workspace create --cwd "$repo" --label "$label" --no-focus)" || exit 1
  ws_id="$(printf '%s' "$created" | jq -r '.workspace.workspace_id // .root_pane.workspace_id // empty')"
  [ -n "$ws_id" ] || die_json "workspace_create_failed" "herdr workspace create returned no workspace_id for $repo"
  printf '%s' "$ws_id"
}

# ---------------------------------------------------------- apply readiness ---

# check_apply_ready <project> <change> -- all applyRequires artifacts done?
check_apply_ready() {
  local project="$1" change="$2" out rc missing msg
  out="$(cd "$project" && openspec status --change "$change" --json 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    msg="$(printf '%s' "$out" | jq -r '.status[0].message // empty' 2>/dev/null || true)"
    [ -n "$msg" ] || msg="$(printf '%s' "$out" | sed -n '1p')"
    die_json "change_not_found" "$msg"
  fi
  missing="$(printf '%s' "$out" | jq -r '
    . as $root
    | [ $root.applyRequires[]? as $id
        | select([ $root.artifacts[]? | select(.id == $id and .status == "done") ] | length == 0)
        | $id ]
    | join(", ")')"
  if [ -n "$missing" ]; then
    die_json "change_not_ready" "change '$change' in $project is not ready for apply; missing artifacts: $missing"
  fi

  local vout vrc vmsg
  vout="$(cd "$project" && openspec validate "$change" --strict 2>&1)"
  vrc=$?
  if [ "$vrc" -ne 0 ]; then
    vmsg="$(printf '%s' "$vout" | sed -n '1p')"
    [ -n "$vmsg" ] || vmsg="openspec validate --strict failed"
    die_json "change_invalid" "change '$change' in $project fails 'openspec validate --strict': $vmsg"
  fi
}

# find_running_apply <change> <project> [<worktree>] -- {pane_id,tab_id,
# workspace_id} of a live apply for this change: a living agent named
# apply_agent_name <change> whose cwd is in the worktree when one is recorded,
# otherwise in the project tree. The base prefix is deliberately not used for a
# worktree apply: an in-tree match would be a different checkout. Pane tokens
# are ignored; the calling pane and registered boss panes are never a running
# apply.
find_running_apply() {
  local change="$1" project="$2" worktree="${3:-}" scope agents hit excluded
  scope="${worktree:-$project}"
  agents="$(herdr_json agent list)" || exit 1
  excluded="$(boss_registered_pane_ids)"
  hit="$(printf '%s' "$agents" | jq -c \
    --arg n "$(apply_agent_name "$change")" --arg p "$scope" --arg ps "$scope/" \
    --arg self "${BOSS_CALLER_PANE:-${HERDR_PANE_ID:-}}" --arg ex "$excluded" \
    '[.agents[] | select(.name == $n)
        | select(((.cwd // "") == $p) or (((.cwd // "") | startswith($ps))))
        | .pane_id as $pid
        | select(($pid // "") != $self)
        | select(($ex | split("\n") | index($pid)) | not)
        | {pane_id, tab_id, workspace_id}] | .[0] // empty')"
  printf '%s' "$hit"
}

# find_workspace_executer <workspace-id> -- compact JSON {change,name,pane_id,
# tab_id,workspace_id} of a living apply agent in that workspace, or empty.
# One workspace runs at most one executer: two changes would share the working
# tree. The calling pane and registered boss panes are never an executer. The
# change is derived from the agent name (apply-<change>), so an over-long name
# is shown in its hashed short form.
find_workspace_executer() {
  local workspace_id="$1" agents excluded
  agents="$(herdr_json agent list)" || exit 1
  excluded="$(boss_registered_pane_ids)"
  printf '%s' "$agents" | jq -c \
    --arg w "$workspace_id" --arg self "${BOSS_CALLER_PANE:-${HERDR_PANE_ID:-}}" --arg ex "$excluded" \
    '[.agents[] | select(((.name // "") | startswith("apply-")))
        | select((.workspace_id // "") == $w)
        | .pane_id as $pid
        | select(($pid // "") != $self)
        | select(($ex | split("\n") | index($pid)) | not)
        | {change: ((.name // "") | sub("^apply-"; "")), name, pane_id, tab_id, workspace_id}] | .[0] // empty'
}

# assert_workspace_free <workspace-id> [<change>] -- die with executer_busy when
# a living apply agent already runs in that workspace. <change> is the change
# the caller wants to start; the running change is always named.
assert_workspace_free() {
  local workspace_id="$1" context="${2:-}" ws_executer busy_agent busy_change msg
  ws_executer="$(find_workspace_executer "$workspace_id")"
  [ -n "$ws_executer" ] && [ "$ws_executer" != "null" ] || return 0
  busy_agent="$(printf '%s' "$ws_executer" | jq -r '.name')"
  busy_change="$(printf '%s' "$ws_executer" | jq -r '.change')"
  if [ -n "$context" ]; then
    msg="workspace $workspace_id already runs executer '$busy_agent' for change '$busy_change'; finish it before dispatching '$context'"
  else
    msg="workspace $workspace_id already runs executer '$busy_agent' for change '$busy_change'; finish it before dispatching the next change"
  fi
  die_json "executer_busy" "$msg"
}

# await_runner_ready <agent> <pane> <runner-json> -- wait until the runner's
# TUI can take input before the first prompt: settle to idle, honour an
# optional `ready` marker (pane wait-output on a cold start) and answer an
# optional first-run dialog (e.g. claude's bypassPermissions consent). Dies
# with agent_not_ready; the caller has set BOSS_FAILED_TAB, so the tab closes.
await_runner_ready() {
  local agent="$1" pane="$2" runner="$3" out rc code
  if ! out="$(herdr agent wait "$agent" --until idle --timeout "$BOSS_AGENT_TUI_TIMEOUT_MS" 2>&1)"; then
    code="$(printf '%s' "$out" | jq -r '.error.code // "unknown"' 2>/dev/null || true)"
    die_json "agent_not_ready" "agent '$agent' not ready before prompting ($code; pane $pane)"
  fi

  local ready regex timeout
  ready="$(printf '%s' "$runner" | jq -r '.ready // empty')"
  if [ -n "$ready" ]; then
    regex="$(printf '%s' "$runner" | jq -r 'if .ready_regex == true then "1" else "" end')"
    timeout="$(printf '%s' "$runner" | jq -r --argjson d "$BOSS_RUNNER_READY_TIMEOUT_MS" '.ready_timeout_ms // $d')"
    if [ -n "$regex" ]; then
      out="$(herdr pane wait-output --regex "$ready" --timeout "$timeout" "$pane" 2>&1)"
    else
      out="$(herdr pane wait-output --match "$ready" --timeout "$timeout" "$pane" 2>&1)"
    fi
    rc=$?
    if [ "$rc" -ne 0 ]; then
      code="$(printf '%s' "$out" | jq -r '.error.code // "timeout"' 2>/dev/null || true)"
      die_json "agent_not_ready" "runner ready marker '$ready' not seen within ${timeout}ms ($code; pane $pane)"
    fi
  fi

  local match
  match="$(printf '%s' "$runner" | jq -r '.dialog_match // empty')"
  if [ -n "$match" ]; then
    local -a keys=()
    while IFS= read -r k; do [ -n "$k" ] && keys+=("$k"); done < <(printf '%s' "$runner" | jq -r '.dialog_keys[]? // empty')
    if [ "${#keys[@]}" -gt 0 ]; then
      local visible
      for _ in 1 2 3; do
        visible="$(herdr pane read "$pane" --source visible --lines 30 2>/dev/null || true)"
        printf '%s' "$visible" | grep -qF -- "$match" || break
        herdr agent send-keys "$agent" "${keys[@]}" >/dev/null 2>&1 || true
        log "answered a runner dialog matching '$match'"
        sleep 1
      done
    fi
  fi
}

# send_prompt <agent> <text> -- deliver a prompt and verify it took effect:
# herdr reports agent_prompt_stalled when the input did not lead to a working
# agent (e.g. the TUI was still booting); retry with backoff until the budget
# BOSS_AGENT_PROMPT_TIMEOUT_MS is used up.
send_prompt() {
  local agent="$1" text="$2" out rc code deadline wait_s now
  deadline=$(( $(now_ms) + BOSS_AGENT_PROMPT_TIMEOUT_MS ))
  wait_s=2
  while :; do
    out="$(herdr agent prompt "$agent" "$text" --wait --until working --timeout 30000 2>&1)"
    rc=$?
    if [ "$rc" -eq 0 ]; then
      return 0
    fi
    code="$(printf '%s' "$out" | jq -r '.error.code // "unknown"' 2>/dev/null || true)"
    case "$code" in
      agent_prompt_stalled|timeout)
        now="$(now_ms)"
        [ "$now" -lt "$deadline" ] || break
        log "prompt did not take effect yet ($code); retrying in ${wait_s}s"
        sleep "$wait_s"
        wait_s=$(( wait_s * 2 ))
        [ "$wait_s" -gt 15 ] && wait_s=15
        ;;
      *)
        die_json "prompt_failed" "sending prompt to $agent failed: $code"
        ;;
    esac
  done
  die_json "prompt_failed" "prompt did not take effect for $agent within $(( BOSS_AGENT_PROMPT_TIMEOUT_MS / 1000 ))s"
}

# external_verify_prompt_block <project> <change> -- prompt text for tasks whose
# proof comes from outside the agent (Mac build, real data). The agent must
# implement and locally test the work but leave the checkbox open. Prints
# nothing when there are no external tasks.
external_verify_prompt_block() {
  local project="$1" change="$2" tasks open
  tasks="$(mission_tasks_json "$project" "$change")"
  open="$(printf '%s' "$tasks" | jq -r '.external_open // 0')"
  [ "$open" -gt 0 ] 2>/dev/null || return 0
  printf 'External verification tasks in this change (e.g. a Mac build or real data): %s. Implement the code and run the local tests now; leave their checkboxes open until the external proof exists. Do not stop, park or hand back merely because the task carries an external marker.\n' \
    "$(printf '%s' "$tasks" | jq -r '[.external_tasks[]? | .text] | join("; ")')"
}

# compose_acp_apply_prompt <project> <change> <note> <lessons> <external>
# <commit> <yield> [<runner-extra>] -- the prompt for an ACP apply. The
# workflow reference is the OpenSpec CLI, never a slash command: an ACP agent
# does not implement the editor-specific '/opsx-apply' recipe. The existing
# note/lessons/external/commit/yield blocks follow unchanged. A runner `apply`
# value that starts with a slash command is ignored for the same reason.
compose_acp_apply_prompt() {
  local project="$1" change="$2" note="$3" lessons="$4" external="$5" commit="$6" yield="$7" extra="${8:-}"
  local instr files instruction head out
  instr="$(cd "$project" && openspec instructions apply --change "$change" --json 2>/dev/null || true)"
  files=""
  instruction=""
  if [ -n "$instr" ] && printf '%s' "$instr" | jq -e . >/dev/null 2>&1; then
    files="$(printf '%s' "$instr" | jq -r '[.contextFiles[]?[]?] | .[0:8] | join(", ")' 2>/dev/null || true)"
    instruction="$(printf '%s' "$instr" | jq -r '.instruction // empty' 2>/dev/null || true)"
  fi
  head="Follow the OpenSpec apply workflow for change \"$change\"."
  head="$head Run 'openspec instructions apply --change \"$change\" --json' in the project and follow the returned instruction and task list."
  [ -n "$instruction" ] && head="$head $instruction"
  [ -n "$files" ] && head="$head Context files: $files."
  out="$head"
  [ -n "$note" ] && out="$out $note"
  [ -n "$lessons" ] && out="$out $lessons"
  [ -n "$external" ] && out="$out $external"
  [ -n "$commit" ] && out="$out $commit"
  case "$extra" in
    /*) log "warning: ignoring the runner apply template '$extra' for the ACP transport; it looks like a slash command" ;;
    *) [ -n "$extra" ] && out="$out $extra" ;;
  esac
  [ -n "$yield" ] && out="$out $yield"
  printf '%s' "$out"
}

# start_herdr_agent <agent> <pane> <kind> [<args>...] -- start a Herdr-native
# apply agent and retry while a freshly created shell pane is still busy. This
# is the unchanged native start path, shared by dispatch and session.
start_herdr_agent() {
  local agent_name="$1" pane_id="$2" kind="$3"
  shift 3
  local -a agent_args=("$@")
  local started=0 deadline out rc code="" msg
  deadline=$(( $(now_ms) + BOSS_AGENT_BUSY_RETRY_MS ))
  # Always try at least once, then keep retrying busy panes until the deadline.
  while :; do
    if [ "${#agent_args[@]}" -gt 0 ]; then
      out="$(herdr agent start "$agent_name" --kind "$kind" --pane "$pane_id" --timeout "$BOSS_AGENT_START_TIMEOUT_MS" -- "${agent_args[@]}" 2>&1)"
    else
      out="$(herdr agent start "$agent_name" --kind "$kind" --pane "$pane_id" --timeout "$BOSS_AGENT_START_TIMEOUT_MS" 2>&1)"
    fi
    rc=$?
    if [ "$rc" -eq 0 ]; then
      started=1
      break
    fi
    code="$(printf '%s' "$out" | jq -r '.error.code // ""' 2>/dev/null || true)"
    [ "$code" = "agent_pane_busy" ] || break
    [ "$(now_ms)" -lt "$deadline" ] || break
    log "agent start for $agent_name hit a busy pane; retrying"
    sleep 1
  done
  if [ "$started" -ne 1 ]; then
    msg="agent '$agent_name' did not become ready within the start timeout"
    if [ -n "$code" ] && [ "$code" != "agent_pane_busy" ]; then
      msg="agent '$agent_name' failed to start: $code"
    fi
    die_json "agent_not_ready" "$msg (pane $pane_id, tab ${BOSS_FAILED_TAB:-} closed)"
  fi
  return 0
}

# start_acp_supervisor <state-file> -- launch the detached ACP supervisor for
# an apply whose state is already on disk. The supervisor owns the child and
# the turn; it writes its pid, session and readiness itself.
start_acp_supervisor() {
  local state_file="$1" bin="${BIN_DIR:-}" change logfile socket
  [ -n "$bin" ] || bin="$(dirname "$(resolve_path "${BASH_SOURCE[0]}")")"
  change="$(jq -r '.change // "acp"' "$state_file" 2>/dev/null || printf acp)"
  logfile="$BOSS_LOGS_DIR/$change-acp.log"
  mkdir -p "$BOSS_LOGS_DIR" "${BOSS_STATE_DIR}/acp" "${BOSS_STATE_DIR}/transcripts" 2>/dev/null || true
  socket="$(jq -r '.acp.control_socket // empty' "$state_file" 2>/dev/null || true)"
  [ -n "$socket" ] && rm -f "$socket" 2>/dev/null || true
  if command -v nohup >/dev/null 2>&1; then
    BOSS_LOG_FILE="$logfile" nohup "$bin/boss-acp" "$state_file" >/dev/null 2>&1 &
  else
    BOSS_LOG_FILE="$logfile" "$bin/boss-acp" "$state_file" >/dev/null 2>&1 &
    disown 2>/dev/null || true
  fi
  local pid=$!
  BOSS_FAILED_ACP_PID="$pid"
  acp_update_state "$state_file" '.acp.supervisor_pid = $pid' --argjson pid "$pid"
  printf '%s\n' "$pid"
}

# acp_wait_ready <state-file> [<timeout-ms>] -- wait until the supervisor has
# completed the ACP handshake and applied the session configuration, or has
# written an error. Dispatch uses this so a bad command/model/mode fails the
# dispatch instead of leaving a half-created apply behind.
acp_wait_ready() {
  local state_file="$1" timeout="${2:-$BOSS_ACP_START_TIMEOUT_MS}" deadline error ready pid change
  change="$(jq -r '.change // "acp"' "$state_file" 2>/dev/null || printf acp)"
  deadline=$(( $(now_ms) + timeout ))
  while :; do
    error="$(jq -r '.acp.error // empty' "$state_file" 2>/dev/null || true)"
    if [ -n "$error" ]; then
      die_json "acp_start_failed" "ACP supervisor failed for the apply: $error"
    fi
    ready="$(jq -r '.acp.ready // false' "$state_file" 2>/dev/null || printf false)"
    [ "$ready" = "true" ] && return 0
    pid="$(jq -r '.acp.supervisor_pid // empty' "$state_file" 2>/dev/null || true)"
    [ -n "$pid" ] || pid="${BOSS_FAILED_ACP_PID:-}"
    if [ -n "$pid" ] && ! acp_pid_alive "$pid"; then
      die_json "acp_start_failed" "the ACP supervisor exited before the session was ready; see $BOSS_LOGS_DIR/$change-acp.log"
    fi
    [ "$(now_ms)" -lt "$deadline" ] \
      || die_json "acp_start_timeout" "the ACP supervisor did not become ready within ${timeout}ms; see $BOSS_LOGS_DIR for its log"
    sleep 0.1
  done
}

# start_runner <transport> <agent> <pane> <kind> <state-file|-> [<args>...] --
# the one start path used by dispatch, retrigger and session. The native path
# is the unchanged Herdr agent start; the ACP path starts the supervisor.
start_runner() {
  local transport="$1" agent_name="$2" pane_id="$3" kind="$4" state_file="$5"
  shift 5
  case "$transport" in
    acp)
      [ -n "$state_file" ] && [ "$state_file" != "-" ] \
        || die_json "acp_session_unsupported" "an ACP runner cannot host the boss session; use a Herdr-native runner for 'boss session'"
      start_acp_supervisor "$state_file" >/dev/null
      acp_wait_ready "$state_file"
      ;;
    *)
      start_herdr_agent "$agent_name" "$pane_id" "$kind" "$@"
      ;;
  esac
}


# ---------------------------------------------------------------- dispatch ---

# parse_touches_value <raw> -- lock array JSON for a manual --touches value.
# 'none' declares that the change shares nothing; otherwise the value is a
# comma list of resource keys or path prefixes.
parse_touches_value() {
  local raw="$1"
  if [ "$raw" = "none" ]; then
    printf '[]\n'
    return 0
  fi
  printf '%s' "$raw" | tr ',' '\n' \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    | jq -Rsc 'split("\n") | map(select(length > 0))'
}

cmd_dispatch() {
  local change="" project_name="" runner_name="" note="" as_target="" arg
  local wt_flag="" no_wt_flag="" touches_raw="" touches_given=0
  while [ $# -gt 0 ]; do
    arg="$1"; shift
    case "$arg" in
      --project) project_name="${1:-}"; shift ;;
      --runner) runner_name="${1:-}"; shift ;;
      --note) note="$(one_line "${1:-}")"; shift ;;
      --worktree) wt_flag=1 ;;
      --no-worktree) no_wt_flag=1 ;;
      --touches) touches_raw="${1:-}"; touches_given=1; shift ;;
      --as) as_target="${1:-}"; shift ;;
      -h|--help) usage ;;
      --*) usage_error "unknown option: $arg" ;;
      *) if [ -z "$change" ]; then change="$arg"; else usage_error "unexpected argument: $arg"; fi ;;
    esac
  done
  [ -n "$change" ] || usage_error "usage: boss dispatch <change> [--project <name|path>] [--runner <name>] [--worktree|--no-worktree] [--touches <list|none>] [--as <pane|agent>]"

  # The identity is resolved before any claim or state write.
  boss_use_caller "$as_target"
  ensure_boss_claim dispatch
  ensure_config

  local runner project wt_mode want_worktree max_parallel touches_json='[]' declared=false
  runner="$(resolve_runner "$runner_name")" || exit 1
  project="$(resolve_project "$project_name")" || exit 1
  max_parallel="$(mission_max_parallel)" || exit 1
  wt_mode="$(mission_worktree_mode)" || exit 1
  want_worktree="$(resolve_worktree_flag "$wt_mode" "$wt_flag" "$no_wt_flag" "$max_parallel")" || exit 1
  if [ "$touches_given" -eq 1 ]; then
    touches_json="$(parse_touches_value "$touches_raw")"
    declared=true
  fi
  dispatch_change "$change" "$project" "$runner" "$note" "$want_worktree" "$touches_json" "$declared"
}

# dispatch_change <change> <project> <runner-json> <note> [<want-worktree>]
# [<touches-json> <declared>] -- shared dispatch path of 'boss dispatch',
# 'boss mission next' and a resumed worktree apply. The caller has established
# the boss claim and config and resolved project and runner. <want-worktree> is
# 1 for the isolated lifecycle; a recorded worktree always wins so
# resume/retrigger reuse it. <touches-json>/<declared> come from a mission
# bullet or a manual --touches; an existing state keeps its own values.
dispatch_change() {
  local change="$1" project="$2" runner="$3" note="$4" want_worktree="${5:-0}"
  # The dispatcher is the verified caller. Its workspace and cwd are recorded
  # too, so the waiter can decide whether the dispatcher may wake this apply
  # even when the apply runs in a different workspace.
  local dispatcher_boss dispatcher_pane dispatcher_workspace dispatcher_cwd
  dispatcher_pane="${BOSS_CALLER_PANE:-${HERDR_PANE_ID:-}}"
  dispatcher_workspace="${BOSS_CALLER_WORKSPACE:-${HERDR_WORKSPACE_ID:-}}"
  dispatcher_cwd="${BOSS_CALLER_CWD:-}"
  dispatcher_boss="${BOSS_CALLER_AGENT:-}"
  [ -n "$dispatcher_boss" ] || dispatcher_boss="$(boss_agent_name "$dispatcher_workspace")"

  check_apply_ready "$project" "$change"
  local agent_name
  agent_name="$(apply_agent_name "$change")"

  # A non-blocking resource notice: it never stops the dispatch, it only names
  # the exhausted reserves so the boss can judge the next start.
  local resource_warn
  resource_warn="$(resource_warning)"
  [ -n "$resource_warn" ] && log "warning: $resource_warn"

  local project_registered=true hint=""
  if ! is_project_registered "$project"; then
    project_registered=false
    hint="project '$project' is not registered in $BOSS_CONFIG; add it under [projects] to address it by name"
    log "warning: $hint"
  fi

  local mode_json
  mode_json="$(runner_mode_of "$runner")"

  # How the runner's deny list is enforced (see BOSS_POLICY_DENY_DEFAULT). It is
  # reported with every dispatch result, never a hard failure: the charter stays
  # the authoritative boundary and the deny list is defence in depth.
  local policy_json
  policy_json="$(policy_check "$runner" "$project")"

  local existing pane_id tab_id workspace_id wake_target warnings_json="[]"
  local state_file
  state_file="$(state_file_for "$project" "$change")"
  local existing_worktree="" existing_branch="" existing_base=""
  local existing_touches="[]" existing_declared="false"
  local touches_json="${6:-[]}" declared="${7:-false}"
  if [ -f "$state_file" ]; then
    existing_worktree="$(jq -r '.worktree // empty' "$state_file" 2>/dev/null || true)"
    existing_branch="$(jq -r '.branch // empty' "$state_file" 2>/dev/null || true)"
    existing_base="$(jq -r '.base_head // empty' "$state_file" 2>/dev/null || true)"
    existing_touches="$(jq -c '.touches // []' "$state_file" 2>/dev/null || printf '[]')"
    existing_declared="$(jq -r '.declared // false' "$state_file" 2>/dev/null || printf false)"
    # A resumed or retriggered apply keeps the declarations it started with;
    # an old state without them stays exclusive.
    touches_json="$existing_touches"
    declared="$existing_declared"
  fi
  [ -n "$existing_worktree" ] && want_worktree=1

  local max_parallel
  max_parallel="$(mission_max_parallel)" || exit 1
  if [ "$max_parallel" -gt 1 ] && [ "$want_worktree" != "1" ]; then
    die_json "worktree_required" "max_parallel=$max_parallel runs applies in worktrees only; dispatch '$change' with --worktree or set [missions] worktrees = \"always\""
  fi

  # An already-running apply wins over the slot/lock checks: dispatching the
  # same change again is idempotent and does not create anything.
  # Everything from here to the state write is serialized per change: without
  # the lock, two bosses can both pass this check and start two applies.
  local dispatch_lock_path
  dispatch_lock_path="$(dispatch_lock "$project" "$change")"
  if lock_acquire "$dispatch_lock_path" "$BOSS_LOCK_TIMEOUT_MS"; then
    BOSS_DISPATCH_LOCK="$dispatch_lock_path"
  else
    die_json "dispatch_busy" "another dispatch of '$change' is in progress; retry in a moment"
  fi

  existing="$(find_running_apply "$change" "$project" "$existing_worktree")"
  if [ -n "$existing" ] && [ "$existing" != "null" ]; then
    pane_id="$(printf '%s' "$existing" | jq -r '.pane_id')"
    tab_id="$(printf '%s' "$existing" | jq -r '.tab_id')"
    workspace_id="$(printf '%s' "$existing" | jq -r '.workspace_id')"
    # The already-running apply keeps its recorded dispatcher as the next wake.
    if [ -f "$state_file" ]; then
      wake_target="$(boss_wake_plan "$state_file" | jq -c '.next // null')"
    else
      wake_target="null"
    fi
    printf '%s\n' "$(jq -n \
      --arg change "$change" --arg project "$project" \
      --arg runner "$(printf '%s' "$runner" | jq -r '.name')" \
      --arg agent "$agent_name" --arg pane_id "$pane_id" --arg tab_id "$tab_id" \
      --arg workspace_id "$workspace_id" --arg status "already_running" \
      --arg transport "$(runner_start_of "$runner")" \
      --arg worktree "$existing_worktree" --arg branch "$existing_branch" \
      --argjson touches "$touches_json" --argjson declared "$declared" \
      --argjson wake_target "$wake_target" --argjson warnings "$warnings_json" \
      --argjson project_registered "$project_registered" --arg hint "$hint" --arg resource_warning "$resource_warn" \
      --argjson mode "$mode_json" --argjson policy "$policy_json" \
      '{change: $change, project: $project, runner: $runner, agent: $agent, pane_id: $pane_id, tab_id: $tab_id, workspace_id: $workspace_id, transport: (if $transport == "" then "herdr" else $transport end), worktree: (if $worktree == "" then null else $worktree end), branch: (if $branch == "" then null else $branch end), touches: $touches, declared: $declared, status: $status, wake_target: $wake_target, warnings: $warnings, project_registered: $project_registered, hint: (if $hint == "" then null else $hint end), resource_warning: (if $resource_warning == "" then null else $resource_warning end), opencode_version: $mode.opencode_version, permission_mode: $mode.permission_mode, policy: $policy}')"
    lock_release "$BOSS_DISPATCH_LOCK"
    BOSS_DISPATCH_LOCK=""
    return 0
  fi

  # Hard concurrency limit: one slot per running apply, globally. Excluding
  # this change's own state lets a retrigger or resume reuse its slot.
  local running
  running="$(open_apply_count "$state_file")"
  if [ "$running" -ge "$max_parallel" ] 2>/dev/null; then
    die_json "parallel_limit" "parallel limit reached: $running running apply(s), max_parallel=$max_parallel; finish or park one before dispatching '$change'" \
      "$(jq -nc --argjson c "$running" --argjson m "$max_parallel" '{current: $c, max: $m, slots_free: 0}')"
  fi

  # Locks are checked before the worktree or tab exists, so a conflict starts
  # nothing. A candidate without a touches declaration is exclusive.
  local lock_json lock_holder
  lock_json="$(lock_check "$project" "$change" "$touches_json" "$declared" "$state_file")"
  if [ "$(printf '%s' "$lock_json" | jq -r '.conflict')" = "true" ]; then
    lock_holder="$(printf '%s' "$lock_json" | jq -r '.holder.change // "unknown"')"
    die_json "lock_conflict" "change '$change' conflicts with running or unmerged change '$lock_holder'; declared locks: $(printf '%s' "$touches_json" | jq -c '.')" \
      "$(printf '%s' "$lock_json" | jq -c '{holder: .holder, holders: .holders}')"
  fi

  local worktree="" branch="" worktree_workspace="" apply_root="$project"
  local base_head=""
  if [ "$want_worktree" = "1" ]; then
    if [ -n "$existing_worktree" ]; then
      [ -d "$existing_worktree" ] \
        || die_json "worktree_missing" "the recorded worktree $existing_worktree for '$change' is missing; run 'boss doctor --fix' or remove the state before dispatching again"
      worktree="$existing_worktree"
      branch="${existing_branch:-$(worktree_branch_for "$change")}"
      # Open the worktree through Herdr when it still knows it, then prefer the
      # workspace that currently hosts it. A stale recorded workspace is
      # repaired below by find/ensure_workspace.
      local opened=""
      opened="$(herdr_worktree_open "$project" "$worktree" 2>/dev/null || true)"
      if [ -n "$opened" ]; then
        worktree_workspace="$(printf '%s' "$opened" | jq -r '.workspace_id // empty' 2>/dev/null || true)"
        [ -n "$branch" ] || branch="$(printf '%s' "$opened" | jq -r '.branch // empty' 2>/dev/null || true)"
      fi
      [ -n "$worktree_workspace" ] || worktree_workspace="$(find_workspace_for_repo "$worktree")"
      base_head="$existing_base"
    else
      git -C "$project" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
        || die_json "not_a_git_repo" "$project is not a git repository; a worktree apply needs one"
      local plan_dirty code_dirty
      plan_dirty="$(git_dirty_paths "$project" plan)"
      if [ -n "$plan_dirty" ]; then
        die_json "plan_uncommitted" "the planning artifacts are not committed: $(printf '%s' "$plan_dirty" | paste -sd ', ' -); run 'boss plan commit $change --project $project' first"
      fi
      code_dirty="$(git_dirty_paths "$project" code)"
      if [ -n "$code_dirty" ]; then
        die_json "base_dirty" "the base checkout has uncommitted changes outside openspec/: $(printf '%s' "$code_dirty" | paste -sd ', ' -); commit or stash them before a worktree dispatch"
      fi
      base_head="$(git -C "$project" rev-parse HEAD 2>/dev/null || true)"
      [ -n "$base_head" ] || die_json "git_head" "cannot determine HEAD in $project"
      worktree="$(worktree_path_for "$project" "$change")"
      branch="$(worktree_branch_for "$change")"
      if [ -e "$worktree" ]; then
        die_json "worktree_exists" "a worktree already exists at $worktree without an apply state; inspect it or remove it before dispatching '$change'"
      fi
      mkdir -p "$(dirname "$worktree")" \
        || die_json "worktree_create_failed" "cannot create the worktree parent directory for $worktree"
      BOSS_FAILED_WORKTREE="$worktree"
      BOSS_FAILED_WORKTREE_PROJECT="$project"
      BOSS_FAILED_WORKTREE_BRANCH="$branch"
      local wt_json
      wt_json="$(herdr_worktree_create "$project" "$branch" "$base_head" "$worktree" "$change")" || exit 1
      worktree="$(printf '%s' "$wt_json" | jq -r '.path // empty')"
      branch="$(printf '%s' "$wt_json" | jq -r '.branch // empty')"
      worktree_workspace="$(printf '%s' "$wt_json" | jq -r '.workspace_id // empty')"
      [ -n "$worktree" ] || worktree="$(worktree_path_for "$project" "$change")"
      [ -n "$branch" ] || branch="$(worktree_branch_for "$change")"
    fi
    [ -n "$worktree_workspace" ] || worktree_workspace="$(find_workspace_for_repo "$worktree")"
    [ -n "$worktree_workspace" ] || worktree_workspace="$(ensure_workspace "$worktree" "$change")"
    BOSS_FAILED_WORKTREE_WS="$worktree_workspace"
    apply_root="$worktree"
  fi

  local kind start apply_template apply_cmd
  kind="$(printf '%s' "$runner" | jq -r '.kind // "acp"')"
  start="$(runner_start_of "$runner")"
  apply_template="$(printf '%s' "$runner" | jq -r '.apply // empty')"
  local -a agent_args=()
  while IFS= read -r a; do agent_args+=("$a"); done < <(runner_args_of "$runner")

  # An ACP command must be executable before anything is created. The
  # handshake and the offered model/mode are checked by the supervisor below,
  # which is what lets the dispatch fail without leaving an apply behind.
  if [ "$start" = "acp" ]; then
    local acp_command acp_bin
    acp_command="$(printf '%s' "$runner" | jq -r '.command // empty')"
    acp_bin="${acp_command%% *}"
    command -v "$acp_bin" >/dev/null 2>&1 \
      || die_json "acp_command_missing" "the ACP command '$acp_bin' for runner '$(printf '%s' "$runner" | jq -r '.name')' is not executable or not on PATH"
  fi

  if [ "$want_worktree" = "1" ]; then
    workspace_id="$worktree_workspace"
  else
    workspace_id="$(ensure_workspace "$project" "$(basename "$project")")"
  fi

  assert_workspace_free "$workspace_id" "$change"

  local -a env_args=()
  while IFS= read -r e; do [ -n "$e" ] && env_args+=(--env "$e"); done < <(runner_env_of "$runner")

  local created
  if [ "${#env_args[@]}" -gt 0 ]; then
    created="$(herdr_json tab create --workspace "$workspace_id" --cwd "$apply_root" --label "$change" --no-focus "${env_args[@]}")" || exit 1
  else
    created="$(herdr_json tab create --workspace "$workspace_id" --cwd "$apply_root" --label "$change" --no-focus)" || exit 1
  fi
  pane_id="$(printf '%s' "$created" | jq -r '.root_pane.pane_id // empty')"
  tab_id="$(printf '%s' "$created" | jq -r '.tab.tab_id // .root_pane.tab_id // empty')"
  [ -n "$pane_id" ] && [ -n "$tab_id" ] || die_json "tab_create_failed" "herdr tab create returned no pane/tab for $apply_root"
  # From here on a failure must not leave the tab behind (see die_json).
  BOSS_FAILED_TAB="$tab_id"
  BOSS_FAILED_PANE="$pane_id"

  apply_cmd="${apply_template/\{change\}/$change}"
  local runner_yield
  runner_yield="$(runner_yield_of "$runner")"
  local gfile pfile lessons_block="" external_block commit_block
  external_block="$(external_verify_prompt_block "$project" "$change")"
  commit_block="$(runner_commit_block "$runner")"
  gfile="$(lessons_global_path 2>/dev/null || true)"
  pfile="$(lessons_project_path "$project" 2>/dev/null || true)"
  if [ -n "$gfile" ] && [ -n "$pfile" ]; then
    lessons_block="$(lessons_prompt_block "$gfile" "$pfile")" || lessons_block=""
  fi

  local acp_prompt="" acp_command="" acp_model="" acp_mode="" acp_policy="" acp_transcript=""
  local acp_socket="" acp_deny="[]" acp_events="" acp_boss_bin="" acp_heartbeat=""
  if [ "$start" = "acp" ]; then
    acp_prompt="$(compose_acp_apply_prompt "$apply_root" "$change" "$note" "$lessons_block" \
      "$external_block" "$commit_block" "$runner_yield" "$apply_cmd")"
    acp_command="$(printf '%s' "$runner" | jq -r '.command // empty')"
    acp_model="$(printf '%s' "$runner" | jq -r '.model // empty')"
    acp_mode="$(printf '%s' "$runner" | jq -r '.mode // "smart_approve"')"
    acp_policy="$(printf '%s' "$runner" | jq -r '.policy // "allow"')"
    acp_transcript="$(acp_transcript_for "$state_file")"
    acp_socket="$(acp_socket_for "$state_file")"
    acp_heartbeat="$(acp_heartbeat_for "$state_file")"
    acp_deny="$(policy_denies "$runner" | jq -Rsc 'split("\n") | map(select(length > 0))')"
    acp_events="$(events_file_for "$project" "$change")"
    acp_boss_bin="${BIN_DIR:-$(dirname "$(resolve_path "${BASH_SOURCE[0]}")")}/boss"
    mkdir -p "$(dirname "$acp_transcript")" "$(dirname "$acp_socket")" 2>/dev/null || true
  fi

  local now runner_name_out base_head dispatcher_cross="false" dispatcher_cross_project="false"
  now="$(now_iso)"
  runner_name_out="$(printf '%s' "$runner" | jq -r '.name')"
  if [ -n "$dispatcher_workspace" ] && [ "$dispatcher_workspace" != "$workspace_id" ]; then
    dispatcher_cross="true"
    warnings_json="$(printf '%s' "$warnings_json" | jq -c --arg p "$dispatcher_pane" --arg dw "$dispatcher_workspace" --arg aw "$workspace_id" \
      '. + ["dispatcher pane \($p) is in workspace \($dw) but the apply runs in \($aw); wakeups will target the dispatcher because it was recorded explicitly"]')"
  fi
  # A verified caller in the same workspace can still belong to another
  # project. Record that scope explicitly, just like a cross-workspace dispatch.
  if [ -n "$dispatcher_cwd" ] && ! boss_cwd_related "$dispatcher_cwd" "$project"; then
    dispatcher_cross_project="true"
    warnings_json="$(printf '%s' "$warnings_json" | jq -c --arg p "$dispatcher_pane" --arg dc "$dispatcher_cwd" --arg ap "$project" \
      '. + ["dispatcher pane \($p) has cwd \($dc), which is unrelated to the apply project \($ap); the cross-project scope is recorded"]')"
  fi
  wake_target="$(jq -nc --arg b "$dispatcher_boss" --arg p "$dispatcher_pane" \
    --arg w "$dispatcher_workspace" \
    '{boss: (if $b == "" then null else $b end),
      pane: (if $p == "" then null else $p end),
      workspace: (if $w == "" then null else $w end), source: "dispatcher"}')"
  # Anchor for the apply's commit range: the HEAD the apply starts from. A
  # resumed worktree keeps its original base so the review still sees the whole
  # change, not just the work since the restart.
  if [ -z "$base_head" ]; then
    base_head="$(git -C "$project" rev-parse HEAD 2>/dev/null || true)"
  fi
  mkdir -p "$BOSS_APPLIES_DIR" || die_json "state_write" "cannot create state dir $BOSS_APPLIES_DIR"
  jq -n \
    --arg change "$change" --arg project "$project" --arg runner "$runner_name_out" \
    --arg kind "$kind" --arg start "$start" --arg apply_cmd "$apply_cmd" --arg note "$note" --arg lessons "$lessons_block" --arg external_block "$external_block" --arg commit_block "$commit_block" --arg commit_policy "$(printf '%s' "$runner" | jq -r '.commit // "explorer"')" --arg yield "$runner_yield" --arg agent "$agent_name" \
    --arg pane_id "$pane_id" --arg tab_id "$tab_id" --arg workspace_id "$workspace_id" --arg boss "$dispatcher_boss" \
    --arg boss_pane "$dispatcher_pane" --arg boss_workspace "$dispatcher_workspace" \
    --arg boss_cwd "$dispatcher_cwd" --argjson boss_cross "$dispatcher_cross" \
    --argjson boss_cross_project "$dispatcher_cross_project" \
    --arg base_head "$base_head" \
    --arg worktree "$worktree" --arg branch "$branch" \
    --arg worktree_workspace "$worktree_workspace" \
    --argjson touches "$touches_json" --argjson declared "$declared" \
    --arg started_at "$now" --arg last_state "$( [ "$start" = "acp" ] && printf starting || printf working )" --arg last_state_at "$now" \
    --arg acp_command "$acp_command" --arg acp_prompt "$acp_prompt" --arg acp_model "$acp_model" \
    --arg acp_mode "$acp_mode" --arg acp_policy "$acp_policy" --arg acp_transcript "$acp_transcript" \
    --arg acp_socket "$acp_socket" --arg acp_events "$acp_events" --arg acp_boss_bin "$acp_boss_bin" \
    --arg acp_heartbeat "$acp_heartbeat" --arg acp_root "$apply_root" --argjson acp_deny "${acp_deny:-[]}" \
    --argjson mode "$mode_json" \
    '{change: $change, project: $project, runner: $runner, kind: $kind, transport: $start, apply_cmd: $apply_cmd, note: $note, lessons: $lessons, external_block: $external_block, commit_block: $commit_block, commit_policy: $commit_policy, yield: $yield, agent: $agent, pane_id: $pane_id, tab_id: $tab_id, workspace_id: $workspace_id, worktree: (if $worktree == "" then null else $worktree end), branch: (if $branch == "" then null else $branch end), worktree_workspace: (if $worktree_workspace == "" then null else $worktree_workspace end), touches: $touches, declared: $declared, merge_state: "none", merged: false, merge_test: "not_run", kept: false, boss: $boss, boss_pane: (if $boss_pane == "" then null else $boss_pane end), boss_workspace: (if $boss_workspace == "" then null else $boss_workspace end), boss_cwd: (if $boss_cwd == "" then null else $boss_cwd end), boss_cross_workspace: $boss_cross, boss_cross_project: $boss_cross_project, base_head: (if $base_head == "" then null else $base_head end), waiter_pid: null, started_at: $started_at, last_state: $last_state, last_state_at: $last_state_at, opencode_version: $mode.opencode_version, permission_mode: $mode.permission_mode,
     acp: (if $start == "acp" then {
       command: $acp_command, apply_root: $acp_root, prompt: $acp_prompt,
       model: (if $acp_model == "" then null else $acp_model end),
       mode: $acp_mode, policy: $acp_policy, deny: $acp_deny,
       session_id: null, supervisor_pid: null, control_socket: $acp_socket,
       transcript: $acp_transcript, events_file: $acp_events,
       boss_bin: $acp_boss_bin, heartbeat_file: $acp_heartbeat,
       ready: false, phase: "starting", last_stop_reason: null,
       pending_permission: null, usage: null, last_update: null,
       error: null, dead_reported: false, load_session: null, resume: false
     } else null end)}' \
    >"$state_file" || die_json "state_write" "cannot write state file $state_file"
  BOSS_FAILED_STATE="$state_file"

  start_runner "$start" "$agent_name" "$pane_id" "$kind" "$state_file" "${agent_args[@]}"

  if [ "$start" = "acp" ]; then
    # The apply tab is a live view only: it tails the transcript and is never
    # read for state, never prompted with keystrokes and hosts no agent.
    if [ -n "$acp_transcript" ]; then
      # The pane hosts a shell, not an agent: use the pane surface. 'agent
      # send-keys' would be rejected because there is no Herdr agent here.
      herdr pane run "$pane_id" "tail -n +1 -f '$acp_transcript'" >/dev/null 2>&1 \
        || log "warning: could not start the transcript tail in pane $pane_id"
    fi
  else
    # Wait until the agent TUI can take input before prompting.
    await_runner_ready "$agent_name" "$pane_id" "$runner"
    send_prompt "$agent_name" "$(compose_apply_prompt "$apply_cmd" "$note" "$lessons_block" "$external_block" "$commit_block" "$runner_yield")"
    herdr_raw "pane.report_metadata" "$(jq -nc --arg p "$pane_id" --arg c "$change" \
      '{pane_id: $p, source: "openspec", tokens: {os_change: $c, os_phase: "apply"}}')" >/dev/null || exit 1
    detach_waiter "$state_file"
  fi
  BOSS_FAILED_STATE=""
  BOSS_FAILED_ACP_PID=""
  BOSS_FAILED_TAB=""
  BOSS_FAILED_WORKTREE=""
  BOSS_FAILED_WORKTREE_WS=""

  log "dispatch: change=$change project=$project runner=$runner_name_out agent=$agent_name tab=$tab_id pane=$pane_id workspace=$workspace_id"

  append_event "$(events_file_for "$project" "$change")" dispatch \
    "$(jq -nc --arg c "$change" --arg p "$project" --arg r "$runner_name_out" --arg a "$agent_name" \
      '{change: $c, project: $p, runner: $r, agent: $a}')" || log "warning: could not record dispatch event"

  printf '%s\n' "$(jq -n \
    --arg change "$change" --arg project "$project" --arg runner "$runner_name_out" \
    --arg agent "$agent_name" --arg pane_id "$pane_id" --arg tab_id "$tab_id" \
    --arg workspace_id "$workspace_id" --arg status "started" \
    --arg transport "$start" \
    --arg worktree "$worktree" --arg branch "$branch" \
    --argjson touches "$touches_json" --argjson declared "$declared" \
    --argjson wake_target "$wake_target" --argjson warnings "$warnings_json" \
    --argjson project_registered "$project_registered" --arg hint "$hint" --arg resource_warning "$resource_warn" \
    --argjson mode "$mode_json" --argjson policy "$policy_json" \
    '{change: $change, project: $project, runner: $runner, agent: $agent, pane_id: $pane_id, tab_id: $tab_id, workspace_id: $workspace_id, transport: $transport, worktree: (if $worktree == "" then null else $worktree end), branch: (if $branch == "" then null else $branch end), touches: $touches, declared: $declared, status: $status, wake_target: $wake_target, warnings: $warnings, project_registered: $project_registered, hint: (if $hint == "" then null else $hint end), resource_warning: (if $resource_warning == "" then null else $resource_warning end), opencode_version: $mode.opencode_version, permission_mode: $mode.permission_mode, policy: $policy}')"
  lock_release "$BOSS_DISPATCH_LOCK"
  BOSS_DISPATCH_LOCK=""
}

# --------------------------------------------------------------- retarget ---

# cmd_retarget <change> [--project <name|path>] [--to <pane|agent>] -- move a
# running apply's dispatcher to the verified caller or an explicit target. The
# workspace registry is untouched; 'boss claim --as' repairs that separately.
cmd_retarget() {
  local change="" project_name="" to_target="" arg
  while [ $# -gt 0 ]; do
    arg="$1"; shift
    case "$arg" in
      --project) project_name="${1:-}"; shift ;;
      --to) to_target="${1:-}"; shift ;;
      -h|--help) usage ;;
      --*) usage_error "unknown option: $arg" ;;
      *) if [ -z "$change" ]; then change="$arg"; else usage_error "unexpected argument: $arg"; fi ;;
    esac
  done
  [ -n "$change" ] || usage_error "usage: boss retarget <change> [--project <name|path>] [--to <pane|agent>]"

  boss_use_caller "$to_target"
  # Retarget is state-only: it validates the caller and updates the apply's
  # dispatcher fields and event. It never claims, renames or writes a registry;
  # 'boss claim --as' is the separate registry repair.
  ensure_config

  local state_file project apply_ws
  state_file="$(find_state_file "$change" "$project_name")" || exit 1
  project="$(jq -r '.project' "$state_file")"
  apply_ws="$(jq -r '.workspace_id // empty' "$state_file")"

  local new_boss new_pane new_ws new_cwd cross=false cross_project=false old_json new_json tmp
  new_pane="${BOSS_CALLER_PANE:-}"
  new_ws="${BOSS_CALLER_WORKSPACE:-}"
  new_cwd="${BOSS_CALLER_CWD:-}"
  new_boss="${BOSS_CALLER_AGENT:-}"
  [ -n "$new_boss" ] || new_boss="$(boss_agent_name "$new_ws")"
  [ -n "$new_boss" ] || new_boss="$(boss_name_for "$new_ws")"
  if [ -n "$apply_ws" ] && [ "$new_ws" != "$apply_ws" ]; then
    cross=true
  fi
  # The recorded dispatcher cwd decides whether this is an intentional
  # cross-project retarget; an unknown cwd keeps the legacy workspace-only rule.
  if [ -n "$new_cwd" ] && [ -n "$project" ] && ! boss_cwd_related "$new_cwd" "$project"; then
    cross_project=true
  fi

  old_json="$(jq -c '{boss: (.boss // null), boss_pane: (.boss_pane // null),
    boss_workspace: (.boss_workspace // null), boss_cwd: (.boss_cwd // null),
    boss_cross_workspace: (.boss_cross_workspace // false),
    boss_cross_project: (.boss_cross_project // false)}' "$state_file")"
  tmp="$(mktemp)"
  if jq --arg b "$new_boss" --arg p "$new_pane" --arg w "$new_ws" --arg c "$new_cwd" \
      --argjson x "$cross" --argjson xp "$cross_project" \
      '.boss = $b
       | .boss_pane = (if $p == "" then null else $p end)
       | .boss_workspace = (if $w == "" then null else $w end)
       | .boss_cwd = (if $c == "" then null else $c end)
       | .boss_cross_workspace = $x
       | .boss_cross_project = $xp' "$state_file" >"$tmp" 2>/dev/null; then
    mv "$tmp" "$state_file"
  else
    rm -f "$tmp"
    die_json "state_write" "cannot update state file $state_file"
  fi

  new_json="$(jq -c '{boss: (.boss // null), boss_pane: (.boss_pane // null),
    boss_workspace: (.boss_workspace // null), boss_cwd: (.boss_cwd // null),
    boss_cross_workspace: (.boss_cross_workspace // false),
    boss_cross_project: (.boss_cross_project // false)}' "$state_file")"

  append_event "$(events_file_for "$project" "$change")" retarget \
    "$(jq -nc --arg c "$change" --arg p "$project" \
      --argjson old "$old_json" --argjson new "$new_json" \
      '{change: $c, project: $p, old: $old, new: $new}')" \
    || log "warning: could not record retarget event"

  local plan
  plan="$(boss_wake_plan "$state_file")"
  log "retarget: change=$change project=$project target=$new_boss pane=$new_pane workspace=$new_ws cross=$cross cross_project=$cross_project"
  printf '%s\n' "$(jq -n --arg change "$change" --arg project "$project" \
    --arg status "retargeted" --argjson old "$old_json" --argjson new "$new_json" \
    --argjson plan "$plan" \
    '{change: $change, project: $project, status: $status, old: $old, new: $new,
      boss_cross_project: ($new.boss_cross_project // false),
      wake_target: ($plan.next // null), skipped: $plan.skipped}')"
}

# ------------------------------------------------------------------ state ---

# find_state_file <change> [<project-name>] -- state file for an apply
