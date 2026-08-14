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
Usage: $SCRIPT_NAME -x [-i INTERVAL] [-f PATH] [-t THRESHOLD]
       $SCRIPT_NAME -a NAME [-i INTERVAL] [-f PATH] [-t THRESHOLD]
       $SCRIPT_NAME -rm NAME
       $SCRIPT_NAME -l
       $SCRIPT_NAME -h

Check disk usage of a path on a repeating interval and warn when it
crosses a threshold. Installs systemd services per monitored path.

Modes:
  -x                Run the monitor loop in the foreground (Ctrl-C to stop).
                    This is exactly what an installed service runs, so it
                    doubles as a dry run of a service.
  -a NAME           Install a systemd service diskmon@NAME that runs the
                    monitor every INTERVAL.
  -rm NAME          Remove a diskmon service and its config.
  -l                List installed diskmon instances.
  -h, --help        Show this help message
  (no args)         Show current disk usage of PATH once (info)

Options:
  -i INTERVAL       Check every INTERVAL. A number with an optional suffix:
                    s (seconds), m (minutes), h (hours), d (days).
                    Default: 1h
  -f PATH           Path to check. Default: /
  -t THRESHOLD      Warn when usage reaches THRESHOLD percent, 1-100.
                    Default: 85

Examples:
  $SCRIPT_NAME
  $SCRIPT_NAME -x
  $SCRIPT_NAME -x -i 5m -f /var -t 80
  $SCRIPT_NAME -a var -i 5m -f /var -t 80
  $SCRIPT_NAME -l
  $SCRIPT_NAME -rm var
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

to_seconds() {
  _v=$1
  _num=${_v%[smhd]}

  case "$_num" in
    *[!0-9]*|"")
      log_error "Invalid interval: $_v"
      exit 1
      ;;
  esac

  case "$_v" in
    "$_num" | "${_num}s") echo "$_num" ;;
    "${_num}m")           echo $((_num * 60)) ;;
    "${_num}h")           echo $((_num * 3600)) ;;
    "${_num}d")           echo $((_num * 86400)) ;;
    *)
      log_error "Invalid interval: $_v"
      exit 1
      ;;
  esac
}

check_once() {
  _pct=$(df -P "$FS_PATH" | awk 'NR==2 { gsub("%", "", $5); print $5 }')
  if [ "$_pct" -ge "$THRESHOLD" ]; then
    log_warn "$FS_PATH: ${_pct}% used (threshold ${THRESHOLD}%)"
  else
    log "$FS_PATH: ${_pct}% used (threshold ${THRESHOLD}%)"
  fi
}

parse_options() {
  INTERVAL=${INTERVAL:-1h}
  FS_PATH=${FS_PATH:-/}
  THRESHOLD=${THRESHOLD:-85}

  while [ $# -gt 0 ]; do
    case "$1" in
      -i)
        INTERVAL=$2
        shift 2
        ;;
      -f)
        FS_PATH=$2
        shift 2
        ;;
      -t)
        THRESHOLD=$2
        shift 2
        ;;
      *)
        log_error "Unknown option: $1"
        show_help
        exit 1
        ;;
    esac
  done

  if [ ! -e "$FS_PATH" ]; then
    log_error "Path does not exist: $FS_PATH"
    exit 1
  fi

  case "$FS_PATH" in
    *[!A-Za-z0-9/_.,:@+=~-]*)
      log_error "Path contains characters unsafe for a generated systemd unit (no spaces, quotes, or \$ % ; \\): $FS_PATH"
      exit 1
      ;;
  esac

  case "$THRESHOLD" in
    *[!0-9]*|"")
      log_error "Invalid threshold (must be an integer): $THRESHOLD"
      exit 1
      ;;
  esac
  if [ "$THRESHOLD" -lt 1 ] || [ "$THRESHOLD" -gt 100 ]; then
    log_error "Invalid threshold (must be 1-100): $THRESHOLD"
    exit 1
  fi

  INTERVAL_SECS=$(to_seconds "$INTERVAL") || exit 1
  if [ "$INTERVAL_SECS" -lt 1 ]; then
    log_error "Invalid interval (must be at least 1 second): $INTERVAL"
    exit 1
  fi
}

do_exec() {
  while true; do
    check_once
    sleep "$INTERVAL_SECS"
  done
}

