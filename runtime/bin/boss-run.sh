#!/usr/bin/env bash
# boss-run -- part of the boss runtime, sourced by bin/boss after boss-lib.sh.
# Contains only function definitions; nothing runs when this file is sourced.

ensure_waiter() {
  local state_file="$1" pid
  pid="$(jq -r '.waiter_pid // empty' "$state_file")"
  if waiter_alive "$pid"; then
    printf '%s running\n' "$pid"
    return 0
  fi
  detach_waiter "$state_file"
  # The waiter records its pid in the state file shortly after start.
  local _
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pid="$(jq -r '.waiter_pid // empty' "$state_file")"
    waiter_alive "$pid" && break
    sleep 0.2
  done
  printf '%s started\n' "${pid:-unknown}"
}

cmd_wait() {
  ensure_boss_claim wait
  ensure_config
  local change="" project_name="" all=0 all_projects=0 arg
  while [ $# -gt 0 ]; do
    arg="$1"; shift
    case "$arg" in
      --all) all=1 ;;
      --all-projects) all_projects=1 ;;
      --project) project_name="${1:-}"; shift ;;
      -h|--help) usage ;;
      --*) usage_error "unknown option: $arg" ;;
      *) if [ -z "$change" ]; then change="$arg"; else usage_error "unexpected argument: $arg"; fi ;;
    esac
  done
  if [ "$all" -eq 1 ]; then
    [ -z "$change" ] || usage_error "boss wait --all takes no change"
    [ "$all_projects" -eq 1 ] && [ -n "$project_name" ] \
      && usage_error "boss wait --all takes either --project or --all-projects, not both"
    local scope_project="" scope_ws=""
    if [ "$all_projects" -eq 0 ]; then
      if [ -n "$project_name" ]; then
        scope_project="$(resolve_project "$project_name")" || exit 1
      else
        scope_project="$(find_openspec_root "$PWD" || true)"
        [ -n "$scope_project" ] || scope_ws="${HERDR_WORKSPACE_ID:-}"
      fi
    fi
    cmd_wait_all "$scope_project" "$scope_ws" "$all_projects"
    return 0
  fi
  [ -n "$change" ] || usage_error "usage: boss wait <change> [--project <name|path>] | boss wait --all [--project <name|path> | --all-projects]"

  local state_file agent pane_id res
  state_file="$(find_state_file "$change" "$project_name")" || exit 1
  agent="$(jq -r '.agent' "$state_file")"
  pane_id="$(jq -r '.pane_id' "$state_file")"
  if [ "$(jq -r '.parked // false' "$state_file" 2>/dev/null || printf false)" = "true" ]; then
    printf '%s\n' "$(jq -n --arg change "$change" --arg agent "$agent" \
      '{change: $change, agent: $agent, waiter_pid: null, status: "parked"}')"
    return 0
  fi
  herdr agent get "$pane_id" >/dev/null 2>&1 || die_json "agent_gone" "agent '$agent' no longer exists; start a new apply with 'boss dispatch $change'"
  res="$(ensure_waiter "$state_file")"
  log "wait: change=$change agent=$agent waiter=$res"
  printf '%s\n' "$(jq -n --arg change "$change" --arg agent "$agent" \
    --arg pid "${res%% *}" --arg status "${res##* }" \
    '{change: $change, agent: $agent, waiter_pid: ($pid | tonumber? // $pid), status: $status}')"
}

# cmd_wait_all -- re-arm every open apply after e.g. a reboot: for each state
# file in $BOSS_APPLIES_DIR report 'running' (a living waiter), 'started' (the
# apply agent lives and a waiter was just started) or 'agent_gone' (the apply
# agent is gone, so no waiter is started). Prints a JSON list, one object per
# change with change/agent/waiter_pid/status.
cmd_wait_all() {
  local scope_project="${1:-}" scope_ws="${2:-}" all_projects="${3:-0}"
  local files state_file change agent pane_id pid status res json="[]"
  if [ "$all_projects" -ne 1 ] && [ -z "$scope_project" ] && [ -z "$scope_ws" ]; then
    log "wait --all: cannot determine project or workspace; pass --all-projects for a global pass"
    printf '[]\n'
    return 0
  fi
  files="$(ls "$BOSS_APPLIES_DIR"/*.json 2>/dev/null || true)"
  if [ -z "$files" ]; then
    log "wait --all: no open applies"
  fi
  for state_file in $files; do
    if [ "$all_projects" -ne 1 ]; then
      if [ -n "$scope_project" ]; then
        [ "$(jq -r '.project // empty' "$state_file" 2>/dev/null || true)" = "$scope_project" ] || continue
      elif [ -n "$scope_ws" ]; then
        [ "$(jq -r '.workspace_id // empty' "$state_file" 2>/dev/null || true)" = "$scope_ws" ] || continue
      fi
    fi
    change="$(jq -r '.change // empty' "$state_file")"
    agent="$(jq -r '.agent // empty' "$state_file")"
    pane_id="$(jq -r '.pane_id // empty' "$state_file")"
    pid="$(jq -r '.waiter_pid // empty' "$state_file")"
    if [ "$(jq -r '.parked // false' "$state_file" 2>/dev/null || printf false)" = "true" ]; then
      status="parked"
      pid=""
    elif waiter_alive "$pid"; then
      status="running"
    elif [ -n "$pane_id" ] && herdr agent get "$pane_id" >/dev/null 2>&1; then
      res="$(ensure_waiter "$state_file")"
      pid="${res%% *}"
      status="started"
    else
      status="agent_gone"
      pid=""
    fi
    log "wait --all: change=$change agent=$agent waiter=${pid:-none} status=$status"
    json="$(printf '%s' "$json" | jq -c \
      --arg change "$change" --arg agent "$agent" --arg pid "$pid" --arg status "$status" \
      '. + [{change: $change, agent: $agent, waiter_pid: (if $pid == "" then null else ($pid | tonumber? // $pid) end), status: $status}]')"
  done
  printf '%s\n' "$json"
}

# ------------------------------------------------------------------ inbox ---

