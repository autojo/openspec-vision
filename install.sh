#!/usr/bin/env bash
set -euo pipefail

src="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
skill_src="$src/vision"
boss_skill_src="$src/boss"
runtime_src="$src/runtime/bin"
opencode_src="$src/commands/opencode"
claude_src="$src/commands/claude/boss"

opencode_dir="$HOME/.config/opencode"
claude_dir="$HOME/.claude"
bin_dir="$HOME/.local/bin"

skill_dirs=(
  "$opencode_dir/skills/vision"
  "$claude_dir/skills/vision"
)
boss_skill_dirs=(
  "$opencode_dir/skills/boss"
  "$claude_dir/skills/boss"
)
boss_skill_marker=".vision-managed"
runtime_files=(boss boss-lib.sh boss-waiter)
opencode_commands_dir="$opencode_dir/commands"
claude_commands_dir="$claude_dir/commands/boss"
config_dir="$HOME/.config/openspec-boss"
state_dir="${BOSS_STATE_DIR:-$HOME/.local/state/openspec-boss}"

no_boss_skill=0
force_boss_skill=0
uninstall=0

info() { printf 'install: %s\n' "$*"; }
warn() { printf 'install: warning: %s\n' "$*" >&2; }
fail() { printf 'install: error: %s\n' "$*" >&2; }

usage() {
  cat <<'EOF'
Usage: ./install.sh [--no-boss-skill | --force-boss-skill] [--help | --uninstall]

Installs the vision skill and, by default, the bundled boss skill together with
the boss runtime and the command wrappers, as regular files. Nothing is
installed as a symbolic link.

  --no-boss-skill     Install the vision skill only; do not touch any boss
                      skill directory.
  --force-boss-skill  Replace a foreign boss skill directory that this
                      installer does not own.
  --help              Show this help and exit.
  --uninstall         Remove the installed skills, runtime binaries and
                      command wrappers. Configuration and runtime state are
                      kept; a foreign boss skill directory is left in place.

The installer requires bash, jq, python3 >= 3.11, openspec and herdr.
EOF
}

# copy_file <src> <dest> <mode> -- atomically replace any file or symlink at
# dest with a regular copy. The temp file lives in the destination directory,
# so rename is atomic on the same filesystem and a running waiter keeps its
# already-open script instead of being disturbed by an unlink.
copy_file() {
  local file="$1" dest="$2" mode="$3" tmp
  mkdir -p -- "$(dirname -- "$dest")"
  tmp="$(mktemp "${dest}.XXXXXX")" || { fail "cannot create temp file for $dest"; return 1; }
  if install -m "$mode" -- "$file" "$tmp"; then
    if mv -f -- "$tmp" "$dest"; then
      return 0
    fi
  fi
  rm -f -- "$tmp"
  fail "cannot install $file to $dest"
  return 1
}

# running_waiters -- number of boss-waiter processes currently alive. The
# installer reports them but never signals or restarts them.
running_waiters() {
  if command -v pgrep >/dev/null 2>&1; then
    { pgrep -f '[/]boss-waiter' 2>/dev/null || true; } | wc -l | tr -d ' '
  else
    { ps -ef 2>/dev/null | grep '[b]oss-waiter' || true; } | wc -l | tr -d ' '
  fi
}

check_prereqs() {
  local missing=() cmd
  for cmd in bash jq python3 openspec herdr; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done
  if command -v python3 >/dev/null 2>&1; then
    if ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
      missing+=("python3 >= 3.11 (tomllib)")
    fi
  fi
  if [ "${#missing[@]}" -gt 0 ]; then
    local joined
    joined="$(printf '%s, ' "${missing[@]}")"
    fail "missing prerequisites: ${joined%, }"
    return 1
  fi
}

install_integrations() {
  local tool status
  for tool in opencode claude; do
    if ! herdr integration install "$tool"; then
      fail "cannot install the Herdr integration for $tool"
      return 1
    fi
    if [ "$tool" = "opencode" ]; then
      # An old V1-only integration installs without an error but cannot report
      # V2 agent state. Fail here instead of silently breaking apply wakeups.
      status="$(herdr integration status 2>/dev/null || true)"
      if ! printf '%s\n' "$status" | grep -q '^opencode: current'; then
        fail "the Herdr opencode integration is not current; update Herdr to a version with opencode integration v13 or newer and run ./install.sh again"
        return 1
      fi
    fi
    info "Herdr integration ready for $tool"
  done
}

