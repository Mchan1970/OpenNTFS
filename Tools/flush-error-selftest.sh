#!/bin/bash
# C-layer regression test for write-flush error reporting: device
# write and read fault injection, cases T1-T9 plus T7b of
# Tools/ntfstool.c flushtest.
#
# The cases encode the target behaviour: sticky flush errors, an owned
# two-step flush, call points that stop on the first failure. T6
# injects its one-shot fault into the file's MFT record, so the trim
# itself succeeds and the record write fails as a retryable error; a
# fault during the trim itself (T8, $Bitmap) fails the volume closed.
#
# Two binaries from make flush-error-test:
#   NTFSTOOL_ASAN - the ASan build running the cases (guards against
#                   use-after-free; macOS has no LeakSanitizer)
#   NTFSTOOL     - the uninstrumented build/ntfstool, used only for the
#                   leak checks of T2 and T8 under `leaks --atExit`
#                   (the ASan runtime and leaks do not mix)
#
# Disposable sparse images in a fresh mktemp directory under build/
# (Tools/selftest_workdir.sh), deleted after the run; never touches
# /Volumes, /Applications, /dev/disk*, or real media.
#
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NTFSTOOL_ASAN="${NTFSTOOL_ASAN:?set NTFSTOOL_ASAN to the ASan ntfstool binary (use make flush-error-test)}"
NTFSTOOL="${NTFSTOOL:?set NTFSTOOL to the uninstrumented ntfstool binary (use make flush-error-test)}"
for b in "$NTFSTOOL_ASAN" "$NTFSTOOL"; do
  [[ -f "$b" && -x "$b" ]] || { echo "FAIL: not an executable file: $b" >&2; exit 1; }
done

. "$ROOT/Tools/selftest_workdir.sh"
WORKDIR="$(selftest_workdir "$ROOT" flush-error-selftest)" || { echo "FAIL: cannot create workdir" >&2; exit 1; }

# The images are disposable: always deleted after use, also on failure
# (the failed assertions are printed into the log, no artifacts needed).
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

echo "ntfstool under test (ASan): $NTFSTOOL_ASAN"
echo "  sha256: $(shasum -a 256 < "$NTFSTOOL_ASAN" | cut -d' ' -f1)"
echo "ntfstool under test (leaks): $NTFSTOOL"
echo "  sha256: $(shasum -a 256 < "$NTFSTOOL" | cut -d' ' -f1)"

IMG="$WORKDIR/vol.img"
FAILED=0
CASE_OUT=""

fresh_image() { # <size>
  rm -f "$IMG"
  mkfile -n "$1" "$IMG" || { echo "FAIL: mkfile $1" >&2; exit 1; }
  ASAN_OPTIONS=detect_leaks=0 "$NTFSTOOL_ASAN" "$IMG" format FlushErr >/dev/null \
    || { echo "FAIL: format" >&2; exit 1; }
}

# run_case <t1..t6> <image-size>: fresh image, then one flushtest process
# under ASan. A case passes only when it exits 0 AND the output carries no
# AddressSanitizer report.
run_case() {
  local cname="$1" size="$2" out ec asan
  fresh_image "$size"
  set +e
  out="$("$NTFSTOOL_ASAN" "$IMG" flushtest "$cname" 2>&1)"
  ec=$?
  set -e
  echo
  echo "=== case $cname (exit $ec) ==="
  printf '%s\n' "$out"
  if printf '%s\n' "$out" | grep -q 'AddressSanitizer'; then
    asan=1
    echo "  -> $cname: sanitizer report detected"
  else
    asan=0
  fi
  if [[ $ec -eq 0 && $asan -eq 0 ]]; then
    echo "  -> $cname: PASS"
  else
    echo "  -> $cname: FAIL (exit $ec, sanitizer $asan)"
    FAILED=$((FAILED + 1))
  fi
  CASE_OUT="$out"
}

