#!/usr/bin/env bash
# boss-review -- part of the boss runtime, sourced by bin/boss after boss-lib.sh.
# Contains only function definitions; nothing runs when this file is sourced.

review_locate() {
  local change="$1" project_name="${2:-}" norm files f count want names
  local evs ev project state_file worktree=""
  norm="$(normalize_name "$change")"

  files="$(ls "$BOSS_APPLIES_DIR"/*-"$norm".json 2>/dev/null || true)"
  count=0
  [ -n "$files" ] && count="$(printf '%s\n' "$files" | wc -l | tr -d ' ')"
  if [ "$count" -gt 0 ]; then
    if [ "$count" -gt 1 ]; then
      if [ -n "$project_name" ]; then
        want="$(resolve_project "$project_name")" || exit 1
        for f in $files; do
          [ "$(jq -r '.project' "$f")" = "$want" ] && { state_file="$f"; break; }
        done
        [ -n "$state_file" ] || die_json "no_apply" "no apply for change '$change' in $want"
      else
        names=""
        for f in $files; do names="$names $(jq -r '.project' "$f")"; done
        die_json "ambiguous_change" "change '$change' has applies in multiple projects:$names; pass --project to disambiguate"
      fi
    else
      state_file="$files"
    fi
    project="$(jq -r '.project' "$state_file")"
    worktree="$(jq -r '.worktree // empty' "$state_file" 2>/dev/null || true)"
    printf '%s\t%s\t%s\t%s\n' "$project" "$(events_file_for "$project" "$change")" \
      "$state_file" "$worktree"
    return 0
  fi

  # No state file: an event log may still exist (it survives boss finish).
  evs="$(ls "$BOSS_CYCLES_DIR"/*-"$norm".events.jsonl 2>/dev/null || true)"
  count=0
  [ -n "$evs" ] && count="$(printf '%s\n' "$evs" | wc -l | tr -d ' ')"
  if [ "$count" -eq 0 ]; then
    die_json "no_apply" "no recorded apply or event log for change '$change'"
  fi
  if [ "$count" -gt 1 ]; then
    if [ -n "$project_name" ]; then
      want="$(resolve_project "$project_name")" || exit 1
      for ev in $evs; do
        [ "$(sed -n '1p' "$ev" | jq -r '.project // empty' 2>/dev/null)" = "$want" ] \
          && { printf '%s\t%s\t\t\n' "$want" "$ev"; return 0; }
      done
    fi
    names=""
    for ev in $evs; do names="$names $(sed -n '1p' "$ev" | jq -r '.project // empty' 2>/dev/null)"; done
    die_json "ambiguous_change" "change '$change' has event logs in multiple projects:$names; pass --project to disambiguate"
  fi
  project="$(sed -n '1p' "$evs" | jq -r '.project // empty' 2>/dev/null)"
  [ -n "$project" ] || die_json "no_apply" "event log for change '$change' carries no project"
  printf '%s\t%s\t\t\n' "$project" "$evs"
}

# is_project_registered <project> -- 0 when the canonical path is in the
# [projects] registry (by any name).
is_project_registered() {
  local project="$1" cfg name path
  cfg="$(config_json)" || exit 1
  while IFS= read -r name; do
    path="$(printf '%s' "$cfg" | jq -r --arg n "$name" '.projects[$n] // empty')"
    [ -n "$path" ] || continue
    [ "$(canonical_path "$path")" = "$project" ] && return 0
  done < <(printf '%s' "$cfg" | jq -r '(.projects // {}) | keys[]')
  return 1
}

# config_test_command <project> -- the [tests] override for the registered
# project whose path resolves to <project>, or empty. The registry maps a name
# to a path, so the override is keyed by that name.
config_test_command() {
  local project="$1" cfg name path
  cfg="$(config_json)" || exit 1
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    path="$(printf '%s' "$cfg" | jq -r --arg n "$name" '.projects[$n] // empty')"
    [ -n "$path" ] || continue
    if [ "$(canonical_path "$path")" = "$project" ]; then
      printf '%s' "$(printf '%s' "$cfg" | jq -r --arg n "$name" '.tests[$n] // empty')"
      return 0
    fi
  done < <(printf '%s' "$cfg" | jq -r '(.tests // {}) | keys[]')
}

