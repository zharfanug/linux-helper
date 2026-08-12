#!/bin/sh

show_help() {
  cat <<EOF
Usage: $(basename "$0") [COUNT] [DIRECTORY]

Show disk usage sorted from largest to smallest.

Arguments:
  COUNT       Number of entries to show.
              Default: 10
              0 = show all entries
  DIRECTORY   Directory to inspect (default: current directory)

Options:
  -h, --help  Show this help message

Examples:
  $(basename "$0")
  $(basename "$0") 20
  $(basename "$0") /var/log
  $(basename "$0") 20 /var/log
  $(basename "$0") 0 /
EOF
}

COUNT=10
TARGET="."

case "$1" in
  -h|--help)
    show_help
    exit 0
    ;;
esac

case "$1" in
  "")
    ;;
  *[!0-9]*)
    TARGET=$1
    ;;
  *)
    COUNT=$1
    [ -n "$2" ] && TARGET=$2
    ;;
esac

# Remove trailing slash (except for root)
[ "$TARGET" != "/" ] && TARGET=${TARGET%/}

echo
echo "Disk usage in: $(cd "$TARGET" 2>/dev/null && pwd -P)"
echo "─────────────────────────────────────────"

TMP=$(mktemp) || exit 1
trap 'rm -f "$TMP"' EXIT INT TERM

du -sk "$TARGET"/* "$TARGET"/.[!.]* 2>/dev/null \
  | sort -rn >"$TMP"

awk -v max="$COUNT" '
function human(k) {
  if (k >= 1048576) return sprintf("%.1fG", k / 1048576)
  if (k >= 1024)    return sprintf("%.1fM", k / 1024)
  return sprintf("%dK", k)
}

{
  path = substr($0, index($0, $2))
  gsub("^//+", "/", path)

  if (max == 0) {
    printf "%s\t%s\n", human($1), path
    next
  }

  if ($1 > 0) {
    nz[++n] = human($1) "\t" path
  } else {
    z[++m] = human($1) "\t" path
  }
}

END {
  printed = 0

  for (i = 1; i <= n && printed < max; i++) {
    print nz[i]
    printed++
  }

  for (i = 1; i <= m && printed < max; i++) {
    print z[i]
    printed++
  }
}
' "$TMP" | column -t

echo "─────────────────────────────────────────"
echo "Total: $(du -sh "$TARGET" 2>/dev/null | cut -f1)"
echo