# Leak checks: macOS has no LeakSanitizer, so the
# cases are run once more with the uninstrumented binary under
# leaks --atExit. A leak check only passes when the wrapped case itself
# passes ALL of its assertions AND the leak summary reports zero.
run_leaks_check() { # <case> <image-size>
  local cname="$1" size="$2" out ec nleaks passed total
  fresh_image "$size"
  set +e
  out="$(leaks --atExit -- "$NTFSTOOL" "$IMG" flushtest "$cname" 2>&1)"
  ec=$?
  set -e
  echo
  echo "=== $cname leaks check, uninstrumented binary (leaks exit $ec) ==="
  printf '%s\n' "$out" | grep -E '^FAIL: |assertions passed' || true
  nleaks="$(printf '%s\n' "$out" | sed -n 's/^Process [0-9][0-9]*: \([0-9][0-9]*\) leaks for .*/\1/p' | tail -1)"
  passed="$(printf '%s\n' "$out" | sed -n 's/^\[[a-z0-9]*\] \([0-9][0-9]*\)\/\([0-9][0-9]*\) assertions passed$/\1/p' | tail -1)"
  total="$(printf '%s\n' "$out" | sed -n 's/^\[[a-z0-9]*\] \([0-9][0-9]*\)\/\([0-9][0-9]*\) assertions passed$/\2/p' | tail -1)"
  if [[ $ec -ne 0 ]]; then
    # leaks exits 0 only when it found no leaks AND the wrapped case
    # exited 0 itself (verified: 0 / 1 / 255 for none / leaks / child
    # failure)
    echo "  -> $cname leaks: FAIL (leaks exit $ec)"
    FAILED=$((FAILED + 1))
  elif [[ -z "$nleaks" ]]; then
    echo "  -> $cname leaks: FAIL (no leak summary line in the leaks output)"
    FAILED=$((FAILED + 1))
  elif [[ "$nleaks" != "0" ]]; then
    echo "  -> $cname leaks: FAIL ($nleaks leaks)"
    FAILED=$((FAILED + 1))
  elif [[ -z "$passed" || -z "$total" || "$passed" != "$total" ]]; then
    echo "  -> $cname leaks: FAIL (the wrapped case did not pass its assertions: ${passed:-none}/${total:-none})"
    FAILED=$((FAILED + 1))
  else
    echo "  -> $cname leaks: PASS (0 leaks, $passed/$total assertions)"
  fi
}

run_case t1 64m

# Independent cross-check of the target range: mftoff resolves the file
# again and recomputes the record range from the boot sector. It must
# match the range flushtest armed (computed from the ino at creation).
mft_range="$(printf '%s\n' "$CASE_OUT" | sed -n 's/.*target ino [0-9]* mft_record \([0-9]*\.\.[0-9]*\)$/\1/p')"
set +e
mout="$(ASAN_OPTIONS=detect_leaks=0 "$NTFSTOOL_ASAN" "$IMG" mftoff /a.bin 2>&1)"
mec=$?
set -e
off_range="$(printf '%s\n' "$mout" | sed -n 's/.*mft_record \([0-9]*\.\.[0-9]*\)$/\1/p')"
echo
echo "=== t1 mftoff cross-check (exit $mec) ==="
echo "$mout"
if [[ -n "$off_range" && "$mft_range" == "$off_range" ]]; then
  echo "  -> mftoff cross-check: PASS ($off_range)"
else
  echo "  -> mftoff cross-check: FAIL (flushtest '$mft_range' vs mftoff '$off_range')"
  FAILED=$((FAILED + 1))
fi

run_case t2 64m
run_leaks_check t2 64m
run_case t3 64m
run_case t4 64m
run_case t5 64m
run_case t6 256m
run_case t7 64m
run_case t7b 64m
run_case t8 256m
run_leaks_check t8 256m
run_case t9 64m

echo
if [[ $FAILED -ne 0 ]]; then
  echo "FAILED: $FAILED case(s) or check(s); see the FAIL lines above"
  exit 1
fi
echo "ALL PASS: flush-error-selftest (T1-T9)"
