#!/usr/bin/env bash
# boss-mission -- part of the boss runtime, sourced by bin/boss after boss-lib.sh.
# Contains only function definitions; nothing runs when this file is sourced.

missions_dir() {
  local project="$1" cfg path
  cfg="$(config_json)" || return 1
  path="$(printf '%s' "$cfg" | jq -r '.missions.dir // empty')"
  [ -n "$path" ] || path="openspec/missions"
  # shellcheck disable=SC2088  # a literal tilde, expanded by expand_home
  case "$path" in
    /*) printf '%s\n' "$path" ;;
    "~"|"~/"*) expand_home "$path" ;;
    *) printf '%s/%s\n' "$project" "$path" ;;
  esac
}

# mission_file_for <project> <slug> -- path of the mission document
mission_file_for() {
  printf '%s/%s.md\n' "$(missions_dir "$1")" "$2"
}

# mission_events_file <project> <slug> -- mission-level event log for reconcile
# markers. Keyed like the apply event logs, with a mission- prefix.
mission_events_file() {
  local project="$1" slug="$2"
  printf '%s/%s-mission-%s.events.jsonl\n' "$BOSS_CYCLES_DIR" \
    "$(sha1_hex "$project")" "$(normalize_name "$slug")"
}

# mission_last_boundary <project> <slug> [<change>...] -- the latest finish or
# park timestamp among the mission changes, or empty. ISO timestamps from
# now_iso are lexicographically ordered.
mission_last_boundary() {
  local project="$1" slug="$2" c file t max=""
  shift 2
  for c in "$@"; do
    [ -n "$c" ] || continue
    file="$(events_file_for "$project" "$c")"
    [ -f "$file" ] || continue
    t="$(jq -Rrs '[split("\n")[] | fromjson? | select(.event == "finish" or .event == "park") | .t] | max // empty' \
      "$file" 2>/dev/null || true)"
    [ -n "$t" ] || continue
    if [ -z "$max" ] || [[ "$t" > "$max" ]]; then max="$t"; fi
  done
  printf '%s' "$max"
}

# mission_reconcile_done_at <project> <slug> <change> -- timestamp of the last
# reconcile_done event for that change, or empty.
mission_reconcile_done_at() {
  local project="$1" slug="$2" change="$3" file
  file="$(mission_events_file "$project" "$slug")"
  [ -f "$file" ] || return 0
  jq -Rrs --arg c "$change" \
    '[split("\n")[] | fromjson? | select(.event == "reconcile_done" and .change == $c) | .t] | last // empty' \
    "$file" 2>/dev/null || true
}

# mission_trim <text> -- strip leading and trailing whitespace
mission_trim() {
  local text="$1"
  text="${text#"${text%%[![:space:]]*}"}"
  text="${text%"${text##*[![:space:]]}"}"
  printf '%s' "$text"
}

# mission_change_spec <bullet> -- compact JSON {name, after, human_ok, runner,
# touches, declared} for one '## Changes' bullet. An annotation is recognized
# only when the trailing parentheses contain 'after:', 'human-ok:', 'runner:'
# or 'touches:'; every other bullet is a plain change name, so legacy missions
# parse unchanged. 'touches: none' declares an empty lock list; a missing
# touches annotation leaves declared=false (the change runs exclusively).
mission_change_spec() {
  local item="$1"
  local name="$item" inner part after="" human="" runner="" touches="" declared=false saved_ifs="$IFS"
  case "$item" in
    *"("*")"*)
      inner="${item#*(}"
      inner="${inner%)}"
      case "$inner" in
        *"after:"*|*"human-ok:"*|*"runner:"*|*"touches:"*)
          name="$(mission_trim "${item%%(*}")"
          IFS=';'
          for part in $inner; do
            part="$(mission_trim "$part")"
            case "$part" in
              after:*) after="$(mission_trim "${part#after:}")" ;;
              human-ok:*) human="$(mission_trim "${part#human-ok:}")" ;;
              runner:*) runner="$(mission_trim "${part#runner:}")" ;;
              touches:*) touches="$(mission_trim "${part#touches:}")"; declared=true ;;
            esac
          done
          IFS="$saved_ifs"
          ;;
      esac
      ;;
  esac
  local after_json human_json touches_json
  after_json="$(printf '%s' "$after" | tr ',' '\n' \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    | jq -Rsc 'split("\n") | map(select(length > 0))')"
  human_json="$(printf '%s' "$human" | tr ',' '\n' \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    | jq -Rsc 'split("\n") | map(select(length > 0))')"
  if [ "$declared" = true ] && [ "$touches" != "none" ]; then
    touches_json="$(printf '%s' "$touches" | tr ',' '\n' \
      | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
      | jq -Rsc 'split("\n") | map(select(length > 0))')"
  else
    touches_json="[]"
  fi
  jq -nc --arg n "$name" --argjson a "$after_json" --argjson h "$human_json" \
    --arg r "$runner" --argjson t "$touches_json" --argjson d "$declared" \
    '{name: $n, after: $a, human_ok: $h, runner: $r, touches: $t, declared: $d}'
}

# mission_parse <file> -- compact JSON {goal, changes:[...], change_specs:[...],
# backlog:[...]} for a mission doc. Section-aware: only bullets under
# '## Changes' are changes and only bullets under '## Backlog' are backlog; the
# goal is read only from '## Goal'/'## Brief'. A doc that carries none of these
# headings keeps the old behavior (every bullet is a change, the remaining
# prose is the goal), so existing missions still parse. Returns 1 when the file
# does not exist.
mission_parse() {
  local file="$1" line item txt section="" recognized=0
  [ -f "$file" ] || return 1
  local -a changes=() backlog=() legacy_changes=()
  local goal="" legacy_goal=""
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ ^[[:space:]]*##[[:space:]]+(Goal|Brief|Changes|Backlog)[[:space:]]*$ ]]; then
      recognized=1
      case "${BASH_REMATCH[1]}" in
        Goal|Brief) section="goal" ;;
        Changes) section="changes" ;;
        Backlog) section="backlog" ;;
      esac
      continue
    fi
    if [[ "$line" =~ ^[[:space:]]*#+[[:space:]] ]]; then
      section="other"
      continue
    fi
    if [[ "$line" =~ ^[[:space:]]*-[[:space:]]+(.+)$ ]]; then
      item="${BASH_REMATCH[1]}"
      item="${item%"${item##*[![:space:]]}"}"
      [ -n "$item" ] || continue
      legacy_changes+=("$item")
      case "$section" in
        changes) changes+=("$item") ;;
        backlog) backlog+=("$item") ;;
      esac
      continue
    fi
    txt="${line#"${line%%[![:space:]]*}"}"
    txt="${txt%"${txt##*[![:space:]]}"}"
    [ -n "$txt" ] || continue
    [ "$section" = "goal" ] && goal="$goal $txt"
    legacy_goal="$legacy_goal $txt"
  done <"$file"

  if [ "$recognized" -eq 0 ]; then
    goal="${legacy_goal# }"
    if [ "${#legacy_changes[@]}" -gt 0 ]; then changes=("${legacy_changes[@]}"); fi
  else
    goal="${goal# }"
  fi

  local changes_json="[]" backlog_json="[]" specs_json="[]" clean_changes=() spec name
  if [ "${#changes[@]}" -gt 0 ]; then
    local raw
    for raw in "${changes[@]}"; do
      spec="$(mission_change_spec "$raw")" || continue
      specs_json="$(printf '%s' "$specs_json" | jq -c --argjson s "$spec" '. + [$s]')"
      name="$(printf '%s' "$spec" | jq -r '.name')"
      clean_changes+=("$name")
    done
    changes_json="$(printf '%s\n' "${clean_changes[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')"
  fi
  [ "${#backlog[@]}" -gt 0 ] && backlog_json="$(printf '%s\n' "${backlog[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')"
  jq -nc --arg goal "$goal" --argjson changes "$changes_json" --argjson specs "$specs_json" \
    --argjson backlog "$backlog_json" \
    '{goal: $goal, changes: $changes, change_specs: $specs, backlog: $backlog}'
}

# mission_setting <file> <key> <default> -- the value of a 'key: value' line in
# the mission doc (first match), or <default>.
mission_setting() {
  local file="$1" key="$2" default="$3" line val=""
  if [ -f "$file" ]; then
    while IFS= read -r line; do
      if [[ "$line" =~ ^[[:space:]]*${key}[[:space:]]*:[[:space:]]*(.+)$ ]]; then
        val="${BASH_REMATCH[1]}"
        val="${val%"${val##*[![:space:]]}"}"
        break
      fi
    done <"$file"
  fi
  [ -n "$val" ] || val="$default"
  printf '%s\n' "$val"
}

# mission_progress_state <project> <slug> <file> -- the state that
# 'boss mission next' would effectively report for this mission: done,
# waiting_human, in_progress, blocked or missing. It mirrors the selection:
# parked changes are skipped, dependency-blocked changes are not startable, and
# waiting_human is returned when nothing else is startable but a parked change
# exists.
mission_progress_state() {
  local project="$1" slug="$2" file="$3" c st state any=false remaining=false waiting=false startable=false
  local planning spec dep human_ok deps_ok
  [ -f "$file" ] || { printf 'missing'; return 0; }
  local parsed
  parsed="$(mission_parse "$file" 2>/dev/null || true)"
  [ -n "$parsed" ] || { printf 'missing'; return 0; }
  planning="$(mission_setting "$file" planning planned)"
  local -a candidates=()
  while IFS= read -r c; do [ -n "$c" ] && candidates+=("$c"); done < <(printf '%s' "$parsed" | jq -r '.changes[]')
  if [ "$planning" = "rolling" ]; then
    while IFS= read -r c; do [ -n "$c" ] && candidates+=("$c"); done < <(printf '%s' "$parsed" | jq -r '.backlog[]')
  fi
  for c in "${candidates[@]}"; do
    [ -n "$c" ] || continue
    any=true
    st="$(mission_done_state "$project" "$c" | jq -r '.state')"
    [ "$st" = "done" ] && continue
    remaining=true
    if [ "$st" = "waiting_human" ]; then waiting=true; continue; fi
    spec="$(printf '%s' "$parsed" | jq -c --arg n "$c" \
      '(.change_specs // []) | map(select(.name == $n))[0] // {name: $n, after: [], human_ok: []}')"
    human_ok="$(printf '%s' "$spec" | jq -c '.human_ok // []')"
    deps_ok=true
    while IFS= read -r dep; do
      [ -n "$dep" ] || continue
      if ! mission_dep_satisfied "$project" "$dep" "$human_ok"; then
        deps_ok=false
        break
      fi
    done < <(printf '%s' "$spec" | jq -r '.after[]?')
    if [ "$deps_ok" = true ]; then
      startable=true
      break
    fi
  done
  if [ "$any" = false ]; then printf 'missing'; return 0; fi
  if [ "$remaining" = false ]; then printf 'done'; return 0; fi
  if [ "$startable" = true ]; then printf 'in_progress'; return 0; fi
  if [ "$waiting" = true ]; then printf 'waiting_human'; return 0; fi
  printf 'blocked'
}

# mission_charter_state <file> -- compact JSON {gate, open_questions,
# undecided_authorization}. 'charter_open' while any '- [ ]' question remains
# under '## Open Questions' or any Authorization table row has an empty decision
# cell; 'open' otherwise (also for a missing or legacy doc).
mission_charter_state() {
  local file="$1" line section="" open_q=0 undecided=0 cell
  if [ -f "$file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      if [[ "$line" =~ ^[[:space:]]*##[[:space:]]+(Open[[:space:]]+Questions|Authorization)[[:space:]]*$ ]]; then
        case "${BASH_REMATCH[1]}" in
          "Open Questions") section="questions" ;;
          "Authorization") section="auth" ;;
        esac
        continue
      fi
      if [[ "$line" =~ ^[[:space:]]*#+[[:space:]] ]]; then
        section=""
        continue
      fi
      case "$section" in
        questions)
          [[ "$line" =~ ^[[:space:]]*-[[:space:]]*\[[[:space:]]\] ]] && open_q=$(( open_q + 1 ))
          ;;
        auth)
          if [[ "$line" =~ ^[[:space:]]*\| ]]; then
            cell="$(printf '%s' "$line" | awk -F'|' '{v=$3; gsub(/^[ \t]+/,"",v); gsub(/[ \t]+$/,"",v); print v}')"
            if [ "$cell" != "Decision" ] && ! printf '%s' "$cell" | grep -qE '^-+$'; then
              [ -n "$cell" ] || undecided=$(( undecided + 1 ))
            fi
          fi
          ;;
      esac
    done <"$file"
  fi
  local gate="open"
  [ "$open_q" -gt 0 ] && gate="charter_open"
  [ "$undecided" -gt 0 ] && gate="charter_open"
  jq -nc --arg gate "$gate" --argjson oq "$open_q" --argjson u "$undecided" \
    '{gate: $gate, open_questions: $oq, undecided_authorization: $u}'
}

# mission_add_change <file> <change> -- append '- <change>' under '## Changes'
# (creating the section if needed), atomically and without duplicating an
# existing entry. Returns 1 on a write error.
mission_add_change() {
  local file="$1" change="$2" tmp
  [ -f "$file" ] || return 1
  tmp="$(mktemp "${file}.XXXXXX" 2>/dev/null)" || return 1
  if awk -v change="$change" '
      /^## Changes[[:space:]]*$/ { in_changes = 1; print; next }
      in_changes && /^## / { if (!inserted && !seen) { printf "- %s\n", change; inserted = 1 } in_changes = 0 }
      in_changes && /^[[:space:]]*-[[:space:]]+/ {
        t = $0; sub(/^[[:space:]]*-[[:space:]]+/, "", t); sub(/[[:space:]]+$/, "", t)
        if (t == change) seen = 1
        print; next
      }
      { print }
      END {
        if (in_changes && !inserted && !seen) { printf "- %s\n", change; inserted = 1 }
        if (!inserted && !seen) { printf "\n## Changes\n- %s\n", change }
      }
    ' "$file" >"$tmp"; then
    mv "$tmp" "$file" || { rm -f "$tmp"; return 1; }
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# mission_remove_change <file> <change> -- remove the '- <change>' line under
# '## Changes', atomically. Returns 1 on a write error.
mission_remove_change() {
  local file="$1" change="$2" tmp
  [ -f "$file" ] || return 1
  tmp="$(mktemp "${file}.XXXXXX" 2>/dev/null)" || return 1
  if awk -v change="$change" '
      /^## Changes[[:space:]]*$/ { in_changes = 1; print; next }
      in_changes && /^## / { in_changes = 0 }
      in_changes && /^[[:space:]]*-[[:space:]]+/ {
        t = $0; sub(/^[[:space:]]*-[[:space:]]+/, "", t); sub(/[[:space:]]+$/, "", t)
        if (t == change) next
      }
      { print }
    ' "$file" >"$tmp"; then
    mv "$tmp" "$file" || { rm -f "$tmp"; return 1; }
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# cmd_mission_start <slug> <project-name> -- create the mission doc if missing
cmd_mission_start() {
  local slug="$1" project_name="$2"
  ensure_config
  local project dir file created=false
  project="$(resolve_project "$project_name")" || exit 1
  dir="$(missions_dir "$project")"
  file="$dir/$slug.md"
  if [ ! -f "$file" ]; then
    mkdir -p "$dir" || die_json "mission_write" "cannot create missions dir: $dir"
    cat >"$file" <<EOF || die_json "mission_write" "cannot write mission file: $file"
# Mission: $slug

## Goal

Describe the goal of this mission: what should exist when it is done.

## Non-Goals

## Constraints

## Build Environment

## External Review

## Marker Policy

## Commit Policy

## Runner Policy

## Start

## Authorization

| Category | Decision | Bound |
| --- | --- | --- |
| Remote push |  |  |
| Spending / API cost |  |  |
| sudo / root |  |  |
| Data deletion |  |  |
| External network / SSH |  |  |
| History rewrite / force-push |  |  |

## Stop Conditions

## Open Questions

## Plan

planning: planned
reconcile: explore

## Changes

EOF
    created=true
  fi
  printf '%s\n' "$(jq -n --arg slug "$slug" --arg project "$project" --arg path "$file" \
    --argjson created "$created" \
    '{slug: $slug, project: $project, path: $path, status: (if $created then "created" else "exists" end)}')"
}

# cmd_mission_status <slug> <project-name> -- goal, charter, planning mode and
# derived per-change state
cmd_mission_status() {
  local slug="$1" project_name="$2"
  ensure_config
  local project file default_runner max_parallel running slots_free
  project="$(resolve_project "$project_name")" || exit 1
  default_runner="$(config_json | jq -r '.default // empty')"
  max_parallel="$(mission_max_parallel)" || exit 1
  running="$(open_apply_count)"
  slots_free=$(( max_parallel - running ))
  [ "$slots_free" -lt 0 ] && slots_free=0
  file="$(mission_file_for "$project" "$slug")"
  if [ ! -f "$file" ]; then
    printf '%s\n' "$(jq -n --arg slug "$slug" --arg project "$project" --arg path "$file" \
      --argjson max_parallel "$max_parallel" --argjson running "$running" --argjson slots_free "$slots_free" \
      '{slug: $slug, project: $project, path: $path, status: "mission_missing", goal: null, charter: {gate: "open", open_questions: 0, undecided_authorization: 0}, planning: "planned", reconcile: "explore", start_after: null, start_after_state: null, max_parallel: $max_parallel, running: $running, slots_used: $running, slots_free: $slots_free, changes: [], dependencies: [], backlog: [], progress: {total: 0, done: 0}}')"
    return 0
  fi
  local parsed goal backlog_json specs_json deps_json charter planning reconcile
  local start_after start_after_state="null"
  parsed="$(mission_parse "$file")" || die_json "mission_invalid" "cannot parse mission file $file"
  goal="$(printf '%s' "$parsed" | jq -r '.goal')"
  backlog_json="$(printf '%s' "$parsed" | jq -c '.backlog')"
  specs_json="$(printf '%s' "$parsed" | jq -c '.change_specs // []')"
  deps_json="$(printf '%s' "$specs_json" | jq -c --arg d "$default_runner" \
    'map(. + {runner: (if (.runner // "") == "" then $d else .runner end)})')"
  charter="$(mission_charter_state "$file")"
  planning="$(mission_setting "$file" planning planned)"
  reconcile="$(mission_setting "$file" reconcile explore)"
  start_after="$(mission_setting "$file" start_after "")"
  if [ -n "$start_after" ]; then
    local sa_slug sa_file
    sa_slug="${start_after%%[ (]*}"
    sa_file="$(mission_file_for "$project" "$sa_slug")"
    start_after_state="$(mission_progress_state "$project" "$sa_slug" "$sa_file" | jq -Rsc '.')"
  fi
  local -a changes=()
  while IFS= read -r c; do [ -n "$c" ] && changes+=("$c"); done < <(printf '%s' "$parsed" | jq -r '.changes[]')
  if [ "${#changes[@]}" -eq 0 ]; then
    printf '%s\n' "$(jq -n --arg slug "$slug" --arg project "$project" --arg path "$file" --arg goal "$goal" \
      --argjson charter "$charter" --arg planning "$planning" --arg reconcile "$reconcile" --argjson backlog "$backlog_json" \
      --argjson specs "$deps_json" --arg start_after "$start_after" --argjson start_after_state "$start_after_state" \
      --argjson max_parallel "$max_parallel" --argjson running "$running" --argjson slots_free "$slots_free" \
      '{slug: $slug, project: $project, path: $path, status: "no_changes", goal: (if $goal == "" then null else $goal end), charter: $charter, planning: $planning, reconcile: $reconcile, start_after: (if $start_after == "" then null else $start_after end), start_after_state: $start_after_state, max_parallel: $max_parallel, running: $running, slots_used: $running, slots_free: $slots_free, changes: [], dependencies: $specs, backlog: $backlog, progress: {total: 0, done: 0}}')"
    return 0
  fi
  local json="[]" c st done_count=0 spec runner touches declared c_running state_file
  for c in "${changes[@]}"; do
    st="$(mission_done_state "$project" "$c")"
    spec="$(printf '%s' "$specs_json" | jq -c --arg n "$c" \
      'map(select(.name == $n))[0] // {name: $n, runner: "", touches: [], declared: false}')"
    runner="$(printf '%s' "$spec" | jq -r '.runner // empty')"
    [ -n "$runner" ] || runner="$default_runner"
    touches="$(printf '%s' "$spec" | jq -c '.touches // []')"
    declared="$(printf '%s' "$spec" | jq -r '.declared // false')"
    c_running=false
    state_file="$(state_file_for "$project" "$c")"
    if [ -f "$state_file" ]; then
      if [ "$(jq -r '.parked // false' "$state_file" 2>/dev/null || printf false)" != "true" ] \
         && [ "$(jq -r '.merge_state // "none"' "$state_file" 2>/dev/null || printf none)" != "done" ]; then
        c_running=true
      fi
    fi
    st="$(printf '%s' "$st" | jq -c --arg r "$runner" --argjson t "$touches" \
      --argjson d "$declared" --argjson run "$c_running" \
      '. + {runner: (if $r == "" then null else $r end), touches: $t, declared: $d, running: $run}')"
    json="$(printf '%s' "$json" | jq -c --argjson s "$st" '. + [$s]')"
    [ "$(printf '%s' "$st" | jq -r '.state')" = "done" ] && done_count=$((done_count + 1))
  done
  printf '%s\n' "$(jq -n --arg slug "$slug" --arg project "$project" --arg path "$file" --arg goal "$goal" \
    --argjson charter "$charter" --arg planning "$planning" --arg reconcile "$reconcile" \
    --argjson changes "$json" --argjson backlog "$backlog_json" --argjson "done" "$done_count" \
    --argjson specs "$deps_json" --arg start_after "$start_after" --argjson start_after_state "$start_after_state" \
    --argjson max_parallel "$max_parallel" --argjson running "$running" --argjson slots_free "$slots_free" \
    '{slug: $slug, project: $project, path: $path, status: "ok", goal: (if $goal == "" then null else $goal end), charter: $charter, planning: $planning, reconcile: $reconcile, start_after: (if $start_after == "" then null else $start_after end), start_after_state: $start_after_state, max_parallel: $max_parallel, running: $running, slots_used: $running, slots_free: $slots_free, changes: $changes, dependencies: $specs, backlog: $backlog, progress: {total: ($changes | length), done: $done}}')"
}

# mission_dep_satisfied <project> <dep> <human-ok-json> -- 0 when a prerequisite
# is done, or is waiting_human and explicitly allowed by human-ok.
mission_dep_satisfied() {
  local project="$1" dep="$2" human_ok="$3" dep_state
  dep_state="$(mission_done_state "$project" "$dep" | jq -r '.state')"
  [ "$dep_state" = "done" ] && return 0
  [ "$dep_state" = "waiting_human" ] || return 1
  printf '%s' "$human_ok" | jq -e --arg d "$dep" 'index($d) != null' >/dev/null 2>&1
}

# cmd_mission_next <slug> <project-name> -- dispatch the first startable change
# that is not done. Parked changes and changes whose prerequisites are neither
# done nor human-ok are skipped; if only parked work remains, the result is the
# non-error handoff waiting_human.
cmd_mission_next() {
  local slug="$1" project_name="$2" as_target="${3:-}" dry_run="${4:-0}" skip_reconcile="${5:-0}" want_worktree="${6:-0}"
  if [ "$dry_run" -ne 1 ]; then
    boss_use_caller "$as_target"
    ensure_boss_claim dispatch
  fi
  ensure_config
  local project file
  project="$(resolve_project "$project_name")" || exit 1
  file="$(mission_file_for "$project" "$slug")"
  [ -f "$file" ] || die_json "mission_missing" "mission '$slug' not found at $file; create it with 'boss mission start $slug --project <name|path>'"

  # The charter gate: nothing is dispatched while a question or an
  # authorization row is still open.
  local charter
  charter="$(mission_charter_state "$file")"
  if [ "$(printf '%s' "$charter" | jq -r '.gate')" != "open" ]; then
    die_json "charter_open" "mission '$slug' has an open charter ($(printf '%s' "$charter" | jq -r '"\(.open_questions) open question(s), \(.undecided_authorization) undecided authorization row(s)"')); resolve the charter before dispatching"
  fi

  local parsed planning specs_json
  parsed="$(mission_parse "$file")" || die_json "mission_invalid" "cannot parse mission file $file"
  planning="$(mission_setting "$file" planning planned)"
  specs_json="$(printf '%s' "$parsed" | jq -c '.change_specs // []')"

  local start_after start_slug start_cond start_file start_state
  start_after="$(mission_setting "$file" start_after "")"
  if [ -n "$start_after" ]; then
    start_slug="${start_after%%[ (]*}"
    start_cond="${start_after#*(}"
    if [ "$start_cond" = "$start_after" ]; then start_cond="waiting_human"; else start_cond="${start_cond%)}"; fi
    start_file="$(mission_file_for "$project" "$start_slug")"
    start_state="$(mission_progress_state "$project" "$start_slug" "$start_file")"
    local start_ok=false
    case "$start_cond" in
      done) [ "$start_state" = "done" ] && start_ok=true ;;
      waiting_human) { [ "$start_state" = "waiting_human" ] || [ "$start_state" = "done" ]; } && start_ok=true ;;
      *) start_ok=false ;;
    esac
    if [ "$start_ok" != true ]; then
      printf '%s\n' "$(jq -n --arg slug "$slug" --arg project "$project" \
        --arg start "$start_after" --arg dep "$start_slug" --arg state "$start_state" \
        '{slug: $slug, project: $project, status: "mission_waiting",
          start_after: $start, prerequisite: $dep, prerequisite_state: $state}')"
      return 0
    fi
  fi
  local -a candidates=()
  while IFS= read -r c; do [ -n "$c" ] && candidates+=("$c"); done < <(printf '%s' "$parsed" | jq -r '.changes[]')
  # In rolling mode the backlog is a second source of candidates.
  if [ "$planning" = "rolling" ]; then
    while IFS= read -r c; do [ -n "$c" ] && candidates+=("$c"); done < <(printf '%s' "$parsed" | jq -r '.backlog[]')
  fi
  [ "${#candidates[@]}" -gt 0 ] || die_json "mission_empty" "mission '$slug' names no changes in $file"

  local max_parallel running slots_free
  max_parallel="$(mission_max_parallel)" || exit 1
  running="$(open_apply_count)"
  slots_free=$(( max_parallel - running ))
  [ "$slots_free" -lt 0 ] && slots_free=0

  local c st state spec dep human_ok target="" target_state="" target_st=""
  local target_touches="[]" target_declared=false
  local any_parked=false any_remaining=false handoff_json="[]"
  local limit_hit=false skipped_json="[]" holders_json="[]"
  local c_state_file c_parked c_open c_touches c_declared c_lock
  for c in "${candidates[@]}"; do
    st="$(mission_done_state "$project" "$c")"
    state="$(printf '%s' "$st" | jq -r '.state')"
    [ "$state" = "done" ] || any_remaining=true

    if [ "$state" = "waiting_human" ]; then
      any_parked=true
      handoff_json="$(printf '%s' "$handoff_json" | jq -c --arg c "$c" --argjson st "$st" \
        '. + [{change: $c, tasks: ($st.human_tasks // []), state: $st.state}]')"
      continue
    fi
    [ "$state" = "done" ] && continue

    # A change that already has an apply state is not started again: it is
    # running, failed or waiting to be finished. The one exception is the
    # documented check-off path: a parked change whose tasks are all checked
    # may start again without an explicit resume.
    c_state_file="$(state_file_for "$project" "$c")"
    if [ -f "$c_state_file" ]; then
      c_parked="$(jq -r '.parked // false' "$c_state_file" 2>/dev/null || printf false)"
      c_open="$(printf '%s' "$st" | jq -r '.tasks.open // "null"')"
      if [ "$c_parked" != "true" ] || [ "$c_open" != "0" ]; then
        skipped_json="$(printf '%s' "$skipped_json" | jq -c --arg c "$c" \
          --argjson parked "$( [ "$c_parked" = "true" ] && printf true || printf false )" \
          '. + [{change: $c, reason: "has_state", parked: $parked}]')"
        continue
      fi
    fi

    spec="$(printf '%s' "$specs_json" | jq -c --arg n "$c" \
      'map(select(.name == $n))[0] // {name: $n, after: [], human_ok: [], touches: [], declared: false}')"
    human_ok="$(printf '%s' "$spec" | jq -c '.human_ok // []')"
    local satisfied=true
    while IFS= read -r dep; do
      [ -n "$dep" ] || continue
      if ! mission_dep_satisfied "$project" "$dep" "$human_ok"; then
        satisfied=false
        break
      fi
    done < <(printf '%s' "$spec" | jq -r '.after[]?')

    [ "$satisfied" = true ] || continue

    c_touches="$(printf '%s' "$spec" | jq -c '.touches // []')"
    c_declared="$(printf '%s' "$spec" | jq -r '.declared // false')"

    if [ "$running" -ge "$max_parallel" ] 2>/dev/null; then
      limit_hit=true
      break
    fi

    c_lock="$(lock_check "$project" "$c" "$c_touches" "$c_declared" "$c_state_file")"
    if [ "$(printf '%s' "$c_lock" | jq -r '.conflict')" = "true" ]; then
      holders_json="$(printf '%s' "$holders_json" | jq -c --argjson hs "$(printf '%s' "$c_lock" | jq -c '.holders')" '. + $hs')"
      skipped_json="$(printf '%s' "$skipped_json" | jq -c --arg c "$c" \
        --argjson holders "$(printf '%s' "$c_lock" | jq -c '[.holders[].change]')" \
        '. + [{change: $c, reason: "lock_conflict", holders: $holders}]')"
      continue
    fi

    target="$c"
    target_state="$state"
    target_st="$st"
    target_touches="$c_touches"
    target_declared="$c_declared"
    break
  done

  if [ -z "$target" ]; then
    if [ "$limit_hit" = true ]; then
      printf '%s\n' "$(jq -n --arg slug "$slug" --arg project "$project" \
        --argjson current "$running" --argjson max "$max_parallel" \
        '{slug: $slug, project: $project, status: "parallel_limit",
          current: $current, max: $max, slots_used: $current, slots_free: 0}')"
      return 0
    fi
    if [ "$any_parked" = true ]; then
      printf '%s\n' "$(jq -n --arg slug "$slug" --arg project "$project" \
        --argjson handoff "$handoff_json" \
        '{slug: $slug, project: $project, status: "waiting_human", handoff: $handoff}')"
      return 0
    fi
    if [ "$any_remaining" = false ]; then
      printf '%s\n' "$(jq -n --arg slug "$slug" --arg project "$project" --arg status "mission_complete" \
        '{slug: $slug, project: $project, status: $status}')"
      return 0
    fi
    if [ "$(printf '%s' "$skipped_json" | jq 'length')" -gt 0 ] \
       || [ "$(printf '%s' "$holders_json" | jq 'length')" -gt 0 ]; then
      local remaining_json
      remaining_json="$(printf '%s' "$parsed" | jq -c '.changes')"
      printf '%s\n' "$(jq -n --arg slug "$slug" --arg project "$project" \
        --argjson holders "$holders_json" --argjson skipped "$skipped_json" \
        --argjson remaining "$remaining_json" \
        '{slug: $slug, project: $project, status: "no_startable",
          reason: "no startable change; running or lock-conflicting applies hold it",
          holders: $holders, skipped: $skipped, remaining: $remaining}')"
      return 0
    fi
    local remaining_json
    remaining_json="$(printf '%s' "$parsed" | jq -c '.changes')"
    printf '%s\n' "$(jq -n --arg slug "$slug" --arg project "$project" \
      --argjson remaining "$remaining_json" \
      '{slug: $slug, project: $project, status: "mission_blocked",
        reason: "no startable change; declared prerequisites are unfinished", remaining: $remaining}')"
    return 0
  fi

  # Resolve the per-change runner before the gate and workspace checks. An
  # unknown name fails here and starts nothing.
  local target_spec target_runner runner
  target_spec="$(printf '%s' "$specs_json" | jq -c --arg n "$target" \
    'map(select(.name == $n))[0] // {name: $n, runner: "", touches: [], declared: false}')"
  target_runner="$(printf '%s' "$target_spec" | jq -r '.runner // empty')"
  runner="$(resolve_runner "$target_runner")" || exit 1

  # Reconcile gate: after a mission boundary (finish/park), the target change
  # needs a fresh reconcile_done marker. A dry run reports the same state but
  # never writes anything.
  local boundary="" done_at="" reconcile_required=false
  boundary="$(mission_last_boundary "$project" "$slug" "${candidates[@]}")"
  if [ -n "$boundary" ]; then
    done_at="$(mission_reconcile_done_at "$project" "$slug" "$target")"
    if [ -z "$done_at" ] || [[ "$done_at" < "$boundary" ]]; then
      reconcile_required=true
    fi
  fi

  if [ "$dry_run" -eq 1 ]; then
    local dry_reason=""
    [ "$target_state" = "change_not_ready" ] && dry_reason="change_not_ready"
    [ "$(printf '%s' "$target_st" | jq -r '.ready')" = "false" ] && dry_reason="change_not_ready"
    [ "$reconcile_required" = true ] && [ "$skip_reconcile" -ne 1 ] && dry_reason="reconcile_required"
    printf '%s\n' "$(jq -n --arg slug "$slug" --arg project "$project" \
      --arg change "$target" --arg runner "$(printf '%s' "$runner" | jq -r '.name')" \
      --arg state "$target_state" --arg boundary "$boundary" --arg done_at "$done_at" \
      --arg reason "$dry_reason" --argjson required "$reconcile_required" \
      --argjson ready "$(printf '%s' "$target_st" | jq -r '.ready')" \
      '{slug: $slug, project: $project, status: (if $reason == "" then "dry_run" else $reason end),
        change: $change, runner: $runner, state: $state, ready: $ready,
        would_start: ($reason == ""), reason: (if $reason == "" then null else $reason end),
        reconcile: {required: $required, boundary: (if $boundary == "" then null else $boundary end),
                    done_at: (if $done_at == "" then null else $done_at end)}}')"
    return 0
  fi

  if [ "$target_state" = "change_not_ready" ]; then
    die_json "change_not_ready" "change '$target' in $project has no proposal yet; create it before 'boss mission next' can dispatch it (missing artifact: proposal)"
  fi

  if [ "$(printf '%s' "$target_st" | jq -r '.ready')" = "false" ]; then
    die_json "change_not_ready" "change '$target' in $project is missing artifacts: $(printf '%s' "$target_st" | jq -r '(.missing_artifacts // []) | join(", ")'); create them before 'boss mission next' can dispatch it"
  fi

  if [ "$reconcile_required" = true ] && [ "$skip_reconcile" -ne 1 ]; then
    die_json "reconcile_required" "change '$target' in mission '$slug' needs a fresh reconcile after the last mission finish/park (boundary ${boundary:-unknown}); run 'boss reconcile $slug --project $project --done $target' or pass --skip-reconcile"
  fi

  if [ "$reconcile_required" = true ] && [ "$skip_reconcile" -eq 1 ]; then
    local jfile
    jfile="$(journal_project_path "$project" 2>/dev/null || true)"
    [ -n "$jfile" ] && journal_append "$jfile" \
      "skipped reconcile for $target after mission boundary $boundary (mission $slug)" \
      "reconcile-skipped" || true
    append_event "$(mission_events_file "$project" "$slug")" reconcile_skipped \
      "$(jq -nc --arg c "$target" --arg s "$slug" --arg b "$boundary" \
        '{change: $c, mission: $s, boundary: (if $b == "" then null else $b end)}')" \
      || log "warning: could not record reconcile_skipped"
  fi

  # One executer per workspace: check only once a change is actually startable,
  # so a handoff or a complete mission is not blocked by a busy workspace. A
  # worktree apply runs in its own workspace; dispatch_change checks that one.
  if [ "$want_worktree" != "1" ]; then
    local workspace_id
    workspace_id="$(find_workspace_for_repo "$project")"
    [ -n "$workspace_id" ] && assert_workspace_free "$workspace_id"
  fi

  dispatch_change "$target" "$project" "$runner" "" "$want_worktree" "$target_touches" "$target_declared"
}

# cmd_mission_add <slug> <change> <project-name> -- append a change to the mission
cmd_mission_add() {
  local slug="$1" change="$2" project_name="$3"
  ensure_config
  local project file
  project="$(resolve_project "$project_name")" || exit 1
  file="$(mission_file_for "$project" "$slug")"
  [ -f "$file" ] || die_json "mission_missing" "mission '$slug' not found at $file"
  mission_add_change "$file" "$change" || die_json "mission_write" "cannot update mission file $file"
  printf '%s\n' "$(jq -n --arg slug "$slug" --arg project "$project" --arg path "$file" --arg change "$change" \
    '{slug: $slug, project: $project, path: $path, change: $change, status: "added"}')"
}

# cmd_mission_rm <slug> <change> <project-name> -- remove a change from the mission
cmd_mission_rm() {
  local slug="$1" change="$2" project_name="$3"
  ensure_config
  local project file
  project="$(resolve_project "$project_name")" || exit 1
  file="$(mission_file_for "$project" "$slug")"
  [ -f "$file" ] || die_json "mission_missing" "mission '$slug' not found at $file"
  mission_remove_change "$file" "$change" || die_json "mission_write" "cannot update mission file $file"
  printf '%s\n' "$(jq -n --arg slug "$slug" --arg project "$project" --arg path "$file" --arg change "$change" \
    '{slug: $slug, project: $project, path: $path, change: $change, status: "removed"}')"
}

# cmd_mission <action> <slug> [--project <name|path>] -- dispatch the mission
# subcommands and reject a slug that would escape the missions directory.
cmd_mission() {
  local action="" slug="" change="" project_name="" as_target="" dry_run=0 skip_reconcile=0 arg
  local wt_flag="" no_wt_flag=""
  while [ $# -gt 0 ]; do
    arg="$1"; shift
    case "$arg" in
      --project) project_name="${1:-}"; shift ;;
      --as) as_target="${1:-}"; shift ;;
      --dry-run) dry_run=1 ;;
      --skip-reconcile) skip_reconcile=1 ;;
      --worktree) wt_flag=1 ;;
      --no-worktree) no_wt_flag=1 ;;
      -h|--help) usage ;;
      --*) usage_error "unknown option: $arg" ;;
      *)
        if [ -z "$action" ]; then action="$arg"
        elif [ -z "$slug" ]; then slug="$arg"
        elif [ -z "$change" ]; then change="$arg"
        else usage_error "unexpected argument: $arg"; fi ;;
    esac
  done
  [ -n "$action" ] || usage_error "usage: boss mission start|status|next|add|rm <slug> [<change>] [--project <name|path>]"
  [ -n "$slug" ] || usage_error "usage: boss mission $action <slug> [--project <name|path>]"
  case "$slug" in
    */*|*..*) usage_error "invalid mission slug: $slug" ;;
  esac
  if [ "$action" != "next" ] && { [ "$dry_run" -eq 1 ] || [ "$skip_reconcile" -eq 1 ] \
       || [ -n "$wt_flag" ] || [ -n "$no_wt_flag" ]; }; then
    usage_error "--dry-run, --skip-reconcile, --worktree and --no-worktree apply only to 'boss mission next'"
  fi
  local want_worktree=0 wt_mode max_parallel
  if [ "$action" = "next" ]; then
    max_parallel="$(mission_max_parallel)" || exit 1
    wt_mode="$(mission_worktree_mode)" || exit 1
    want_worktree="$(resolve_worktree_flag "$wt_mode" "$wt_flag" "$no_wt_flag" "$max_parallel")" || exit 1
  fi
  case "$action" in
    start) cmd_mission_start "$slug" "$project_name" ;;
    status) cmd_mission_status "$slug" "$project_name" ;;
    next) cmd_mission_next "$slug" "$project_name" "$as_target" "$dry_run" "$skip_reconcile" "$want_worktree" ;;
    add)
      [ -n "$change" ] || usage_error "usage: boss mission add <slug> <change> [--project <name|path>]"
      cmd_mission_add "$slug" "$change" "$project_name" ;;
    rm)
      [ -n "$change" ] || usage_error "usage: boss mission rm <slug> <change> [--project <name|path>]"
      cmd_mission_rm "$slug" "$change" "$project_name" ;;
    *) usage_error "unknown mission action: $action" ;;
  esac
}

