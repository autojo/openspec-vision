#!/usr/bin/env bash
# boss-model -- part of the boss runtime, sourced by bin/boss after boss-lib.sh.
# Contains only function definitions; nothing runs when this file is sourced.
#
#   boss model list  [--project <name|path>] [--json]
#   boss model check <runner> [--project <name|path>] [--json]
#   boss model trial <runner> [--project <name|path>] [--confirm-spend <amount>] [--json]
#
# 'list' and 'check' never send a prompt. 'trial' sends one fixed prompt in an
# empty temporary directory and only with an explicit spending confirmation.

# model_list_json <project> <config-json> -- one row per configured runner.
model_list_json() {
  local project="$1" cfg="$2" name runner_json declared effort pinned entry billing
  local provider limit_usd limit_tokens trial helpers rows="[]" default
  default="$(printf '%s' "$cfg" | jq -r '.default // empty')"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    runner_json="$(printf '%s' "$cfg" | jq -c --arg n "$name" '.runners[$n] + {name: $n}')"
    declared="$(printf '%s' "$runner_json" | jq -r '.model // empty')"
    effort="$(printf '%s' "$runner_json" | jq -r '.effort // empty')"
    if model_runner_pinned "$runner_json"; then pinned=true; else pinned=false; fi
    entry="$(model_catalog_entry "$cfg" "$declared")"
    billing=""; provider=""; limit_usd="null"; limit_tokens="null"; trial='{"status":"not_required","reasons":[]}'
    if [ "$declared" != "" ] && [ "$entry" != "null" ]; then
      billing="$(printf '%s' "$entry" | jq -r '.billing // empty')"
      provider="$(printf '%s' "$entry" | jq -r '.provider // empty')"
      limit_usd="$(printf '%s' "$entry" | jq -c '.limit_usd // null')"
      limit_tokens="$(printf '%s' "$entry" | jq -c '.limit_tokens // null')"
      trial="$(model_trial_status "$runner_json" "$cfg" "$project" | jq -c '{status, reasons}')"
    fi
    helpers="$(model_configured_helpers "$runner_json" "$cfg" "$project")"
    rows="$(printf '%s' "$rows" | jq -c \
      --arg name "$name" --arg declared "$declared" --arg effort "$effort" \
      --arg start "$(printf '%s' "$runner_json" | jq -r '.start // "herdr"')" \
      --arg kind "$(printf '%s' "$runner_json" | jq -r '.kind // empty')" \
      --argjson pinned "$pinned" --arg provider "$provider" --arg billing "$billing" \
      --argjson limit_usd "$limit_usd" --argjson limit_tokens "$limit_tokens" \
      --argjson trial "$trial" --argjson helpers "$helpers" \
      --argjson default "$([ "$name" = "$default" ] && printf true || printf false)" \
      '. + [{runner: $name, kind: (if $kind == "" then null else $kind end), start: $start,
             model: (if $declared == "" then null else $declared end),
             effort: (if $effort == "" then null else $effort end),
             pinned: $pinned, provider: (if $provider == "" then null else $provider end),
             billing: (if $billing == "" then null else $billing end),
             limit_usd: $limit_usd, limit_tokens: $limit_tokens,
             trial: $trial, helpers: $helpers, default: $default}]')"
  done < <(printf '%s' "$cfg" | jq -r '(.runners // {}) | keys[]' 2>/dev/null || true)
  printf '%s' "$rows"
}

