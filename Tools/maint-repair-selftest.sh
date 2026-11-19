#!/bin/bash
# Offline self-test for ntfstool check/repair (the engine behind 检查卷/修复卷).
#
# Creates a disposable sparse file image in a fresh mktemp directory under the
# repo build/ tree (Tools/selftest_workdir.sh); never touches /Volumes,
# /Applications, /dev/disk*, or real USB media.
#
# Contract:
#   1. Fresh format → check exit 0, repair exit 0
#   2. Corrupt alternate boot sector → check exit != 0 (read-only cannot fix);
#      image bytes unchanged by check
#   3. repair exit 0 and reports FIXED
#   4. check exit 0 afterwards; boot signature restored
#   5. DevicePathRules fixtures (canonical key / allowlist)
#
# On failure the workdir is kept as <workdir>.FAILED.
#
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# The binaries under test must be given explicitly; `make maint-repair-test`
# passes the ones it just built for $(BUILD). No implicit rebuild here, so a
# stale build/ copy can never be tested in place of the requested one.
NTFSTOOL="${NTFSTOOL:?set NTFSTOOL to the ntfstool binary under test (use make maint-repair-test)}"
RULES_BIN="${RULES_BIN:?set RULES_BIN to the device_path_rules_test binary (use make maint-repair-test)}"
for b in "$NTFSTOOL" "$RULES_BIN"; do
  [[ -f "$b" && -x "$b" ]] || { echo "FAIL: not an executable file: $b" >&2; exit 1; }
done
EXIT_STATUS=0

die() {
  echo "FAIL: $*" >&2
  EXIT_STATUS=1
  exit 1
}
pass() { echo "PASS: $*"; }

run_ntfstool() {
  # usage: run_ntfstool <expected_exit|any> <cmd...>
  # sets RUN_OUT and RUN_EC
  local expect="$1"; shift
  set +e
  RUN_OUT="$("$NTFSTOOL" "$@" 2>&1)"
  RUN_EC=$?
  set -e
  if [[ "$expect" == "any" ]]; then
    return 0
  fi
  if [[ "$RUN_EC" -ne "$expect" ]]; then
    die "ntfstool $* : expected exit $expect, got $RUN_EC\n$RUN_OUT"
  fi
}

. "$ROOT/Tools/selftest_workdir.sh"
WORKDIR="$(selftest_workdir "$ROOT" maint-repair-selftest)"

cleanup() {
  local ec=${EXIT_STATUS:-$?}
  if [[ "$ec" -ne 0 ]]; then
    local keep="${WORKDIR}.FAILED"
    if [[ -d "$WORKDIR" ]]; then
      if mv "$WORKDIR" "$keep"; then
        echo "Kept failure artifacts at $keep" >&2
      else
        echo "Failed to move workdir; left at $WORKDIR" >&2
      fi
    fi
  else
    rm -rf "$WORKDIR"
  fi
}
trap 'EXIT_STATUS=$?; cleanup' EXIT

# Freshness (J-issue): the binaries come from `make maint-repair-test`, whose
# prerequisites rebuild them when sources change; running this script directly
# requires naming them, so a stale binary is never picked up implicitly.
echo "ntfstool under test: $NTFSTOOL ($(shasum -a 256 < "$NTFSTOOL" | cut -d' ' -f1))"
echo "rules test binary:   $RULES_BIN ($(shasum -a 256 < "$RULES_BIN" | cut -d' ' -f1))"

IMG="$WORKDIR/vol.img"

# --- 0. DevicePathRules via compiled Shared/DevicePathRules.swift ---
"$RULES_BIN" || die "DevicePathRules Swift self-check failed"
pass "DevicePathRules (compiled Shared implementation)"

# --- 1. clean volume ---
mkfile -n 64m "$IMG"
"$NTFSTOOL" "$IMG" format "RepairSelftest" >/dev/null
run_ntfstool 0 "$IMG" check
echo "$RUN_OUT" | grep -qx 'check: 0' || echo "$RUN_OUT" | grep -q $'check: 0\n\|check: 0$' \
  || die "clean check missing exact status line:\n$RUN_OUT"
# Prefer last line / explicit token
echo "$RUN_OUT" | grep -E '(^|[^0-9])check: 0([^0-9]|$)' >/dev/null \
  || die "clean check:0 not found:\n$RUN_OUT"
pass "clean check exit 0"

# ntfsfix may still touch journal/flags on a clean volume; only require exit 0.
run_ntfstool 0 "$IMG" repair
echo "$RUN_OUT" | grep -E '(^|[^0-9])repair: 0([^0-9]|$)' >/dev/null \
  || die "clean repair:0 not found:\n$RUN_OUT"
pass "clean repair exit 0"

# --- 2. corrupt alternate boot sector (last 2 bytes = 55 AA) ---
python3 - "$IMG" <<'PY'
import sys
from pathlib import Path
img = Path(sys.argv[1])
data = bytearray(img.read_bytes())
if data[-2:] != bytes([0x55, 0xAA]):
    raise SystemExit(f"expected backup boot signature 55AA, got {data[-2:].hex()}")
data[-2:] = b"\x00\x00"
img.write_bytes(data)
print(f"corrupted backup boot signature at eof-2 of {img}")
PY
CORRUPT_HASH="$(shasum -a 256 "$IMG" | awk '{print $1}')"
run_ntfstool any "$IMG" check
[[ "$RUN_EC" -ne 0 ]] || die "corrupt check should fail, got exit 0:\n$RUN_OUT"
echo "$RUN_OUT" | grep -qi 'alternate boot sector' \
  || die "corrupt check should mention alternate boot sector:\n$RUN_OUT"
CHECK_HASH="$(shasum -a 256 "$IMG" | awk '{print $1}')"
[[ "$CORRUPT_HASH" == "$CHECK_HASH" ]] || die "read-only check mutated image"
pass "corrupt check fails; image unchanged"

# --- 3. repair must fix ---
run_ntfstool 0 "$IMG" repair
echo "$RUN_OUT" | grep -qi 'FIXED\|successfully' \
  || die "repair should report FIXED/success:\n$RUN_OUT"
pass "repair exit 0 and reports fix"

# --- 4. check clean again; signature restored ---
run_ntfstool 0 "$IMG" check
python3 - "$IMG" <<'PY'
import sys
from pathlib import Path
data = Path(sys.argv[1]).read_bytes()
if data[-2:] != bytes([0x55, 0xAA]):
    raise SystemExit(f"backup boot signature not restored: {data[-2:].hex()}")
print("backup boot signature restored 55AA")
PY
pass "post-repair check exit 0; boot signature restored"

echo
echo "ALL PASS: maint-repair-selftest (offline ntfstool check/repair)"
echo "NOTE: Helper lease / FDA / remount paths are not covered here."