do_add() {
  [ -n "$NAME" ] || { show_help; exit 1; }
  validate_name
  parse_options "$@"

  RECORD_DIR=/etc/diskmon
  UNIT_DIR=/etc/systemd/system
  RECORD_FILE="${RECORD_DIR}/${NAME}"
  UNIT_FILE="${UNIT_DIR}/diskmon@${NAME}.service"

  mkdir -p "$RECORD_DIR"

  cat >"$RECORD_FILE" <<EOF
# Managed by diskmon. Do not edit manually.
# diskmon: path=$FS_PATH threshold=$THRESHOLD interval=$INTERVAL
EOF

  cat >"$UNIT_FILE" <<EOF
[Unit]
Description=diskmon disk space monitor ($NAME): $FS_PATH @ $THRESHOLD% every $INTERVAL
After=local-fs.target

[Service]
Type=simple
ExecStart=${SCRIPT_DIR}/${SCRIPT_NAME} -x -i ${INTERVAL} -f ${FS_PATH} -t ${THRESHOLD}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now "diskmon@${NAME}.service"
  systemctl restart "diskmon@${NAME}.service"
  log "Installed diskmon service diskmon@${NAME}"
}

do_list() {
  _tmp=$(mktemp) || exit 1
  trap 'rm -f "$_tmp"' EXIT INT TERM

  for _f in /etc/diskmon/*; do
    [ -f "$_f" ] || continue
    grep -q '^# diskmon: ' "$_f" || continue

    _name=$(basename "$_f")
    _meta=$(sed -n 's/^# diskmon: //p' "$_f")
    _path=$(echo "$_meta" | sed -n 's/.*path=\([^ ]*\).*/\1/p')
    _threshold=$(echo "$_meta" | sed -n 's/.*threshold=\([^ ]*\).*/\1/p')
    _interval=$(echo "$_meta" | sed -n 's/.*interval=\([^ ]*\).*/\1/p')

    [ -n "$_path" ] || _path="-"
    [ -n "$_threshold" ] || _threshold="-"
    [ -n "$_interval" ] || _interval="-"

    printf '%s\t%s\t%s\t%s\n' "$_name" "$_path" "$_threshold" "$_interval"
  done >"$_tmp"

  if [ ! -s "$_tmp" ]; then
    printf 'No diskmon-managed instances found.\n'
    return
  fi

  {
    printf 'NAME\tPATH\tTHRESHOLD\tINTERVAL\n'
    cat "$_tmp"
  } | awk -F'\t' '
    {
      n[NR] = $1; p[NR] = $2; t[NR] = $3; i[NR] = $4
      if (length($1) > w1) w1 = length($1)
      if (length($2) > w2) w2 = length($2)
      if (length($3) > w3) w3 = length($3)
    }
    END {
      for (r = 1; r <= NR; r++) printf "%-*s  %-*s  %-*s  %s\n", w1, n[r], w2, p[r], w3, t[r], i[r]
    }
  '
}

do_remove() {
  [ -n "$NAME" ] || { show_help; exit 1; }
  validate_name

  RECORD_DIR=/etc/diskmon
  UNIT_DIR=/etc/systemd/system
  RECORD_FILE="${RECORD_DIR}/${NAME}"
  UNIT_FILE="${UNIT_DIR}/diskmon@${NAME}.service"

  if [ ! -e "$RECORD_FILE" ]; then
    log_error "No such diskmon instance: $RECORD_FILE"
    exit 1
  fi

  if ! grep -q '^# diskmon: ' "$RECORD_FILE" 2>/dev/null; then
    log_error "Not managed by diskmon, refusing to remove: $RECORD_FILE"
    exit 1
  fi

  systemctl stop "diskmon@${NAME}.service" >/dev/null 2>&1 || true
  systemctl disable "diskmon@${NAME}.service" >/dev/null 2>&1 || true
  rm -f "$UNIT_FILE"
  rm -f "$RECORD_FILE"
  systemctl daemon-reload
  log "Removed diskmon service diskmon@${NAME}"
}

if [ $# -eq 0 ]; then
  INTERVAL=1h
  FS_PATH=/
  THRESHOLD=85
  check_once
  exit 0
fi

case "$1" in
  -h|--help)
    show_help
    exit 0
    ;;
  -x)
    shift
    parse_options "$@"
    do_exec
    ;;
  -a)
    shift
    if [ "$(id -u)" -ne 0 ]; then
      log_error "This command must be run as root"
      exit 1
    fi
    require_cmd systemctl
    NAME=$1
    shift
    do_add "$@"
    ;;
  -rm)
    shift
    if [ "$(id -u)" -ne 0 ]; then
      log_error "This command must be run as root"
      exit 1
    fi
    require_cmd systemctl
    NAME=$1
    shift
    do_remove "$@"
    ;;
  -l)
    do_list
    ;;
  *)
    show_help
    exit 1
    ;;
esac