# cmd_inbox [--project <name|path>] [--json] [--ack <id>] -- list the durable
# wake items and, with --ack, drop one. Items whose apply state file is gone
# are dropped while listing, so a finished apply leaves nothing behind.
cmd_inbox() {
  ensure_config
  local project_name="" want_json=0 ack="" arg
  while [ $# -gt 0 ]; do
    arg="$1"; shift
    case "$arg" in
      --project) project_name="${1:-}"; shift ;;
      --json) want_json=1 ;;
      --ack) ack="${1:-}"; shift ;;
      -h|--help) usage ;;
      --*) usage_error "unknown option: $arg" ;;
      *) usage_error "unexpected argument: $arg" ;;
    esac
  done

  local acked="null"
  if [ -n "$ack" ]; then
    local ack_path
    ack_path="$(inbox_item_path "$ack")" || usage_error "invalid inbox id: $ack"
    if [ -f "$ack_path" ]; then
      rm -f "$ack_path"
      acked=true
    else
      acked=false
    fi
  fi

  local filter_project=""
  if [ -n "$project_name" ]; then
    filter_project="$(resolve_project "$project_name")" || exit 1
  fi

  local json="[]" f item change project
  for f in "$BOSS_INBOX_DIR"/*.json; do
    [ -f "$f" ] || continue
    change="$(jq -r '.change // empty' "$f" 2>/dev/null || true)"
    project="$(jq -r '.project // empty' "$f" 2>/dev/null || true)"
    if [ -z "$change" ] || [ -z "$project" ]; then
      rm -f "$f"
      continue
    fi
    # Drop an item whose apply is gone (finished).
    if [ ! -f "$(state_file_for "$project" "$change")" ]; then
      rm -f "$f"
      continue
    fi
    if [ -n "$filter_project" ] && [ "$project" != "$filter_project" ]; then
      continue
    fi
    item="$(jq -c '{id, ts, change, project, state, summary_at}' "$f" 2>/dev/null || true)"
    [ -n "$item" ] && json="$(printf '%s' "$json" | jq -c --argjson i "$item" '. + [$i]')"
  done

  if [ "$want_json" -eq 1 ]; then
    jq -nc --argjson items "$json" --argjson ack "$acked" \
      '{ack: $ack, pending: ($items | length), items: $items}'
    return 0
  fi
  if [ "$(printf '%s' "$json" | jq 'length')" -eq 0 ]; then
    printf 'inbox empty\n'
  else
    printf '%s' "$json" | jq -r '.[] | "\(.change) in \(.project): \(.state) (\(.ts)) -- boss status \(.change)"'
  fi
  return 0
}

# ---------------------------------------------------------------- journal ---

# cmd_journal [--project <name|path>] [--change <change>] [--tag <tag>] <text>
# -- append a dated entry to the project's decision journal. The journal is
# read by the human, never injected into an apply prompt.
cmd_journal() {
  ensure_config
  local project_name="" change="" tag="" text="" arg
  while [ $# -gt 0 ]; do
    arg="$1"; shift
    case "$arg" in
      --project) project_name="${1:-}"; shift ;;
      --change) change="${1:-}"; shift ;;
      --tag) tag="$(normalize_name "${1:-}")"; shift ;;
      -h|--help) usage ;;
      --*) usage_error "unknown option: $arg" ;;
      *) if [ -z "$text" ]; then text="$arg"; else text="$text $arg"; fi ;;
    esac
  done
  [ -n "$text" ] || usage_error "usage: boss journal [--project <name|path>] [--change <change>] [--tag <tag>] <text>"

  local project file clean
  project="$(resolve_project "$project_name")" || exit 1
  file="$(journal_project_path "$project")" || die_json "journal_path" "cannot resolve the journal path for $project"
  clean="$(one_line "$text")"
  journal_append "$file" "$clean" "$tag" \
    || die_json "journal_write" "cannot write the journal $file"

  printf '%s\n' "$(jq -n \
    --arg project "$project" --arg path "$file" --arg change "$change" --arg tag "$tag" \
    --arg text "$clean" --arg at "$(now_iso)" \
    '{project: $project, path: $path, change: (if $change == "" then null else $change end),
      tag: (if $tag == "" then null else $tag end), text: $text, at: $at, status: "journaled"}')"
}

# ----------------------------------------------------------------- doctor ---

# doctor_check_json <id> <status> <hint> -- one doctor check as compact JSON.
cmd_retrigger() {
  local change="" project_name="" note="" note_given=0 as_target="" arg
  while [ $# -gt 0 ]; do
    arg="$1"; shift
    case "$arg" in
      --project) project_name="${1:-}"; shift ;;
      --note) note="$(one_line "${1:-}")"; note_given=1; shift ;;
      --as) as_target="${1:-}"; shift ;;
      -h|--help) usage ;;
      --*) usage_error "unknown option: $arg" ;;
      *) if [ -z "$change" ]; then change="$arg"; else usage_error "unexpected argument: $arg"; fi ;;
    esac
  done
  [ -n "$change" ] || usage_error "usage: boss retrigger <change> [--project <name|path>] [--note <text>] [--as <pane|agent>]"
  boss_use_caller "$as_target"
  ensure_boss_claim retrigger
  ensure_config

  local state_file agent pane_id apply_cmd res project runner_yield lessons_block external_block commit_block
  state_file="$(find_state_file "$change" "$project_name")" || exit 1
  agent="$(jq -r '.agent' "$state_file")"
  pane_id="$(jq -r '.pane_id' "$state_file")"
  apply_cmd="$(jq -r '.apply_cmd' "$state_file")"
  project="$(jq -r '.project' "$state_file")"
  # A retrigger is the explicit resume after an interrupt; the next settle is
  # a normal completion again.
  if jq -e 'has("interrupted")' "$state_file" >/dev/null 2>&1; then
    local itmp
    itmp="$(mktemp)"
    if jq 'del(.interrupted, .interrupted_at, .interrupt_keys)' "$state_file" >"$itmp" 2>/dev/null; then
      mv "$itmp" "$state_file"
    else
      rm -f "$itmp"
    fi
  fi
  if jq -e 'has("yield")' "$state_file" >/dev/null 2>&1; then
    runner_yield="$(jq -r '.yield' "$state_file")"
  else
    # State files from before the yield field: derive it from the runner config.
    runner_yield="$(runner_yield_of "$(resolve_runner "$(jq -r '.runner // empty' "$state_file")")")"
  fi
  if jq -e 'has("lessons")' "$state_file" >/dev/null 2>&1; then
    # The dispatch froze the block in the state; resend exactly that.
    lessons_block="$(jq -r '.lessons // ""' "$state_file")"
  else
    # State files from before the lessons field: read the stores again.
    local rgfile rpfile
    rgfile="$(lessons_global_path 2>/dev/null || true)"
    rpfile="$(lessons_project_path "$project" 2>/dev/null || true)"
    lessons_block=""
    if [ -n "$rgfile" ] && [ -n "$rpfile" ]; then
      lessons_block="$(lessons_prompt_block "$rgfile" "$rpfile")" || lessons_block=""
    fi
  fi
  if jq -e 'has("external_block")' "$state_file" >/dev/null 2>&1; then
    external_block="$(jq -r '.external_block // ""' "$state_file")"
  else
    external_block="$(external_verify_prompt_block "$project" "$change")"
  fi
  if jq -e 'has("commit_block")' "$state_file" >/dev/null 2>&1; then
    commit_block="$(jq -r '.commit_block // ""' "$state_file")"
  else
    commit_block="$(runner_commit_block "$(jq -c --arg c "$(jq -r '.commit_policy // "explorer"' "$state_file")" '. + {commit: $c}' "$state_file")")"
  fi
  if [ "$note_given" -eq 1 ]; then
    write_state_field "$state_file" note "$note"
  else
    note="$(jq -r '.note // ""' "$state_file")"
  fi

  # State files from before the commit range: set the base, never move it.
  if [ -z "$(jq -r '.base_head // empty' "$state_file")" ]; then
    local base_head
    base_head="$(git -C "$project" rev-parse HEAD 2>/dev/null || true)"
    [ -n "$base_head" ] && write_state_field "$state_file" base_head "$base_head"
  fi

  if [ -z "$pane_id" ] || [ "$pane_id" = "null" ] || ! herdr agent get "$pane_id" >/dev/null 2>&1; then
    local retrigger_worktree retrigger_runner
    retrigger_worktree="$(jq -r '.worktree // empty' "$state_file" 2>/dev/null || true)"
    if [ -n "$retrigger_worktree" ]; then
      [ -d "$retrigger_worktree" ] \
        || die_json "worktree_missing" "the recorded worktree $retrigger_worktree for '$change' is missing; do not fall back to the base checkout"
      retrigger_runner="$(jq -r '.runner // empty' "$state_file")"
      retrigger_runner="$(resolve_runner "$retrigger_runner")" || exit 1
      log "retrigger: agent $agent is gone; starting a new agent in $retrigger_worktree"
      dispatch_change "$change" "$project" "$retrigger_runner" "$note" 1
      return 0
    fi
    die_json "agent_gone" "agent '$agent' no longer exists; start a new apply with 'boss dispatch $change'"
  fi

  # The waiter stays armed across turns; make sure one is alive before prompting.
  res="$(ensure_waiter "$state_file")"
  send_prompt "$pane_id" "$(compose_apply_prompt "$apply_cmd" "$note" "$lessons_block" "$external_block" "$commit_block" "$runner_yield")"
  log "retrigger: change=$change agent=$agent waiter=$res"

  append_event "$(events_file_for "$project" "$change")" retrigger \
    "$(jq -nc --arg c "$change" --arg p "$project" '{change: $c, project: $p}')" \
    || log "warning: could not record retrigger event"

  printf '%s\n' "$(jq -n \
    --arg change "$change" --arg project "$project" \
    --arg agent "$agent" --arg status "retriggered" \
    '{change: $change, project: $project, agent: $agent, status: $status}')"
}

# finish_run_test <project> <change> <command> <timeout-seconds> -- run the
# finish test gate on the base checkout and print compact JSON with the result,
# log path, timestamp, budget and a bounded output tail.
finish_run_test() {
  local project="$1" change="$2" cmd="$3" secs="$4" log result at tail
  log="$(test_log_file "$change" finish)"
  [ -n "$log" ] || log="/dev/null"
  result="$(test_gate_run "$project" "$cmd" "$secs" "$log")"
  at="$(now_iso)"
  tail="$(test_output_tail "$log" 40)"
  jq -nc --arg result "$result" --arg log "$log" --arg at "$at" \
    --argjson timeout_s "$secs" --arg tail "$tail" \
    '{result: $result, log: $log, at: $at, timeout_s: $timeout_s, tail: $tail}'
}

# finish_record_test <state-file> <merge-state> <merge-test> <gate-json> --
# record the test outcome, timestamp and captured output on the apply state.
finish_record_test() {
  local f="$1" ms="$2" mt="$3" gate="$4" tmp
  tmp="$(mktemp)"
  if jq --arg ms "$ms" --arg mt "$mt" \
      --arg at "$(printf '%s' "$gate" | jq -r '.at')" \
      --arg path "$(printf '%s' "$gate" | jq -r '.log')" \
      --arg tail "$(printf '%s' "$gate" | jq -r '.tail')" \
      '.merged = true | .merge_state = $ms | .merge_test = $mt
       | .merge_test_at = $at | .merge_test_output = {path: $path, tail: $tail}
       | .last_state_at = $at' "$f" >"$tmp" 2>/dev/null; then
    mv "$tmp" "$f"
  else
    rm -f "$tmp"
    return 1
  fi
}

# tasks_file_for <project> <change> -- active or archived tasks.md, or empty
finish_worktree() {
  local change="$1" project="$2" state_file="$3" worktree="$4" branch="$5"
  local commit_policy="$6" keep="$7" no_merge="$8" lesson_text="$9" lesson_scope="${10}"
  local tab_id waiter_pid base_head merge_state merged merge_test worktree_workspace
  tab_id="$(jq -r '.tab_id // empty' "$state_file")"
  waiter_pid="$(jq -r '.waiter_pid // empty' "$state_file")"
  worktree_workspace="$(jq -r '.worktree_workspace // empty' "$state_file")"
  base_head="$(jq -r '.base_head // empty' "$state_file")"
  merge_state="$(jq -r '.merge_state // "none"' "$state_file")"
  merged="$(jq -r '.merged // false' "$state_file")"
  merge_test="$(jq -r '.merge_test // "not_run"' "$state_file")"

  # The worktree must be clean: under explorer the Explorer has not committed
  # yet; under agent the apply was expected to commit its tested work.
  local wt_changed wt_paths
  wt_changed="$(git -C "$worktree" status --porcelain 2>/dev/null || true)"
  wt_paths="$(git_dirty_paths "$worktree" all)"
  if [ -n "$wt_changed" ]; then
    die_json "worktree_dirty" "the worktree $worktree still has uncommitted changes: $(printf '%s' "$wt_paths" | paste -sd ', ' -); commit them before finishing (commit policy: $commit_policy)"
  fi

  # A merge into a dirty base is worse than refusing.
  local base_paths
  base_paths="$(git_dirty_paths "$project" all)"
  if [ -n "$base_paths" ]; then
    die_json "base_dirty" "the base checkout $project has uncommitted changes: $(printf '%s' "$base_paths" | paste -sd ', ' -); commit or stash them before finishing"
  fi

  local already_merged=false
  git -C "$project" rev-parse --verify "$branch" >/dev/null 2>&1 || {
    git -C "$project" merge-base --is-ancestor "$branch" HEAD >/dev/null 2>&1 \
      && already_merged=true \
      || die_json "branch_missing" "the recorded branch '$branch' for '$change' does not exist in $project"
  }
  if git -C "$project" merge-base --is-ancestor "$branch" HEAD >/dev/null 2>&1; then
    already_merged=true
  fi

  # --no-merge is the manual path: close the agent, keep worktree and state.
  if [ "$no_merge" = "1" ]; then
    [ -n "$tab_id" ] && [ "$tab_id" != "null" ] && herdr tab close "$tab_id" >/dev/null 2>&1 || true
    kill_waiter "$waiter_pid" >/dev/null 2>&1 || true
    local nm_now tmp
    nm_now="$(now_iso)"
    tmp="$(mktemp)"
    if jq --arg t "$nm_now" \
        '.pane_id = null | .tab_id = null | .waiter_pid = null
         | .kept = true | .last_state = "detached" | .last_state_at = $t' \
        "$state_file" >"$tmp" 2>/dev/null; then
      mv "$tmp" "$state_file"
    else
      rm -f "$tmp"
      die_json "state_write" "cannot mark apply $change as detached"
    fi
    log "finish: --no-merge kept worktree $worktree and branch $branch for $change"
    printf '%s\n' "$(jq -n --arg change "$change" --arg project "$project" \
      --arg worktree "$worktree" --arg branch "$branch" --arg status "kept" \
      --arg merge_state "$merge_state" --argjson merged "$merged" --arg merge_test "$merge_test" \
      '{change: $change, project: $project, status: $status, no_merge: true,
        worktree: $worktree, branch: $branch, merge_state: $merge_state,
        merged: $merged, merge_test: $merge_test}')"
    return 0
  fi

  if [ "$already_merged" != true ]; then
    local base_now
    base_now="$(git -C "$project" rev-parse HEAD 2>/dev/null || true)"
    if [ -n "$base_head" ] && [ "$base_now" = "$base_head" ]; then
      git -C "$project" merge --ff-only "$branch" >/dev/null 2>&1 || true
    else
      git -C "$project" merge --no-ff --no-edit "$branch" >/dev/null 2>&1 || true
    fi
    if ! git -C "$project" merge-base --is-ancestor "$branch" HEAD >/dev/null 2>&1; then
      local conflicts
      conflicts="$(git -C "$project" diff --name-only --diff-filter=U 2>/dev/null || true)"
      git -C "$project" merge --abort >/dev/null 2>&1 || true
      write_state_field "$state_file" merge_state "conflict" >/dev/null 2>&1 || true
      die_json "merge_conflict" "merging '$branch' into $project conflicted: $(printf '%s' "$conflicts" | paste -sd ', ' -); the merge was aborted and the worktree and state were kept"
    fi
    merged=true
  else
    merged=true
  fi

  # Integration test on the merged base. 'not_run' passes, as in review.
  local test_cmd="" test_result="not_run" test_timeout=300 test_gate="" test_log=""
  test_cmd="$(config_test_command "$project")"
  [ -n "$test_cmd" ] || test_cmd="$(detect_test_command "$project")"
  if [ -n "$test_cmd" ] && ! command -v "${test_cmd%% *}" >/dev/null 2>&1; then
    log "test command '$test_cmd' not found in PATH; reporting not_run"
    test_cmd=""
  fi
  if [ -n "$test_cmd" ]; then
    test_timeout="$(config_test_timeout "$project")"
    test_gate="$(finish_run_test "$project" "$change" "$test_cmd" "$test_timeout")"
    test_result="$(printf '%s' "$test_gate" | jq -r '.result')"
    test_log="$(printf '%s' "$test_gate" | jq -r '.log')"
  fi

  local done_now tmp
  done_now="$(now_iso)"
  if [ "$test_result" = "timeout" ]; then
    finish_record_test "$state_file" "test_timeout" "timeout" "$test_gate" || true
    die_json "merge_test_timeout" "the change merged into $project but '$test_cmd' did not finish within ${test_timeout}s on the merged base (log: $(printf '%s' "$test_gate" | jq -r '.log')); raise [tests.<project>].timeout_s or BOSS_REVIEW_TEST_TIMEOUT_S and run boss finish again" \
      "$(printf '%s' "$test_gate" | jq -c --argjson timeout_s "$test_timeout" '{timeout_s: $timeout_s, log}')"
  fi
  if [ "$test_result" = "fail" ]; then
    finish_record_test "$state_file" "test_failed" "fail" "$test_gate" >/dev/null 2>&1 || true
    die_json "merge_test_failed" "the change merged into $project but '$test_cmd' failed on the merged base (log: $(printf '%s' "$test_gate" | jq -r '.log')); the state was kept so a second finish can retry after the fix"
  fi
  if [ -n "$test_cmd" ]; then
    merge_test="$test_result"
  else
    merge_test="not_run"
  fi

  if [ -n "$test_gate" ]; then
    finish_record_test "$state_file" "done" "$merge_test" "$test_gate" \
      || die_json "state_write" "cannot update state file $state_file"
  else
    tmp="$(mktemp)"
    if jq --arg t "$done_now" --arg ms "done" --arg mt "$merge_test" \
        '.merged = true | .merge_state = $ms | .merge_test = $mt | .last_state_at = $t' \
        "$state_file" >"$tmp" 2>/dev/null; then
      mv "$tmp" "$state_file"
    else
      rm -f "$tmp"
      die_json "state_write" "cannot update state file $state_file"
    fi
  fi

  # Snapshot the friction before the state file disappears.
  local ev retriggers blocked_count waiter_lost duration_s tasks_open started_at tasks_file archived=false
  ev="$(events_file_for "$project" "$change")"
  retriggers="$(event_count_since_dispatch "$ev" retrigger)"
  blocked_count="$(event_count_since_dispatch "$ev" blocked)"
  waiter_lost=false
  [ "$(event_count_since_dispatch "$ev" lost)" -gt 0 ] && waiter_lost=true
  started_at="$(jq -r '.started_at // ""' "$state_file")"
  duration_s=null
  if [ -n "$started_at" ]; then
    local started_epoch
    started_epoch="$(epoch_of_iso "$started_at")"
    [ -n "$started_epoch" ] && duration_s=$(( $(date +%s) - started_epoch ))
  fi
  tasks_open=null
  tasks_file="$(tasks_file_for "$worktree" "$change")"
  if [ -n "$tasks_file" ]; then
    tasks_open="$(grep -c '^[[:space:]]*- \[ \]' "$tasks_file" || true)"
  fi
  ls -d "$project"/openspec/changes/archive/*-"$change" >/dev/null 2>&1 && archived=true

  append_event "$ev" finish \
    "$(jq -nc --arg c "$change" --arg p "$project" --argjson a "$archived" --argjson o "$tasks_open" \
      '{change: $c, project: $p, archived: $a, tasks_open: $o}')" \
    || log "warning: could not record finish event"
  append_event "$ev" cycle \
    "$(jq -nc --arg c "$change" --arg p "$project" --arg started_at "$started_at" \
      --arg finished_at "$(now_iso)" --argjson duration_s "$duration_s" \
      --argjson retriggers "$retriggers" --argjson blocked_count "$blocked_count" \
      --argjson waiter_lost "$waiter_lost" --argjson tasks_open "$tasks_open" --argjson archived "$archived" \
      '{change: $c, project: $p, started_at: $started_at, finished_at: $finished_at, duration_s: $duration_s, retriggers: $retriggers, blocked_count: $blocked_count, waiter_lost: $waiter_lost, tasks_open: $tasks_open, archived: $archived}')" \
    || log "warning: could not record cycle event"

  [ -n "$tab_id" ] && [ "$tab_id" != "null" ] && herdr tab close "$tab_id" >/dev/null 2>&1 || true
  kill_waiter "$waiter_pid" >/dev/null 2>&1 || true

  local lesson_json
  lesson_json="$(record_finish_lesson "$project" "$lesson_text" "$lesson_scope")"

  if [ "$keep" = "1" ]; then
    tmp="$(mktemp)"
    if jq --arg t "$done_now" \
        '.kept = true | .pane_id = null | .tab_id = null | .waiter_pid = null
         | .last_state = "finished" | .last_state_at = $t' \
        "$state_file" >"$tmp" 2>/dev/null; then
      mv "$tmp" "$state_file"
    else
      rm -f "$tmp"
    fi
    log "finish: --keep-worktree kept $worktree and branch $branch for $change"
    printf '%s\n' "$(jq -n --arg change "$change" --arg project "$project" \
      --arg worktree "$worktree" --arg branch "$branch" --arg status "kept" \
      --argjson archived "$archived" --argjson lesson "$lesson_json" \
      --arg merge_state "$merge_state" --arg merge_test "$merge_test" \
      --argjson test_timeout "$test_timeout" --arg test_log "$test_log" \
      '{change: $change, project: $project, status: $status, kept: true,
        worktree: $worktree, branch: $branch, merge_state: "done",
        merged: true, merge_test: $merge_test, test_timeout: $test_timeout,
        test_log: (if $test_log == "" then null else $test_log end),
        archived: $archived, lesson: $lesson}')"
    return 0
  fi

  # Cleanup on green: remove the worktree, delete the branch and the state.
  herdr_worktree_remove "$project" "$worktree" "$worktree_workspace"
  git -C "$project" worktree remove --force "$worktree" >/dev/null 2>&1 || true
  git -C "$project" worktree prune >/dev/null 2>&1 || true
  git -C "$project" branch -D "$branch" >/dev/null 2>&1 || true
  rm -rf "$worktree" 2>/dev/null || true
  rmdir "$(dirname "$worktree")" 2>/dev/null || true
  rm -f "$state_file"
  inbox_remove "$project" "$change"

  log "finish: change=$change project=$project worktree=$worktree branch=$branch removed"
  printf '%s\n' "$(jq -n --arg change "$change" --arg project "$project" \
    --arg worktree "$worktree" --arg branch "$branch" --arg status "finished" \
    --arg json_merge_state "done" --arg merge_test "$merge_test" \
    --argjson test_timeout "$test_timeout" --arg test_log "$test_log" \
    --argjson archived "$archived" --argjson lesson "$lesson_json" \
    '{change: $change, project: $project, status: $status,
      worktree: $worktree, branch: $branch, removed: true,
      merge_state: $json_merge_state, merged: true, merge_test: $merge_test,
      test_timeout: $test_timeout,
      test_log: (if $test_log == "" then null else $test_log end),
      archived: $archived, lesson: $lesson,
      working_tree_warning: false, changed_files: []}')"
}

# ------------------------------------------------------------------ finish ---

cmd_finish() {
  local change="" project_name="" force=0 lesson_text="" lesson_scope="project" as_target="" arg
  local keep_worktree=0 no_merge=0
  while [ $# -gt 0 ]; do
    arg="$1"; shift
    case "$arg" in
      --project) project_name="${1:-}"; shift ;;
      --force) force=1 ;;
      --keep-worktree) keep_worktree=1 ;;
      --no-merge) no_merge=1 ;;
      --lesson) lesson_text="$(one_line "${1:-}")"; shift ;;
      --lesson-scope) lesson_scope="${1:-}"; shift ;;
      --as) as_target="${1:-}"; shift ;;
      -h|--help) usage ;;
      --*) usage_error "unknown option: $arg" ;;
      *) if [ -z "$change" ]; then change="$arg"; else usage_error "unexpected argument: $arg"; fi ;;
    esac
  done
  [ -n "$change" ] || usage_error "usage: boss finish <change> [--project <name|path>] [--force] [--keep-worktree] [--no-merge] [--lesson <text>] [--lesson-scope project|global] [--as <pane|agent>]"
  boss_use_caller "$as_target"
  ensure_boss_claim finish
  ensure_config
  case "$lesson_scope" in
    project|global) ;;
    *) usage_error "--lesson-scope must be project or global" ;;
  esac

  local state_file project tab_id pane_id waiter_pid archived=false agent_state
  local commit_policy working_tree_warning=false changed_files=""
  state_file="$(find_state_file "$change" "$project_name")" || exit 1
  project="$(jq -r '.project' "$state_file")"
  tab_id="$(jq -r '.tab_id' "$state_file")"
  pane_id="$(jq -r '.pane_id' "$state_file")"
  waiter_pid="$(jq -r '.waiter_pid // empty' "$state_file")"
  commit_policy="$(state_commit_policy "$state_file")"
  changed_files="$(git -C "$project" status --short 2>/dev/null || true)"
  if [ "$commit_policy" = "explorer" ] && [ -n "$changed_files" ]; then
    working_tree_warning=true
    log "warning: explorer commit policy expects a clean reviewed tree, but $project has uncommitted changes; commit the reviewed change paths before finishing"
  fi
  if ls -d "$project"/openspec/changes/archive/*-"$change" >/dev/null 2>&1; then
    archived=true
  fi

  # Finishing only ends the apply session; archiving stays a separate step.
  # The one thing worth guarding is an agent that is still working.
  agent_state="$(agent_state_of "$pane_id")"
  if [ "$force" -ne 1 ] && [ "$agent_state" = "working" ]; then
    die_json "agent_working" "apply agent for '$change' is still working; wait for it (boss wait $change) or use --force"
  fi

  local finish_worktree_path finish_branch
  finish_worktree_path="$(jq -r '.worktree // empty' "$state_file" 2>/dev/null || true)"
  finish_branch="$(jq -r '.branch // empty' "$state_file" 2>/dev/null || true)"
  if [ -n "$finish_worktree_path" ]; then
    finish_worktree "$change" "$project" "$state_file" "$finish_worktree_path" \
      "${finish_branch:-$(worktree_branch_for "$change")}" "$commit_policy" \
      "$keep_worktree" "$no_merge" "$lesson_text" "$lesson_scope"
    return 0
  fi

  if [ -n "$tab_id" ] && [ "$tab_id" != "null" ]; then
    if herdr tab close "$tab_id" >/dev/null 2>&1; then
      log "finish: closed tab $tab_id"
    else
      log "finish: tab $tab_id already gone"
    fi
  fi
  kill_waiter "$waiter_pid"

  # The base-checkout path has no merge step, but it runs the same test gate so
  # a serial apply cannot be finished with a red or timed-out suite either.
  local test_cmd="" test_result="not_run" test_timeout=300 test_gate="" test_log="" merge_test="not_run"
  test_cmd="$(config_test_command "$project")"
  [ -n "$test_cmd" ] || test_cmd="$(detect_test_command "$project")"
  if [ -n "$test_cmd" ] && ! command -v "${test_cmd%% *}" >/dev/null 2>&1; then
    log "test command '$test_cmd' not found in PATH; reporting not_run"
    test_cmd=""
  fi
  if [ -n "$test_cmd" ]; then
    test_timeout="$(config_test_timeout "$project")"
    test_gate="$(finish_run_test "$project" "$change" "$test_cmd" "$test_timeout")"
    test_result="$(printf '%s' "$test_gate" | jq -r '.result')"
    test_log="$(printf '%s' "$test_gate" | jq -r '.log')"
    merge_test="$test_result"
  fi
  if [ "$test_result" = "timeout" ]; then
    finish_record_test "$state_file" "test_timeout" "timeout" "$test_gate" || true
    die_json "merge_test_timeout" "the base checkout $project did not finish '$test_cmd' within ${test_timeout}s (log: $test_log); raise [tests.<project>].timeout_s or BOSS_REVIEW_TEST_TIMEOUT_S and run boss finish again" \
      "$(printf '%s' "$test_gate" | jq -c --argjson timeout_s "$test_timeout" '{timeout_s: $timeout_s, log}')"
  fi
  if [ "$test_result" = "fail" ]; then
    finish_record_test "$state_file" "test_failed" "fail" "$test_gate" >/dev/null 2>&1 || true
    die_json "merge_test_failed" "the base checkout $project failed '$test_cmd' (log: $test_log); the state was kept so a second finish can retry after the fix"
  fi

  # Snapshot the friction before the state file (and with it started_at/note)
  # disappears: append the raw finish event and one aggregated cycle record.
  local ev retriggers blocked_count waiter_lost duration_s tasks_open started_at tasks_file
  ev="$(events_file_for "$project" "$change")"
  retriggers="$(event_count_since_dispatch "$ev" retrigger)"
  blocked_count="$(event_count_since_dispatch "$ev" blocked)"
  waiter_lost=false
  [ "$(event_count_since_dispatch "$ev" lost)" -gt 0 ] && waiter_lost=true
  started_at="$(jq -r '.started_at // ""' "$state_file")"
  duration_s=null
  if [ -n "$started_at" ]; then
    local started_epoch
    started_epoch="$(epoch_of_iso "$started_at")"
    [ -n "$started_epoch" ] && duration_s=$(( $(date +%s) - started_epoch ))
  fi
  tasks_open=null
  tasks_file="$(tasks_file_for "$project" "$change")"
  if [ -n "$tasks_file" ]; then
    tasks_open="$(grep -c '^[[:space:]]*- \[ \]' "$tasks_file" || true)"
  fi

  append_event "$ev" finish \
    "$(jq -nc --arg c "$change" --arg p "$project" --argjson a "$archived" --argjson o "$tasks_open" \
      '{change: $c, project: $p, archived: $a, tasks_open: $o}')" \
    || log "warning: could not record finish event"
  append_event "$ev" cycle \
    "$(jq -nc --arg c "$change" --arg p "$project" --arg started_at "$started_at" \
      --arg finished_at "$(now_iso)" --argjson duration_s "$duration_s" \
      --argjson retriggers "$retriggers" --argjson blocked_count "$blocked_count" \
      --argjson waiter_lost "$waiter_lost" --argjson tasks_open "$tasks_open" --argjson archived "$archived" \
      '{change: $c, project: $p, started_at: $started_at, finished_at: $finished_at, duration_s: $duration_s, retriggers: $retriggers, blocked_count: $blocked_count, waiter_lost: $waiter_lost, tasks_open: $tasks_open, archived: $archived}')" \
    || log "warning: could not record cycle event"

  rm -f "$state_file"
  # The apply is gone: drop its pending wake items with it.
  inbox_remove "$project" "$change"

  # The verified lesson of the run is written only here, never by the apply
  # agent. A write error is reported but must not block the finish.
  local lesson_json="null" lesson_file
  if [ -n "$lesson_text" ]; then
    if [ "$lesson_scope" = "global" ]; then
      lesson_file="$(lessons_global_path 2>/dev/null || true)"
    else
      lesson_file="$(lessons_project_path "$project" 2>/dev/null || true)"
    fi
    if [ -z "$lesson_file" ]; then
      lesson_json="$(jq -nc --arg s "$lesson_scope" '{scope: $s, path: null, error: "cannot resolve lessons path"}')"
      log "warning: could not record lesson: cannot resolve $lesson_scope lessons path"
    elif lesson_append "$lesson_file" "$lesson_text"; then
      lesson_json="$(jq -nc --arg s "$lesson_scope" --arg p "$lesson_file" '{scope: $s, path: $p}')"
      log "finish: recorded $lesson_scope lesson in $lesson_file"
    else
      lesson_json="$(jq -nc --arg s "$lesson_scope" --arg p "$lesson_file" '{scope: $s, path: $p, error: "cannot write lessons file"}')"
      log "warning: could not record $lesson_scope lesson in $lesson_file"
    fi
  fi

  log "finish: change=$change project=$project"

  printf '%s\n' "$(jq -n \
    --arg change "$change" --arg project "$project" --arg tab_id "$tab_id" --arg status "finished" \
    --argjson archived "$archived" --argjson lesson "$lesson_json" \
    --arg merge_test "$merge_test" --argjson test_timeout "$test_timeout" --arg test_log "$test_log" \
    --arg commit_policy "$commit_policy" --argjson working_tree_warning "$working_tree_warning" \
    --argjson changed_files "$(printf '%s' "$changed_files" | jq -Rsc 'split("\n") | map(select(length > 0))')" \
    '{change: $change, project: $project, tab_id: $tab_id, archived: $archived, lesson: $lesson,
      merge_test: $merge_test, test_timeout: $test_timeout, test_log: (if $test_log == "" then null else $test_log end),
      commit_policy: $commit_policy, working_tree_warning: $working_tree_warning,
      changed_files: $changed_files, status: $status}')"
}

# -------------------------------------------------------------------- park ---

# cmd_park <change> [--project <name|path>] [--note <text>] -- detach a change
# whose only open tasks belong to a human: close the apply tab, stop the
# waiter, keep the state and event log, record the park, and write the handoff
# to the inbox and journal. The workspace becomes free for other changes.
cmd_park() {
  local change="" project_name="" note="" as_target="" arg
  while [ $# -gt 0 ]; do
    arg="$1"; shift
    case "$arg" in
      --project) project_name="${1:-}"; shift ;;
      --note) note="$(one_line "${1:-}")"; shift ;;
      --as) as_target="${1:-}"; shift ;;
      -h|--help) usage ;;
      --*) usage_error "unknown option: $arg" ;;
      *) if [ -z "$change" ]; then change="$arg"; else usage_error "unexpected argument: $arg"; fi ;;
    esac
  done
  [ -n "$change" ] || usage_error "usage: boss park <change> [--project <name|path>] [--note <text>] [--as <pane|agent>]"
  boss_use_caller "$as_target"
  ensure_boss_claim park
  ensure_config

  local project st tasks_missing human_open external_open agent_open human_tasks external_tasks agent_tasks
  local state_file tab_id waiter_pid now summary human_lines external_lines journal_text jfile
  project="$(resolve_project "$project_name")" || exit 1
  st="$(mission_done_state "$project" "$change")"
  tasks_missing="$(printf '%s' "$st" | jq -r '.tasks.missing')"
  [ "$tasks_missing" = "true" ] && die_json "no_tasks" "change '$change' in $project has no tasks.md to park"
  human_open="$(printf '%s' "$st" | jq -r '.tasks.human_open // 0')"
  external_open="$(printf '%s' "$st" | jq -r '.tasks.external_open // 0')"
  agent_open="$(printf '%s' "$st" | jq -r '.tasks.agent_open // 0')"
  human_tasks="$(printf '%s' "$st" | jq -c '.human_tasks // []')"
  external_tasks="$(printf '%s' "$st" | jq -c '.external_tasks // []')"
  agent_tasks="$(printf '%s' "$st" | jq -c '.tasks.agent_tasks // []')"
  if [ "$agent_open" -gt 0 ]; then
    die_json "agent_tasks_open" "change '$change' still has agent task(s) open, e.g. '$(printf '%s' "$agent_tasks" | jq -r '.[0].text // "unknown"')'; finish or retrigger them before parking"
  fi
  [ $(( human_open + external_open )) -gt 0 ] || die_json "no_human_tasks" "change '$change' has no open human or external-verification tasks; nothing to park"

  state_file="$(find_state_file "$change" "$project_name" 2>/dev/null || true)"
  now="$(now_iso)"
  if [ -n "$state_file" ] && [ -f "$state_file" ]; then
    local park_pane park_agent_state
    park_pane="$(jq -r '.pane_id // empty' "$state_file")"
    if [ -n "$park_pane" ] && herdr agent get "$park_pane" >/dev/null 2>&1; then
      park_agent_state="$(agent_state_of "$park_pane")"
      if [ "$park_agent_state" = "working" ]; then
        die_json "agent_working" "apply agent for '$change' is still working; wait for it (boss wait $change) before parking"
      fi
    fi
    tab_id="$(jq -r '.tab_id // empty' "$state_file")"
    waiter_pid="$(jq -r '.waiter_pid // empty' "$state_file")"
    if [ -n "$tab_id" ] && [ "$tab_id" != "null" ]; then
      herdr tab close "$tab_id" >/dev/null 2>&1 \
        && log "park: closed tab $tab_id for $change" \
        || log "park: tab $tab_id already gone for $change"
    fi
    kill_waiter "$waiter_pid" >/dev/null 2>&1 || true
    local tmp park_lock acquired=0
    park_lock="$(state_lock "$state_file")"
    if lock_acquire "$park_lock"; then acquired=1; else log "warning: park: state lock busy; updating without it"; fi
    tmp="$(mktemp)"
    if jq --arg t "$now" --arg n "$note" \
        '.parked = true | .parked_at = $t | .parked_note = (if $n == "" then null else $n end) | .waiter_pid = null' \
        "$state_file" >"$tmp" 2>/dev/null; then
      mv "$tmp" "$state_file"
    else
      rm -f "$tmp"
      log "park: could not update state file $state_file"
    fi
    [ "$acquired" -eq 1 ] && lock_release "$park_lock"
  else
    mkdir -p "$BOSS_APPLIES_DIR" || die_json "state_write" "cannot create state dir $BOSS_APPLIES_DIR"
    state_file="$(state_file_for "$project" "$change")"
    jq -n --arg change "$change" --arg project "$project" --arg t "$now" --arg n "$note" \
      '{change: $change, project: $project, runner: null, kind: null, agent: null,
        pane_id: null, tab_id: null, workspace_id: null, boss: null, boss_pane: null,
        waiter_pid: null, started_at: $t, last_state: "waiting_human", last_state_at: $t,
        parked: true, parked_at: $t, parked_note: (if $n == "" then null else $n end)}' \
      >"$state_file" || die_json "state_write" "cannot write state file $state_file"
  fi

  append_event "$(events_file_for "$project" "$change")" park \
    "$(jq -nc --arg c "$change" --arg p "$project" --arg n "$note" \
      --argjson h "$human_tasks" --argjson e "$external_tasks" \
      '{change: $c, project: $p, note: (if $n == "" then null else $n end),
        human_tasks: $h, external_tasks: $e}')" \
    || log "warning: could not record park event"

  human_lines="$(printf '%s' "$human_tasks" | jq -r '.[] | "- [human] \(.text) [criterion: \(.criterion)]"')"
  external_lines="$(printf '%s' "$external_tasks" | jq -r '.[] | "- [external] \(.text) [criterion: \(.criterion)]"')"
  summary="$(printf 'Parked for human/external work:\n%s\n%s' "$human_lines" "$external_lines")"
  inbox_write "$state_file" "waiting_human" "$summary" >/dev/null 2>&1 \
    || log "warning: could not write an inbox item for $change"

  jfile="$(journal_project_path "$project" 2>/dev/null || true)"
  journal_text="$(printf '%s' "$human_tasks" | jq -r 'map("[human] " + .text + " (Prüfkriterium: " + .criterion + ")") | join("; ")')"
  local external_journal
  external_journal="$(printf '%s' "$external_tasks" | jq -r 'map("[external] " + .text + " (Prüfkriterium: " + .criterion + ")") | join("; ")')"
  [ -n "$external_journal" ] && journal_text="${journal_text:+$journal_text; }$external_journal"
  [ -n "$note" ] && journal_text="$journal_text -- note: $note"
  if [ -n "$jfile" ]; then
    journal_append "$jfile" "parked $change for human/external work: $journal_text" "park" \
      || log "warning: could not write the park journal entry"
  fi

  printf '%s\n' "$(jq -n --arg change "$change" --arg project "$project" --arg note "$note" \
    --argjson h "$human_tasks" --argjson e "$external_tasks" \
    '{change: $change, project: $project, status: "parked", workspace_released: true,
      note: (if $note == "" then null else $note end), human_tasks: $h, external_tasks: $e}')"
}

# cmd_resume <change> [--project <name|path>] [--note <text>] -- clear a park
# and make the change selectable again. Without a live apply this starts a
# fresh dispatch with the note, so the human's result is in the new context.
cmd_resume() {
  local change="" project_name="" note="" note_given=0 as_target="" arg
  while [ $# -gt 0 ]; do
    arg="$1"; shift
    case "$arg" in
      --project) project_name="${1:-}"; shift ;;
      --note) note="$(one_line "${1:-}")"; note_given=1; shift ;;
      --as) as_target="${1:-}"; shift ;;
      -h|--help) usage ;;
      --*) usage_error "unknown option: $arg" ;;
      *) if [ -z "$change" ]; then change="$arg"; else usage_error "unexpected argument: $arg"; fi ;;
    esac
  done
  [ -n "$change" ] || usage_error "usage: boss resume <change> [--project <name|path>] [--note <text>] [--as <pane|agent>]"
  boss_use_caller "$as_target"
  ensure_boss_claim resume
  ensure_config

  local project state_file pane_id jfile state_runner="" resume_worktree=""
  project="$(resolve_project "$project_name")" || exit 1
  state_file="$(find_state_file "$change" "$project_name" 2>/dev/null || true)"
  pane_id=""
  if [ -n "$state_file" ]; then
    pane_id="$(jq -r '.pane_id // empty' "$state_file" 2>/dev/null || true)"
    state_runner="$(jq -r '.runner // empty' "$state_file" 2>/dev/null || true)"
    resume_worktree="$(jq -r '.worktree // empty' "$state_file" 2>/dev/null || true)"
    if [ -n "$resume_worktree" ] && [ ! -d "$resume_worktree" ]; then
      die_json "worktree_missing" "the recorded worktree $resume_worktree for '$change' is missing; do not fall back to the base checkout"
    fi
  fi

  append_event "$(events_file_for "$project" "$change")" resume \
    "$(jq -nc --arg c "$change" --arg p "$project" --arg n "$note" \
      '{change: $c, project: $p, note: (if $n == "" then null else $n end)}')" \
    || log "warning: could not record resume event"
  jfile="$(journal_project_path "$project" 2>/dev/null || true)"
  if [ -n "$jfile" ]; then
    journal_append "$jfile" "resumed $change${note:+ -- $note}" "resume" \
      || log "warning: could not write the resume journal entry"
  fi

  if [ -n "$pane_id" ] && herdr agent get "$pane_id" >/dev/null 2>&1; then
    local tmp
    tmp="$(mktemp)"
    if jq 'del(.parked, .parked_at, .parked_note)' "$state_file" >"$tmp" 2>/dev/null; then
      mv "$tmp" "$state_file"
    else
      rm -f "$tmp"
    fi
    printf '%s\n' "$(jq -n --arg change "$change" --arg project "$project" \
      '{change: $change, project: $project, status: "resumed", started: false}')"
    return 0
  fi

  # Preserve the runner of the original dispatch; a missing state field keeps
  # the configured default. A removed/renamed runner is an explicit error.
  local runner want_worktree=0
  [ -n "$resume_worktree" ] && want_worktree=1
  runner="$(resolve_runner "$state_runner")" || exit 1
  dispatch_change "$change" "$project" "$runner" "$note" "$want_worktree"
}

# --------------------------------------------------------------- interrupt ---

# cmd_interrupt <change> [--project <name|path>] [--as <pane|agent>] -- send the
# runner's interrupt keys, mark the state/event log and journal the action. The
# waiter reports the next settle as 'interrupted'.
cmd_interrupt() {
  local change="" project_name="" as_target="" arg
  while [ $# -gt 0 ]; do
    arg="$1"; shift
    case "$arg" in
      --project) project_name="${1:-}"; shift ;;
      --as) as_target="${1:-}"; shift ;;
      -h|--help) usage ;;
      --*) usage_error "unknown option: $arg" ;;
      *) if [ -z "$change" ]; then change="$arg"; else usage_error "unexpected argument: $arg"; fi ;;
    esac
  done
  [ -n "$change" ] || usage_error "usage: boss interrupt <change> [--project <name|path>] [--as <pane|agent>]"
  boss_use_caller "$as_target"
  ensure_boss_claim interrupt
  ensure_config

  local state_file project pane_id runner_name runner_json kind
  local -a keys=()
  state_file="$(find_state_file "$change" "$project_name")" || exit 1
  project="$(jq -r '.project' "$state_file")"
  pane_id="$(jq -r '.pane_id // empty' "$state_file")"
  runner_name="$(jq -r '.runner // empty' "$state_file")"
  kind="$(jq -r '.kind // empty' "$state_file")"
  if [ -n "$runner_name" ]; then
    runner_json="$(resolve_runner "$runner_name")" || exit 1
  else
    runner_json="$(jq -nc --arg k "$kind" '{kind: $k}')"
  fi
  while IFS= read -r k; do [ -n "$k" ] && keys+=("$k"); done < <(runner_interrupt_keys "$runner_json")
  [ "${#keys[@]}" -gt 0 ] || die_json "interrupt_keys" "runner '$runner_name' has no interrupt keys"

  local out
  if ! out="$(herdr agent send-keys "$pane_id" "${keys[@]}" 2>&1)"; then
    local code
    code="$(printf '%s' "$out" | jq -r '.error.code // "unknown"' 2>/dev/null || true)"
    die_json "send_keys_failed" "sending interrupt keys to pane $pane_id failed: $code"
  fi
  ensure_waiter "$state_file" >/dev/null || true

  local now keys_json
  now="$(now_iso)"
  keys_json="$(printf '%s\n' "${keys[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')"
  local tmp
  tmp="$(mktemp)"
  if jq --arg t "$now" --argjson k "$keys_json" \
      '.interrupted = true | .interrupted_at = $t | .interrupt_keys = $k' \
      "$state_file" >"$tmp" 2>/dev/null; then
    mv "$tmp" "$state_file"
  else
    rm -f "$tmp"
    die_json "state_write" "cannot mark apply $change as interrupted"
  fi
  append_event "$(events_file_for "$project" "$change")" interrupt \
    "$(jq -nc --arg c "$change" --arg p "$project" --argjson k "$keys_json" \
      '{change: $c, project: $p, keys: $k}')" \
    || log "warning: could not record interrupt event"
  local jfile
  jfile="$(journal_project_path "$project" 2>/dev/null || true)"
  [ -n "$jfile" ] && journal_append "$jfile" "interrupted $change with keys: $(printf '%s ' "${keys[@]}")" "interrupt" \
    || true

  printf '%s\n' "$(jq -n --arg change "$change" --arg project "$project" \
    --arg pane "$pane_id" --argjson keys "$keys_json" \
    '{change: $change, project: $project, pane_id: $pane, keys: $keys, status: "interrupted"}')"
}

# ------------------------------------------------------------------ answer ---

cmd_answer() {
  local change="" project_name="" as_target="" arg
  local -a keys=()
  while [ $# -gt 0 ]; do
    arg="$1"; shift
    case "$arg" in
      --project) project_name="${1:-}"; shift ;;
      --as) as_target="${1:-}"; shift ;;
      -h|--help) usage ;;
      --*) usage_error "unknown option: $arg" ;;
      *) if [ -z "$change" ]; then change="$arg"; else keys+=("$arg"); fi ;;
    esac
  done
  [ -n "$change" ] || usage_error "usage: boss answer <change> <key>... [--project <name|path>] [--as <pane|agent>]"
  [ "${#keys[@]}" -gt 0 ] || usage_error "usage: boss answer <change> <key>... [--project <name|path>] [--as <pane|agent>]"
  boss_use_caller "$as_target"
  ensure_boss_claim answer
  ensure_config

  local state_file agent pane_id project out code keys_json
  state_file="$(find_state_file "$change" "$project_name")" || exit 1
  agent="$(jq -r '.agent' "$state_file")"
  pane_id="$(jq -r '.pane_id' "$state_file")"
  project="$(jq -r '.project' "$state_file")"
  keys_json="$(printf '%s\n' "${keys[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')"

  ensure_waiter "$state_file" >/dev/null
  if ! out="$(herdr agent send-keys "$pane_id" "${keys[@]}" 2>&1)"; then
    code="$(printf '%s' "$out" | jq -r '.error.code // "unknown"' 2>/dev/null || true)"
    die_json "send_keys_failed" "sending keys to $agent failed: $code"
  fi
  append_event "$(events_file_for "$project" "$change")" answer \
    "$(jq -nc --arg c "$change" --arg p "$project" --arg a "$agent" --arg pane "$pane_id" --argjson k "$keys_json" \
      '{change: $c, project: $p, agent: $a, pane: $pane, keys: $k}')" \
    || log "warning: could not record answer event"

  printf '%s\n' "$(jq -n \
    --arg change "$change" --arg agent "$agent" --arg status "sent" \
    --argjson keys "$keys_json" \
    '{change: $change, agent: $agent, keys: $keys, status: $status}')"
}

# ------------------------------------------------------------------ skills ---

# skills_dirs_json [<project>] -- the skill directories of both tools as compact
# JSON: the project-scoped ones (opencode plus claude) when a project is given,
# and the machine-global ones. A leading ~ is expanded, so all paths absolute.
# A skill is plain Markdown at <dir>/<name>/SKILL.md in either location.
skills_dirs_json() {
  local project="${1:-}" p_open p_claude g_open g_claude
  p_open=""
  p_claude=""
  if [ -n "$project" ]; then
    p_open="$project/.opencode/skills"
    p_claude="$project/.claude/skills"
  fi
  # shellcheck disable=SC2088  # a literal tilde, expanded by expand_home
  g_open="$(expand_home "~/.config/opencode/skills")"
  # shellcheck disable=SC2088  # a literal tilde, expanded by expand_home
  g_claude="$(expand_home "~/.claude/skills")"
  jq -nc --arg project "$project" --arg po "$p_open" --arg pc "$p_claude" \
    --arg go "$g_open" --arg gc "$g_claude" \
    '{project: (if $project == "" then null else $project end),
      project_skills: (if $project == "" then []
        else [{tool: "opencode", dir: $po}, {tool: "claude", dir: $pc}] end),
      global_skills: [{tool: "opencode", dir: $go}, {tool: "claude", dir: $gc}]}'
}

# cmd_skills dir [--project <name|path>] [--json] -- print where skills live:
# the project-scoped directories of both tools (when a project can be resolved)
# and the machine-global ones. Without --json a short labelled list; the
# explorer uses it instead of guessing tool-specific paths.
cmd_skills() {
  local action="" project_name="" want_json=0 arg
  while [ $# -gt 0 ]; do
    arg="$1"; shift
    case "$arg" in
      --project) project_name="${1:-}"; shift ;;
      --json) want_json=1 ;;
      -h|--help) usage ;;
      --*) usage_error "unknown option: $arg" ;;
      *)
        if [ -z "$action" ]; then action="$arg"
        else usage_error "unexpected argument: $arg"; fi ;;
    esac
  done
  [ -n "$action" ] || usage_error "usage: boss skills dir [--project <name|path>] [--json]"
  case "$action" in
    dir) ;;
    *) usage_error "unknown skills action: $action" ;;
  esac
  ensure_config

  local project=""
  if [ -n "$project_name" ]; then
    project="$(resolve_project "$project_name")" || exit 1
  else
    project="$(find_openspec_root "$PWD" || true)"
  fi

  local json
  json="$(skills_dirs_json "$project")"
  if [ "$want_json" -eq 1 ]; then
    printf '%s\n' "$json"
    return 0
  fi
  printf 'project skills (write here for this project):\n'
  if [ -n "$project" ]; then
    printf '%s' "$json" | jq -r '.project_skills[] | "  \(.dir)  [\(.tool)]"'
  else
    printf '  (no project resolved; pass --project <name|path>)\n'
  fi
  printf 'global skills (write here for the machine):\n'
  printf '%s' "$json" | jq -r '.global_skills[] | "  \(.dir)  [\(.tool)]"'
}

# ----------------------------------------------------------------- mission ---

# missions_dir <project> -- directory of the mission docs: '[missions] dir'
# relative to the project root (default openspec/missions); an absolute or ~
# path is used as is. A leading ~ is expanded.
