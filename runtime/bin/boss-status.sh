#!/usr/bin/env bash
# boss-status -- part of the boss runtime, sourced by bin/boss after boss-lib.sh.
# Contains only function definitions; nothing runs when this file is sourced.

find_state_file() {
  local change="$1" project_name="${2:-}" norm files count f want
  norm="$(normalize_name "$change")"
  files="$(ls "$BOSS_APPLIES_DIR"/*-"$norm".json 2>/dev/null || true)"
  [ -n "$files" ] || die_json "no_apply" "no recorded apply for change '$change' (start one with 'boss dispatch $change')"
  count="$(printf '%s\n' "$files" | wc -l | tr -d ' ')"
  if [ "$count" -gt 1 ]; then
    if [ -n "$project_name" ]; then
      want="$(resolve_project "$project_name")" || exit 1
      for f in $files; do
        if [ "$(jq -r '.project' "$f")" = "$want" ]; then
          printf '%s' "$f"
          return 0
        fi
      done
    fi
    local names=""
    for f in $files; do names="$names $(jq -r '.project' "$f")"; done
    die_json "ambiguous_change" "change '$change' has applies in multiple projects:$names; pass --project to disambiguate"
  fi
  printf '%s' "$files"
}

# ----------------------------------------------------------------- status ---

# herdr_agent_of <target> -- the Herdr agent object as compact JSON, or empty
herdr_agent_of() {
  local out
  if out="$(herdr agent get "$1" 2>&1)"; then
    printf '%s' "$out" | jq -c '.result.agent // empty'
  fi
}

agent_state_of() {
  local obj
  obj="$(herdr_agent_of "$1")"
  if [ -n "$obj" ]; then
    printf '%s' "$obj" | jq -r '.agent_status // "unknown"'
  else
    printf 'no_agent'
  fi
}

