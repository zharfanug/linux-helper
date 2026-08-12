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

require_cmd git

SKIP_PROMPT=false

while getopts "y" opt; do
  case "$opt" in
    y)
      SKIP_PROMPT=true
      ;;
    *)
      ;;
  esac
done
shift $((OPTIND - 1))

TAG="$1"
TAG_MESSAGE="$2"

if [ -z "$TAG" ]; then
  log_error "Missing required argument: TAG"
  log_error "Usage: $SCRIPT_NAME [-y] TAG [MESSAGE]"
  exit 1
fi

confirm_tag() {
  if [ "$SKIP_PROMPT" = "true" ]; then
    return 0
  fi

  printf "Create tag '%s'? (Y/n): " "$TAG"
  read -r answer

  case "$answer" in
    n|N)
      log "Operation cancelled"
      exit 0
      ;;
    *)
      ;;
  esac
}

create_tag() {
  git tag -d "$TAG" >/dev/null 2>&1 || true

  if [ -n "$TAG_MESSAGE" ]; then
    log "Creating annotated tag '$TAG'"
    git tag -a "$TAG" -m "$TAG_MESSAGE"
  else
    log "Creating tag '$TAG'"
    git tag "$TAG"
  fi
}

push_remote() {
  if ! git remote get-url origin >/dev/null 2>&1; then
    log "No origin remote found, skipping push"
    return
  fi

  log "Checking origin remote access"

  if ! git ls-remote origin >/dev/null 2>&1; then
    log_warn "Origin remote is not accessible"
    log_warn "Fix credentials or remote access, then push manually:"
    log_warn "git push --force origin $TAG"
    return
  fi

  log "Pushing tag '$TAG' to origin"

  if ! git push --force origin "$TAG"; then
    log_warn "Push failed"
    log_warn "Fix credentials or remote access, then run:"
    log_warn "git push --force origin $TAG"
  fi
}

main() {
  confirm_tag
  create_tag
  push_remote

  log "Done"
}

main "$@"
