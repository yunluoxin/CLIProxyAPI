#!/usr/bin/env bash
# scripts/install.sh — manage a locally-built CLIProxyAPI as a macOS launchd service.
#
# Layout (defaults, override via env vars):
#   CONFIG_DIR    = ~/.config/cli-proxy-api      # holds config.yaml, auths/, logs/
#   BIN_DIR       = ~/.local/bin                 # install dir for the binary
#   BIN_NAME      = cliproxyapi                  # binary name (was cli-proxy-api)
#   PLIST_PATH    = ~/Library/LaunchAgents/com.cliproxyapi.server.plist
#   SOURCE_DIR    = auto-detected (script's parent directory) or $CLI_PROXY_SRC
#
# Subcommands:
#   (no args)     Same as `install` — default action. So `./scripts/install.sh` or
#                 `sh scripts/install.sh` both work.
#   install       Build the binary, install it, generate plist, copy config skeleton,
#                 register with launchd, and start the service.
#   uninstall     Unload the service, remove the plist, and remove the binary.
#   start|stop    launchctl start/stop the service.
#   restart       launchctl kickstart -k (graceful restart) or stop+start fallback.
#   status        Show whether the service is running and the resolved paths.
#   logs          Tail the service's stdout/stderr log files (Ctrl-C to exit).
#   rebuild       Pull latest source (git pull), gofmt, go build, reinstall, reload.
#   config-path   Print the resolved CONFIG_DIR and exit.
#
# Flags (may appear before or after the subcommand):
#   --debug       Build without stripping symbol table / DWARF info. By default the
#                 release binary is built with -ldflags="-s -w" for a smaller
#                 footprint; use --debug to keep symbols + line numbers for
#                 stack-trace / pprof readability.
#
# Env overrides:
#   CLI_PROXY_SRC      Absolute path to the repo root (auto-detected if unset).
#   CLI_PROXY_CONFIG   Absolute path to the config.yaml (default: $CONFIG_DIR/config.yaml).
#   CLI_PROXY_PORT     Port to expose (default: 8317, must match config.yaml).
#   CLI_PROXY_BREW     Set non-empty to symlink the existing Homebrew install dir
#                      instead of copying the binary (handy when the official
#                      formula is installed via brew).

set -euo pipefail

CONFIG_DIR="${CLI_PROXY_CONFIG_DIR:-$HOME/.config/cli-proxy-api}"
CONFIG_FILE="${CLI_PROXY_CONFIG:-$CONFIG_DIR/config.yaml}"
LOG_DIR="$CONFIG_DIR/logs"
# CONFIG_DIR_TILDE is the same path with $HOME replaced by `~` — used when writing
# settings back into config.yaml so the file stays portable across machines.
CONFIG_DIR_TILDE="${CONFIG_DIR/#$HOME/~}"
BIN_DIR="${CLI_PROXY_BIN_DIR:-$HOME/.local/bin}"
BIN_NAME="cliproxyapi"
BIN_PATH="$BIN_DIR/$BIN_NAME"
PLIST_NAME="com.cliproxyapi.server.plist"
PLIST_PATH="$HOME/Library/LaunchAgents/$PLIST_NAME"
LABEL="com.cliproxyapi.server"
TARGET="gui/$UID/$LABEL"
PORT="${CLI_PROXY_PORT:-8317}"

# --- source detection ---------------------------------------------------------
if [[ -n "${CLI_PROXY_SRC:-}" ]]; then
  SOURCE_DIR="$CLI_PROXY_SRC"
elif [[ -z "${BASH_SOURCE[0]:-}" ]]; then
  SOURCE_DIR="$(pwd)"
else
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  SOURCE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
fi