# detect_test_command <project> -- a recognizable standard test command, or empty
detect_test_command() {
  local project="$1" jf="" runner=""
  [ -f "$project/Justfile" ] && jf="$project/Justfile"
  [ -z "$jf" ] && [ -f "$project/justfile" ] && jf="$project/justfile"
  if [ -n "$jf" ] && grep -qE '^[[:space:]]*test[[:space:]]*:' "$jf" 2>/dev/null; then
    printf 'just test'
    return 0
  fi
  if [ -f "$project/package.json" ] && jq -e '.scripts.test' "$project/package.json" >/dev/null 2>&1; then
    if [ -f "$project/pnpm-lock.yaml" ]; then
      runner="pnpm test"
    elif [ -f "$project/yarn.lock" ]; then
      runner="yarn test"
    else
      runner="npm test"
    fi
    printf '%s' "$runner"
    return 0
  fi
  if [ -f "$project/pytest.ini" ] || [ -f "$project/tox.ini" ] \
    || { [ -f "$project/pyproject.toml" ] && grep -q 'pytest' "$project/pyproject.toml" 2>/dev/null; }; then
    if [ -f "$project/uv.lock" ]; then
      runner="uv run pytest"
    elif [ -f "$project/poetry.lock" ]; then
      runner="poetry run pytest"
    else
      runner="pytest"
    fi
    printf '%s' "$runner"
    return 0
  fi
  if [ -f "$project/Makefile" ] && grep -qE '^test:' "$project/Makefile" 2>/dev/null; then
    printf 'make test'
    return 0
  fi
  return 0
}

# state_commit_policy <state-file> -- commit policy of the apply: the recorded
# commit_policy, else the runner config's commit value, else explorer.
state_commit_policy() {
  local state_file="$1" policy runner
  policy="$(jq -r '.commit_policy // empty' "$state_file" 2>/dev/null || true)"
  if [ -z "$policy" ]; then
    runner="$(jq -r '.runner // empty' "$state_file" 2>/dev/null || true)"
    if [ -n "$runner" ]; then
      policy="$(config_json 2>/dev/null | jq -r --arg n "$runner" '.runners[$n].commit // empty' 2>/dev/null || true)"
    fi
  fi
  [ -n "$policy" ] || policy="explorer"
  case "$policy" in agent|explorer) printf '%s' "$policy" ;; *) printf 'explorer' ;; esac
}

# changed_files_of <root> [<base>] -- every path changed in <root>, one per
# line: uncommitted and untracked files from git status plus committed files
# since <base>. Errors are ignored; the caller sorts and intersects the result.
changed_files_of() {
  local root="$1" base="${2:-}" line path
  git -C "$root" status --porcelain --untracked-files=all 2>/dev/null \
    | while IFS= read -r line; do
        [ -n "$line" ] || continue
        path="${line:3}"
        case "$path" in *" -> "*) path="${path#* -> }" ;; esac
        printf '%s\n' "$path"
      done
  if [ -n "$base" ]; then
    git -C "$root" diff --name-only "$base...HEAD" 2>/dev/null || true
  fi
  return 0
}

