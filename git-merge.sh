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

SKIP_PROMPT=false

while getopts "yf" opt; do
  case "$opt" in
    y|f)
      SKIP_PROMPT=true
      ;;
    *)
      ;;
  esac
done
shift $((OPTIND - 1))

COMMIT_MESSAGE="${1:-Initial commit}"

confirm_reset() {
  if [ "$SKIP_PROMPT" = "true" ]; then
    return 0
  fi

  printf "%bWARNING: This operation will delete all git history.%b\n" "$Y" "$C0"
  printf "Continue? (y/N): "
  read -r answer

  case "$answer" in
    y|Y)
      return 0
      ;;
    *)
      log "Operation cancelled"
      exit 0
      ;;
  esac
}

check_git_identity() {
  _name="$(git config user.name)"
  _email="$(git config user.email)"

  if [ -z "$_name" ] || [ -z "$_email" ]; then
    log_error "Git user.name and user.email must be configured before committing"
    log_error "Run: git config --global user.name \"Your Name\""
    log_error "Run: git config --global user.email \"you@example.com\""
    exit 1
  fi
}

init_repo() {
  if [ ! -d ".git" ]; then
    log "Initializing new git repository"
    git init -b main
  else
    confirm_reset

    log "Creating temporary orphan branch"

    git checkout --orphan merge-reset-temp

    log "Removing old tracked files"
    git rm -rf --cached . >/dev/null 2>&1 || true

    log "Removing old branch history"
    git branch -D main >/dev/null 2>&1 || true

    log "Renaming temporary branch to main"
    git branch -M main
  fi

  log "Adding all current files"
  git add -A

  if git diff --cached --quiet; then
    log_warn "Nothing to commit"
    exit 0
  fi

  log "Creating initial commit"
  git commit -m "$COMMIT_MESSAGE"

  git branch -M main
}

tag_latest() {
  log "Tagging latest commit as 'latest'"
  git tag -f latest
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
    log_warn "git push --force origin main"
    log_warn "git push --force origin latest"
    return
  fi

  log "Force pushing new main branch"

  if ! git push --force origin main; then
    log_warn "Push failed"
    log_warn "Fix credentials or remote access, then run:"
    log_warn "git push --force origin main"
  fi

  log "Pushing tag 'latest' to origin"

  if ! git push --force origin latest; then
    log_warn "Push failed"
    log_warn "Fix credentials or remote access, then run:"
    log_warn "git push --force origin latest"
  fi
}

main() {
  check_git_identity
  init_repo
  tag_latest
  push_remote

  log "Done"
}

main "$@"

