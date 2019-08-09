#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'
umask 077

readonly DOOMSDAY_VERSION="0.1.0"
readonly DOOMSDAY_LABEL="com.local.doomsday.tick"
readonly DOOMSDAY_SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
readonly DOOMSDAY_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly DOOMSDAY_STATE_DIR="${DOOMSDAY_STATE_DIR:-${HOME:?}/.local/share/doomsday}"
readonly DOOMSDAY_DEFAULT_CRYO_TARGET="${DOOMSDAY_CRYO_TARGET:-/Volumes/CRYO}"

DOOMSDAY_LOG_FILE=""

usage() {
  cat <<'EOF'
usage:
  doomsday set [days]
  doomsday whatsup
  doomsday abort
  doomsday doom [--yes] [--target path] [--skip-cryo] [--fetch-installer] [--installer app] [--force] [--no-countdown]
  doomsday tick
  doomsday doctor
  doomsday install-launchd [--allow-usb-agent]
  doomsday uninstall-launchd
  doomsday help

api:
  set [days]
    Arms doom for N days from now. Default: 30.

  whatsup
    Prints current state.

  abort
    Aborts any armed doom.

  doom [--yes]
    Begins doom, freezes environment with cryo, then invokes Apple's
    startosinstall --eraseinstall reinstall flow.
EOF
}

main() {
  init_logging
  local command="${1:-help}"
  shift || true

  case "$command" in
    set) command_set "$@" ;;
    whatsup) command_whatsup "$@" ;;
    abort) command_abort "$@" ;;
    doom) command_doom "$@" ;;
    tick) command_tick "$@" ;;
    doctor) command_doctor "$@" ;;
    install-launchd) command_install_launchd "$@" ;;
    uninstall-launchd) command_uninstall_launchd "$@" ;;
    help|-h|--help) usage ;;
    version|--version) printf '%s\n' "$DOOMSDAY_VERSION" ;;
    *) usage >&2; die "unknown command: $command" ;;
  esac
}

init_logging() {
  mkdir -p "$DOOMSDAY_STATE_DIR/logs"
  DOOMSDAY_LOG_FILE="$DOOMSDAY_STATE_DIR/logs/doomsday-$(date -u +%Y-%m-%d).log"
}

log() {
  local message="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
  printf '%s\n' "$message" >&2
  if [ -n "$DOOMSDAY_LOG_FILE" ]; then
    printf '%s\n' "$message" >> "$DOOMSDAY_LOG_FILE" 2>/dev/null || true
  fi
}

info() { log "INFO: $*"; }
warn() { log "WARN: $*"; }
die() { log "ERROR: $*"; exit 1; }

require_macos() {
  [ "$(uname -s)" = "Darwin" ] || die "doomsday requires macOS"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command missing: $1"
}

require_core_commands() {
  require_command date
  require_command sw_vers
  require_command diskutil
  require_command pmset
  require_command hdiutil
  require_command osascript
}

now_epoch() {
  date -u +%s
}

future_epoch_days() {
  local days="$1"
  date -u -v+"${days}"d +%s
}

format_epoch_utc() {
  local epoch="$1"
  date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ
}

human_remaining() {
  local seconds="$1"
  local sign=""
  if [ "$seconds" -lt 0 ]; then
    sign="-"
    seconds=$((seconds * -1))
  fi
  local days hours minutes
  days=$((seconds / 86400))
  hours=$(((seconds % 86400) / 3600))
  minutes=$(((seconds % 3600) / 60))
  printf '%s%dd %dh %dm\n' "$sign" "$days" "$hours" "$minutes"
}

state_path() {
  printf '%s/%s\n' "$DOOMSDAY_STATE_DIR" "$1"
}

state_write() {
  local key="$1"
  local value="$2"
  printf '%s\n' "$value" > "$(state_path "$key")"
}

state_read() {
  local key="$1"
  local default="${2:-}"
  local path
  path="$(state_path "$key")"
  if [ -f "$path" ]; then
    cat "$path"
  else
    printf '%s\n' "$default"
  fi
}

validate_positive_integer() {
  local value="$1"
  case "$value" in
    ''|*[!0-9]*) return 1 ;;
    *) [ "$value" -gt 0 ] ;;
  esac
}

notify() {
  local title="$1"
  local body="$2"
  osascript -e "display notification \"$(applescript_escape "$body")\" with title \"$(applescript_escape "$title")\"" >/dev/null 2>&1 || true
}

