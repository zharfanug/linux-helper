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
Usage: $SCRIPT_NAME -a NAME -f LOG_PATH [-z ARCHIVE_DIR] [-r DAYS] [-co LEVEL] [-y]
       $SCRIPT_NAME -l
       $SCRIPT_NAME -rm NAME
       $SCRIPT_NAME -x NAME
       $SCRIPT_NAME -h

Create and manage /etc/logrotate.d configs that rotate a log daily and
archive each rotated copy as a dated gzip file. Relies on logrotate's own
daily trigger (/etc/cron.daily/logrotate) -- this does not install any
cron job or systemd unit of its own.

Arguments:
  NAME       Identifier for the config; also its filename under
             /etc/logrotate.d. Allowed characters: A-Z a-z 0-9 _ -
  LOG_PATH   Absolute path to the log file to rotate. May be a glob
             (e.g. /var/log/app/*.log), same as logrotate itself accepts.
             Glob paths cannot contain spaces. Quote it (e.g.
             -f '/var/log/app/*.log') so your shell passes the glob
             through as-is instead of expanding it itself -- otherwise
             rotateit only ever sees whichever files exist right now,
             and any extra matched files get misread as stray options.

Options:
  -z ARCHIVE_DIR  Archive directory. Default: <dirname of LOG_PATH>/archives
  -r DAYS         Delete archives older than DAYS. Default: keep forever
  -co LEVEL       gzip compression level, 1-9. Default: 9
  -y              Skip the overwrite confirmation prompt
  -l              List rotateit-managed configs
  -rm NAME        Remove a rotateit-managed config
  -x NAME         Dry run: logrotate -d against the config
  -h, --help      Show this help message

Archives are stored as: ARCHIVE_DIR/YYYY/MM/DD-<log filename>.gz

Examples:
  $SCRIPT_NAME -a myapp -f /var/log/myapp/myapp.log
  $SCRIPT_NAME -a myapp -f '/var/log/myapp/*.log' -r 30 -co 6
  $SCRIPT_NAME -l
  $SCRIPT_NAME -x myapp
  $SCRIPT_NAME -rm myapp
EOF
}

validate_name() {
  case "$NAME" in
    *[!A-Za-z0-9_-]*)
      log_error "Invalid NAME (only letters, digits, '_', '-' allowed): $NAME"
      exit 1
      ;;
  esac
}

if [ $# -eq 0 ]; then
  show_help
  exit 1
fi

case "$1" in
  -h|--help)
    show_help
    exit 0
    ;;
esac

MODE=""
NAME=""
LOG_PATH=""
ARCHIVE_DIR_OPT=""
RETENTION_DAYS=""
COMPRESS_LEVEL_OPT=""
ASSUME_YES=false

case "$1" in
  -a)
    MODE=add
    NAME=$2
    [ -n "$NAME" ] || { show_help; exit 1; }
    validate_name
    shift 2

    while [ $# -gt 0 ]; do
      case "$1" in
        -f)
          LOG_PATH=$2
          shift 2
          ;;
        -z)
          ARCHIVE_DIR_OPT=$2
          shift 2
          ;;
        -r)
          RETENTION_DAYS=$2
          shift 2
          ;;
        -co)
          COMPRESS_LEVEL_OPT=$2
          shift 2
          ;;
        -y)
          ASSUME_YES=true
          shift
          ;;
        *)
          case "$1" in
            -*)
              log_error "Unknown option: $1"
              ;;
            *)
              log_error "Unexpected argument: $1"
              log_error "If this came from -f, your shell likely expanded an unquoted glob before rotateit saw it. Quote it: -f '/path/*.log'"
              ;;
          esac
          show_help
          exit 1
          ;;
      esac
    done

    if [ -z "$LOG_PATH" ]; then
      log_error "-f <log path> is required"
      show_help
      exit 1
    fi
    ;;
  -l)
    MODE=list
    ;;
  -rm)
    MODE=remove
    NAME=$2
    [ -n "$NAME" ] || { show_help; exit 1; }
    validate_name
    ;;
  -x)
    MODE=dryrun
    NAME=$2
    [ -n "$NAME" ] || { show_help; exit 1; }
    validate_name
    ;;
  *)
    show_help
    exit 1
    ;;
esac

if [ ! -e /etc/cron.daily/logrotate ]; then
  log_warn "/etc/cron.daily/logrotate not found; make sure logrotate is scheduled to run daily some other way"
fi

if [ "$MODE" = "add" ] || [ "$MODE" = "remove" ]; then
  if [ "$(id -u)" -ne 0 ]; then
    log_error "This command must be run as root"
    exit 1
  fi
fi

write_config() {
  {
    cat <<HDR
# Managed by rotateit. Do not edit manually.
# rotateit: retention=${RETENTION_META}

"${LOG_PATH}" {
  daily
  missingok
  compress
  compressoptions -${COMPRESS_LEVEL}
  rotate 1
  create

  lastaction
    _archive_dir="${ARCHIVE_DIR}/\$(date +%Y/%m)"
    mkdir -p "\$_archive_dir"

HDR

    if [ "$HAS_GLOB" = true ]; then
      cat <<BODY
    for _f in ${LOG_PATH}.1.gz; do
      [ -e "\$_f" ] || continue
      _name=\$(basename "\${_f%.1.gz}")
      mv "\$_f" "\${_archive_dir}/\$(date +%d)-\${_name}.gz"
    done
BODY
    else
      cat <<BODY
    _f="${LOG_PATH}.1.gz"
    if [ -e "\$_f" ]; then
      _name=\$(basename "\${_f%.1.gz}")
      mv "\$_f" "\${_archive_dir}/\$(date +%d)-\${_name}.gz"
    fi
BODY
    fi

    if [ -n "$RETENTION_DAYS" ]; then
      cat <<RET

    find "${ARCHIVE_DIR}" -type f -name '*.gz' -mtime +${RETENTION_DAYS} -delete
RET
    fi

    cat <<FTR
    find "${ARCHIVE_DIR}" -mindepth 1 -type d -empty -delete
  endscript
}
FTR
  } >"$CONF"
}

do_add() {
  case "$LOG_PATH" in
    /*) ;;
    *)
      log_error "LOG_PATH must be an absolute path: $LOG_PATH"
      exit 1
      ;;
  esac

  case "$LOG_PATH" in
    *'"'*)
      log_error "LOG_PATH must not contain a double-quote character: $LOG_PATH"
      exit 1
      ;;
  esac

  case "$LOG_PATH" in
    *[*?[]*) HAS_GLOB=true ;;
    *)       HAS_GLOB=false ;;
  esac

  case "$LOG_PATH" in
    *' '*)
      if [ "$HAS_GLOB" = true ]; then
        log_error "Glob log paths cannot contain spaces: $LOG_PATH"
        exit 1
      fi
      ;;
  esac

  if [ "$HAS_GLOB" = true ]; then
    _found=false
    for _f in $LOG_PATH; do
      [ -e "$_f" ] && _found=true
    done
    if [ "$_found" = false ]; then
      log_error "No files match log path: $LOG_PATH"
      exit 1
    fi
  else
    if [ ! -e "$LOG_PATH" ]; then
      log_error "Log path does not exist: $LOG_PATH"
      exit 1
    fi
  fi

  LOG_DIR=$(dirname "$LOG_PATH")
  ARCHIVE_DIR=${ARCHIVE_DIR_OPT:-${LOG_DIR}/archives}
  COMPRESS_LEVEL=${COMPRESS_LEVEL_OPT:-9}

  case "$COMPRESS_LEVEL" in
    [1-9]) ;;
    *)
      log_error "Invalid compression level (must be 1-9): $COMPRESS_LEVEL"
      exit 1
      ;;
  esac

  RETENTION_META="-"
  if [ -n "$RETENTION_DAYS" ]; then
    case "$RETENTION_DAYS" in
      *[!0-9]*|"")
        log_error "Invalid retention days (must be a positive integer): $RETENTION_DAYS"
        exit 1
        ;;
    esac
    RETENTION_META=$RETENTION_DAYS
  fi

  CONF="/etc/logrotate.d/${NAME}"

  if [ -e "$CONF" ] && [ "$ASSUME_YES" = false ]; then
    if grep -q '^# rotateit: ' "$CONF" 2>/dev/null; then
      printf 'Config %s already exists. Overwrite? [Y/n] ' "$CONF"
    else
      printf 'Config %s already exists (not managed by rotateit). Overwrite? [Y/n] ' "$CONF"
    fi
    read -r _ans
    case "$_ans" in
      ""|[Yy]*) ;;
      *)
        log "Aborted"
        exit 0
        ;;
    esac
  fi

  mkdir -p "$ARCHIVE_DIR"

  write_config

  log "Wrote $CONF"
}

do_list() {
  _tmp=$(mktemp) || exit 1
  trap 'rm -f "$_tmp"' EXIT INT TERM

  for _f in /etc/logrotate.d/*; do
    [ -f "$_f" ] || continue
    grep -q '^# rotateit: ' "$_f" || continue

    _name=$(basename "$_f")
    _path=$(awk '/^[^#[:space:]]/ { sub(/[[:space:]]*\{[[:space:]]*$/, ""); print; exit }' "$_f")
    _path=${_path#\"}
    _path=${_path%\"}
    _retention=$(sed -n 's/^# rotateit: retention=//p' "$_f")
    [ -n "$_retention" ] || _retention="-"

    printf '%s\t%s\t%s\n' "$_name" "$_path" "$_retention"
  done >"$_tmp"

  if [ ! -s "$_tmp" ]; then
    printf 'No rotateit-managed logrotate configs found.\n'
    return
  fi

  {
    printf 'NAME\tPATH\tRETENTION\n'
    cat "$_tmp"
  } | awk -F'\t' '
    {
      n[NR] = $1; p[NR] = $2; r[NR] = $3
      if (length($1) > w1) w1 = length($1)
      if (length($2) > w2) w2 = length($2)
    }
    END {
      for (i = 1; i <= NR; i++) printf "%-*s  %-*s  %s\n", w1, n[i], w2, p[i], r[i]
    }
  '
}

do_remove() {
  CONF="/etc/logrotate.d/${NAME}"

  if [ ! -e "$CONF" ]; then
    log_error "No such config: $CONF"
    exit 1
  fi

  if ! grep -q '^# rotateit: ' "$CONF" 2>/dev/null; then
    log_error "Not managed by rotateit, refusing to remove: $CONF"
    exit 1
  fi

  rm -f "$CONF"
  log "Removed $CONF"
}

do_dryrun() {
  CONF="/etc/logrotate.d/${NAME}"

  if [ ! -e "$CONF" ]; then
    log_error "No such config: $CONF"
    exit 1
  fi

  require_cmd logrotate
  logrotate -d "$CONF"
}

case "$MODE" in
  add)    do_add ;;
  list)   do_list ;;
  remove) do_remove ;;
  dryrun) do_dryrun ;;
esac