# model_charter_trial_amount <project> <model> -- the first amount in a
# Spending/API-cost row of a mission charter. Empty when no charter authorizes
# a trial. Read-only.
model_charter_trial_amount() {
  local project="$1" model="$2" mdir mf amount line section=""
  mdir="$(missions_dir "$project" 2>/dev/null || true)"
  [ -n "$mdir" ] && [ -d "$mdir" ] || return 0
  for mf in "$mdir"/*.md; do
    [ -f "$mf" ] || continue
    section=""
    while IFS= read -r line || [ -n "$line" ]; do
      if printf '%s' "$line" | grep -qE '^[[:space:]]*##[[:space:]]+Authorization[[:space:]]*$'; then
        section="auth"; continue
      fi
      if printf '%s' "$line" | grep -qE '^[[:space:]]*#+[[:space:]]'; then
        section=""; continue
      fi
      [ "$section" = "auth" ] || continue
      case "$line" in
        *"|"*)
          local category decision
          category="$(printf '%s' "$line" | awk -F'|' '{v=$2; gsub(/^[ \t]+/,"",v); gsub(/[ \t]+$/,"",v); print v}')"
          decision="$(printf '%s' "$line" | awk -F'|' '{v=$3; gsub(/^[ \t]+/,"",v); gsub(/[ \t]+$/,"",v); print v}')"
          printf '%s' "$category" | grep -qiE 'spending|api|cost' || continue
          amount="$(printf '%s' "$decision" | grep -oE '[0-9]+([.][0-9]+)?' | head -n 1 || true)"
          [ -n "$amount" ] && { printf '%s' "$amount"; return 0; }
          ;;
      esac
    done <"$mf"
  done
  return 0
}

# cmd_model_list [--project <name|path>] [--json]
cmd_model_list() {
  local project_name="" json_only=0 arg
  while [ $# -gt 0 ]; do
    arg="$1"; shift
    case "$arg" in
      --project) project_name="${1:-}"; shift ;;
      --json) json_only=1 ;;
      -h|--help) usage ;;
      --*) usage_error "unknown option: $arg" ;;
      *) usage_error "unexpected argument: $arg" ;;
    esac
  done
  ensure_config
  local project cfg rows
  project="$(resolve_project "$project_name")" || exit 1
  cfg="$(config_json)" || exit 1
  rows="$(model_list_json "$project" "$cfg")"
  if [ "$json_only" -eq 1 ]; then
    jq -nc --arg project "$project" --argjson runners "$rows" \
      '{project: $project, runners: $runners}' 
    return 0
  fi
  printf 'project: %s\n' "$project"
  printf '%s' "$rows" | jq -r '.[] |
    "\(if .default then "*" else " " end) \(.runner) [\(.start)\(if .kind then "/" + .kind else "" end)]: "
    + (if .model then .model else "unpinned" end)
    + (if .effort then " effort " + .effort else "" end)
    + (if .billing then " (" + .billing + ", " + (.provider // "?") + ")" else " (uncataloged)" end)
    + (if (.limit_usd // null) != null then " limit " + (.limit_usd | tostring) + " USD" else "" end)
    + (if (.limit_tokens // null) != null then " limit " + (.limit_tokens | tostring) + " tokens" else "" end)
    + (if .trial.status != "not_required" then " trial " + .trial.status else "" end)
    + (if (.helpers | length) > 0 then " helpers " + (.helpers | join(", ")) else "" end)'
  return 0
}

# model_check_json <project> <runner-json> -- ACP: handshake only, no prompt,
# with the same profile kind a dispatch uses. Native: the command and the model
# arrangement are checked without starting an agent.
model_check_json() {
  local project="$1" runner="$2" name command model effort mode
  local script out rc
  name="$(printf '%s' "$runner" | jq -r '.name // "?"')"
  command="$(printf '%s' "$runner" | jq -r '.command // empty')"
  model="$(printf '%s' "$runner" | jq -r '.model // empty')"
  effort="$(printf '%s' "$runner" | jq -r '.effort // empty')"
  mode="$(printf '%s' "$runner" | jq -r '.mode // ""')"
  if [ "$(runner_start_of "$runner")" != "acp" ]; then
    local kind binary present=true
    kind="$(printf '%s' "$runner" | jq -r '.kind // empty')"
    binary="$(printf '%s' "$runner" | jq -r '.kind // empty')"
    command -v "$binary" >/dev/null 2>&1 || present=false
    jq -nc --arg runner "$name" --arg kind "$kind" --arg model "$model" \
      --arg effort "$effort" --argjson present "$present" --argjson pinned "$(model_runner_pinned "$runner" && printf true || printf false)" \
      '{runner: $runner, transport: "herdr", kind: $kind, status: (if $present then "ok" else "fail" end),
        pinned: $pinned, model: (if $model == "" then null else $model end),
        effort: (if $effort == "" then null else $effort end),
        message: (if $present then "the native command is on PATH; check sends no prompt" else "the native command is not on PATH" end)}'
    return 0
  fi
  script="$(boss_acp_py)"
  if [ -z "$script" ]; then
    jq -nc --arg runner "$name" '{runner: $runner, status: "fail", message: "boss_acp.py is missing; reinstall the runtime"}'
    return 0
  fi
  out="$(cd "$project" && run_with_deadline 300 python3 "$script" --probe "$command" --cwd "$project" \
    --timeout 120 ${model:+--model "$model"} ${effort:+--effort "$effort"} ${mode:+--mode "$mode"} 2>/dev/null)"
  rc=$?
  if ! printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
    jq -nc --arg runner "$name" --argjson rc "$rc" \
      '{runner: $runner, status: "fail", message: ("the ACP probe failed with exit " + ($rc | tostring))}'
    return 0
  fi
  printf '%s' "$out" | jq -c --arg runner "$name" '{runner: $runner} + .'
}

# cmd_model_check <runner> [--project] [--json]
cmd_model_check() {
  local runner_name="" project_name="" json_only=0 arg runner project out status
  while [ $# -gt 0 ]; do
    arg="$1"; shift
    case "$arg" in
      --project) project_name="${1:-}"; shift ;;
      --json) json_only=1 ;;
      -h|--help) usage ;;
      --*) usage_error "unknown option: $arg" ;;
      *) if [ -z "$runner_name" ]; then runner_name="$arg"; else usage_error "unexpected argument: $arg"; fi ;;
    esac
  done
  [ -n "$runner_name" ] || usage_error "usage: boss model check <runner> [--project <name|path>] [--json]"
  ensure_config
  runner="$(resolve_runner "$runner_name")" || exit 1
  project="$(resolve_project "$project_name")" || exit 1
  out="$(model_check_json "$project" "$runner")"
  status="$(printf '%s' "$out" | jq -r '.status')"
  if [ "$json_only" -eq 1 ]; then
    printf '%s\n' "$out"
  else
    printf '%s\n' "$out" | jq -r '"runner: " + .runner + " (" + .status + ")" + (if .message then " -- " + .message else "" end)'
  fi
  [ "$status" = "ok" ] && return 0
  return 1
}

# cmd_model_trial <runner> [--project] [--confirm-spend <amount>] [--json] --
# one fixed prompt in an empty temporary directory, with its own limit. Only a
# metered model that confirms over ACP can be tried; the record is written to
# $BOSS_STATE_DIR/models/.
cmd_model_trial() {
  local runner_name="" project_name="" amount="" json_only=0 arg
  while [ $# -gt 0 ]; do
    arg="$1"; shift
    case "$arg" in
      --project) project_name="${1:-}"; shift ;;
      --confirm-spend) amount="${1:-}"; shift ;;
      --json) json_only=1 ;;
      -h|--help) usage ;;
      --*) usage_error "unknown option: $arg" ;;
      *) if [ -z "$runner_name" ]; then runner_name="$arg"; else usage_error "unexpected argument: $arg"; fi ;;
    esac
  done
  [ -n "$runner_name" ] || usage_error "usage: boss model trial <runner> [--project <name|path>] [--confirm-spend <amount>] [--json]"
  ensure_config
  local runner project cfg name model effort command mode entry billing authoritative
  runner="$(resolve_runner "$runner_name")" || exit 1
  project="$(resolve_project "$project_name")" || exit 1
  cfg="$(config_json)" || exit 1
  name="$(printf '%s' "$runner" | jq -r '.name')"
  model="$(printf '%s' "$runner" | jq -r '.model // empty')"
  effort="$(printf '%s' "$runner" | jq -r '.effort // empty')"
  command="$(printf '%s' "$runner" | jq -r '.command // empty')"
  mode="$(printf '%s' "$runner" | jq -r '.mode // ""')"
  entry="$(model_catalog_entry "$cfg" "$model")"
  if [ "$entry" = "null" ]; then
    die_json "model_uncataloged" "model '$model' of runner '$name' has no [models] entry; add one before a trial"
  fi
  billing="$(printf '%s' "$entry" | jq -r '.billing // empty')"
  if [ "$billing" != "metered" ]; then
    die_json "trial_not_required" "model '$model' is '$billing', not metered; a trial is only needed for a metered model"
  fi
  if [ "$(runner_start_of "$runner")" != "acp" ]; then
    die_json "model_confirmation_late" "runner '$name' cannot confirm a metered model before the first prompt; use an ACP runner"
  fi
  if [ -z "$amount" ]; then
    amount="$(model_charter_trial_amount "$project" "$model")"
  fi
  case "$amount" in
    ''|*[!0-9.]*)
      die_json "trial_not_authorized" "a trial of metered model '$model' needs an explicit spending confirmation: pass --confirm-spend <amount> or record a Spending / API cost amount for the trial in a mission charter" \
        "$(jq -nc --arg m "$model" --argjson limit "$(printf '%s' "$entry" | jq -c '.limit_usd // null')" \
          '{model: $m, trial_limit_usd: $limit, confirm: ("boss model trial " + $m + " --confirm-spend 0.10")}')"
      ;;
  esac
  authoritative="$amount"

  local dir state_file socket transcript events heartbeat prompt boss_bin deny_json
  local deadline stop_reason trial_json record_path result status confirmed cost tokens agent_version
  dir="$(mktemp -d "${TMPDIR:-/tmp}/boss-model-trial.XXXXXX")" || die_json "state_write" "cannot create a temporary directory"
  state_file="$dir/state.json"
  socket="$dir/control.sock"
  transcript="$dir/transcript.jsonl"
  events="$dir/events.jsonl"
  heartbeat="$dir/heartbeat"
  prompt="This is a boss model trial. Reply with the single word OK and nothing else."
  boss_bin="${BIN_DIR:-$(dirname "$(resolve_path "${BASH_SOURCE[0]}")")}/boss"
  deny_json="$(policy_denies "$runner" | jq -Rsc 'split("\n") | map(select(length > 0))')"

  jq -n --arg change "trial-$name" --arg project "$dir" \
    --arg model "$model" --arg effort "$effort" --arg provider "$(printf '%s' "$entry" | jq -r '.provider // empty')" \
    --argjson limit_usd "$authoritative" --arg command "$command" --arg mode "$mode" \
    --arg prompt "$prompt" --arg socket "$socket" --arg transcript "$transcript" \
    --arg events "$events" --arg heartbeat "$heartbeat" --arg boss_bin "$boss_bin" \
    --argjson deny "$deny_json" \
    '{change: $change, project: $project, runner: "trial", kind: "acp", transport: "acp",
      agent: "trial", pane_id: null, tab_id: null, workspace_id: null,
      started_at: (now | strftime("%Y-%m-%dT%H:%M:%S%z")), last_state: "starting",
      last_state_at: (now | strftime("%Y-%m-%dT%H:%M:%S%z")), parked: false,
      model: {declared: $model, effort_declared: (if $effort == "" then null else $effort end),
        confirmed: null, effort_confirmed: null, status: "pending", source: null,
        checked_at: null, trust: "declared", provider: (if $provider == "" then null else $provider end),
        billing: "metered", vendor: null, limit_usd: $limit_usd, limit_tokens: null,
        expect: [], helpers: [], seen: [], cost_usd: null, tokens: null,
        unchecked: false, warnings: [], trial: true},
      acp: {command: $command, apply_root: $project, prompt: $prompt,
        model: $model, effort: (if $effort == "" then null else $effort end),
        mode: $mode, policy: "allow", deny: $deny,
        session_id: null, supervisor_pid: null, control_socket: $socket,
        transcript: $transcript, events_file: $events, boss_bin: $boss_bin,
        heartbeat_file: $heartbeat,
        ready: false, phase: "starting", last_stop_reason: null,
        pending_permission: null, pending_permissions: [], apply_allows: [],
        usage: null, last_update: null, stalled: false, stalled_at: null,
        error: null, error_code: null, dead_reported: false, load_session: null, resume: false}}' \
    >"$state_file" || die_json "state_write" "cannot write the trial state"

  # shellcheck disable=SC2034  # read by die_json in boss-lib.sh
  BOSS_FAILED_ACP_PID=""
  start_acp_supervisor "$state_file" >/dev/null || { rm -rf "$dir"; exit 1; }
  acp_wait_ready "$state_file"
  deadline=$(( $(now_ms) + ${BOSS_MODEL_TRIAL_TIMEOUT_S:-300} * 1000 ))
  while :; do
    stop_reason="$(jq -r '.acp.last_stop_reason // empty' "$state_file" 2>/dev/null || true)"
    [ -n "$stop_reason" ] && break
    if ! acp_pid_alive "$(acp_supervisor_pid "$state_file")"; then break; fi
    [ "$(now_ms)" -lt "$deadline" ] || { stop_reason="timeout"; break; }
    sleep 0.2
  done
  acp_control_send "$(jq -r '.acp.control_socket // empty' "$state_file")" '{"command":"finish"}' 10 >/dev/null 2>&1 || true
  acp_stop_supervisor "$state_file" finish >/dev/null 2>&1 || true
  trial_json="$(model_state_json "$state_file")"
  confirmed="$(printf '%s' "$trial_json" | jq -r '.confirmed // empty')"
  status="$(printf '%s' "$trial_json" | jq -r '.status // "unknown"')"
  cost="$(printf '%s' "$trial_json" | jq -c '.cost_usd // null')"
  tokens="$(printf '%s' "$trial_json" | jq -c '.tokens // null')"
  agent_version="$(jq -r '.acp.agent_version // empty' "$state_file" 2>/dev/null || true)"
  record_path="$(model_trial_record_for "$model")"
  mkdir -p "$BOSS_MODELS_DIR" 2>/dev/null || true
  result="ok"
  if [ "$status" != "confirmed" ] || [ "$confirmed" != "$model" ]; then
    result="failed"
  fi
  jq -n --arg model "$model" --arg runner "$name" --arg command "$command" \
    --arg effort "$effort" --arg status "$result" --arg confirmed "$confirmed" \
    --argjson cost "$cost" --argjson tokens "$tokens" --argjson limit "$authoritative" \
    --arg agent_version "$agent_version" --arg date "$(now_iso)" --arg stop "$stop_reason" \
    '{model: $model, runner: $runner, command: $command,
      effort: (if $effort == "" then null else $effort end), status: $status,
      confirmed: (if $confirmed == "" then null else $confirmed end),
      cost_usd: $cost, tokens: $tokens, limit_usd: $limit,
      agent_version: (if $agent_version == "" then null else $agent_version end),
      date: $date, stop_reason: $stop}' >"$record_path" 2>/dev/null \
    || { rm -rf "$dir"; die_json "state_write" "cannot write the trial record $record_path"; }
  rm -rf "$dir" 2>/dev/null || true

  local out
  out="$(jq -nc --arg runner "$name" --arg model "$model" --arg effort "$effort" \
    --arg status "$result" --arg confirmed "$confirmed" --argjson cost "$cost" \
    --argjson tokens "$tokens" --argjson limit "$authoritative" \
    --arg agent_version "$agent_version" --arg record "$record_path" --arg stop "$stop_reason" \
    '{runner: $runner, model: $model, effort: (if $effort == "" then null else $effort end),
      status: $status, confirmed: (if $confirmed == "" then null else $confirmed end),
      cost_usd: $cost, tokens: $tokens, limit_usd: $limit,
      agent_version: (if $agent_version == "" then null else $agent_version end),
      record: $record, stop_reason: $stop}')"
  if [ "$json_only" -eq 1 ]; then printf '%s\n' "$out"; else printf '%s\n' "$out" | jq -r '"trial " + .runner + ": " + .status + " (model " + (.confirmed // "none") + ", cost " + (if .cost_usd == null then "unknown" else (.cost_usd | tostring) + " USD" end) + ")"'; fi
  [ "$result" = "ok" ] && return 0
  return 1
}

cmd_model() {
  local action="${1:-}"
  [ $# -gt 0 ] && shift
  case "$action" in
    list) cmd_model_list "$@" ;;
    check) cmd_model_check "$@" ;;
    trial) cmd_model_trial "$@" ;;
    ""|-h|--help) usage ;;
    *) usage_error "unknown model action: $action (use list, check or trial)" ;;
  esac
}