# --------------------------------------------------------------- reconcile ---

# cmd_reconcile <slug> [--project <name|path>] [--json] -- read-only context for
# the post-apply reconciliation: charter state, remaining changes, backlog, open
# inbox items and the journal tail.
cmd_reconcile() {
  ensure_config
  local slug="" project_name="" want_json=0 done_change="" note="" arg
  while [ $# -gt 0 ]; do
    arg="$1"; shift
    case "$arg" in
      --project) project_name="${1:-}"; shift ;;
      --json) want_json=1 ;;
      --done) done_change="${1:-}"; shift ;;
      --note) note="$(one_line "${1:-}")"; shift ;;
      -h|--help) usage ;;
      --*) usage_error "unknown option: $arg" ;;
      *) if [ -z "$slug" ]; then slug="$arg"; else usage_error "unexpected argument: $arg"; fi ;;
    esac
  done
  [ -n "$slug" ] || usage_error "usage: boss reconcile <slug> [--project <name|path>] [--json] [--done <change>] [--note <text>]"
  case "$slug" in
    */*|*..*) usage_error "invalid mission slug: $slug" ;;
  esac

  local project file
  project="$(resolve_project "$project_name")" || exit 1
  file="$(mission_file_for "$project" "$slug")"
  [ -f "$file" ] || die_json "mission_missing" "mission '$slug' not found at $file"

  local parsed goal charter planning reconcile backlog_json specs_json
  parsed="$(mission_parse "$file")" || die_json "mission_invalid" "cannot parse mission file $file"
  goal="$(printf '%s' "$parsed" | jq -r '.goal')"
  backlog_json="$(printf '%s' "$parsed" | jq -c '.backlog')"
  specs_json="$(printf '%s' "$parsed" | jq -c '.change_specs // []')"
  if [ -n "$done_change" ]; then
    printf '%s' "$parsed" | jq -e --arg c "$done_change" '.changes | index($c) != null' >/dev/null 2>&1 \
      || die_json "mission_change_unknown" "change '$done_change' is not listed in mission '$slug' ($file)"
  fi
  charter="$(mission_charter_state "$file")"
  planning="$(mission_setting "$file" planning planned)"
  reconcile="$(mission_setting "$file" reconcile explore)"

  local changes_json="[]" remaining_json="[]" c st state
  local next_change="" next_fallback=""
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    st="$(mission_done_state "$project" "$c")"
    state="$(printf '%s' "$st" | jq -r '.state')"
    changes_json="$(printf '%s' "$changes_json" | jq -c --argjson s "$st" '. + [$s]')"
    if [ "$state" != "done" ]; then
      remaining_json="$(printf '%s' "$remaining_json" | jq -c --arg c "$c" '. + [$c]')"
      [ -n "$next_fallback" ] || next_fallback="$c"
      if [ -z "$next_change" ] && [ "$state" != "waiting_human" ]; then
        next_change="$c"
      fi
    fi
  done < <(printf '%s' "$parsed" | jq -r '.changes[]')
  [ -n "$next_change" ] || next_change="$next_fallback"

  local inbox_json="[]" f iproject
  for f in "$BOSS_INBOX_DIR"/*.json; do
    [ -f "$f" ] || continue
    iproject="$(jq -r '.project // empty' "$f" 2>/dev/null || true)"
    [ "$iproject" = "$project" ] || continue
    inbox_json="$(printf '%s' "$inbox_json" | jq -c --argjson i "$(jq -c '{id, ts, change, state}' "$f")" '. + [$i]')"
  done

  local jfile journal_json="[]" reconciled="null" recommendations="[]"
  jfile="$(journal_project_path "$project" 2>/dev/null || true)"
  if [ -n "$done_change" ]; then
    append_event "$(mission_events_file "$project" "$slug")" reconcile_done \
      "$(jq -nc --arg c "$done_change" --arg s "$slug" --arg n "$note" \
        '{change: $c, mission: $s, note: (if $n == "" then null else $n end)}')" \
      || die_json "state_write" "cannot record reconcile marker for $done_change"
    if [ -n "$jfile" ]; then
      journal_append "$jfile" "reconciled mission $slug for $done_change${note:+ -- $note}" "reconcile-done" \
        || log "warning: could not write the reconcile journal entry"
    fi
    reconciled="$(jq -nc --arg c "$done_change" --arg at "$(now_iso)" \
      '{change: $c, at: $at}')"
    # Refresh the tail after the journal write.
    journal_json="[]"
    [ -f "$jfile" ] && journal_json="$(tail -n 20 "$jfile" | jq -Rsc 'split("\n") | map(select(length > 0))')"
  elif [ -n "$jfile" ] && [ -f "$jfile" ]; then
    journal_json="$(tail -n 20 "$jfile" | jq -Rsc 'split("\n") | map(select(length > 0))')"
  fi

  # Approved research recommendations targeting the next change that have no
  # recommendation-adopted journal entry yet.
  local rec_file="$project/openspec/recommendations.md"
  if [ -n "$next_change" ] && [ -f "$rec_file" ]; then
    local row_id row_target row_decision row_note adopted
    while IFS='|' read -r _ row_id row_target row_decision row_note _; do
      row_id="$(mission_trim "${row_id:-}")"
      row_target="$(mission_trim "${row_target:-}")"
      row_decision="$(mission_trim "${row_decision:-}")"
      row_note="$(mission_trim "${row_note:-}")"
      [ -n "$row_id" ] || continue
      [ "$(printf '%s' "$row_decision" | tr '[:upper:]' '[:lower:]')" = "approved" ] || continue
      [ "$row_target" = "$next_change" ] || continue
      adopted=false
      if [ -n "$jfile" ] && [ -f "$jfile" ] && grep -q "\[recommendation-adopted\].*${row_id}" "$jfile" 2>/dev/null; then
        adopted=true
      fi
      [ "$adopted" = true ] && continue
      recommendations="$(printf '%s' "$recommendations" | jq -c \
        --arg id "$row_id" --arg t "$row_target" --arg n "$row_note" \
        '. + [{id: $id, target: $t, note: (if $n == "" then null else $n end)}]')"
    done < <(grep '^|' "$rec_file" 2>/dev/null || true)
  fi

  local json
  json="$(jq -n --arg slug "$slug" --arg project "$project" --arg path "$file" --arg goal "$goal" \
    --argjson charter "$charter" --arg planning "$planning" --arg reconcile "$reconcile" \
    --argjson changes "$changes_json" --argjson remaining "$remaining_json" --argjson backlog "$backlog_json" \
    --argjson inbox "$inbox_json" --argjson journal "$journal_json" --argjson specs "$specs_json" \
    --argjson reconciled "$reconciled" --arg next_change "$next_change" \
    --argjson recommendations "$recommendations" \
    '{slug: $slug, project: $project, path: $path, goal: (if $goal == "" then null else $goal end),
      charter: $charter, planning: $planning, reconcile: $reconcile,
      changes: $changes, dependencies: $specs, remaining: $remaining, backlog: $backlog,
      next_change: (if $next_change == "" then null else $next_change end),
      recommendations: $recommendations,
      inbox: $inbox, journal_tail: $journal, reconciled: $reconciled}')"

  if [ "$want_json" -eq 1 ]; then
    printf '%s\n' "$json"
    return 0
  fi
  printf 'mission: %s (%s)\n' "$slug" "$project"
  printf 'charter: %s -- %s open question(s), %s undecided authorization row(s)\n' \
    "$(printf '%s' "$charter" | jq -r '.gate')" \
    "$(printf '%s' "$charter" | jq -r '.open_questions')" \
    "$(printf '%s' "$charter" | jq -r '.undecided_authorization')"
  printf 'planning: %s, reconcile: %s\n' "$planning" "$reconcile"
  printf 'remaining: %s\n' "$(printf '%s' "$remaining_json" | jq -r 'if length == 0 then "(none)" else join(", ") end')"
  printf 'inbox: %s open item(s)\n' "$(printf '%s' "$inbox_json" | jq -r 'length')"
  printf 'next change: %s\n' "${next_change:-(none)}"
  if [ "$(printf '%s' "$recommendations" | jq 'length')" -gt 0 ]; then
    printf 'pending recommendations for %s:\n' "$next_change"
    printf '%s' "$recommendations" | jq -r '.[] | "- \(.id) \(.note // "")"'
  fi
  printf '%s\n' "$json"
  return 0
}

# -------------------------------------------------------------------- main ---