cmd_review() {
  # Read-only and herd-free: review must work in the boss session and outside
  # Herdr alike, so it does not claim the boss agent identity.
  ensure_config
  local change="" project_name="" json_only=0 arg
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
  [ -n "$change" ] || usage_error "usage: boss review <change> [--project <name|path>] [--json]"

  local line state_file project ev located_worktree
  line="$(review_locate "$change" "$project_name")" || exit 1
  IFS=$'\t' read -r project ev state_file located_worktree <<<"$line"

  local worktree="$located_worktree" branch="" worktree_workspace="" merge_state="none" merged=false
  local merge_test="not_run" kept=false review_root="$project"
  if [ -n "$state_file" ] && [ -f "$state_file" ]; then
    [ -n "$worktree" ] || worktree="$(jq -r '.worktree // empty' "$state_file" 2>/dev/null || true)"
    branch="$(jq -r '.branch // empty' "$state_file" 2>/dev/null || true)"
    worktree_workspace="$(jq -r '.worktree_workspace // empty' "$state_file" 2>/dev/null || true)"
    merge_state="$(jq -r '.merge_state // "none"' "$state_file" 2>/dev/null || true)"
    merged="$(jq -r '.merged // false' "$state_file" 2>/dev/null || printf false)"
    merge_test="$(jq -r '.merge_test // "not_run"' "$state_file" 2>/dev/null || true)"
    kept="$(jq -r '.kept // false' "$state_file" 2>/dev/null || printf false)"
    [ -n "$worktree" ] && review_root="$worktree"
  fi

  local boss_workspace="" boss_dispatcher=""
  if [ -n "$state_file" ] && [ -f "$state_file" ]; then
    boss_workspace="$(jq -r '.workspace_id // empty' "$state_file")"
    boss_dispatcher="$(jq -r '.boss // empty' "$state_file")"
  fi
  local boss_wakeup boss boss_pane boss_reachable boss_name_ok boss_state
  boss_wakeup="$(boss_wakeup_check "$boss_workspace" "$boss_dispatcher")"
  boss="$(printf '%s' "$boss_wakeup" | jq -r '.boss // ""')"
  boss_pane="$(printf '%s' "$boss_wakeup" | jq -r '.boss_pane // ""')"
  boss_reachable="$(printf '%s' "$boss_wakeup" | jq -r '.boss_reachable')"
  boss_name_ok="$(printf '%s' "$boss_wakeup" | jq -r '.boss_name_ok')"
  boss_state="$(printf '%s' "$boss_wakeup" | jq -r '.state')"

  # Same wake block as 'boss status'. A finished apply keeps its event log but
  # has no state file, so the plan and next target are deliberately empty.
  local events_file wake_plan wake_target last_wake
  events_file="$ev"
  wake_plan='{"candidates":[],"skipped":[],"next":null}'
  wake_target='null'
  if [ -n "$state_file" ] && [ -f "$state_file" ]; then
    wake_plan="$(boss_wake_plan "$state_file")"
    wake_target="$(printf '%s' "$wake_plan" | jq -c '.next // null')"
  fi
  last_wake="$(last_wake_event "$events_file")"

  local tasks_file tasks_open tasks_done tasks_total tasks_json
  tasks_file="$(tasks_file_for "$review_root" "$change")"
  if [ -n "$tasks_file" ]; then
    tasks_open="$(grep -c '^[[:space:]]*- \[ \]' "$tasks_file" || true)"
    tasks_done="$(grep -c '^[[:space:]]*- \[x\]' "$tasks_file" || true)"
    tasks_total=$((tasks_open + tasks_done))
    tasks_json="$(jq -nc --argjson o "$tasks_open" --argjson d "$tasks_done" --argjson t "$tasks_total" \
      '{missing: false, open: $o, done: $d, total: $t}')"
  else
    tasks_json='{"missing":true,"open":null,"done":null,"total":null}'
  fi

  local validate_result="not_run"
  if command -v openspec >/dev/null 2>&1; then
    if (cd "$review_root" && openspec validate "$change" --strict >/dev/null 2>&1); then
      validate_result="pass"
    else
      validate_result="fail"
    fi
  fi

  local test_cmd test_result="not_run"
  test_cmd="$(config_test_command "$project")"
  [ -n "$test_cmd" ] || test_cmd="$(detect_test_command "$review_root")"
  # A command whose program is not installed did not run and must not read as
  # a red test: drop it and report not_run instead.
  if [ -n "$test_cmd" ] && ! command -v "${test_cmd%% *}" >/dev/null 2>&1; then
    log "test command '$test_cmd' not found in PATH; reporting not_run"
    test_cmd=""
  fi
  if [ -n "$test_cmd" ]; then
    if (cd "$review_root" && run_with_deadline "$BOSS_REVIEW_TEST_TIMEOUT_S" bash -c "$test_cmd" >/dev/null 2>&1); then
      test_result="pass"
    else
      test_result="fail"
    fi
  fi

  local changed_files diff_stat
  changed_files="$(git -C "$review_root" status --short 2>/dev/null || true)"
  diff_stat="$(git -C "$review_root" diff --stat 2>/dev/null || true)"

  local base_head="" commits="" diff_stat_range="" foreign_commits="" foreign_count=0
  local expected_name expected_email commit_details commit_policy="explorer" violations="[]"
  if [ -n "$state_file" ] && [ -f "$state_file" ]; then
    commit_policy="$(state_commit_policy "$state_file")"
  fi
  if [ -n "$state_file" ] && [ -f "$state_file" ]; then
    base_head="$(git_range_base "$review_root" "$(jq -r '.base_head // empty' "$state_file")")"
  fi
  if [ -n "$base_head" ]; then
    commits="$(git -C "$review_root" log --oneline "$base_head..HEAD" 2>/dev/null || true)"
    diff_stat_range="$(git -C "$review_root" diff --stat "$base_head..HEAD" 2>/dev/null || true)"
    expected_name="$(git -C "$review_root" config user.name 2>/dev/null || true)"
    expected_email="$(git -C "$review_root" config user.email 2>/dev/null || true)"
    if [ -n "$expected_name" ] || [ -n "$expected_email" ]; then
      commit_details="$(git -C "$review_root" log --format='%H%x09%an%x09%ae%x09%s' "$base_head..HEAD" 2>/dev/null || true)"
      foreign_commits="$(printf '%s\n' "$commit_details" | awk -F '\t' -v n="$expected_name" -v e="$expected_email" \
        'NF >= 4 && ((n != "" && $2 != n) || (e != "" && $3 != e)) { print $1 "\t" $2 " <" $3 ">\t" $4 }')"
      foreign_count="$(printf '%s' "$foreign_commits" | grep -c . 2>/dev/null || true)"
    fi
  fi
  if [ "$commit_policy" = "explorer" ]; then
    violations="$(printf '%s' "$commits" | jq -Rsc 'split("\n") | map(select(length > 0))')"
  fi

  # Merge overlap backstop: compare this worktree's changed files with those of
  # the other running, parked and test-failed worktrees of the same project.
  # The runtime never merges, rebases or resolves; the Explorer decides.
  local overlaps="[]" current_files overlap_rows="[]"
  local holder holder_change holder_wt holder_base holder_files ofile
  current_files="$(changed_files_of "$review_root" "$base_head" | sort -u)"
  if [ -n "$current_files" ] && [ -n "$state_file" ] && [ -f "$state_file" ]; then
    while IFS= read -r holder; do
      [ -n "$holder" ] || continue
      holder_change="$(printf '%s' "$holder" | jq -r '.change')"
      holder_wt="$(printf '%s' "$holder" | jq -r '.worktree // empty')"
      [ -n "$holder_wt" ] && [ -d "$holder_wt" ] || continue
      holder_base="$(jq -r '.base_head // empty' "$(printf '%s' "$holder" | jq -r '.state_file')" 2>/dev/null || true)"
      holder_files="$(changed_files_of "$holder_wt" "$holder_base" | sort -u)"
      while IFS= read -r ofile; do
        [ -n "$ofile" ] || continue
        printf '%s\n' "$current_files" | grep -Fxq -- "$ofile" || continue
        overlap_rows="$(printf '%s' "$overlap_rows" | jq -c --arg f "$ofile" --arg c "$holder_change" \
          '. + [{file: $f, change: $c}]')"
      done <<<"$holder_files"
    done < <(lock_holders "$project" "$state_file" | jq -c '.[]')
    overlaps="$(printf '%s' "$overlap_rows" | jq -c --arg cur "$change" \
      'group_by(.file) | map({file: .[0].file, changes: ([$cur] + map(.change) | unique)})')"
  fi

  local summary
  summary=""
  if [ -n "$state_file" ] && [ -f "$state_file" ]; then
    summary="$(jq -r '.summary // empty' "$state_file")"
  fi
  [ -n "$summary" ] || summary="$(last_event_field "$ev" summary summary)"

  local inbox_pending
  inbox_pending="$(inbox_count "$project" "$change")"

  local retriggers blocked_count waiter_lost duration_s note started_at started_epoch
  retriggers="$(event_count_since_dispatch "$ev" retrigger)"
  blocked_count="$(event_count_since_dispatch "$ev" blocked)"
  waiter_lost=false
  [ "$(event_count_since_dispatch "$ev" lost)" -gt 0 ] && waiter_lost=true
  note=""
  duration_s=null
  if [ -n "$state_file" ] && [ -f "$state_file" ]; then
    note="$(jq -r '.note // ""' "$state_file")"
    started_at="$(jq -r '.started_at // ""' "$state_file")"
    if [ -n "$started_at" ]; then
      started_epoch="$(epoch_of_iso "$started_at")"
      [ -n "$started_epoch" ] && duration_s=$(( $(date +%s) - started_epoch ))
    fi
  fi

  local lessons_global_json lessons_project_json gfile pfile
  lessons_global_json="[]"
  lessons_project_json="[]"
  gfile="$(lessons_global_path 2>/dev/null || true)"
  pfile="$(lessons_project_path "$project" 2>/dev/null || true)"
  [ -n "$gfile" ] && lessons_global_json="$(lessons_active_json "$gfile")"
  [ -n "$pfile" ] && lessons_project_json="$(lessons_active_json "$pfile")"

  local json
  json="$(jq -n \
    --arg change "$change" --arg project "$project" \
    --argjson tasks "$tasks_json" --arg validate "$validate_result" \
    --arg test_result "$test_result" --arg test_cmd "$test_cmd" \
    --argjson changed_files "$(printf '%s' "$changed_files" | jq -Rsc 'split("\n") | map(select(length > 0))')" \
    --argjson diff_stat "$(printf '%s' "$diff_stat" | jq -Rsc 'split("\n") | map(select(length > 0))')" \
    --arg base_head "$base_head" \
    --argjson commits "$(printf '%s' "$commits" | jq -Rsc 'split("\n") | map(select(length > 0))')" \
    --argjson diff_stat_range "$(printf '%s' "$diff_stat_range" | jq -Rsc 'split("\n") | map(select(length > 0))')" \
    --argjson foreign_commits "$(printf '%s' "$foreign_commits" | jq -Rsc 'split("\n") | map(select(length > 0))')" \
    --argjson foreign_count "$foreign_count" --arg commit_policy "$commit_policy" \
    --argjson violations "$violations" \
    --arg summary "$summary" \
    --argjson lessons_global "$lessons_global_json" --argjson lessons_project "$lessons_project_json" \
    --argjson retriggers "$retriggers" --argjson blocked_count "$blocked_count" \
    --argjson waiter_lost "$waiter_lost" --argjson duration_s "$duration_s" --arg note "$note" \
    --argjson inbox_pending "$inbox_pending" \
    --arg boss "$boss" --arg boss_pane "$boss_pane" \
    --argjson boss_reachable "$boss_reachable" --argjson boss_name_ok "$boss_name_ok" \
    --arg events_file "$events_file" --argjson wake_plan "$wake_plan" \
    --argjson wake_target "$wake_target" --argjson last_wake "$last_wake" \
    --arg worktree "$worktree" --arg branch "$branch" --arg worktree_workspace "$worktree_workspace" \
    --arg merge_state "$merge_state" --argjson merged "$merged" --arg merge_test "$merge_test" \
    --argjson kept "$kept" --argjson overlaps "$overlaps" \
    '{change: $change, project: $project, summary: (if $summary == "" then null else $summary end),
      worktree: (if $worktree == "" then null else $worktree end),
      branch: (if $branch == "" then null else $branch end),
      worktree_workspace: (if $worktree_workspace == "" then null else $worktree_workspace end),
      merge_state: $merge_state, merged: $merged, merge_test: $merge_test, kept: $kept,
      overlaps: $overlaps,
      boss: (if $boss == "" then null else $boss end),
      boss_pane: (if $boss_pane == "" then null else $boss_pane end),
      boss_reachable: $boss_reachable, boss_name_ok: $boss_name_ok,
      events_file: $events_file, wake_plan: $wake_plan, wake_target: $wake_target,
      last_wake: $last_wake,
      inbox_pending: $inbox_pending,
      lessons: {global: $lessons_global, project: $lessons_project},
      quality: {tasks: $tasks, validate: $validate,
        tests: {result: $test_result, command: (if $test_cmd == "" then null else $test_cmd end)},
        git: {base_head: (if $base_head == "" then null else $base_head end),
          commits: $commits, diff_stat_range: $diff_stat_range,
          commit_policy: $commit_policy,
          foreign_commits: $foreign_commits,
          changed_files: $changed_files, diff_stat: $diff_stat}},
      friction: {retriggers: $retriggers, blocked_count: $blocked_count,
        waiter_lost: $waiter_lost, foreign_commits: $foreign_count,
        commit_policy_violations: $violations,
        duration_s: $duration_s, note: (if $note == "" then null else $note end)}}')"

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
  printf '%s' "$overlaps" | jq -r '.[] | "overlap: \(.file) (changes: \(.changes | join(", ")))"'
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
  if [ "$inbox_pending" -gt 0 ]; then
    printf 'inbox: %s pending -- boss inbox\n' "$inbox_pending"
  fi
  printf 'validate: %s\n' "$validate_result"
  if [ -n "$test_cmd" ]; then
    printf 'tests (%s): %s\n' "$test_cmd" "$test_result"
  else
    printf 'tests: %s (no standard command recognized)\n' "$test_result"
  fi
  printf 'friction: %s retrigger(s), %s blocked, waiter_lost=%s, foreign commits=%s, commit policy=%s\n' \
    "$retriggers" "$blocked_count" "$waiter_lost" "$foreign_count" "$commit_policy"
  if [ "$(printf '%s' "$violations" | jq 'length')" -gt 0 ]; then
    printf 'commit-policy violations (explorer expects no commits):\n%s\n' \
      "$(printf '%s' "$violations" | jq -r 'join("\n")')"
  fi
  if [ -n "$foreign_commits" ]; then
    printf 'foreign-author commits:\n%s\n' "$foreign_commits"
  fi
  if [ "$(printf '%s' "$lessons_global_json" | jq 'length')" -gt 0 ]; then
    printf 'lessons (global):\n%s\n' "$(printf '%s' "$lessons_global_json" | jq -r 'join("\n")')"
  fi
  if [ "$(printf '%s' "$lessons_project_json" | jq 'length')" -gt 0 ]; then
    printf 'lessons (project):\n%s\n' "$(printf '%s' "$lessons_project_json" | jq -r 'join("\n")')"
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
  printf '%s\n' "$json"
}

