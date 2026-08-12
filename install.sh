#!/bin/sh

SCRIPT_NAME=${0##*/}
SCRIPT_BASENAME=${SCRIPT_NAME%.*}
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
WORKSPACE_DIR=$(pwd)

LOG_FILE=${LOG_FILE:-/tmp/${SCRIPT_NAME}.log}
LOG_TO_FILE=${LOG_TO_FILE:-false}

if [ -t 2 ]; then
  ESC=$(printf '\033')

  W="${ESC}[0;39m"
  R="${ESC}[1;31m"
  G="${ESC}[1;32m"
  Y="${ESC}[1;33m"
  B="${ESC}[1;34m"
  DIM="${ESC}[2m"
  C0="${ESC}[0m"
else
  W=
  R=
  G=
  Y=
  B=
  DIM=
  C0=
fi

log_format() {
  _level=$1
  shift

  _ts=$(date '+%Y-%m-%d %H:%M:%S %z')
  _msg=$_ts" - $_level : $*"

  case $_level in
    INFO)
      _print=$_msg
      _fd=1
      ;;
    WARN)
      _print=$_ts" - ${Y}WARN${C0} : $*"
      _fd=2
      ;;
    ERROR)
      _print=$_ts" - ${R}ERROR${C0} : $*"
      _fd=2
      ;;
    *)
      _print=$_msg
      _fd=1
      ;;
  esac

  printf '%b\n' "$_print" >&$_fd

  if [ "$LOG_TO_FILE" = "true" ]; then
    printf '%s\n' "$_msg" >>"$LOG_FILE"
  fi
}

log() {
  log_format INFO "$@"
}

log_warn() {
  log_format WARN "$@"
}

log_error() {
  log_format ERROR "$@"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    log_error "Required command not found: $1"
    exit 1
  fi
}

require_cmd_list() {
  for cmd do
    require_cmd "$cmd"
  done
}

show_help() {
  cat <<EOF
Usage: $SCRIPT_NAME SOURCE_SCRIPT

Install a shell script into /usr/local/bin, stripped of its .sh
extension, and mark it executable.

Arguments:
  SOURCE_SCRIPT  Path to the script to install

Options:
  -h, --help     Show this help message

Example:
  $SCRIPT_NAME durank.sh
EOF
}

download() {
  _url="$1"
  _output="$2"
  _exit_on_error="${3:-0}"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 5 --max-time 30 -o "$_output" "$_url"
    _rc=$?
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$_output" --timeout=5 --tries=1 "$_url"
    _rc=$?
  else
    log_error "Neither curl nor wget is available — please install one of them"
    if [ "$_exit_on_error" = "1" ]; then
      exit 1
    fi
    return 1
  fi

  if [ "$_rc" -ne 0 ]; then
    log_error "Failed to download ${_url}"
    if [ "$_exit_on_error" = "1" ]; then
      exit 1
    fi
  fi

  return "$_rc"
}

case "$1" in
  -h|--help)
    show_help
    exit 0
    ;;
esac

if [ -z "$1" ]; then
  show_help
  exit 1
fi

PKG_PATH="$1"
PKG_NAME="${PKG_PATH##*/}"
PKG_BASENAME="${PKG_NAME%.*}"
INSTALL_PATH="/usr/local/bin/$PKG_BASENAME"

REPO="zharfanug/linux-helper"
PKG_URL="https://raw.githubusercontent.com/${REPO}/latest/${PKG_NAME}"

main() {
  require_cmd sudo

  if [ -f "$PKG_PATH" ]; then
    log "Installing $PKG_PATH to $INSTALL_PATH"
    sudo cp "$PKG_PATH" "$INSTALL_PATH"
  else
    log "Downloading $PKG_URL to /tmp/${PKG_NAME}"
    download "$PKG_URL" "/tmp/${PKG_NAME}" 1
    log "Installing /tmp/${PKG_NAME} to $INSTALL_PATH"
    sudo cp "/tmp/${PKG_NAME}" "$INSTALL_PATH"
    rm -f "/tmp/${PKG_NAME}"
  fi

  log "Marking $INSTALL_PATH as executable"
  sudo chmod +x "$INSTALL_PATH"

  log "Done"
}

main "$@"