# install_skill <source dir> <target dir> -- replace the target with a copy of
# every file in the source directory. The caller decides whether replacing the
# target is safe.
install_skill() {
  local src="$1" dir="$2" file rel
  [ -d "$src" ] || { fail "missing directory $src"; return 1; }
  [ -f "$src/SKILL.md" ] || { fail "missing $src/SKILL.md"; return 1; }
  rm -rf -- "$dir"
  mkdir -p -- "$dir"
  while IFS= read -r -d '' file; do
    rel="${file#"$src"/}"
    copy_file "$file" "$dir/$rel" 0644
  done < <(find "$src" -type f -print0)
  info "installed $dir"
}

install_vision_skill() {
  local dir
  for dir in "${skill_dirs[@]}"; do
    install_skill "$skill_src" "$dir" || return 1
  done
}

# install_boss_skill -- install the bundled boss skill without destroying a
# directory the installer did not create. A symlink (old boss-mode link or a
# foreign one) is replaced; a real directory is replaced only when it carries
# the ownership marker or --force-boss-skill is given.
install_boss_skill() {
  local dir
  [ -d "$boss_skill_src" ] || { fail "missing directory $boss_skill_src"; return 1; }
  [ -f "$boss_skill_src/SKILL.md" ] || { fail "missing $boss_skill_src/SKILL.md"; return 1; }
  for dir in "${boss_skill_dirs[@]}"; do
    if [ -L "$dir" ]; then
      rm -f -- "$dir"
      info "removed old boss skill symlink $dir"
    elif [ -e "$dir" ] && [ ! -d "$dir" ]; then
      if [ "$force_boss_skill" -eq 1 ]; then
        rm -f -- "$dir"
      else
        warn "left foreign boss skill file in place: $dir (use --force-boss-skill to replace it)"
        continue
      fi
    elif [ -d "$dir" ] && [ ! -f "$dir/$boss_skill_marker" ]; then
      if [ "$force_boss_skill" -eq 1 ]; then
        rm -rf -- "$dir"
      else
        warn "left foreign boss skill directory in place: $dir (use --force-boss-skill to replace it)"
        continue
      fi
    fi
    install_skill "$boss_skill_src" "$dir" || return 1
    printf 'managed by the vision-skill installer; safe to replace\n' >"$dir/$boss_skill_marker"
  done
}

install_runtime() {
  local name
  mkdir -p -- "$bin_dir"
  for name in "${runtime_files[@]}"; do
    [ -f "$runtime_src/$name" ] || { fail "missing $runtime_src/$name"; return 1; }
    copy_file "$runtime_src/$name" "$bin_dir/$name" 0755
  done
  info "installed the boss runtime into $bin_dir"
}

