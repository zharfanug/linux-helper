#!/bin/sh
# test-case/rotateit/daily-rotation.sh
#
# End-to-end test of the existing rotateit.sh against real systemd:
#   1. boot a Debian container with systemd as PID 1 (+ logrotate)
#   2. write a dummy log file
#   3. monitor it with rotateit -a
#   4. trigger the daily logrotate.timer
#   5. check the file was rotated and archived
#
# WHY NOT "set clock to 23:59:58":
#   a) the container clock gets snapped back by an external sync within
#      ~0.5s of every `date -s` on this host, so midnight is never reached;
#   b) logrotate's `daily` policy refuses to rotate when the state file's
#      "last rotated" is on the SAME calendar day as "now" ("log has already
#      been rotated") -- a brand-new config always has today's date in the
#      state, so it can never be rotated on the day it was installed, no
#      matter how the clock is fiddled.
# So the test simulates "config was installed yesterday" by pre-seeding the
# state file with yesterday's date, then uses a logrotate.timer drop-in that
# fires every minute. Same machinery end to end (systemd timer -> logrotate
# -> rotateit config -> archive), deterministic and fast.
#
# Run: sh test-case/rotateit/daily-rotation.sh

set -eu

CTR=rotateit-test
IMG=rotateit-test:latest
REPO_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)

command -v docker >/dev/null 2>&1 || { echo "docker not found" >&2; exit 1; }

echo "== 0. build container image (systemd + logrotate) =="
docker build -q -t "$IMG" - <<'DOCKERFILE'
FROM debian:bookworm-slim
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends systemd systemd-sysv logrotate gzip \
 && rm -rf /var/lib/apt/lists/*
CMD ["/sbin/init"]
DOCKERFILE

echo "== 1. start container with systemd as PID 1 =="
docker rm -f "$CTR" >/dev/null 2>&1 || true
docker run -d --name "$CTR" --privileged --cgroupns=host \
  -v "$REPO_DIR":/repo \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  --tmpfs /run --tmpfs /run/lock \
  -e container=docker \
  "$IMG" >/dev/null

echo "== 2. wait for systemd to come up =="
_st=
_i=0
while [ "$_i" -lt 30 ]; do
  _st=$(docker exec "$CTR" systemctl is-system-running 2>/dev/null || true)
  case "$_st" in running|degraded) break ;; esac
  sleep 1
  _i=$((_i + 1))
done
echo "system state: ${_st:-unknown}"

docker exec "$CTR" sh -eu -c '
echo "--- install rotateit ---"
cp /repo/rotateit.sh /usr/local/bin/rotateit
chmod +x /usr/local/bin/rotateit

echo "--- write a dummy log ---"
mkdir -p /var/log/dummyapp
printf "%s\n" "dummy line 1" "dummy line 2" "dummy line 3" > /var/log/dummyapp/app.log

echo "--- monitor it with rotateit ---"
rotateit -a dummyapp -f /var/log/dummyapp/app.log
echo "--- state file after add (brand-new config -> today date) ---"
grep dummyapp /var/lib/logrotate/status 2>/dev/null || echo "(no entry yet)"

echo "--- demonstrate the same-day skip (config installed TODAY) ---"
logrotate -v /etc/logrotate.d/dummyapp 2>&1 | grep -E "Last rotated|does not need" || true

echo "--- simulate it was installed YESTERDAY: pre-seed the state ---"
printf "logrotate state -- version 2\n\"/var/log/dummyapp/app.log\" 2026-8-13-0:0:0\n" > /var/lib/logrotate/status

echo "--- make the daily timer fire every minute ---"
mkdir -p /etc/systemd/system/logrotate.timer.d
cat > /etc/systemd/system/logrotate.timer.d/fast.conf <<"EOF"
[Timer]
OnCalendar=
OnCalendar=*:0/1
EOF
systemctl daemon-reload
systemctl enable --now logrotate.timer >/dev/null 2>&1 || true
systemctl list-timers logrotate --no-pager | head -3
'

echo "== 3. wait for the timer to rotate + archive the dummy log =="
_found=
_i=0
while [ "$_i" -lt 150 ]; do
  _n=$(docker exec "$CTR" sh -c 'find /var/log/dummyapp/archives -type f -name "*.gz" 2>/dev/null | wc -l')
  [ "$_n" -gt 0 ] && { _found=yes; break; }
  sleep 1
  _i=$((_i + 1))
done
echo "waited ${_i}s for the archive to appear"

docker exec "$CTR" sh -eu -c '
echo "--- did the timer run logrotate? ---"
journalctl -u logrotate.service --no-pager -n 6 | tail -6

echo "--- result ---"
ls -la /var/log/dummyapp/
echo "--- archives ---"
find /var/log/dummyapp/archives -type f | sort
echo "--- archive content (should be the 3 dummy lines) ---"
for gz in /var/log/dummyapp/archives/*/*/*.gz; do
  [ -e "$gz" ] && { echo "> $gz"; zcat "$gz"; }
done
echo "--- logrotate state ---"
grep dummyapp /var/lib/logrotate/status || true
'

echo "--- verdict ---"
if [ -n "$_found" ]; then
  echo "PASS: log was rotated and archived by the systemd logrotate.timer"
else
  echo "FAIL: no archive appeared"
  docker exec "$CTR" systemctl list-timers logrotate --no-pager
fi

echo
echo "container '$CTR' left running for inspection."
echo "cleanup: docker rm -f $CTR; docker rmi $IMG"