status_one() {
  local change="$1" project_name="$2" json_only="$3"
  local state_file project agent pane_id tab_id workspace_id last_state last_state_at waiter_pid waiter_alive_flag
  local opencode_version permission_mode
  local worktree branch worktree_workspace merge_state merged merge_test kept review_root touches declared
  state_file="$(find_state_file "$change" "$project_name")" || exit 1
  project="$(jq -r '.project' "$state_file")"
  worktree="$(jq -r '.worktree // empty' "$state_file" 2>/dev/null || true)"
  branch="$(jq -r '.branch // empty' "$state_file" 2>/dev/null || true)"
  worktree_workspace="$(jq -r '.worktree_workspace // empty' "$state_file" 2>/dev/null || true)"
  merge_state="$(jq -r '.merge_state // "none"' "$state_file" 2>/dev/null || true)"
  merged="$(jq -r '.merged // false' "$state_file" 2>/dev/null || printf false)"
  merge_test="$(jq -r '.merge_test // "not_run"' "$state_file" 2>/dev/null || true)"
  kept="$(jq -r '.kept // false' "$state_file" 2>/dev/null || printf false)"
  touches="$(jq -c '.touches // []' "$state_file" 2>/dev/null || printf '[]')"
  declared="$(jq -r '.declared // false' "$state_file" 2>/dev/null || printf false)"
  review_root="${worktree:-$project}"
  agent="$(jq -r '.agent' "$state_file")"
  pane_id="$(jq -r '.pane_id' "$state_file")"
  tab_id="$(jq -r '.tab_id' "$state_file")"
  workspace_id="$(jq -r '.workspace_id' "$state_file")"
  last_state="$(jq -r '.last_state // ""' "$state_file")"
  last_state_at="$(jq -r '.last_state_at // ""' "$state_file")"
  opencode_version="$(jq -r '.opencode_version // empty' "$state_file")"
  permission_mode="$(jq -r '.permission_mode // empty' "$state_file")"
  waiter_pid="$(jq -r '.waiter_pid // empty' "$state_file")"
  waiter_alive_flag=false
  waiter_alive "$waiter_pid" && waiter_alive_flag=true
  local waiter_state
  if [ -z "$waiter_pid" ]; then
    waiter_state="none"
  elif [ "$waiter_alive_flag" = true ]; then
    waiter_state="alive"
  else
    waiter_state="dead"
  fi

  local herdr_agent agent_state pane_json
  herdr_agent="$(herdr_agent_of "$pane_id")"
  if [ -n "$herdr_agent" ]; then
    agent_state="$(printf '%s' "$herdr_agent" | jq -r '.agent_status // "unknown"')"
  else
    herdr_agent="null"
    agent_state="no_agent"
  fi
  pane_json="$(jq -nc --argjson a "$herdr_agent" --arg p "$pane_id" --arg t "$tab_id" --arg w "$workspace_id" \
    '{pane_id: ($a.pane_id // $p), tab_id: ($a.tab_id // $t), workspace_id: ($a.workspace_id // $w), cwd: ($a.cwd // null), focused: ($a.focused // null)}')"

  local tasks_json tasks_open tasks_done tasks_total tasks_path
  tasks_path="$(tasks_file_for "$review_root" "$change")"
  if [ -n "$tasks_path" ]; then
    tasks_open="$(grep -c '^[[:space:]]*- \[ \]' "$tasks_path" || true)"
    tasks_done="$(grep -c '^[[:space:]]*- \[x\]' "$tasks_path" || true)"
    tasks_total=$((tasks_open + tasks_done))
    tasks_json="$(jq -nc --argjson o "$tasks_open" --argjson d "$tasks_done" --argjson t "$tasks_total" '{missing: false, open: $o, done: $d, total: $t}')"
  else
    tasks_json='{"missing":true,"open":null,"done":null,"total":null}'
  fi

  local changed_files diff_stat
  changed_files="$(git -C "$review_root" status --short 2>/dev/null || true)"
  diff_stat="$(git -C "$review_root" diff --stat 2>/dev/null || true)"

  local base_head commits diff_stat_range summary
  base_head="$(git_range_base "$review_root" "$(jq -r '.base_head // empty' "$state_file")")"
  commits=""
  diff_stat_range=""
  if [ -n "$base_head" ]; then
    commits="$(git -C "$review_root" log --oneline "$base_head..HEAD" 2>/dev/null || true)"
    diff_stat_range="$(git -C "$review_root" diff --stat "$base_head..HEAD" 2>/dev/null || true)"
  fi
  summary="$(jq -r '.summary // empty' "$state_file")"
  [ -n "$summary" ] || summary="$(last_event_field "$(events_file_for "$project" "$change")" summary summary)"

  local inbox_pending
  inbox_pending="$(inbox_count "$project" "$change")"

  local dialog=""
  if [ "$agent_state" = "blocked" ]; then
    dialog="$(herdr agent read "$pane_id" --source visible 2>/dev/null || true)"
  fi

  local boss_wakeup boss boss_pane boss_reachable boss_name_ok boss_state
  boss_wakeup="$(boss_wakeup_check "$workspace_id" "$(jq -r '.boss // empty' "$state_file")")"
  boss="$(printf '%s' "$boss_wakeup" | jq -r '.boss // ""')"
  boss_pane="$(printf '%s' "$boss_wakeup" | jq -r '.boss_pane // ""')"
  boss_reachable="$(printf '%s' "$boss_wakeup" | jq -r '.boss_reachable')"
  boss_name_ok="$(printf '%s' "$boss_wakeup" | jq -r '.boss_name_ok')"
  boss_state="$(printf '%s' "$boss_wakeup" | jq -r '.state')"

  local wake_plan wake_target last_wake events_file
  wake_plan="$(boss_wake_plan "$state_file")"
  wake_target="$(printf '%s' "$wake_plan" | jq -c '.next // null')"
  events_file="$(events_file_for "$project" "$change")"
  last_wake="$(last_wake_event "$events_file")"

  local lessons_global_json lessons_project_json gfile pfile
  lessons_global_json="[]"
  lessons_project_json="[]"
  gfile="$(lessons_global_path 2>/dev/null || true)"
  pfile="$(lessons_project_path "$project" 2>/dev/null || true)"
  [ -n "$gfile" ] && lessons_global_json="$(lessons_active_json "$gfile")"
  [ -n "$pfile" ] && lessons_project_json="$(lessons_active_json "$pfile")"

  local mission_st mission_state mission_human mission_external
  mission_st="$(mission_done_state "$project" "$change")"
  mission_state="$(printf '%s' "$mission_st" | jq -r '.state')"
  mission_human="$(printf '%s' "$mission_st" | jq -c '.human_tasks // []')"
  mission_external="$(printf '%s' "$mission_st" | jq -c '.external_tasks // []')"

  local json
  json="$(jq -n \
    --arg change "$change" --arg project "$project" --arg agent "$agent" \
    --arg agent_state "$agent_state" --arg pane_id "$pane_id" --arg tab_id "$tab_id" \
    --arg workspace_id "$workspace_id" --arg last_state "$last_state" --arg last_state_at "$last_state_at" \
    --argjson tasks "$tasks_json" --arg dialog "$dialog" \
    --argjson herdr_agent "$herdr_agent" --argjson pane "$pane_json" --arg note "$(jq -r '.note // ""' "$state_file")" \
    --arg waiter_pid "$waiter_pid" --argjson waiter_alive "$waiter_alive_flag" \
    --arg waiter "$waiter_state" \
    --argjson inbox_pending "$inbox_pending" \
    --argjson changed_files "$(printf '%s' "$changed_files" | jq -Rsc 'split("\n") | map(select(length > 0))')" \
    --argjson diff_stat "$(printf '%s' "$diff_stat" | jq -Rsc 'split("\n") | map(select(length > 0))')" \
    --arg base_head "$base_head" \
    --argjson commits "$(printf '%s' "$commits" | jq -Rsc 'split("\n") | map(select(length > 0))')" \
    --argjson diff_stat_range "$(printf '%s' "$diff_stat_range" | jq -Rsc 'split("\n") | map(select(length > 0))')" \
    --arg summary "$summary" \
    --argjson lessons_global "$lessons_global_json" --argjson lessons_project "$lessons_project_json" \
    --argjson wake_plan "$wake_plan" --argjson wake_target "$wake_target" \
    --argjson last_wake "$last_wake" \
    --arg boss "$boss" --arg boss_pane "$boss_pane" \
    --argjson boss_reachable "$boss_reachable" --argjson boss_name_ok "$boss_name_ok" \
    --arg state "$mission_state" --argjson human_tasks "$mission_human" \
    --argjson external_tasks "$mission_external" \
    --arg opencode_version "$opencode_version" --arg permission_mode "$permission_mode" \
    --arg worktree "$worktree" --arg branch "$branch" --arg worktree_workspace "$worktree_workspace" \
    --arg merge_state "$merge_state" --argjson merged "$merged" --arg merge_test "$merge_test" \
    --argjson kept "$kept" --argjson touches "$touches" --argjson declared "$declared" \
    '{change: $change, project: $project, agent: $agent, agent_state: $agent_state, agent_status: $agent_state, pane_id: $pane_id, tab_id: $tab_id, workspace_id: $workspace_id, worktree: (if $worktree == "" then null else $worktree end), branch: (if $branch == "" then null else $branch end), worktree_workspace: (if $worktree_workspace == "" then null else $worktree_workspace end), merge_state: $merge_state, merged: $merged, merge_test: $merge_test, kept: $kept, touches: $touches, declared: $declared, pane: $pane, herdr_agent: $herdr_agent, waiter_pid: (if $waiter_pid == "" then null else ($waiter_pid | tonumber? // $waiter_pid) end), waiter_alive: $waiter_alive, waiter: $waiter, inbox_pending: $inbox_pending, note: (if $note == "" then null else $note end), summary: (if $summary == "" then null else $summary end), last_state: $last_state, last_state_at: $last_state_at, tasks: $tasks, state: $state, human_tasks: $human_tasks, external_tasks: $external_tasks, opencode_version: (if $opencode_version == "" then null else ($opencode_version | tonumber? // null) end), permission_mode: (if $permission_mode == "" then null else $permission_mode end), lessons: {global: $lessons_global, project: $lessons_project}, git: {base_head: (if $base_head == "" then null else $base_head end), commits: $commits, diff_stat_range: $diff_stat_range, changed_files: $changed_files, diff_stat: $diff_stat}, blocked_dialog: (if $dialog == "" then null else $dialog end), boss: (if $boss == "" then null else $boss end), boss_pane: (if $boss_pane == "" then null else $boss_pane end), boss_reachable: $boss_reachable, boss_name_ok: $boss_name_ok, wake_plan: $wake_plan, wake_target: $wake_target, last_wake: $last_wake}')"

  if [ "$json_only" -eq 1 ]; then
    printf '%s\n' "$json"
    return 0
  fi

  printf 'change: %s\n' "$change"
  printf 'project: %s\n' "$project"
  if [ -n "$worktree" ]; then
    printf 'worktree: %s\n' "$worktree"
    printf 'branch: %s\n' "${branch:-unknown}"
  fi
  printf 'merge: %s (merged: %s, test: %s)\n' "$merge_state" "$merged" "$merge_test"
  if [ "$declared" = "true" ]; then
    printf 'locks: %s\n' "$(printf '%s' "$touches" | jq -r 'if length == 0 then "none" else join(", ") end')"
  else
    printf 'locks: undeclared (exclusive)\n'
  fi
  if [ -n "$opencode_version" ]; then
    printf 'opencode: v%s (permission %s)\n' "$opencode_version" "${permission_mode:-unknown}"
  elif [ -n "$permission_mode" ]; then
    printf 'permission: %s (OpenCode version unknown)\n' "$permission_mode"
  fi
  printf 'agent: %s (%s)\n' "$agent" "$agent_state"
  printf 'tab/pane: %s / %s (workspace %s)\n' "$tab_id" "$pane_id" "$workspace_id"
  case "$waiter_state" in
    alive) printf 'waiter: alive (pid %s)\n' "$waiter_pid" ;;
    dead)  printf 'waiter: DEAD -- the apply is not watched; boss wait %s\n' "$change" ;;
    none)  printf 'waiter: none -- boss wait %s\n' "$change" ;;
  esac
  if [ "$inbox_pending" -gt 0 ]; then
    printf 'inbox: %s pending -- boss inbox\n' "$inbox_pending"
  fi
  if [ "$boss_state" = "name_stale" ]; then
    printf 'warning: workspace boss %s on pane %s lost its Herdr name; the waiter may not wake it (run boss claim there to heal it)\n' "${boss:-unknown}" "${boss_pane:-unknown}"
  elif [ "$boss_state" = "not_reachable" ]; then
    printf 'warning: workspace boss %s on pane %s is not reachable and no fallback boss was found\n' "${boss:-unknown}" "${boss_pane:-unknown}"
  fi
  if [ "$(printf '%s' "$wake_target" | jq -r 'if . == null then "none" else "ok" end')" = "none" ]; then
    printf 'wake next: no safe target\n'
  else
    printf 'wake next: %s (pane %s, workspace %s, source %s)\n' \
      "$(printf '%s' "$wake_target" | jq -r '.target')" \
      "$(printf '%s' "$wake_target" | jq -r '.pane // "-"')" \
      "$(printf '%s' "$wake_target" | jq -r '.workspace // "-"')" \
      "$(printf '%s' "$wake_target" | jq -r '.source')"
  fi
  printf '%s' "$wake_plan" | jq -r '.skipped[]? | "wake skipped: \(.target) (\(.source), reason: \(.reason))"'
  if [ "$(printf '%s' "$last_wake" | jq -r 'if . == null then "none" else "ok" end')" = "none" ]; then
    printf 'last wake: none\n'
  elif [ "$(printf '%s' "$last_wake" | jq -r '.event')" = "wake" ]; then
    printf 'last wake: %s at %s (pane %s, workspace %s, state %s)\n' \
      "$(printf '%s' "$last_wake" | jq -r '.target // "-"')" \
      "$(printf '%s' "$last_wake" | jq -r '.t // "-"')" \
      "$(printf '%s' "$last_wake" | jq -r '.pane // "-"')" \
      "$(printf '%s' "$last_wake" | jq -r '.workspace // "-"')" \
      "$(printf '%s' "$last_wake" | jq -r '.state // "-"')"
  else
    printf 'last wake: FAILED at %s (reason: %s, tried: %s)\n' \
      "$(printf '%s' "$last_wake" | jq -r '.t // "-"')" \
      "$(printf '%s' "$last_wake" | jq -r '.reason // "unknown"')" \
      "$(printf '%s' "$last_wake" | jq -r '(.tried // []) | join(", ") | if . == "" then "-" else . end')"
  fi
  if [ "$(printf '%s' "$tasks_json" | jq -r '.missing')" = "true" ]; then
    printf 'tasks: missing (no tasks.md)\n'
  else
    printf 'tasks: %s open, %s done\n' "$(printf '%s' "$tasks_json" | jq -r '.open')" "$(printf '%s' "$tasks_json" | jq -r '.done')"
  fi
  printf 'state: %s\n' "$mission_state"
  if [ "$mission_state" = "waiting_human" ]; then
    printf 'waiting for human tasks:\n'
    printf '%s' "$mission_human" | jq -r '.[] | "- \(.text) [criterion: \(.criterion)]"'
    if [ "$(printf '%s' "$mission_external" | jq 'length')" -gt 0 ]; then
      printf 'waiting for external verification:\n'
      printf '%s' "$mission_external" | jq -r '.[] | "- \(.text) [criterion: \(.criterion)]"'
    fi
  fi
  if [ -n "$summary" ]; then
    printf 'summary (last agent output):\n%s\n' "$summary"
  fi
  if [ -n "$commits" ]; then
    printf 'git log --oneline %s..HEAD:\n%s\n' "$base_head" "$commits"
  fi
  if [ -n "$changed_files" ]; then
    printf 'git status --short:\n%s\n' "$changed_files"
  else
    printf 'git: working tree clean\n'
  fi
  if [ -n "$diff_stat" ]; then
    printf 'git diff --stat:\n%s\n' "$diff_stat"
  fi
  if [ "$(printf '%s' "$lessons_global_json" | jq 'length')" -gt 0 ]; then
    printf 'lessons (global):\n%s\n' "$(printf '%s' "$lessons_global_json" | jq -r 'join("\n")')"
  fi
  if [ "$(printf '%s' "$lessons_project_json" | jq 'length')" -gt 0 ]; then
    printf 'lessons (project):\n%s\n' "$(printf '%s' "$lessons_project_json" | jq -r 'join("\n")')"
  fi
  if [ "$agent_state" = "blocked" ] && [ -n "$dialog" ]; then
    printf 'blocked dialog:\n%s\n' "$dialog"
  fi
  printf '%s\n' "$json"
}