install_wrappers() {
  local file
  mkdir -p -- "$opencode_commands_dir"
  for file in "$opencode_src"/boss-*.md; do
    [ -e "$file" ] || continue
    copy_file "$file" "$opencode_commands_dir/$(basename -- "$file")" 0644
  done

  if [ -L "$claude_commands_dir" ]; then
    rm -f -- "$claude_commands_dir"
  fi
  mkdir -p -- "$claude_commands_dir"
  for file in "$claude_src"/*.md; do
    [ -e "$file" ] || continue
    copy_file "$file" "$claude_commands_dir/$(basename -- "$file")" 0644
  done
  info "installed the boss command wrappers"
}

verify_install() {
  local bad=0 dir name file target
  local -a check_dirs=("${skill_dirs[@]}")
  if [ "$no_boss_skill" -eq 0 ]; then
    check_dirs+=("${boss_skill_dirs[@]}")
  fi
  for dir in "${check_dirs[@]}"; do
    target="$dir/SKILL.md"
    if [ ! -f "$target" ] || [ -L "$target" ]; then
      fail "verification failed: $target is not a regular file"
      bad=1
    fi
  done
  for name in "${runtime_files[@]}"; do
    target="$bin_dir/$name"
    if [ ! -f "$target" ] || [ -L "$target" ] || { [ "$name" = boss ] && [ ! -x "$target" ]; }; then
      fail "verification failed: $target is not a regular executable file"
      bad=1
    fi
  done
  for file in "$opencode_src"/boss-*.md; do
    [ -e "$file" ] || continue
    target="$opencode_commands_dir/$(basename -- "$file")"
    if [ ! -f "$target" ] || [ -L "$target" ]; then
      fail "verification failed: $target is not a regular file"
      bad=1
    fi
  done
  for file in "$claude_src"/*.md; do
    [ -e "$file" ] || continue
    target="$claude_commands_dir/$(basename -- "$file")"
    if [ ! -f "$target" ] || [ -L "$target" ]; then
      fail "verification failed: $target is not a regular file"
      bad=1
    fi
  done
  [ "$bad" -eq 0 ]
}

install_all() {
  check_prereqs
  local waiters_before waiters_after
  waiters_before="$(running_waiters)"
  mkdir -p -- "$opencode_dir" "$claude_dir"
  install_integrations
  install_vision_skill
  if [ "$no_boss_skill" -eq 0 ]; then
    install_boss_skill
  else
    info "skipping the boss skill (--no-boss-skill)"
  fi
  install_runtime
  install_wrappers
  verify_install
  waiters_after="$(running_waiters)"
  if [ "${waiters_after:-0}" -gt 0 ] 2>/dev/null; then
    info "left $waiters_after running waiter(s) untouched (before install: ${waiters_before:-0}); they keep their loaded code until they exit"
  fi
  info "done; config is $config_dir and state is $state_dir"
}

remove_wrappers() {
  local file target
  for file in "$opencode_src"/boss-*.md; do
    [ -e "$file" ] || continue
    target="$opencode_commands_dir/$(basename -- "$file")"
    rm -f -- "$target"
  done
  if [ -L "$claude_commands_dir" ]; then
    rm -f -- "$claude_commands_dir"
  elif [ -d "$claude_commands_dir" ]; then
    for file in "$claude_src"/*.md; do
      [ -e "$file" ] || continue
      rm -f -- "$claude_commands_dir/$(basename -- "$file")"
    done
    rmdir --ignore-fail-on-non-empty -- "$claude_commands_dir" 2>/dev/null || true
  fi
  info "removed the boss command wrappers"
}

uninstall_all() {
  local dir name
  for dir in "${skill_dirs[@]}"; do
    rm -rf -- "$dir"
    info "removed $dir"
  done
  for dir in "${boss_skill_dirs[@]}"; do
    if [ -L "$dir" ]; then
      warn "left boss skill symlink in place: $dir (not installed by this installer)"
    elif [ -d "$dir" ]; then
      if [ -f "$dir/$boss_skill_marker" ]; then
        rm -rf -- "$dir"
        info "removed $dir"
      else
        warn "left foreign boss skill directory in place: $dir"
      fi
    elif [ -e "$dir" ]; then
      warn "left foreign boss skill file in place: $dir"
    fi
  done
  for name in "${runtime_files[@]}"; do
    rm -f -- "$bin_dir/$name"
  done
  info "removed the boss runtime from $bin_dir"
  remove_wrappers
  info "kept config $config_dir and state $state_dir"
}

parse_args() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --no-boss-skill) no_boss_skill=1 ;;
      --force-boss-skill) force_boss_skill=1 ;;
      --uninstall) uninstall=1 ;;
      --help|-h) usage; exit 0 ;;
      *)
        fail "unknown argument: $arg"
        usage >&2
        exit 2
        ;;
    esac
  done
  if [ "$no_boss_skill" -eq 1 ] && [ "$force_boss_skill" -eq 1 ]; then
    fail "--no-boss-skill and --force-boss-skill cannot be combined"
    exit 2
  fi
}

parse_args "$@"
if [ "$uninstall" -eq 1 ]; then
  uninstall_all
else
  install_all
fi
