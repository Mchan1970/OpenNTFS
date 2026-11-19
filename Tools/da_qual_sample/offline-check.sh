#!/bin/bash
# Offline checks for da_qual_sample: exercises ONLY the
# offline-fixture mode. No real DA session, device stat, or mount query.
#
# Isolation contract:
# * Every run gets its OWN mktemp directory; an existing directory is never
#   reused. Output files live only there — no fixed /tmp paths.
# * Each tool invocation's REAL exit code is captured and asserted
#   (expected-success / expected-failure / input-error / crash are distinct;
#   a crash rc>128 can never pass via leftover output or "no verdict").
# * The directory is removed only when ALL checks pass; on failure or
#   abnormal exit it is KEPT and its path printed.
#
# SPDX-License-Identifier: GPL-2.0-or-later
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="${ROOT}/build/da_qual_sample"
FIX="${ROOT}/Tools/da_qual_sample/fixtures"
FAIL=0

WORK="$(mktemp -d "${TMPDIR:-/tmp}/daq-offline.XXXXXX")"
[[ -d "$WORK" ]] || { echo "FAIL: no workdir"; exit 1; }
# shellcheck disable=SC2329  # invoked via the EXIT trap below
cleanup() {
  local rc=$?
  if [[ $rc -eq 0 && $FAIL -eq 0 ]]; then
    rm -rf "$WORK"
  else
    echo "SCENE KEPT: $WORK"
  fi
  exit "$rc"
}
trap cleanup EXIT

check() { # check <description> <condition-result>
  if [[ "$2" -eq 0 ]]; then echo "PASS: $1"; else echo "FAIL: $1"; FAIL=1; fi
}
check_rc() { # check_rc <expected-exit> <actual-exit> <description>
  if [[ "$2" -gt 128 || "$2" -lt 0 ]]; then
    echo "FAIL: $3 — tool CRASHED (rc=$2)"; FAIL=1; return
  fi
  if [[ "$2" -eq "$1" ]]; then echo "PASS: $3"; else echo "FAIL: $3 (want rc=$1 got rc=$2)"; FAIL=1; fi
}

# run <fixture> — runs the tool, stores stdout in $WORK/<name>.out, sets RC.
run() {
  local f="$1"; local name; name="$(basename "$f" .json)"
  "$BIN" offline-fixture "$f" > "$WORK/$name.out" 2> "$WORK/$name.err"
  RC=$?
}
# expect_in <file> <ERE> <description>
expect_in() { # expect_in <file> <ERE> <description>
  if grep -qE "$2" "$1"; then check "$3" 0; else check "$3" 1; fi
}

# 1. No-arg invocation must refuse (no implicit device selection).
"$BIN" > "$WORK/usage.out" 2>&1
check_rc 2 $? "no-arg → usage exit 2 (no implicit device selection)"

# 2. Label-keyed unmounted partition NTFS: VolumePath ABSENT, kind present.
run "$FIX/partition_ntfs_unmounted.json"
check_rc 0 $RC "partition_ntfs_unmounted → exit 0"
expect_in "$WORK/partition_ntfs_unmounted.out" $'^VolumePath\tabsent\t-$' "unmounted → VolumePath absent"
expect_in "$WORK/partition_ntfs_unmounted.out" $'^VolumeKind\tpresent\tntfs$' "VolumeKind present ntfs"
expect_in "$WORK/partition_ntfs_unmounted.out" $'^MediaLeaf\tpresent\ttrue$' "MediaLeaf present true"
expect_in "$WORK/partition_ntfs_unmounted.out" $'^MediaWhole\tpresent\tfalse$' "MediaWhole present false"
expect_in "$WORK/partition_ntfs_unmounted.out" $'^description-adapt=ok$' "description-adapt=ok reported"

# 3. Mounted variant: VolumePath present with the path (contrast case).
run "$FIX/partition_ntfs_mounted.json"
check_rc 0 $RC "partition_ntfs_mounted → exit 0"
expect_in "$WORK/partition_ntfs_mounted.out" $'^VolumePath\tpresent\t/Volumes/EXAMPLE$' "mounted → VolumePath present path"

# 4. Whole-disk variant: MediaWhole true (raw fact, no verdict implied).
run "$FIX/wholedisk_ntfs.json"
check_rc 0 $RC "wholedisk_ntfs → exit 0"
expect_in "$WORK/wholedisk_ntfs.out" $'^MediaWhole\tpresent\ttrue$' "whole-disk → MediaWhole true"

# 5. Missing keys report absent, never fabricated defaults.
run "$FIX/missing_keys.json"
check_rc 0 $RC "missing_keys → exit 0"
expect_in "$WORK/missing_keys.out" $'^VolumeKind\tabsent\t-$' "missing VolumeKind → absent"
expect_in "$WORK/missing_keys.out" $'^MediaBSDMajor\tabsent\t-$' "missing number key → absent"

# 6. Wrong types report the OBSERVED CF type, never coerced values; one bad
# field must not sink the whole description (adapt still succeeds).
run "$FIX/wrong_types.json"
check_rc 0 $RC "wrong_types → exit 0 (per-field, not whole-description failure)"
expect_in "$WORK/wrong_types.out" '^description-adapt=ok$' "wrong-typed FIELD keeps the description adaptable"
expect_in "$WORK/wrong_types.out" $'^VolumeKind\twrongType\texpected CFString, got .*Boolean' "bool-as-VolumeKind → wrongType(Boolean)"
expect_in "$WORK/wrong_types.out" $'^MediaLeaf\twrongType\texpected CFBoolean, got .*String' "string-as-MediaLeaf → wrongType(String)"
expect_in "$WORK/wrong_types.out" $'^MediaBSDMajor\twrongType\texpected CFNumber, got .*String' "string-as-number → wrongType(String)"
expect_in "$WORK/wrong_types.out" $'^VolumePath\twrongType\texpected CFURL, got .*String' "string-as-URL → wrongType(String)"