status_all() {
  local json_only="$1"
  local files state_file agent agent_state waiter_pid waiter_alive_flag inbox_pending e json="[]" idx mission_state
  local opencode_version permission_mode
  files="$(ls "$BOSS_APPLIES_DIR"/*.json 2>/dev/null || true)"
  if [ "$json_only" -eq 0 ] && [ -z "$files" ]; then
    printf 'no applies recorded\n'
  fi
  idx=0
  for state_file in $files; do
    idx=$((idx + 1))
    agent="$(jq -r '.agent' "$state_file")"
    agent_state="$(agent_state_of "$agent")"
    waiter_pid="$(jq -r '.waiter_pid // empty' "$state_file")"
    waiter_alive_flag=false
    waiter_alive "$waiter_pid" && waiter_alive_flag=true
    inbox_pending="$(inbox_count "$(jq -r '.project' "$state_file")" "$(jq -r '.change' "$state_file")")"
    mission_state="$(mission_done_state "$(jq -r '.project' "$state_file")" "$(jq -r '.change' "$state_file")" | jq -r '.state')"
    opencode_version="$(jq -r '.opencode_version // empty' "$state_file")"
    permission_mode="$(jq -r '.permission_mode // empty' "$state_file")"
    e="$(jq -c --arg s "$agent_state" --argjson wa "$waiter_alive_flag" --argjson ip "$inbox_pending" --arg ms "$mission_state" \
      --arg ov "$opencode_version" --arg pm "$permission_mode" \
      '. + {agent_state: $s, waiter_alive: $wa, inbox_pending: $ip, waiter_pid: (.waiter_pid // null)} | {change, project, agent, agent_state, waiter_pid, waiter_alive, inbox_pending, pane_id, tab_id, workspace_id, worktree: (.worktree // null), branch: (.branch // null), merge_state: (.merge_state // "none"), merged: (.merged // false), merge_test: (.merge_test // "not_run"), kept: (.kept // false), touches: (.touches // []), declared: (.declared // false), last_state, last_state_at, state: $ms, opencode_version: (if $ov == "" then null else ($ov | tonumber? // null) end), permission_mode: (if $pm == "" then null else $pm end)}' "$state_file")"
    json="$(printf '%s' "$json" | jq -c --argjson e "$e" '. + [$e]')"
    if [ "$json_only" -eq 0 ]; then
      if [ "$mission_state" = "waiting_human" ]; then
        printf '%s) %s in %s: waiting_human (parked)\n' "$idx" "$(jq -r '.change' "$state_file")" "$(jq -r '.project' "$state_file")"
      elif [ "$waiter_alive_flag" = true ]; then
        printf '%s) %s in %s: %s (%s), waiter: alive (pid %s)\n' "$idx" "$(jq -r '.change' "$state_file")" "$(jq -r '.project' "$state_file")" "$agent" "$agent_state" "$waiter_pid"
      else
        printf '%s) %s in %s: %s (%s), waiter: DEAD\n' "$idx" "$(jq -r '.change' "$state_file")" "$(jq -r '.project' "$state_file")" "$agent" "$agent_state"
      fi
      if [ "$(jq -r '.worktree // empty' "$state_file")" != "" ]; then
        printf '   worktree: %s (branch %s, merge %s)\n' \
          "$(jq -r '.worktree' "$state_file")" \
          "$(jq -r '.branch // "unknown"' "$state_file")" \
          "$(jq -r '.merge_state // "none"' "$state_file")"
      fi
      if [ "$(jq -r '.declared // false' "$state_file")" = "true" ]; then
        printf '   locks: %s\n' "$(jq -r '(.touches // []) | if length == 0 then "none" else join(", ") end' "$state_file")"
      else
        printf '   locks: undeclared (exclusive)\n'
      fi
      if [ -n "$opencode_version" ]; then
        printf '   opencode: v%s, permission: %s\n' "$opencode_version" "${permission_mode:-unknown}"
      elif [ -n "$permission_mode" ]; then
        printf '   permission: %s (OpenCode version unknown)\n' "$permission_mode"
      fi
      if [ "$inbox_pending" -gt 0 ]; then
        printf '   inbox: %s pending -- boss inbox\n' "$inbox_pending"
      fi
    fi
  done
  printf '%s\n' "$json"
}

cmd_status() {
  ensure_boss_claim status
  ensure_config
  local json_only=0 change="" project_name="" arg
  while [ $# -gt 0 ]; do
    arg="$1"; shift
    case "$arg" in
      --json) json_only=1 ;;
      --project) project_name="${1:-}"; shift ;;
      -h|--help) usage ;;
      --*) usage_error "unknown option: $arg" ;;
      *) if [ -z "$change" ]; then change="$arg"; else usage_error "unexpected argument: $arg"; fi ;;
    esac
  done
  if [ -z "$change" ]; then
    status_all "$json_only"
  else
    status_one "$change" "$project_name" "$json_only"
  fi
}

# ------------------------------------------------------------------ review ---

# review_locate <change> [<project-name>] -- locate the apply's sources without
# dying when only an event log is left. Prints
# "<project>\t<events-file>\t<state-file>\t<worktree>". The state file comes
# before the worktree so a finished apply can leave both trailing fields empty;
# a legacy state without a worktree prints an empty fourth field. Dies with
# no_apply when there is nothing to review.
