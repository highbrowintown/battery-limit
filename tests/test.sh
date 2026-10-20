#!/usr/bin/env bash
# Tests for bin/battery-limit against a simulated sysfs tree. Needs no root and no hardware.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BIN="$ROOT/bin/battery-limit"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
PASS=0
FAIL=0
CONF_FILE=""

# new_tree START STOP CAPACITY AC_ONLINE
new_tree() {
  rm -rf "$T/ps" "$T/state"
  mkdir -p "$T/ps/BAT0" "$T/ps/AC" "$T/state"
  echo "$1" > "$T/ps/BAT0/charge_control_start_threshold"
  echo "$2" > "$T/ps/BAT0/charge_control_end_threshold"
  echo "$3" > "$T/ps/BAT0/capacity"
  echo "Not charging" > "$T/ps/BAT0/status"
  echo Mains > "$T/ps/AC/type"
  echo "$4" > "$T/ps/AC/online"
  : > "$T/empty.conf"
  CONF_FILE=""
}

bl() {
  PS_ROOT="$T/ps" BATTERY_LIMIT_STATE="$T/state" \
    BATTERY_LIMIT_CONF="${CONF_FILE:-$T/empty.conf}" "$BIN" "$@"
}

thresholds() {
  echo "$(cat "$T/ps/BAT0/charge_control_start_threshold")/$(cat "$T/ps/BAT0/charge_control_end_threshold")"
}

check() { # name expected actual
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1)); echo "ok   $1"
  else
    FAIL=$((FAIL + 1)); echo "FAIL $1: expected '$2', got '$3'"
  fi
}

flag() { [ -e "$T/state/full-once" ] && echo yes || echo no; }

new_tree 0 63 50 1
bl auto; check "stuck at 63 moves to daily profile" 75/80 "$(thresholds)"
bl auto; check "second auto is idempotent" 75/80 "$(thresholds)"

new_tree 75 80 50 1
bl full; check "full on AC sets 0/100" 0/100 "$(thresholds)"
check "full creates the flag" yes "$(flag)"
echo 0 > "$T/ps/AC/online"; echo 60 > "$T/ps/BAT0/capacity"
bl auto; check "early unplug keeps 0/100" 0/100 "$(thresholds)"
check "early unplug keeps the flag" yes "$(flag)"
echo 100 > "$T/ps/BAT0/capacity"
bl auto; check "unplug at 100 reverts to daily" 75/80 "$(thresholds)"
check "revert removes the flag" no "$(flag)"

new_tree 75 80 90 1
bl full; bl daily
check "daily cancels a pending full charge" 75/80 "$(thresholds)"
check "daily removes the flag" no "$(flag)"

new_tree 0 100 50 1
printf 'DAILY_START=40\nDAILY_STOP=80\n' > "$T/custom.conf"
CONF_FILE="$T/custom.conf"
bl auto; check "custom config is applied" 40/80 "$(thresholds)"

new_tree 0 100 50 1
printf 'DAILY_START=90\nDAILY_STOP=80\n' > "$T/bad.conf"
CONF_FILE="$T/bad.conf"
bl auto >/dev/null 2>&1; rc=$?
check "invalid config exits non-zero" 1 "$rc"
check "invalid config writes nothing" 0/100 "$(thresholds)"

new_tree 90 95 50 1
bl auto; check "lowering a high window" 75/80 "$(thresholds)"

new_tree 0 50 50 1
bl auto; check "raising stop above the new start" 75/80 "$(thresholds)"

new_tree 0 63 50 1
rm "$T/ps/BAT0/charge_control_start_threshold"
bl auto
check "missing start file: stop is written" 80 "$(cat "$T/ps/BAT0/charge_control_end_threshold")"
check "missing start file: none is created" no "$([ -e "$T/ps/BAT0/charge_control_start_threshold" ] && echo yes || echo no)"

new_tree 75 80 50 1
rm -rf "$T/ps/BAT0"
bl auto >/dev/null 2>&1; rc=$?
check "no battery exits non-zero" 1 "$rc"

new_tree 75 80 50 1
out=$(bl status)
check "status reports thresholds" yes "$(grep -q 'start=75 stop=80' <<<"$out" && echo yes || echo no)"

bl bogus >/dev/null 2>&1; rc=$?
check "unknown command exits non-zero" 1 "$rc"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" = 0 ]