log() { printf '\033[1;34m[install]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
err() { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

require_macos() {
  [[ "$(uname -s)" == "Darwin" ]] || err "this script targets macOS (uses launchd)."
}

require_go() {
  command -v go >/dev/null || err "go is not on PATH; install Go 1.26+ first."
}

usage() {
  sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
}

write_plist() {
  cat >"$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${BIN_PATH}</string>
    <string>--config</string>
    <string>${CONFIG_FILE}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>WorkingDirectory</key>
  <string>${CONFIG_DIR}</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
  <key>StandardOutPath</key>
  <string>${LOG_DIR}/stdout.log</string>
  <key>StandardErrorPath</key>
  <string>${LOG_DIR}/stderr.log</string>
  <key>SoftResourceLimits</key>
  <dict>
    <key>NumberOfFiles</key>
    <integer>65536</integer>
  </dict>
</dict>
</plist>
EOF
}

# build_ldflags prints the -ldflags value to use when invoking `go build`.
#
# - In release mode, strips symbol table + DWARF and injects version metadata
#   (Version / Commit / BuildDate) into main.Version etc., matching the
#   Dockerfile build so the management UI shows the right version string.
# - In debug mode, keeps symbols and still injects version metadata (so
#   `--debug` builds are still self-describing in the UI).
#
# Version metadata can be overridden via env vars (handy for release tags):
#   CLI_PROXY_VERSION    e.g. "v7.1.0"  (default: git describe --tags --always --dirty, or "dev")
#   CLI_PROXY_COMMIT     e.g. "abc1234" (default: git rev-parse --short=12 HEAD, or "none")
#   CLI_PROXY_BUILD_DATE e.g. "2026-07-20T10:00:00Z" (default: date -u +...)
build_ldflags() {
  local debug="$1"

  local version="${CLI_PROXY_VERSION:-}"
  local commit="${CLI_PROXY_COMMIT:-}"
  local build_date="${CLI_PROXY_BUILD_DATE:-}"

  if [[ -z "$version" || -z "$commit" || -z "$build_date" ]]; then
    if [[ -d "$SOURCE_DIR/.git" ]] && command -v git >/dev/null 2>&1; then
      if [[ -z "$commit" ]]; then
        commit="$(git -C "$SOURCE_DIR" rev-parse --short=12 HEAD 2>/dev/null || echo none)"
      fi
      if [[ -z "$version" ]]; then
        # describe --tags --always --dirty gives e.g. "v7.0.0-3-gabc1234-dirty" or
        # just the short SHA if no tags exist. We strip a leading "v" so the
        # resulting string stays consistent with how the UI renders the version.
        local describe
        describe="$(git -C "$SOURCE_DIR" describe --tags --always --dirty 2>/dev/null || echo dev)"
        if [[ -z "$describe" || "$describe" == "dev" ]]; then
          version="dev"
        else
          version="$describe"
        fi
      fi
    else
      [[ -z "$version" ]] && version="dev"
      [[ -z "$commit" ]] && commit="none"
    fi
  fi
  [[ -z "$build_date" ]] && build_date="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local parts=()
  if [[ "$debug" -ne 1 ]]; then
    parts+=("-s -w")
  fi
  parts+=("-X 'main.Version=${version}'")
  parts+=("-X 'main.Commit=${commit}'")
  parts+=("-X 'main.BuildDate=${build_date}'")

  # log lines for the operator
  log "  version:    $version"
  log "  commit:     $commit"
  log "  build date: $build_date"

  # join with spaces
  ( IFS=' '; echo "${parts[*]}" )
}

do_install() {
  require_macos
  require_go
  [[ -d "$SOURCE_DIR" ]] || err "source dir not found: $SOURCE_DIR"
  [[ -f "$SOURCE_DIR/cmd/server/main.go" ]] || err "cmd/server/main.go not found under $SOURCE_DIR — set CLI_PROXY_SRC if the repo is elsewhere."

  mkdir -p "$CONFIG_DIR" "$LOG_DIR" "$BIN_DIR"

  # config.yaml: keep the user's existing one if present; otherwise seed from the repo template.
  if [[ ! -f "$CONFIG_FILE" ]]; then
    if [[ -f "$SOURCE_DIR/config.example.yaml" ]]; then
      log "seeding $CONFIG_FILE from config.example.yaml"
      # Rewrite auth-dir to point at $CONFIG_DIR_TILDE/auths so OAuth credentials land
      # in a subdirectory rather than mixed with config.yaml and logs. The tilde
      # form keeps config.yaml portable across machines.
      sed "s|^auth-dir:.*|auth-dir: \"${CONFIG_DIR_TILDE}/auths\"|" \
        "$SOURCE_DIR/config.example.yaml" > "$CONFIG_FILE"
    else
      warn "config.example.yaml not found in $SOURCE_DIR — leaving $CONFIG_FILE empty"
      : >"$CONFIG_FILE"
    fi
  else
    log "keeping existing $CONFIG_FILE"
  fi

  # auths/ subdir so the app has a place to store OAuth credentials.
  mkdir -p "$CONFIG_DIR/auths"

  # build & install the binary
  local ldflags
  ldflags="$(build_ldflags "$DEBUG_BUILD")"
  log "ldflags: $ldflags"
  ( cd "$SOURCE_DIR" && gofmt -w . && go build -ldflags="$ldflags" -o "$BIN_PATH" ./cmd/server )

  if [[ -n "${CLI_PROXY_BREW:-}" ]]; then
    log "CLI_PROXY_BREW set — skipping binary copy (using upstream brew formula instead)"
  fi

  write_plist
  log "plist written to $PLIST_PATH"

  # launchd: load (register) and start. launchctl bootstrap is the modern API;
  # fall back to launchctl load for older macOS releases.
  if launchctl bootstrap "gui/$UID" "$PLIST_PATH" 2>/dev/null; then
    log "bootstrapped plist into gui/$UID"
  else
    launchctl load -w "$PLIST_PATH"
    log "loaded plist (legacy launchctl)"
  fi
  launchctl kickstart -k "$TARGET" 2>/dev/null || true

  log "service installed"
  log "  binary:   $BIN_PATH"
  log "  config:   $CONFIG_FILE"
  log "  logs:     $LOG_DIR/"
  log "  plist:    $PLIST_PATH"
  log "  manage:   $(basename "$0") {start|stop|restart|status|logs|rebuild|uninstall}"
}

do_uninstall() {
  require_macos
  if launchctl bootout "gui/$UID/$LABEL" 2>/dev/null; then
    log "booted out $LABEL"
  elif launchctl list | grep -q "$LABEL"; then
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
    log "unloaded $LABEL (legacy)"
  else
    log "$LABEL is not loaded"
  fi
  rm -f "$PLIST_PATH"
  if [[ -z "${CLI_PROXY_BREW:-}" && -f "$BIN_PATH" ]]; then
    rm -f "$BIN_PATH"
    log "removed $BIN_PATH"
  fi
  log "uninstalled (config kept at $CONFIG_DIR — delete manually if you want it gone)"
}

do_start() {
  require_macos
  launchctl kickstart -k "$TARGET"
  log "kickstarted $LABEL"
}

do_stop() {
  require_macos
  launchctl bootout "gui/$UID/$LABEL" 2>/dev/null \
    || launchctl unload "$PLIST_PATH" 2>/dev/null \
    || true
  log "stopped $LABEL"
}

do_restart() {
  require_macos
  launchctl kickstart -k "$TARGET" || do_stop
  log "restarted $LABEL"
}

do_status() {
  require_macos
  echo "config: $CONFIG_FILE"
  echo "logs:   $LOG_DIR"
  echo "binary: $BIN_PATH"
  echo "plist: $PLIST_PATH"
  echo "target: $TARGET"
  if launchctl print "$TARGET" >/dev/null 2>&1; then
    launchctl print "$TARGET" 2>/dev/null | grep -E "^\s*(state|pid|last exit code|program)" | head -10
  else
    warn "$LABEL is NOT loaded"
    return 1
  fi
}

do_logs() {
  [[ -d "$LOG_DIR" ]] || err "log dir not found: $LOG_DIR"
  ls -lt "$LOG_DIR"/*.log 2>/dev/null | head -5 || true
  exec tail -F "$LOG_DIR"/stdout.log "$LOG_DIR"/stderr.log
}

do_rebuild() {
  require_macos
  require_go
  [[ -d "$SOURCE_DIR/.git" ]] || err "no git repo at $SOURCE_DIR; pull manually before rebuild"
  log "pulling latest source"
  ( cd "$SOURCE_DIR" && git pull --rebase --autostash )
  do_install
}

do_config_path() {
  printf '%s\n' "$CONFIG_DIR"
}

main() {
  DEBUG_BUILD=0
  local cmd=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --debug)        DEBUG_BUILD=1; shift ;;
      -h|--help|help) usage; exit 0 ;;
      install|uninstall|start|stop|restart|status|logs|rebuild|config-path)
                      cmd="$1"; shift ;;
      *)              usage; err "unknown argument: $1" ;;
    esac
  done
  if [[ -z "$cmd" ]]; then
    cmd="install"
  fi
  case "$cmd" in
    install)        do_install ;;
    uninstall)      do_uninstall ;;
    start)          do_start ;;
    stop)           do_stop ;;
    restart)        do_restart ;;
    status)         do_status ;;
    logs)           do_logs ;;
    rebuild)        do_rebuild ;;
    config-path)    do_config_path ;;
  esac
}

main "$@"