# -------------------------------------------------------------------- wait ---

# ensure_waiter <state-file> -- start a waiter unless one is alive; prints
# "<pid> running|started".
tasks_file_for() {
  local project="$1" change="$2" f
  f="$project/openspec/changes/$change/tasks.md"
  if [ -f "$f" ]; then
    printf '%s\n' "$f"
    return 0
  fi
  f="$(ls "$project"/openspec/changes/archive/*-"$change"/tasks.md 2>/dev/null | sed -n '1p')"
  [ -n "$f" ] && printf '%s\n' "$f"
}

# record_finish_lesson <project> <text> <scope> -- append a verified lesson and
# print its JSON description. A write error never blocks the finish.
record_finish_lesson() {
  local project="$1" text="$2" scope="$3" file
  [ -n "$text" ] || { printf 'null\n'; return 0; }
  if [ "$scope" = "global" ]; then
    file="$(lessons_global_path 2>/dev/null || true)"
  else
    file="$(lessons_project_path "$project" 2>/dev/null || true)"
  fi
  if [ -z "$file" ]; then
    log "warning: could not record lesson: cannot resolve $scope lessons path"
    jq -nc --arg s "$scope" '{scope: $s, path: null, error: "cannot resolve lessons path"}'
  elif lesson_append "$file" "$text"; then
    log "finish: recorded $scope lesson in $file"
    jq -nc --arg s "$scope" --arg p "$file" '{scope: $s, path: $p}'
  else
    log "warning: could not record $scope lesson in $file"
    jq -nc --arg s "$scope" --arg p "$file" '{scope: $s, path: $p, error: "cannot write lessons file"}'
  fi
}

# finish_worktree <change> <project> <state-file> <worktree> <branch> <commit-
# policy> <keep> <no-merge> <lesson-text> <lesson-scope> -- the isolated finish:
# verify, merge into the base, test the merged base and clean up. Calls die_json
# for a dirty base/worktree, a conflict or a red integration test, always
# leaving the worktree and state intact in those cases.