# 7. Description-layer failure: distinct status lines + exit 4.
run "$FIX/description_missing.json"
check_rc 4 $RC "description missing → exit 4"
expect_in "$WORK/description_missing.out" '^description=missing' "description=missing line"
expect_in "$WORK/description_missing.out" '^session=ok' "session layer still ok (distinguishable)"

# 8. ADAPT failure: the fixture names a REAL non-adaptable CF OBJECT (a
# CFDictionary with a CFNumber key / a non-dictionary object); the shared
# adaptDescription() produces the failure — NOT a fixture switch printing a
# canned result. Distinct from query failure and from field absence.
run "$FIX/adapt_fail_nonstringkey.json"
check_rc 5 $RC "adapt: non-string-key dictionary → exit 5 (shared adaptation rejects it)"
expect_in "$WORK/adapt_fail_nonstringkey.out" '^description-adapt=failed' "description-adapt=failed line (non-string-key)"
run "$FIX/adapt_fail_nondict.json"
check_rc 5 $RC "adapt: non-dictionary object → exit 5 (shared adaptation rejects it)"
expect_in "$WORK/adapt_fail_nondict.out" '^description-adapt=failed' "description-adapt=failed line (non-dictionary)"

# 8b. descriptionObject misuse is an INPUT ERROR (exit 3): conflicting with
# values, or an unknown kind (a switch value cannot invent new outcomes).
run "$FIX/illegal_description_object_conflict.json"
check_rc 3 $RC "values + descriptionObject conflict → exit 3"
expect_in "$WORK/illegal_description_object_conflict.err" 'cannot set both values and descriptionObject' "conflict error message"
run "$FIX/illegal_description_object_unknown.json"
check_rc 3 $RC "unknown descriptionObject kind → exit 3"
expect_in "$WORK/illegal_description_object_unknown.err" 'unknown kind: make-it-fail' "unknown-kind error names the value"

# 9. Illegal fixtures are INPUT ERRORS (exit 3) naming the field — never
# silently coerced or dropped to absent.
run "$FIX/illegal_bool_value.json"
check_rc 3 $RC "illegal bool value → exit 3"
expect_in "$WORK/illegal_bool_value.err" 'fixture\[MediaLeaf\] type=bool' "error names the field (bool)"

run "$FIX/illegal_number_bool.json"
check_rc 3 $RC "number given a JSON bool → exit 3"
expect_in "$WORK/illegal_number_bool.err" 'fixture\[MediaBSDMajor\] type=number' "error names the field (number)"

run "$FIX/illegal_unknown_key.json"
check_rc 3 $RC "unknown fixture key → exit 3"
expect_in "$WORK/illegal_unknown_key.err" 'not a known label: NotARealKey' "error names the unknown key"

# 10. An EXPLICIT false stays false (never dropped or flipped).
run "$FIX/explicit_false_kept.json"
check_rc 0 $RC "explicit_false_kept → exit 0"
expect_in "$WORK/explicit_false_kept.out" $'^MediaWhole\tpresent\tfalse$' "explicit false preserved"

# 11. Non-NTFS kind is a RAW fact — no verdict anywhere.
run "$FIX/non_ntfs_kinds.json"
check_rc 0 $RC "non_ntfs_kinds → exit 0"
expect_in "$WORK/non_ntfs_kinds.out" $'^VolumeKind\tpresent\texfat$' "exfat present as raw fact"

# 12. verbatim REAL-KEY fixture (what a real DA dictionary looks like) must
# be read correctly through the SDK-constant lookup.
# fixtures/real_keys_verbatim.json: real DiskArbitration key names (DAVolumeKind …)
# with placeholder values.
run "$FIX/real_keys_verbatim.json"
check_rc 0 $RC "real_keys_verbatim → exit 0"
expect_in "$WORK/real_keys_verbatim.out" $'^VolumeKind\tpresent\tntfs$' "verbatim real key read: VolumeKind"
expect_in "$WORK/real_keys_verbatim.out" $'^MediaLeaf\tpresent\ttrue$' "verbatim real key read: MediaLeaf"
expect_in "$WORK/real_keys_verbatim.out" $'^VolumePath\tpresent\t/Volumes/EXAMPLE$' "verbatim real key read: VolumePath"

# 13. No verdict-like line in ANY exercised fixture output (line-anchored;
# the header's explicit disclaimer must not count).
for n in partition_ntfs_unmounted partition_ntfs_mounted wholedisk_ntfs \
         missing_keys wrong_types description_missing adapt_fail_nonstringkey \
         adapt_fail_nondict explicit_false_kept non_ntfs_kinds real_keys_verbatim; do
  if grep -qiE '^(verdict|accept|reject|qualified)' "$WORK/$n.out" 2>/dev/null; then
    echo "FAIL: verdict-like line in $n.out"; FAIL=1
  fi
done
check "no verdict-like output in any fixture" 0

if [[ "$FAIL" -eq 0 ]]; then echo "ALL PASS: da_qual_sample offline checks"; exit 0
else echo "FAILED — scene kept at $WORK"; exit 1; fi
