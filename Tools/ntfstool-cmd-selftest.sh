#!/bin/bash
# Offline self-test: ntfstool must reject an unknown command BEFORE opening
# the image, so a stale caller (e.g. a removed `extents` command) can never
# turn into a read-write open + mount of a disk it was not meant to write.
#
# Contract:
#   1. unknown command on a writable image  -> exit 64, "unknown command",
#      image bytes unchanged
#   2. unknown command on a read-only (0444) image -> exit 64 (not an open
#      error), i.e. no O_RDWR open was attempted
#   3. read-only command `info` on the 0444 image -> exit 0 (opens O_RDONLY)
#   4. write command `mkdir` on the 0444 image -> open fails (exit 1),
#      i.e. write commands still open read-write
#
# Uses a disposable sparse image in a fresh mktemp directory under build/
# (Tools/selftest_workdir.sh). NTFSTOOL (required) is the binary under test;
# its sha256 is printed. On failure the workdir is kept as <workdir>.FAILED.
#
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAILS=0
# The binary under test must be given explicitly (make ntfstool-cmd-test
# passes the one it just built); no implicit rebuild here.
NTFSTOOL="${NTFSTOOL:?set NTFSTOOL to the ntfstool binary under test}"
[[ -x "$NTFSTOOL" && -f "$NTFSTOOL" ]] || { echo "FAIL: not an executable file: $NTFSTOOL"; exit 1; }

. "$ROOT/Tools/selftest_workdir.sh"
WORKDIR="$(selftest_workdir "$ROOT" ntfstool-cmd-selftest)"
cleanup() {
  local ec=$?
  if [[ $ec -ne 0 || $FAILS -ne 0 ]]; then
    local keep="${WORKDIR}.FAILED"
    chmod u+w "$WORKDIR"/* 2>/dev/null || true   # restore so the scene can be inspected/moved
    mv "$WORKDIR" "$keep" && echo "Kept failure artifacts at $keep" >&2
  else
    chmod u+w "$WORKDIR"/vol.img
    rm -rf "$WORKDIR"
  fi
}
trap cleanup EXIT

echo "ntfstool under test: $NTFSTOOL"
echo "  sha256: $(shasum -a 256 < "$NTFSTOOL" | cut -d' ' -f1)"

expect() { # label expected_exit actual_exit
  if [[ "$2" == "$3" ]]; then echo "PASS: $1 (exit $3)"; else echo "FAIL: $1: expected exit $2, got $3"; FAILS=$((FAILS+1)); fi; }

IMG="$WORKDIR/vol.img"
mkfile -n 64m "$IMG"
"$NTFSTOOL" "$IMG" format CmdSelftest >/dev/null
H0=$(shasum -a 256 "$IMG" | cut -d' ' -f1)

# 1. unknown command, writable image
set +e; out=$("$NTFSTOOL" "$IMG" extents /nothing 2>&1); ec=$?; set -e
echo "  output: $out"
expect "unknown command on writable image" 64 "$ec"
if grep -q 'unknown command' <<<"$out"; then echo "PASS: reports unknown command"; else echo "FAIL: no 'unknown command' message"; FAILS=$((FAILS+1)); fi
H1=$(shasum -a 256 "$IMG" | cut -d' ' -f1)
if [[ "$H0" == "$H1" ]]; then echo "PASS: image bytes unchanged"; else echo "FAIL: image bytes changed ($H0 -> $H1)"; FAILS=$((FAILS+1)); fi

# 2-4. read-only image
chmod 0444 "$IMG"
set +e; out=$("$NTFSTOOL" "$IMG" extents /nothing 2>&1); ec=$?; set -e
echo "  output: $out"
expect "unknown command on 0444 image (no read-write open attempted)" 64 "$ec"
set +e; "$NTFSTOOL" "$IMG" info >/dev/null 2>&1; ec=$?; set -e
expect "read-only command info on 0444 image" 0 "$ec"
set +e; out=$("$NTFSTOOL" "$IMG" mkdir /d 2>&1); ec=$?; set -e
echo "  output: $out"
expect "write command mkdir on 0444 image fails to open" 1 "$ec"
if grep -q 'Permission denied' <<<"$out"; then echo "PASS: mkdir failure is the read-write open (Permission denied)"
else echo "FAIL: mkdir did not fail with Permission denied"; FAILS=$((FAILS+1)); fi

if [[ $FAILS -ne 0 ]]; then echo "FAILED: $FAILS check(s)"; exit 1; fi
echo "ALL PASS: ntfstool-cmd-selftest"