applescript_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

command_set() {
  require_macos
  local days="${1:-30}"
  [ $# -le 1 ] || die "set accepts at most one argument"
  validate_positive_integer "$days" || die "days must be a positive integer"
  [ "$days" -le 366 ] || die "refusing schedules longer than 366 days"

  local epoch utc
  epoch="$(future_epoch_days "$days")"
  utc="$(format_epoch_utc "$epoch")"

  state_write status armed
  state_write created_at_utc "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  state_write doom_at_epoch "$epoch"
  state_write doom_at_utc "$utc"
  state_write cryo_target "$DOOMSDAY_DEFAULT_CRYO_TARGET"
  rm -f "$DOOMSDAY_STATE_DIR"/notified_* "$DOOMSDAY_STATE_DIR/due_terminal_opened" 2>/dev/null || true

  info "doom armed for $utc ($days days)"
  notify "doomsday armed" "Doom scheduled for $utc"
}

command_whatsup() {
  require_macos
  local status epoch utc remaining now target
  status="$(state_read status disarmed)"
  epoch="$(state_read doom_at_epoch '')"
  utc="$(state_read doom_at_utc '')"
  target="$(state_read cryo_target "$DOOMSDAY_DEFAULT_CRYO_TARGET")"

  printf 'status=%s\n' "$status"
  [ -n "$utc" ] && printf 'doom_at_utc=%s\n' "$utc"
  [ -n "$target" ] && printf 'cryo_target=%s\n' "$target"

  if [ "$status" = "armed" ] && [ -n "$epoch" ]; then
    now="$(now_epoch)"
    remaining=$((epoch - now))
    printf 'remaining=%s\n' "$(human_remaining "$remaining")"
  fi

  if [ -f "$DOOMSDAY_STATE_DIR/last_doom_attempt_utc" ]; then
    printf 'last_doom_attempt_utc=%s\n' "$(cat "$DOOMSDAY_STATE_DIR/last_doom_attempt_utc")"
  fi
}

command_abort() {
  require_macos
  state_write status aborted
  state_write aborted_at_utc "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  rm -f "$DOOMSDAY_STATE_DIR/due_terminal_opened" 2>/dev/null || true
  info "doom aborted"
  notify "doomsday aborted" "Scheduled doom has been aborted."
}

is_ac_powered() {
  pmset -g ps 2>/dev/null | head -n 1 | grep -q "AC Power"
}

filevault_status() {
  if command -v fdesetup >/dev/null 2>&1; then
    fdesetup status 2>/dev/null || true
  fi
}

find_cryo() {
  if [ -x "$DOOMSDAY_SCRIPT_DIR/cryo" ]; then
    printf '%s\n' "$DOOMSDAY_SCRIPT_DIR/cryo"
    return 0
  fi
  if command -v cryo >/dev/null 2>&1; then
    command -v cryo
    return 0
  fi
  return 1
}

resolve_cryo_target() {
  local target="$1"
  [ -n "$target" ] || target="$(state_read cryo_target "$DOOMSDAY_DEFAULT_CRYO_TARGET")"
  [ -n "$target" ] || target="$DOOMSDAY_DEFAULT_CRYO_TARGET"
  [ -d "$target" ] || die "cryo target is not mounted: $target"
  [ -w "$target" ] || die "cryo target is not writable: $target"
  printf '%s\n' "$target"
}

find_installer_app() {
  local explicit="${1:-}"
  local app

  if [ -n "$explicit" ]; then
    [ -d "$explicit" ] || die "installer app not found: $explicit"
    [ -x "$explicit/Contents/Resources/startosinstall" ] || die "installer missing startosinstall: $explicit"
    printf '%s\n' "$explicit"
    return 0
  fi

  if [ -n "${DOOMSDAY_INSTALLER:-}" ]; then
    find_installer_app "$DOOMSDAY_INSTALLER"
    return 0
  fi

  for app in "/Applications"/Install\ macOS*.app; do
    [ -d "$app" ] || continue
    if [ -x "$app/Contents/Resources/startosinstall" ]; then
      printf '%s\n' "$app"
      return 0
    fi
  done

  return 1
}

fetch_installer() {
  local version="${DOOMSDAY_FULL_INSTALLER_VERSION:-}"
  require_command softwareupdate

  if [ -n "$version" ]; then
    info "fetching full macOS installer version: $version"
    softwareupdate --fetch-full-installer --full-installer-version "$version"
  else
    info "fetching latest compatible full macOS installer"
    softwareupdate --fetch-full-installer
  fi
}

startosinstall_usage_contains() {
  local startosinstall="$1"
  local needle="$2"
  "$startosinstall" --usage 2>&1 | grep -q -- "$needle"
}

read_secret_once() {
  local prompt="$1"
  local secret old_tty
  old_tty="$(stty -g 2>/dev/null || true)"
  printf '%s' "$prompt" >&2
  stty -echo 2>/dev/null || true
  IFS= read -r secret || {
    [ -n "$old_tty" ] && stty "$old_tty" 2>/dev/null || true
    printf '\n' >&2
    die "failed to read secret"
  }
  [ -n "$old_tty" ] && stty "$old_tty" 2>/dev/null || true
  printf '\n' >&2
  REPLY_SECRET="$secret"
}

confirm_phrase() {
  local expected="$1"
  local prompt="$2"
  local answer
  printf '%s\n' "$prompt" >&2
  printf 'Type exactly %s to continue: ' "$expected" >&2
  IFS= read -r answer || die "confirmation failed"
  [ "$answer" = "$expected" ] || die "confirmation phrase did not match"
}

countdown_or_abort() {
  local seconds="$1"
  local status
  while [ "$seconds" -gt 0 ]; do
    status="$(state_read status disarmed)"
    [ "$status" != "aborted" ] || die "doom aborted during countdown"
    printf '\rStarting destructive reinstall in %02d seconds. Press Ctrl-C to abort. ' "$seconds" >&2
    sleep 1
    seconds=$((seconds - 1))
  done
  printf '\n' >&2
}

run_cryo_sleep() {
  local target="$1"
  local cryo
  cryo="$(find_cryo || true)"
  [ -n "$cryo" ] || die "cryo command not found; use --skip-cryo only if you intentionally accept no fresh snapshot"
  info "running cryo sleep against target: $target"
  "$cryo" sleep "$target" --yes
}

verify_cryo_target_has_snapshot() {
  local target="$1"
  local latest checksum base dir
  latest="$target/snapshots/latest"
  [ -L "$latest" ] || die "cryo did not create latest snapshot symlink: $latest"
  base="$(readlink "$latest")"
  case "$base" in
    /*) latest="$base" ;;
    *) latest="$target/snapshots/$base" ;;
  esac
  [ -f "$latest" ] || die "latest cryo snapshot missing: $latest"
  dir="$(dirname "$latest")"
  base="$(basename "$latest")"
  checksum="$dir/$base.sha256"
  [ -f "$checksum" ] || die "latest cryo checksum missing: $checksum"
  (
    cd "$dir"
    shasum -a 256 -c "$base.sha256" >/dev/null
  ) || die "latest cryo checksum verification failed"
  info "verified cryo snapshot: $latest"
}

preflight_for_doom() {
  local force="$1"
  require_macos
  require_core_commands

  [ "$EUID" -ne 0 ] || warn "running as root; local user context may not match expected cryo state"

  if ! is_ac_powered; then
    [ "$force" = "1" ] || die "Mac is not on AC power; use --force to override"
    warn "continuing without AC power because --force was supplied"
  fi

  local fv
  fv="$(filevault_status)"
  if [ -n "$fv" ]; then
    info "FileVault: $fv"
  fi

  local free_kb
  free_kb="$(df -k /Applications 2>/dev/null | awk 'NR==2 {print $4}')"
  if [ -n "$free_kb" ] && [ "$free_kb" -lt 15000000 ]; then
    [ "$force" = "1" ] || die "less than 15GB free on /Applications volume; use --force to override"
    warn "continuing with low free disk space because --force was supplied"
  fi
}

run_startosinstall_erase() {
  local installer_app="$1"
  local startosinstall="$installer_app/Contents/Resources/startosinstall"
  local arch volume_owner pass

  [ -x "$startosinstall" ] || die "startosinstall is not executable: $startosinstall"

  info "using installer: $installer_app"
  info "authenticating sudo before handing off to startosinstall"
  sudo -v

  arch="$(uname -m)"

  if [ "$arch" = "arm64" ] && \
     startosinstall_usage_contains "$startosinstall" "--user" && \
     startosinstall_usage_contains "$startosinstall" "--stdinpass"; then
    volume_owner="${DOOMSDAY_VOLUME_OWNER:-$USER}"
    [ -n "$volume_owner" ] || die "could not determine Volume Owner user"
    read_secret_once "Volume Owner password for $volume_owner: "
    pass="$REPLY_SECRET"
    info "invoking startosinstall erase flow with Apple Silicon Volume Owner credentials"
    printf '%s\n' "$pass" | sudo "$startosinstall" \
      --eraseinstall \
      --agreetolicense \
      --forcequitapps \
      --nointeraction \
      --user "$volume_owner" \
      --stdinpass
    unset pass REPLY_SECRET
  else
    info "invoking startosinstall erase flow"
    sudo "$startosinstall" \
      --eraseinstall \
      --agreetolicense \
      --forcequitapps \
      --nointeraction
  fi
}

command_doom() {
  local assume_yes="0"
  local force="0"
  local skip_cryo="0"
  local fetch="0"
  local no_countdown="0"
  local scheduled="0"
  local target=""
  local installer_app=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --yes|-y) assume_yes="1" ;;
      --force) force="1" ;;
      --skip-cryo) skip_cryo="1" ;;
      --fetch-installer) fetch="1" ;;
      --no-countdown) no_countdown="1" ;;
      --scheduled) scheduled="1" ;;
      --target)
        shift
        [ $# -gt 0 ] || die "--target requires a path"
        target="$1"
        ;;
      --installer)
        shift
        [ $# -gt 0 ] || die "--installer requires a path"
        installer_app="$1"
        ;;
      --help|-h) usage; return 0 ;;
      --*) die "unknown doom option: $1" ;;
      *) die "unexpected doom argument: $1" ;;
    esac
    shift
  done

  preflight_for_doom "$force"

  if [ "$scheduled" = "1" ]; then
    [ "$(state_read status disarmed)" = "armed" ] || die "scheduled doom is not armed"
  fi

  state_write last_doom_attempt_utc "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  target="$(resolve_cryo_target "$target")"
  state_write cryo_target "$target"

  if [ "$assume_yes" != "1" ]; then
    confirm_phrase "WIPE $(hostname -s 2>/dev/null || hostname)" "This will freeze your environment to $target, erase this Mac, and reinstall macOS."
  fi

  notify "doomsday" "Destructive reinstall preflight has started."

  if [ "$skip_cryo" != "1" ]; then
    run_cryo_sleep "$target"
    verify_cryo_target_has_snapshot "$target"
  else
    [ "$force" = "1" ] || die "--skip-cryo requires --force"
    warn "skipping cryo snapshot because --skip-cryo and --force were supplied"
  fi

  if [ -n "$installer_app" ]; then
    installer_app="$(find_installer_app "$installer_app")"
  else
    installer_app="$(find_installer_app "" 2>/dev/null || true)"
  fi

  if [ -z "$installer_app" ] && [ "$fetch" = "1" ]; then
    fetch_installer
    installer_app="$(find_installer_app "" 2>/dev/null || true)"
  fi

  [ -n "$installer_app" ] || die "no valid /Applications/Install macOS*.app found; rerun with --fetch-installer or --installer path"

  if [ "$no_countdown" != "1" ]; then
    countdown_or_abort 10
  fi

  [ "$(state_read status armed)" != "aborted" ] || die "doom aborted before startosinstall"
  state_write status executing
  state_write executing_at_utc "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  notify "doomsday" "Starting Apple erase/reinstall flow."
  run_startosinstall_erase "$installer_app"
}

notify_threshold_once() {
  local label="$1"
  local threshold_seconds="$2"
  local remaining="$3"
  local message="$4"
  local marker="$DOOMSDAY_STATE_DIR/notified_$label"

  if [ "$remaining" -le "$threshold_seconds" ] && [ ! -f "$marker" ]; then
    notify "doomsday" "$message"
    date -u +%Y-%m-%dT%H:%M:%SZ > "$marker"
  fi
}

open_terminal_for_due_doom() {
  local runner="$DOOMSDAY_STATE_DIR/run-due-doom.sh"
  local marker="$DOOMSDAY_STATE_DIR/due_terminal_opened"
  local command escaped

  if [ -f "$marker" ]; then
    warn "due doom terminal was already opened; not opening another"
    return 0
  fi

  cat > "$runner" <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec $(shell_quote "$DOOMSDAY_SCRIPT_PATH") doom --yes --scheduled
EOF
  chmod 700 "$runner"

  command="/bin/bash $(shell_quote "$runner")"
  escaped="$(applescript_escape "$command")"

  osascript \
    -e 'tell application "Terminal" to activate' \
    -e "tell application \"Terminal\" to do script \"$escaped\"" >/dev/null 2>&1 || \
    die "failed to open Terminal for due doom"

  date -u +%Y-%m-%dT%H:%M:%SZ > "$marker"
  notify "doomsday due" "Opened Terminal to run scheduled doom."
}

command_tick() {
  require_macos
  local status epoch now remaining utc
  status="$(state_read status disarmed)"
  [ "$status" = "armed" ] || exit 0

  epoch="$(state_read doom_at_epoch '')"
  [ -n "$epoch" ] || die "armed state missing doom_at_epoch"
  now="$(now_epoch)"
  remaining=$((epoch - now))
  utc="$(state_read doom_at_utc "$(format_epoch_utc "$epoch")")"

  notify_threshold_once "7d" 604800 "$remaining" "Doom is scheduled for $utc."
  notify_threshold_once "3d" 259200 "$remaining" "Doom is 3 days away. Run doomsday abort to cancel."
  notify_threshold_once "1d" 86400 "$remaining" "Doom is 1 day away. Ensure cryo target is available."
  notify_threshold_once "6h" 21600 "$remaining" "Doom is less than 6 hours away."
  notify_threshold_once "1h" 3600 "$remaining" "Doom is less than 1 hour away."

  if [ "$remaining" -le 0 ]; then
    open_terminal_for_due_doom
  fi
}

command_doctor() {
  require_macos
  printf 'doomsday_version=%s\n' "$DOOMSDAY_VERSION"
  printf 'script_path=%s\n' "$DOOMSDAY_SCRIPT_PATH"
  printf 'state_dir=%s\n' "$DOOMSDAY_STATE_DIR"
  printf 'status=%s\n' "$(state_read status disarmed)"
  if [ -f "$(state_path doom_at_utc)" ]; then
    printf 'doom_at_utc=%s\n' "$(state_read doom_at_utc '')"
  fi
  printf 'cryo_target=%s\n' "$(state_read cryo_target "$DOOMSDAY_DEFAULT_CRYO_TARGET")"
  if find_cryo >/dev/null 2>&1; then
    printf 'cryo=%s\n' "$(find_cryo)"
  else
    printf 'cryo=missing\n'
  fi
  if find_installer_app "" >/dev/null 2>&1; then
    printf 'installer=%s\n' "$(find_installer_app "")"
  else
    printf 'installer=missing\n'
  fi
  if is_ac_powered; then
    printf 'ac_power=yes\n'
  else
    printf 'ac_power=no\n'
  fi
  filevault_status | sed 's/^/filevault=/' || true
}

command_install_launchd() {
  require_macos
  local allow_usb="0"
  while [ $# -gt 0 ]; do
    case "$1" in
      --allow-usb-agent) allow_usb="1" ;;
      --help|-h) usage; return 0 ;;
      *) die "unknown install-launchd option: $1" ;;
    esac
    shift
  done

  case "$DOOMSDAY_SCRIPT_PATH" in
    /Volumes/*)
      [ "$allow_usb" = "1" ] || die "refusing to install LaunchAgent pointing to a removable volume; use --allow-usb-agent to override"
      ;;
  esac

  local agents_dir plist
  agents_dir="$HOME/Library/LaunchAgents"
  plist="$agents_dir/$DOOMSDAY_LABEL.plist"
  mkdir -p "$agents_dir"

  cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$DOOMSDAY_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$DOOMSDAY_SCRIPT_PATH</string>
    <string>tick</string>
  </array>
  <key>StartInterval</key>
  <integer>3600</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$DOOMSDAY_STATE_DIR/logs/launchd.out.log</string>
  <key>StandardErrorPath</key>
  <string>$DOOMSDAY_STATE_DIR/logs/launchd.err.log</string>
</dict>
</plist>
EOF
  chmod 600 "$plist"

  launchctl unload "$plist" >/dev/null 2>&1 || true
  launchctl load -w "$plist"
  info "installed LaunchAgent: $plist"
}

command_uninstall_launchd() {
  require_macos
  local plist="$HOME/Library/LaunchAgents/$DOOMSDAY_LABEL.plist"
  if [ -f "$plist" ]; then
    launchctl unload "$plist" >/dev/null 2>&1 || true
    rm -f "$plist"
    info "removed LaunchAgent: $plist"
  else
    info "LaunchAgent not installed: $plist"
  fi
}

main "$@"