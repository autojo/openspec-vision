#!/usr/bin/env bash
# boss-doctor -- part of the boss runtime, sourced by bin/boss after boss-lib.sh.
# Contains only function definitions; nothing runs when this file is sourced.

doctor_check_json() {
  jq -nc --arg id "$1" --arg s "$2" --arg h "$3" \
    '{id: $id, status: $s, hint: (if $h == "" then null else $h end)}'
}

# doctor_add <id> <status> <hint> -- append one check to $DOCTOR_TMP.
doctor_add() {
  doctor_check_json "$1" "$2" "$3" >>"${DOCTOR_TMP:-/dev/null}"
}

# doctor_register_project <project> <name> -- add '[projects] name = "path"'
# to $BOSS_CONFIG when the project is not registered yet. Additive and safe;
# returns 0 when already present or written, 1 when it cannot (name taken).
doctor_register_project() {
  local project="$1" name="$2" cfg tmp
  is_project_registered "$project" && return 0
  cfg="$(config_json 2>/dev/null || true)"
  if printf '%s' "$cfg" | jq -e --arg n "$name" '.projects // {} | has($n)' >/dev/null 2>&1; then
    return 1
  fi
  [ -f "$BOSS_CONFIG" ] || return 1
  tmp="$(mktemp "${BOSS_CONFIG}.XXXXXX" 2>/dev/null)" || return 1
  if awk -v name="$name" -v path="$project" '
      BEGIN { in_projects = 0; inserted = 0 }
      /^\[projects\][[:space:]]*$/ { in_projects = 1; print; printf "%s = \"%s\"\n", name, path; inserted = 1; next }
      /^\[/ { if (in_projects) in_projects = 0 }
      { print }
      END { if (!inserted) printf "\n[projects]\n%s = \"%s\"\n", name, path }
    ' "$BOSS_CONFIG" >"$tmp"; then
    mv "$tmp" "$BOSS_CONFIG" || { rm -f "$tmp"; return 1; }
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# doctor_check_worktrees <project> <have-herdr> <fix> -- the worktree checks of
# one project: whether dispatch can create a worktree at all, which worktree
# applies are open, and which worktrees under BOSS_WORKTREES_DIR have no state.
# Split out of cmd_doctor so the command stays navigable.
doctor_check_worktrees() {
  local project="$1" have_herdr="$2" fix="$3"
  # Worktree support and the state of every worktree apply of this project.
  local wt_support=ok wt_support_hint=""
  if ! git -C "$project" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    wt_support=warn
    wt_support_hint="$project is not a git repository; worktree dispatch is unavailable"
  elif ! git -C "$project" worktree list >/dev/null 2>&1; then
    wt_support=warn
    wt_support_hint="git worktree is unavailable in $project"
  elif [ "$have_herdr" -ne 1 ]; then
    wt_support=warn
    wt_support_hint="cannot check 'herdr worktree list' without herdr"
  elif ! herdr worktree list --cwd "$project" >/dev/null 2>&1; then
    wt_support=warn
    wt_support_hint="'herdr worktree list' failed in $project; update Herdr for native worktree support"
  fi
  doctor_add worktree_support "$wt_support" "$wt_support_hint"

  local wt_project_hash wt_warn="" wt_orphans="" wt_removed="" wt_count=0
  local wt_f wt_ch wt_path wt_ms wt_merged wt_kept wt_branch wt_tab wt_ws
  wt_project_hash="$(sha1_hex "$project")"
  if [ -d "$BOSS_APPLIES_DIR" ]; then
    for wt_f in "$BOSS_APPLIES_DIR"/*.json; do
      [ -f "$wt_f" ] || continue
      [ "$(jq -r '.project // empty' "$wt_f" 2>/dev/null || true)" = "$project" ] || continue
      wt_path="$(jq -r '.worktree // empty' "$wt_f" 2>/dev/null || true)"
      [ -n "$wt_path" ] || continue
      wt_count=$((wt_count + 1))
      wt_ch="$(jq -r '.change // empty' "$wt_f" 2>/dev/null || true)"
      wt_ms="$(jq -r '.merge_state // "none"' "$wt_f" 2>/dev/null || true)"
      wt_merged="$(jq -r '.merged // false' "$wt_f" 2>/dev/null || true)"
      wt_kept="$(jq -r '.kept // false' "$wt_f" 2>/dev/null || true)"
      wt_branch="$(jq -r '.branch // empty' "$wt_f" 2>/dev/null || true)"
      wt_ws="$(jq -r '.worktree_workspace // empty' "$wt_f" 2>/dev/null || true)"
      if [ ! -d "$wt_path" ]; then
        wt_warn="$wt_warn $wt_ch:path missing ($wt_path)"
        continue
      fi
      case "$wt_ms" in
        conflict|test_failed) wt_warn="$wt_warn $wt_ch:merge_state=$wt_ms" ;;
      esac
      if [ -d "$wt_path/openspec/changes/$wt_ch" ]; then
        local wt_plan_dirty
        wt_plan_dirty="$(git -C "$wt_path" status --porcelain -- "openspec/changes/$wt_ch" 2>/dev/null || true)"
        [ -n "$wt_plan_dirty" ] && wt_warn="$wt_warn $wt_ch:change dir not committed in the worktree"
      fi
      if [ "$fix" -eq 1 ] && [ "$wt_merged" = "true" ]; then
        if [ "$wt_kept" = "true" ] || [ "$wt_ms" = "done" ]; then
          wt_tab="$(jq -r '.tab_id // empty' "$wt_f" 2>/dev/null || true)"
          [ -n "$wt_tab" ] && [ "$wt_tab" != "null" ] && herdr tab close "$wt_tab" >/dev/null 2>&1 || true
          herdr_worktree_remove "$project" "$wt_path" "$wt_ws"
          git -C "$project" worktree remove --force "$wt_path" >/dev/null 2>&1 || true
          git -C "$project" worktree prune >/dev/null 2>&1 || true
          [ -n "$wt_branch" ] && git -C "$project" branch -D "$wt_branch" >/dev/null 2>&1 || true
          rm -rf "$wt_path" 2>/dev/null || true
          rmdir "$(dirname "$wt_path")" 2>/dev/null || true
          rm -f "$wt_f"
          inbox_remove "$project" "$wt_ch"
          wt_removed="$wt_removed $wt_ch"
          log "doctor --fix: removed merged worktree $wt_path for $wt_ch"
        fi
      fi
    done
  fi

  if [ -d "$BOSS_WORKTREES_DIR/$wt_project_hash" ]; then
    local wt_dir wt_name wt_state
    for wt_dir in "$BOSS_WORKTREES_DIR/$wt_project_hash"/*; do
      [ -d "$wt_dir" ] || continue
      wt_name="$(basename "$wt_dir")"
      wt_state="$BOSS_APPLIES_DIR/$wt_project_hash-$wt_name.json"
      if [ ! -f "$wt_state" ]; then
        wt_orphans="$wt_orphans $wt_dir"
      fi
    done
  fi

  if [ -z "$wt_warn" ]; then
    local wt_hint=""
    [ -n "$wt_removed" ] && wt_hint="removed merged worktrees:$wt_removed"
    doctor_add worktree_state ok "$wt_hint"
  else
    local wt_hint="worktree states need attention:$wt_warn; run 'boss review' and 'boss finish', or 'boss doctor --fix' for merged kept worktrees"
    [ -n "$wt_removed" ] && wt_hint="$wt_hint; removed merged worktrees:$wt_removed"
    doctor_add worktree_state warn "$wt_hint"
  fi
  if [ -z "$wt_orphans" ]; then
    doctor_add worktree_orphans ok ""
  else
    doctor_add worktree_orphans warn "worktrees under $BOSS_WORKTREES_DIR have no apply state:$wt_orphans; inspect them before removing anything"
  fi

  if [ "$wt_count" -gt 0 ] || [ -n "$wt_orphans" ]; then
    local wt_base_paths wt_base_hint=""
    wt_base_paths="$(git_dirty_paths "$project" code)"
    [ -n "$wt_base_paths" ] && wt_base_hint="dirty base outside openspec/: $(printf '%s' "$wt_base_paths" | paste -sd ', ' -)"
    local wt_plan_paths
    wt_plan_paths="$(git_dirty_paths "$project" plan)"
    if [ -n "$wt_plan_paths" ]; then
      wt_base_hint="${wt_base_hint:+$wt_base_hint; }plan paths not committed: $(printf '%s' "$wt_plan_paths" | paste -sd ', ' -)"
    fi
    if [ -n "$wt_base_hint" ]; then
      doctor_add worktree_base warn "$wt_base_hint"
    else
      doctor_add worktree_base ok ""
    fi
  fi

  if is_project_registered "$project"; then
    doctor_add project_registry ok ""
  elif [ "$fix" -eq 1 ] && doctor_register_project "$project" "$(basename "$project")"; then
    log "doctor --fix: registered '$project' as '$(basename "$project")'"
    doctor_add project_registry ok ""
  else
    doctor_add project_registry warn "add '$project' under [projects] in $BOSS_CONFIG"
  fi

}

# cmd_doctor [--project <name|path>] [--json] [--fix] -- preflight the
# permissions and prerequisites of a run. Read-only by default; --fix performs
# only safe, reversible repairs. Never blocks: it reports, and exits 0.
cmd_doctor() {
  ensure_config
  local project_name="" want_json=0 fix=0 arg
  while [ $# -gt 0 ]; do
    arg="$1"; shift
    case "$arg" in
      --project) project_name="${1:-}"; shift ;;
      --json) want_json=1 ;;
      --fix) fix=1 ;;
      -h|--help) usage ;;
      --*) usage_error "unknown option: $arg" ;;
      *) usage_error "unexpected argument: $arg" ;;
    esac
  done

  local project
  project="$(resolve_project "$project_name")" || exit 1

  DOCTOR_TMP="$(mktemp)" || die_json "state_write" "cannot create a temporary file"
  local cfg kinds k iname default_runner

  if command -v openspec >/dev/null 2>&1; then
    doctor_add openspec_cli ok ""
  else
    doctor_add openspec_cli fail "install OpenSpec ('openspec') and put it on PATH"
  fi

  local have_herdr=0
  if command -v herdr >/dev/null 2>&1; then
    have_herdr=1
    doctor_add herdr_cli ok ""
  else
    doctor_add herdr_cli fail "install Herdr and put 'herdr' on PATH"
  fi

  # dependencies: the tools a run needs, each satisfied by any alternative.
  local dep_missing=""
  if ! { command -v sha1sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 \
         || command -v python3 >/dev/null 2>&1 || command -v openssl >/dev/null 2>&1; }; then
    dep_missing="$dep_missing sha1"
  fi
  if ! command -v ps >/dev/null 2>&1 && [ ! -r /proc/self/cmdline ]; then
    dep_missing="$dep_missing ps"
  fi
  command -v jq >/dev/null 2>&1 || dep_missing="$dep_missing jq"
  command -v python3 >/dev/null 2>&1 || dep_missing="$dep_missing python3"
  if [ -z "$dep_missing" ]; then
    doctor_add dependencies ok ""
  else
    doctor_add dependencies fail "install:$dep_missing"
  fi

  cfg="$(config_json 2>/dev/null || true)"
  kinds="$(printf '%s' "$cfg" | jq -r '(.runners // {}) | to_entries[] | .value.kind // empty' 2>/dev/null | sort -u || true)"
  default_runner="$(printf '%s' "$cfg" | jq -r '.default // empty' 2>/dev/null || true)"
  local have_opencode=0 opencode_version=""
  # kinds is newline-separated (one kind per line from sort -u), so match the
  # whole line rather than a substring of a space-delimited value.
  if printf '%s\n' "$kinds" | grep -qx 'opencode'; then
    have_opencode=1
    opencode_version="$(opencode_major_version)"
  fi

  local init_missing=""
  [ -f "$project/.claude/commands/opsx/apply.md" ] || init_missing="$init_missing claude"
  ls "$project"/.opencode/commands/opsx-*.md >/dev/null 2>&1 || init_missing="$init_missing opencode"
  if [ -z "$init_missing" ]; then
    doctor_add project_init ok ""
  elif [ "$fix" -eq 1 ] && command -v openspec >/dev/null 2>&1 \
       && (cd "$project" && openspec init --tools claude,opencode >/dev/null 2>&1); then
    log "doctor --fix: ran 'openspec init --tools claude,opencode' in $project"
    doctor_add project_init ok ""
  else
    doctor_add project_init warn "run 'openspec init --tools claude,opencode' in $project"
  fi

  local status_out bad_kinds="" bad_runner=""
  if [ "$have_herdr" -eq 1 ] && [ -n "$kinds" ]; then
    status_out="$(herdr integration status 2>/dev/null || true)"
    for k in $kinds; do
      iname="$k"
      [ "$k" = "gemini" ] && iname="antigravity-cli"
      printf '%s\n' "$status_out" | grep -q "^$iname: current" || bad_kinds="$bad_kinds $k"
    done
  fi
  if [ -z "$bad_kinds" ]; then
    doctor_add herdr_integration ok ""
  else
    doctor_add herdr_integration fail "run 'herdr integration install <kind>' for:$bad_kinds"
  fi

  for k in $kinds; do
    command -v "$k" >/dev/null 2>&1 || bad_runner="$bad_runner $k"
  done
  if [ -z "$bad_runner" ]; then
    doctor_add runner_path ok ""
  else
    doctor_add runner_path fail "put the runner on PATH:$bad_runner"
  fi

  if [ "$have_herdr" -eq 1 ]; then
    if [ -n "$(find_workspace_for_repo "$project" 2>/dev/null || true)" ]; then
      doctor_add workspace ok ""
    else
      doctor_add workspace warn "no Herdr workspace for $project yet; dispatch will create one"
    fi
  else
    doctor_add workspace warn "cannot check the workspace without herdr"
  fi

  local test_cmd
  test_cmd="$(config_test_command "$project" 2>/dev/null || true)"
  [ -n "$test_cmd" ] || test_cmd="$(detect_test_command "$project" 2>/dev/null || true)"
  if [ -n "$test_cmd" ]; then
    doctor_add test_command ok ""
  else
    doctor_add test_command warn "no test command recognized; the review will report not_run"
  fi

  doctor_check_worktrees "$project" "$have_herdr" "$fix"

  # The registry must only name living panes that are still in their workspace.
  local reg_warn="" reg_removed="" reg_f reg_pane reg_ws reg_meta reg_mws reg_name
  if [ "$have_herdr" -eq 1 ]; then
    local reg_agents
    reg_agents="$(boss_agents)"
    if [ -d "$BOSS_BOSSES_DIR" ]; then
      for reg_f in "$BOSS_BOSSES_DIR"/*.json; do
        [ -f "$reg_f" ] || continue
        reg_name="$(basename "$reg_f" .json)"
        reg_pane="$(jq -r '.pane_id // empty' "$reg_f" 2>/dev/null || true)"
        reg_ws="$(jq -r '.workspace_id // empty' "$reg_f" 2>/dev/null || true)"
        if [ -z "$reg_pane" ] || ! boss_agent_alive_pane "$reg_agents" "$reg_pane"; then
          if [ "$fix" -eq 1 ]; then
            rm -f "$reg_f"
            reg_removed="$reg_removed $reg_name:pane ${reg_pane:-unknown}"
            log "doctor --fix: removed dead registry $reg_f"
          else
            reg_warn="$reg_warn $reg_name:pane ${reg_pane:-unknown} is dead"
          fi
          continue
        fi
        reg_meta="$(boss_agent_meta "$reg_agents" "$reg_pane")"
        reg_mws="$(printf '%s' "$reg_meta" | jq -r '.workspace_id // empty' 2>/dev/null || true)"
        if [ -n "$reg_ws" ] && [ -n "$reg_mws" ] && [ "$reg_mws" != "$reg_ws" ]; then
          reg_warn="$reg_warn $reg_name:pane $reg_pane moved from $reg_ws to $reg_mws"
        fi
      done
    fi
    if [ -z "$reg_warn" ]; then
      if [ -n "$reg_removed" ]; then
        doctor_add boss_registry ok "removed dead registry entries:$reg_removed"
      else
        doctor_add boss_registry ok ""
      fi
    else
      local reg_hint="registered boss entries are stale:$reg_warn; run 'boss claim' in the affected workspace to repair"
      [ -n "$reg_removed" ] && reg_hint="$reg_hint; removed dead registry entries:$reg_removed"
      doctor_add boss_registry warn "$reg_hint"
    fi
  else
    doctor_add boss_registry warn "cannot check the boss registry without herdr"
  fi

  # Each open apply needs a dispatcher that a wake may safely use.
  local wake_warn="" wake_f wake_ch wake_plan wake_reason wake_boss wake_pane
  if [ -d "$BOSS_APPLIES_DIR" ]; then
    for wake_f in "$BOSS_APPLIES_DIR"/*.json; do
      [ -f "$wake_f" ] || continue
      [ "$(jq -r '.project // empty' "$wake_f" 2>/dev/null || true)" = "$project" ] || continue
      [ "$(jq -r '.parked // false' "$wake_f" 2>/dev/null || true)" = "true" ] && continue
      wake_ch="$(jq -r '.change // empty' "$wake_f" 2>/dev/null || true)"
      wake_boss="$(jq -r '.boss // empty' "$wake_f" 2>/dev/null || true)"
      wake_pane="$(jq -r '.boss_pane // empty' "$wake_f" 2>/dev/null || true)"
      if [ -z "$wake_boss" ] && [ -z "$wake_pane" ]; then
        wake_warn="$wake_warn $wake_ch:no dispatcher recorded"
        continue
      fi
      wake_plan="$(boss_wake_plan "$wake_f")"
      wake_reason="$(printf '%s' "$wake_plan" | jq -r         '[.skipped[] | select(.source == "dispatcher") | .reason] | .[0] // empty')"
      [ -n "$wake_reason" ] && wake_warn="$wake_warn $wake_ch:$wake_reason"
    done
  fi
  if [ -z "$wake_warn" ]; then
    doctor_add wake_target ok ""
  else
    doctor_add wake_target warn "the recorded dispatcher is missing, dead or unsafe for:$wake_warn; run 'boss retarget <change>' to point it at the verified caller"
  fi

  # Read-only: report a stale inherited environment without claiming anything.
  if [ "${HERDR_ENV:-}" = "1" ]; then
    local ci_status ci_message
    ci_status="$(boss_caller_identity_json "" | jq -r '.status')"
    ci_message="$(boss_caller_identity_json "" | jq -r '.message // empty')"
    case "$ci_status" in
      ok) doctor_add caller_identity ok "" ;;
      mismatch) doctor_add caller_identity warn "$ci_message" ;;
      missing) doctor_add caller_identity warn "$ci_message" ;;
      invalid_override) doctor_add caller_identity warn "$ci_message" ;;
      *) doctor_add caller_identity warn "$ci_message" ;;
    esac
  else
    doctor_add caller_identity ok "not inside Herdr; the caller identity check is skipped"
  fi

  local mission_warn="" mdir mf mparsed first_change has_after first_human
  local known_runners="" runner_warn="" runner_pair runner_change runner_name
  mdir="$(missions_dir "$project" 2>/dev/null || true)"
  known_runners="$(printf '%s' "$cfg" | jq -r '(.runners // {}) | keys[]' 2>/dev/null || true)"
  if [ -n "$mdir" ] && [ -d "$mdir" ]; then
    for mf in "$mdir"/*.md; do
      [ -f "$mf" ] || continue
      mparsed="$(mission_parse "$mf" 2>/dev/null || true)"
      [ -n "$mparsed" ] || continue
      while IFS= read -r runner_pair; do
        [ -n "$runner_pair" ] || continue
        runner_change="${runner_pair%% *}"
        runner_name="${runner_pair#* }"
        if ! printf '%s\n' "$known_runners" | grep -qx "$runner_name"; then
          runner_warn="$runner_warn $(basename "$mf"):$runner_change=$runner_name"
        fi
      done < <(printf '%s' "$mparsed" | jq -r \
        '.change_specs[]? | select((.runner // "") != "") | "\(.name) \(.runner)"' 2>/dev/null)
      first_change="$(printf '%s' "$mparsed" | jq -r '.changes[0] // empty')"
      [ -n "$first_change" ] || continue
      has_after="$(printf '%s' "$mparsed" | jq -r '[.change_specs[]?.after[]?] | length')"
      [ "$has_after" -gt 0 ] && continue
      first_human="$(mission_tasks_json "$project" "$first_change" | jq -r '.human_open // 0')"
      case "$first_human" in ''|null) first_human=0 ;; esac
      [ "$first_human" -gt 0 ] && mission_warn="$mission_warn $mf"
    done
  fi
  if [ -z "$mission_warn" ]; then
    doctor_add mission_human_dependencies ok ""
  else
    doctor_add mission_human_dependencies warn "first change has human tasks but the mission declares no dependencies:$mission_warn; add (after: ...) to the changes that do not depend on the human result"
  fi
  if [ -z "$runner_warn" ]; then
    doctor_add mission_runners ok ""
  else
    doctor_add mission_runners warn "unknown runner(s) in missions:$runner_warn; add them under [runners] in $BOSS_CONFIG or correct the bullet"
  fi

  # The effective parallel limit and, above one, the lock declarations of every
  # mission change. A missing declaration is safe (the change runs alone) but
  # must be visible before a parallel run.
  local parallel_value="1" parallel_hint lock_missing="" lock_mf lock_parsed lock_change
  if parallel_value="$(mission_max_parallel 2>/dev/null)"; then
    parallel_hint="max_parallel = $parallel_value"
    [ -n "${BOSS_MAX_PARALLEL:-}" ] && parallel_hint="$parallel_hint (BOSS_MAX_PARALLEL)"
    [ "$parallel_value" -gt 1 ] && parallel_hint="$parallel_hint; parallel mode uses worktrees only"
    doctor_add mission_parallel ok "$parallel_hint"
  else
    parallel_value=1
    doctor_add mission_parallel fail "invalid max_parallel; use an integer >= 1 in [missions] or BOSS_MAX_PARALLEL"
  fi
  if [ "$parallel_value" -gt 1 ] && [ -n "$mdir" ] && [ -d "$mdir" ]; then
    for lock_mf in "$mdir"/*.md; do
      [ -f "$lock_mf" ] || continue
      lock_parsed="$(mission_parse "$lock_mf" 2>/dev/null || true)"
      [ -n "$lock_parsed" ] || continue
      while IFS= read -r lock_change; do
        [ -n "$lock_change" ] || continue
        lock_missing="$lock_missing $(basename "$lock_mf" .md):$lock_change"
      done < <(printf '%s' "$lock_parsed" | jq -r \
        '.changes[] as $c | select(([.change_specs[]? | select(.name == $c and (.declared // false) == true)] | length) == 0) | $c')
    done
  fi
  if [ -z "$lock_missing" ]; then
    doctor_add mission_parallel_locks ok ""
  else
    doctor_add mission_parallel_locks warn "changes without a touches declaration run exclusively:$lock_missing; add 'touches: none' or a lock list in P4"
  fi

  local jdir ldir
  jdir="$(dirname "$(journal_project_path "$project" 2>/dev/null)")"
  ldir="$(dirname "$(lessons_project_path "$project" 2>/dev/null)")"
  mdir="$(missions_dir "$project" 2>/dev/null || true)"
  [ "$fix" -eq 1 ] && mkdir -p "$jdir" "$ldir" "$mdir" 2>/dev/null || true
  if [ -d "$jdir" ] && [ -d "$ldir" ] && { [ -z "$mdir" ] || [ -d "$mdir" ]; }; then
    doctor_add write_access ok ""
  else
    doctor_add write_access warn "run 'boss doctor --fix' to create the journal/lessons/missions directories"
  fi

  # probe holds the effective OpenCode V2 rules, so the policy check below does
  # not have to ask 'opencode debug config' a second time.
  local probe="" probe_status probe_hint
  if [ "$have_opencode" -eq 0 ]; then
    doctor_add boss_permission ok "no OpenCode runner is configured; the OpenCode permission check is skipped"
  elif [ "$opencode_version" = "2" ]; then
    probe="$(opencode_permission_probe "$project")"
    probe_status="$(printf '%s' "$probe" | jq -r '.status')"
    case "$probe_status" in
      ok)
        doctor_add boss_permission ok "the effective OpenCode V2 config has no broad deny for shell, edit, read or external directory; explicit deny rules still apply"
        ;;
      deny)
        probe_hint="$(printf '%s' "$probe" | jq -r '.message') in the effective OpenCode V2 config; run 'opencode debug config' to inspect it"
        doctor_add boss_permission warn "$probe_hint"
        ;;
      *)
        doctor_add boss_permission warn "cannot read the effective OpenCode V2 config: 'opencode debug config' and 'opencode api get /api/config' both failed; run 'opencode debug config' manually"
        ;;
    esac
  elif printf '%s' "${OPENCODE_CONFIG_CONTENT:-}" | grep -q '"allow"'; then
    doctor_add boss_permission ok ""
  else
    doctor_add boss_permission warn "start the boss via 'boss session' so its tab carries the allow scope (OpenCode V1/legacy path)"
  fi

  # Policy: does the agent configuration in effect deny the destructive
  # commands an apply never needs? Reported for the default runner; never a
  # hard failure, because the charter remains the boundary.
  if [ -n "$default_runner" ]; then
    local policy_json policy_status policy_hint policy_runner
    policy_runner="$(resolve_runner "$default_runner" 2>/dev/null || true)"
    policy_json="$(policy_check "$policy_runner" "$project" "$probe")"
    policy_status="$(printf '%s' "$policy_json" | jq -r '.status // "unavailable"')"
    policy_hint="$(printf '%s' "$policy_json" | jq -r '.hint // ""')"
    case "$policy_status" in
      enforced|verified) doctor_add policy ok "" ;;
      off) doctor_add policy warn "runner '$default_runner': $policy_hint" ;;
      missing)
        doctor_add policy warn "runner '$default_runner' denies no destructive command (missing: $(printf '%s' "$policy_json" | jq -r '.missing | join(", ")')); $policy_hint"
        ;;
      *) doctor_add policy warn "runner '$default_runner': $policy_hint" ;;
    esac
  else
    doctor_add policy warn "no default runner configured; the deny policy cannot be checked"
  fi

  # Under V2 the runner only gets --auto when its args are absent or empty.
  # An explicit non-empty args list without --auto is a supported opt-out, but
  # doctor names it so a silently missing auto-approval is visible.
  if [ "$have_opencode" -eq 1 ] && [ "$opencode_version" = "2" ]; then
    local runner_warn="" rn rargs
    while IFS= read -r rn; do
      [ -n "$rn" ] || continue
      rargs="$(printf '%s' "$cfg" | jq -c --arg n "$rn" '.runners[$n].args // []')"
      if [ "$(printf '%s' "$rargs" | jq 'length > 0 and (index("--auto") == null)')" = "true" ]; then
        runner_warn="$runner_warn $rn"
      fi
    done < <(printf '%s' "$cfg" | jq -r '(.runners // {}) | to_entries[] | select(.value.kind == "opencode") | .key')
    if [ -z "$runner_warn" ]; then
      doctor_add opencode_runner_args ok "the OpenCode V2 runner receives --auto"
    else
      doctor_add opencode_runner_args warn "explicit args without --auto on runner(s):$runner_warn; add '--auto' or remove the explicit args so boss adds it"
    fi
  fi

  local checks overall json
  checks="$(jq -s '.' "$DOCTOR_TMP")"
  rm -f "$DOCTOR_TMP"

  if [ "$(printf '%s' "$checks" | jq '[.[] | select(.status == "fail")] | length')" -gt 0 ]; then
    overall="fail"
  elif [ "$(printf '%s' "$checks" | jq '[.[] | select(.status == "warn")] | length')" -gt 0 ]; then
    overall="warn"
  else
    overall="ok"
  fi

  json="$(jq -nc --arg project "$project" --arg status "$overall" --argjson checks "$checks" \
    '{project: $project, status: $status, checks: $checks}')"

  if [ "$want_json" -eq 1 ]; then
    printf '%s\n' "$json"
    return 0
  fi
  printf 'project: %s\n' "$project"
  printf '%s' "$checks" | jq -r '.[] | "\(.id): \(.status)" + (if .hint then " -- \(.hint)" else "" end)'
  printf 'overall: %s\n' "$overall"
  printf '%s\n' "$json"
  return 0
}

# --------------------------------------------------------------- retrigger ---

