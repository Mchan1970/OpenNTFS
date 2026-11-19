#!/bin/bash
# Offline self-test for Tools/install.sh. Never runs the real xcodebuild,
# xcodegen, pkill, open or lsregister and never touches /Applications:
#   * the script under test (INSTALL_SH, default Tools/install.sh) is copied
#     into a fresh work dir (Tools/selftest_workdir.sh); every case gets its
#     own sub-directory <work>/<case>/ holding the copied tree (with its
#     build/), the install location apps/ and the call log calls.log, so a
#     failed run keeps every case's state;
#   * OPENNTFS_APPS_DIR and OPENNTFS_LSREGISTER point into the case dir;
#   * xcodegen, xcodebuild, pkill, open and mv are recording stubs first in
#     PATH. The mv stub runs /bin/mv on the case's paths unless the case asks
#     it to fail its n-th call (STUB_MV_FAIL=n[,m]).
# Before any case runs, a self-check refuses to start unless every stub
# resolves inside the work dir and every literal /Applications or system
# lsregister path in the script under test is only an overridable default.
# Known gap: a script that calls a real tool by absolute path (for example
# /usr/bin/pkill) bypasses the stubs and is not detected; only review covers it.
#
# Every case also requires its own diagnostic(s) in the output (the diag
# argument may hold several newline-separated regexes; each must match), and
# no OpenNTFS.app or .OpenNTFS-install.* may appear outside the case's apps/,
# tree/build/ and the install location the script actually saw. When the
# install location the script actually saw is not the case's own apps/ and did
# not exist before the run, the run must not have created it (H, J).
# "unchanged" = the install location hashes the same
# (paths, types, modes, link targets, file contents; hidden entries included)
# and pkill, lsregister and open were never called.
#   A  CONFIG=Bogus                              -> 64, unchanged, no xcodebuild
#   B  xcodebuild fails after a partial product  -> non-zero, unchanged
#   C  stale complete product + xcodebuild fails -> non-zero, unchanged
#   D  xcodebuild "succeeds", helper missing     -> non-zero, unchanged
#   E  complete product -> 0; new app installed; build copy removed; calls in
#      order xcodegen, xcodebuild, pkill (after a COMPLETE copy: MARKER=NEW
#      and the three executables already in the stage dir), lsregister -u
#      on the build copy, lsregister -f, open -g — the last three checked
#      with grep -Fx (literal); apps/ holds nothing but OpenNTFS.app
#   F  product cannot be copied (unreadable file)-> non-zero, unchanged
#   G  extension Info.plist missing              -> non-zero, unchanged
#   G2 app Info.plist missing                    -> non-zero, unchanged
#   H  OPENNTFS_APPS_DIR relative                -> 64, unchanged, no xcodebuild, tree/apps not created
#   I  OPENNTFS_LSREGISTER relative              -> 64, unchanged, no xcodebuild
#   J  OPENNTFS_APPS_DIR does not exist          -> 64, unchanged, no xcodebuild, no-such-dir not created
#   R  OPENNTFS_LSREGISTER not executable        -> 64, unchanged, no xcodebuild
#   K  as E, with redundant leftovers (.new and .previous next to the app) -> as E
#   L  lock directory already present            -> non-zero, unchanged, no xcodebuild
#   L2 as L, the lock holds a foreign owner file -> as L (owner file untouched)
#   M  interrupted earlier run (only .previous) + copy fails
#      -> non-zero; BOTH diagnostics (restored AND copy failed); old app back
#      as OpenNTFS.app; no pkill/lsregister/open
#   N  interrupted earlier run + complete product -> as E, and mv#1 is exactly
#      .previous -> OpenNTFS.app and precedes xcodebuild in calls.log
#   S  moving the installed app aside fails (mv #1) -> non-zero; old app in
#      place; pkill called exactly once; mv#1 is exactly OpenNTFS.app -> .previous
#   O  moving the new app into place fails (mv #2) -> non-zero; old app
#      restored; pkill called exactly once; mv#2/mv#3 sources and targets
#      checked; diagnostic anchored at end of line
#   P  mv #2 and the restore (mv #3) fail -> non-zero; old app in .previous;
#      .OpenNTFS-install.new kept, lock released; pkill called exactly once;
#      mv#2/mv#3 sources and targets checked
#   Q  continues from P's install location with a complete product -> as N
#   OV OPENNTFS_APPS_DIR is the case's own tree/build/dd/Build/Products/<cfg>,
#      start: only .previous there -> 64; no xcodebuild, no xcodegen and no
#      mv calls; no lock directory appears there; the .previous copy still
#      holds OLD and nothing else appears there (source-tree overlap)
#   OV2 as OV, but OPENNTFS_APPS_DIR is a symlink to that directory -> as OV
#      (the overlap must be detected through the alias)
#   PL the tree's build products dir is a symlink to the case's own apps/
#      (start: only .previous there) -> 64 with the overlap diagnostic;
#      .previous still holds OLD; no mv, no xcodegen, no xcodebuild, no
#      side-effect calls, no lock directory in the install dir
#   DL apps/OpenNTFS.app is a symlink to apps/.OpenNTFS-install.previous
#      (start: only .previous there) -> as PL, with the symlink diagnostic
#   SI the source tree itself sits inside apps/.OpenNTFS-install.new/checkout
#      (start: only .previous in apps/) -> as PL, with the reverse-containment
#      diagnostic (the stage cleanup would delete the whole tree)
#   CI OPENNTFS_APPS_DIR differs from the tree path only by letter case
#      -> as PL; only runnable on a volume that resolves paths without
#      regard to case, otherwise skipped with a printed reason (not faked)
#   RF startup-restore mv fails (only .previous, STUB_MV_FAIL=1)
#      -> exit code exactly 1 and mv#1 is exactly .previous -> OpenNTFS.app;
#      .previous still holds OLD; no OpenNTFS.app; no xcodebuild;
#      no side-effect calls; lock released
#   FF first install (no OpenNTFS.app), the stage->DEST mv fails
#      -> non-zero; "there was no previous app"; install location empty;
#      pkill called exactly once; mv#1 is exactly .new -> OpenNTFS.app
#   KL a stub replaces the lock owner token mid-run -> install succeeds,
#      exit 0, warning printed, the foreign lock kept with its owner file
# In S, O, P and FF pkill has been called (that is the documented behaviour);
# lsregister and open must not be.
# SPDX-License-Identifier: GPL-2.0-or-later
set -Eeuo pipefail
# Report an unexpected abort; only in the main shell (in command substitutions
# a handled grep exit 1 would also trigger ERR).
trap '[[ $BASH_SUBSHELL -ne 0 ]] || echo "FAIL: aborted at line $LINENO" >&2' ERR
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_SH="${INSTALL_SH:-$ROOT/Tools/install.sh}"
[[ -f "$INSTALL_SH" ]] || { echo "FAIL: no script under test: $INSTALL_SH"; exit 1; }
. "$ROOT/Tools/selftest_workdir.sh"
W="$(selftest_workdir "$ROOT" install-selftest)"
FAILS=0
cleanup() {
  local ec=$?
  if [[ $ec -ne 0 || $FAILS -ne 0 ]]; then /bin/mv "$W" "$W.FAILED" && echo "Kept failure artifacts at $W.FAILED" >&2
  else rm -rf "$W"; fi
}
trap cleanup EXIT
echo "script under test: $INSTALL_SH ($(shasum -a 256 < "$INSTALL_SH" | cut -d' ' -f1))"
echo "test driver: $0 ($(shasum -a 256 < "$0" | cut -d' ' -f1))"

# ---- static guard on the script under test
python3 -I - "$INSTALL_SH" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
lsr = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
ok_apps = "${OPENNTFS_APPS_DIR:-/Applications}"
ok_lsr = "${OPENNTFS_LSREGISTER:-" + lsr + "}"
code = "\n".join(l for l in s.splitlines() if not l.lstrip().startswith("#"))
rest = code.replace(ok_apps, "").replace(ok_lsr, "")
if "/Applications" in rest or lsr in rest:
    raise SystemExit("FAIL: script under test uses /Applications or the system lsregister outside an overridable default")
print("static guard: /Applications and lsregister only as overridable defaults")
PY

# ---- stubs (every call is appended to $STUB_CALLS, set per case)
S="$W/stubs"; mkdir "$S"
for c in xcodegen open lsregister; do
  printf '#!/bin/bash\necho "%s $*" >> "${STUB_CALLS:?}"\n' "$c" > "$S/$c"
done
cat > "$S/pkill" <<'EOF'
#!/bin/bash
# Records whether the stage dir already holds the complete new app
# (MARKER=NEW and the three executables) at call time.
d="${OPENNTFS_APPS_DIR:?}/.OpenNTFS-install.new"
st=no
if [[ -d "$d" ]]; then
  st=incomplete
  ok=yes
  [[ "$(cat "$d/MARKER" 2>/dev/null)" == NEW ]] || ok=no
  for f in Contents/MacOS/OpenNTFS Contents/MacOS/OpenNTFSHelper Contents/Extensions/OpenNTFSModule.appex/Contents/MacOS/OpenNTFSModule; do
    [[ -f "$d/$f" && -x "$d/$f" ]] || ok=no
  done
  if [[ "$ok" == yes ]]; then st=complete; fi
fi
echo "pkill $* stage=$st" >> "${STUB_CALLS:?}"
exit 1
EOF
cat > "$S/mv" <<'EOF'
#!/bin/bash
n=$(( $(cat "${STUB_CALLS:?}.mvn") + 1 )); echo "$n" > "$STUB_CALLS.mvn"
echo "mv#$n $*" >> "$STUB_CALLS"
case ",${STUB_MV_FAIL:-}," in *",$n,"*) echo "mv: stub-injected failure (call $n)" >&2; exit 1 ;; esac
exec /bin/mv "$@"
EOF
cat > "$S/xcodebuild" <<'EOF'
#!/bin/bash
echo "xcodebuild $*" >> "${STUB_CALLS:?}"
cfg=""; prev=""; for a in "$@"; do [[ $prev == -configuration ]] && cfg=$a; prev=$a; done
P="$PWD/build/dd/Build/Products/$cfg/OpenNTFS.app"
mk() { mkdir -p "$P/Contents/MacOS" "$P/Contents/Extensions/OpenNTFSModule.appex/Contents/MacOS" "$P/Contents/Library/LaunchDaemons"
       for f in Contents/MacOS/OpenNTFS Contents/MacOS/OpenNTFSHelper Contents/Extensions/OpenNTFSModule.appex/Contents/MacOS/OpenNTFSModule; do
         printf '#!/bin/sh\n' > "$P/$f"; chmod +x "$P/$f"; done
       for f in Contents/Info.plist Contents/Extensions/OpenNTFSModule.appex/Contents/Info.plist; do echo '<plist/>' > "$P/$f"; done
       echo '<plist/>' > "$P/Contents/Library/LaunchDaemons/x.Helper.plist"; echo NEW > "$P/MARKER"; }
ok() { echo "** BUILD SUCCEEDED **"; exit 0; }
case "$STUB_XCB" in
  ok)             mk; ok ;;
  ok-incomplete)  mk; rm "$P/Contents/MacOS/OpenNTFSHelper"; ok ;;
  ok-noplist)     mk; rm "$P/Contents/Extensions/OpenNTFSModule.appex/Contents/Info.plist"; ok ;;
  ok-noappplist)  mk; rm "$P/Contents/Info.plist"; ok ;;
  ok-uncopyable)  mk; mkdir -p "$P/Contents/Resources"; echo x > "$P/Contents/Resources/locked"; chmod 000 "$P/Contents/Resources/locked"; ok ;;
  ok-steal-lock)  printf 'foreign-token\n' > "${OPENNTFS_APPS_DIR:?}/.OpenNTFS-install.lock/owner"; mk; ok ;;
  fail-partial)   mkdir -p "$P/Contents/MacOS"; printf '#!/bin/sh\n' > "$P/Contents/MacOS/OpenNTFS"; chmod +x "$P/Contents/MacOS/OpenNTFS"
                  echo "error: signing failed"; echo "** BUILD FAILED **"; exit 65 ;;
  fail-none)      echo "error: compile failed"; echo "** BUILD FAILED **"; exit 65 ;;
  *) echo "stub: bad STUB_XCB" >&2; exit 99 ;;
esac
EOF
chmod +x "$S"/*
export PATH="$S:$PATH"
for c in xcodegen xcodebuild pkill open mv; do
  [[ "$(command -v "$c")" == "$S/$c" ]] || { echo "FAIL: $c does not resolve to the stub"; exit 1; }
done
echo "self-check: xcodegen, xcodebuild, pkill, open and mv resolve to stubs inside the work dir"

# Every entry of a directory (hidden ones included): relative path, type,
# mode, link target, sha256 of each file. An unreadable entry is an error.
tree_hash() { python3 -I - "$1" <<'PY'
import hashlib, os, stat, sys
root = sys.argv[1]; h = hashlib.sha256()
def boom(e): raise e
for d, dirs, files in os.walk(root, onerror=boom):
    dirs.sort()
    for n in sorted(dirs + files):
        p = os.path.join(d, n); rel = os.path.relpath(p, root); st = os.lstat(p)
        line = f"{rel} {oct(st.st_mode)}"
        if stat.S_ISLNK(st.st_mode): line += " -> " + os.readlink(p)
        elif stat.S_ISREG(st.st_mode):
            with open(p, "rb") as f: line += " " + hashlib.sha256(f.read()).hexdigest()
        h.update((line + "\n").encode())
print(h.hexdigest())
PY
}
# Number of logged calls matching ^($1); grep exit 1 (none) is 0, >1 aborts.
calls() { local n rc=0; n=$(grep -cE "^($1)" "$C/calls.log") || rc=$?
  [[ $rc -le 1 ]] || { echo "FAIL: grep error $rc on $C/calls.log" >&2; return 2; }; echo "$n"; }
# Line number of the first calls.log line matching regex $1; empty if none.
first_call_line() { awk -v re="$1" '$0 ~ re { print NR; exit }' "$C/calls.log"; }

# run_case name config stub expect pre diag [VAR=value ...]
#   expect: 64 | fail | locked | ok | okrestore | keptlock | overlap64 |
#           restored | restorefail | firstfail | asidefail | intofail | stranded
#   pre:    - | stale | leftover | locked | locked-owner | interrupted | fresh |
#           nonexec | overlap | overlap-link | from:<case>
#   diag:   newline-separated extended regexes; each must match the output
#   VAR=value: extra environment; @C@ is replaced by the case dir
run_case() {
  local name="$1" cfg="$2" stub="$3" expect="$4" pre="$5" diag="$6" rc=0 before after why="" e
  local -a envs=()
  local APPS_OVERRIDE="" eff_apps eff_abs eff_created d dline tree
  local nx nall nlo np nxg nmv pmark olist mv1 xcb1 nent
  shift 6
  C="$W/$name"; tree="$C/tree"; mkdir -p "$C/tree/Tools" "$C/apps/OpenNTFS.app"
  for e in "$@"; do envs+=("${e//@C@/$C}"); done
  echo OLD > "$C/apps/OpenNTFS.app/MARKER"; chmod 755 "$C/apps/OpenNTFS.app"
  : > "$C/calls.log"; echo 0 > "$C/calls.log.mvn"
  cp "$INSTALL_SH" "$C/tree/Tools/install.sh"
  case "$pre" in
    -) ;;
    stale) (cd "$C/tree" && STUB_CALLS="$C/calls.log" STUB_XCB=ok "$S/xcodebuild" -configuration "$cfg" >/dev/null)
           echo STALE > "$C/tree/build/dd/Build/Products/$cfg/OpenNTFS.app/MARKER"; : > "$C/calls.log" ;;
    leftover) mkdir -p "$C/apps/.OpenNTFS-install.new/x" "$C/apps/.OpenNTFS-install.previous/y" ;;
    locked) mkdir "$C/apps/.OpenNTFS-install.lock" ;;
    locked-owner) mkdir "$C/apps/.OpenNTFS-install.lock"; printf 'foreign-token\n' > "$C/apps/.OpenNTFS-install.lock/owner" ;;
    interrupted) /bin/mv "$C/apps/OpenNTFS.app" "$C/apps/.OpenNTFS-install.previous" ;;
    fresh) rm -rf "$C/apps/OpenNTFS.app" ;;
    nonexec) printf '#!/bin/sh\n' > "$C/not-exec"; chmod 644 "$C/not-exec" ;;
    overlap) d="$C/tree/build/dd/Build/Products/$cfg"; mkdir -p "$d"
             /bin/mv "$C/apps/OpenNTFS.app" "$d/.OpenNTFS-install.previous"; APPS_OVERRIDE="$d" ;;
    overlap-link) d="$C/tree/build/dd/Build/Products/$cfg"; mkdir -p "$d"
             /bin/mv "$C/apps/OpenNTFS.app" "$d/.OpenNTFS-install.previous"
             ln -s "$d" "$C/link-apps"; APPS_OVERRIDE="$C/link-apps" ;;
    prod-link) d="$C/tree/build/dd/Build/Products/$cfg"; mkdir -p "${d%/*}"
             /bin/mv "$C/apps/OpenNTFS.app" "$C/apps/.OpenNTFS-install.previous"
             ln -s "$C/apps" "$d" ;;
    dest-link) /bin/mv "$C/apps/OpenNTFS.app" "$C/apps/.OpenNTFS-install.previous"
             ln -s "$C/apps/.OpenNTFS-install.previous" "$C/apps/OpenNTFS.app" ;;
    src-inside) mkdir -p "$C/apps/.OpenNTFS-install.new"
             /bin/mv "$tree" "$C/apps/.OpenNTFS-install.new/checkout"
             tree="$C/apps/.OpenNTFS-install.new/checkout"
             /bin/mv "$C/apps/OpenNTFS.app" "$C/apps/.OpenNTFS-install.previous"
             mkdir -p "$tree/build/dd/Build/Products/$cfg" ;;
    case-alias) /bin/mv "$C/apps/OpenNTFS.app" "$C/tree/.OpenNTFS-install.previous"
             mkdir -p "$C/tree/build/dd/Build/Products/$cfg"; APPS_OVERRIDE="$C/TREE" ;;
    from:*) rm -rf "$C/apps"; cp -Rp "$W/${pre#from:}/apps" "$C/apps" ;;
    *) echo "FAIL $name: bad pre '$pre'"; FAILS=$((FAILS+1)); return 0 ;;
  esac
  [[ -z "$APPS_OVERRIDE" ]] || envs+=("OPENNTFS_APPS_DIR=$APPS_OVERRIDE")
  # The install location the script will actually see (later values win),
  # resolved the way the script resolves it (relative to the tree).
  eff_apps="$C/apps"
  for e in ${envs[@]+"${envs[@]}"}; do
    if [[ "$e" == OPENNTFS_APPS_DIR=* ]]; then eff_apps="${e#OPENNTFS_APPS_DIR=}"; fi
  done
  eff_abs="$eff_apps"
  if [[ "$eff_abs" != /* ]]; then eff_abs="$C/tree/$eff_abs"; fi
  # Canonical spelling (pwd -P; on a case-insensitive volume this is the
  # on-disk case), so the stray-prefix and marker checks below look at the
  # same directory the script resolves.
  if [[ -d "$eff_abs" ]]; then eff_abs="$(cd "$eff_abs" && pwd -P)"; fi
  eff_created=1
  if [[ "$eff_apps" == "$C/apps" || -e "$eff_abs" ]]; then eff_created=0; fi
  case "$C" in "$W"/*) ;; *) echo "FAIL: case dir outside work dir"; exit 1 ;; esac
  before=$(tree_hash "$C/apps") || { echo "FAIL $name: cannot hash the install location before the run"; FAILS=$((FAILS+1)); return 0; }
  (cd "$tree" && env STUB_CALLS="$C/calls.log" OPENNTFS_APPS_DIR="$C/apps" OPENNTFS_LSREGISTER="$S/lsregister" \
      CONFIG="$cfg" STUB_XCB="$stub" ${envs[@]+"${envs[@]}"} bash Tools/install.sh) > "$C/out.txt" 2>&1 || rc=$?
  after=$(tree_hash "$C/apps") || { why+=" install-location-unreadable"; after="?"; }
  while IFS= read -r dline; do
    [[ -n "$dline" ]] || continue
    grep -qE "$dline" "$C/out.txt" || why+=" diagnostic-missing(/$dline/)"
  done <<< "$diag"
  if [[ $eff_created -eq 1 ]]; then
    [[ ! -e "$eff_abs" ]] || why+=" install-location-created($eff_apps)"
  fi
  local found stray eff_rel
  eff_rel="${eff_abs#"$C"/}"
  found=$(cd "$C" && find . \( -name OpenNTFS.app -o -name '.OpenNTFS-install.*' \) -prune -print) || why+=" find-failed"
  # Reserved names are allowed in the case's apps/, under tree/build/ and
  # anywhere inside the install location the script actually saw (compared
  # lowercased: pwd -P keeps the given letter case on this volume, so the
  # CI alias spells the same directory differently).
  stray=$(printf '%s\n' "$found" | awk -v pre="./$eff_rel/" 'BEGIN{p=tolower(pre)} NF && !/^\.\/(apps|tree\/build)\// && index(tolower($0), p) != 1')
  [[ -z "$stray" ]] || why+=" stray:$(echo $stray)"
  # A missing MARKER yields cat's error text, which never equals OLD or NEW.
  local marker; marker=$(cat "$C/apps/OpenNTFS.app/MARKER" 2>&1) || true
  local listing; listing=$(cd "$C/apps" && ls -A | tr '\n' ',')
  case "$expect" in
    64|fail|locked)
      if [[ $expect == 64 ]]; then [[ $rc -eq 64 ]] || why+=" exit=$rc(want 64)"; else [[ $rc -ne 0 ]] || why+=" exit=0(want non-zero)"; fi
      if [[ $expect != fail ]]; then nx=$(calls xcodebuild); [[ $nx -eq 0 ]] || why+=" xcodebuild-called"; fi
      [[ "$before" == "$after" ]] || why+=" install-location-changed(marker=$marker; has=$listing)"
      nall=$(calls 'pkill|lsregister|open'); [[ $nall -eq 0 ]] || why+=" side-effect-calls($nall)" ;;
    overlap64)
      [[ $rc -eq 64 ]] || why+=" exit=$rc(want 64)"
      [[ "$before" == "$after" ]] || why+=" install-location-changed(marker=$marker; has=$listing)"
      olist=$(ls -A "$eff_abs" | tr '\n' ',')
      [[ "$olist" == ".OpenNTFS-install.previous," ]] || why+=" install-dir-modified(has=$olist)"
      pmark=$(cat "$eff_abs/.OpenNTFS-install.previous/MARKER" 2>&1) || true
      [[ "$pmark" == OLD ]] || why+=" previous-marker($pmark)"
      nx=$(calls xcodebuild); [[ $nx -eq 0 ]] || why+=" xcodebuild-called"
      nxg=$(calls xcodegen); [[ $nxg -eq 0 ]] || why+=" xcodegen-called"
      nmv=$(calls 'mv#[0-9]+'); [[ $nmv -eq 0 ]] || why+=" mv-called($nmv)"
      [[ ! -e "$eff_abs/.OpenNTFS-install.lock" ]] || why+=" lock-created"
      nall=$(calls 'pkill|lsregister|open'); [[ $nall -eq 0 ]] || why+=" side-effect-calls($nall)" ;;
    preflight64)
      [[ $rc -eq 64 ]] || why+=" exit=$rc(want 64)"
      [[ "$before" == "$after" ]] || why+=" install-location-changed(marker=$marker; has=$listing)"
      pmark=$(cat "$eff_abs/.OpenNTFS-install.previous/MARKER" 2>&1) || true
      [[ "$pmark" == OLD ]] || why+=" previous-marker($pmark)"
      [[ ! -e "$eff_abs/.OpenNTFS-install.lock" ]] || why+=" lock-created"
      nx=$(calls xcodebuild); [[ $nx -eq 0 ]] || why+=" xcodebuild-called"
      nxg=$(calls xcodegen); [[ $nxg -eq 0 ]] || why+=" xcodegen-called"
      nmv=$(calls 'mv#[0-9]+'); [[ $nmv -eq 0 ]] || why+=" mv-called($nmv)"
      nall=$(calls 'pkill|lsregister|open'); [[ $nall -eq 0 ]] || why+=" side-effect-calls($nall)" ;;
    restored)
      [[ $rc -ne 0 ]] || why+=" exit=0(want non-zero)"
      [[ $marker == OLD && $listing == "OpenNTFS.app," ]] || why+=" old-app-not-back(marker=$marker; has=$listing)"
      nall=$(calls 'pkill|lsregister|open'); [[ $nall -eq 0 ]] || why+=" side-effect-calls($nall)" ;;
    restorefail)
      [[ $rc -eq 1 ]] || why+=" exit=$rc(want 1)"
      grep -Fxq "mv#1 $C/apps/.OpenNTFS-install.previous $C/apps/OpenNTFS.app" "$C/calls.log" || why+=" restore-mv-not-attempted"
      pmark=$(cat "$C/apps/.OpenNTFS-install.previous/MARKER" 2>&1) || true
      [[ "$pmark" == OLD && ! -e "$C/apps/OpenNTFS.app" ]] || why+=" previous-not-preserved(marker=$pmark; has=$listing)"
      [[ "$listing" == ".OpenNTFS-install.previous," ]] || why+=" unexpected-leftovers(has=$listing)"
      nx=$(calls xcodebuild); [[ $nx -eq 0 ]] || why+=" xcodebuild-called"
      nall=$(calls 'pkill|lsregister|open'); [[ $nall -eq 0 ]] || why+=" side-effect-calls($nall)" ;;
    firstfail)
      [[ $rc -ne 0 ]] || why+=" exit=0(want non-zero)"
      [[ -z "$listing" ]] || why+=" install-location-not-empty(has=$listing)"
      np=$(calls '^pkill '); [[ $np -eq 1 ]] || why+=" pkill-calls($np)"
      grep -Fxq "mv#1 $C/apps/.OpenNTFS-install.new $C/apps/OpenNTFS.app" "$C/calls.log" || why+=" into-place-mv-args-wrong"
      nlo=$(calls 'lsregister|open'); [[ $nlo -eq 0 ]] || why+=" lsregister/open-called($nlo)" ;;
    asidefail)
      [[ $rc -ne 0 ]] || why+=" exit=0(want non-zero)"
      [[ $marker == OLD && $listing == "OpenNTFS.app," ]] || why+=" old-app-not-in-place(marker=$marker; has=$listing)"
      np=$(calls '^pkill '); [[ $np -eq 1 ]] || why+=" pkill-calls($np)"
      grep -Fxq "mv#1 $C/apps/OpenNTFS.app $C/apps/.OpenNTFS-install.previous" "$C/calls.log" || why+=" aside-mv-args-wrong"
      nlo=$(calls 'lsregister|open'); [[ $nlo -eq 0 ]] || why+=" lsregister/open-called($nlo)" ;;
    intofail)
      [[ $rc -ne 0 ]] || why+=" exit=0(want non-zero)"
      [[ $marker == OLD && $listing == "OpenNTFS.app," ]] || why+=" old-app-not-in-place(marker=$marker; has=$listing)"
      np=$(calls '^pkill '); [[ $np -eq 1 ]] || why+=" pkill-calls($np)"
      grep -Fxq "mv#2 $C/apps/.OpenNTFS-install.new $C/apps/OpenNTFS.app" "$C/calls.log" || why+=" into-place-mv-args-wrong"
      grep -Fxq "mv#3 $C/apps/.OpenNTFS-install.previous $C/apps/OpenNTFS.app" "$C/calls.log" || why+=" restore-mv-args-wrong"
      nlo=$(calls 'lsregister|open'); [[ $nlo -eq 0 ]] || why+=" lsregister/open-called($nlo)" ;;
    stranded)
      [[ $rc -ne 0 ]] || why+=" exit=0(want non-zero)"
      pmark=$(cat "$C/apps/.OpenNTFS-install.previous/MARKER" 2>&1) || true
      [[ "$pmark" == OLD && ! -e "$C/apps/OpenNTFS.app" ]] || why+=" old-app-not-in-previous(has=$listing)"
      [[ -d "$C/apps/.OpenNTFS-install.new" ]] || why+=" stage-not-kept"
      [[ ! -e "$C/apps/.OpenNTFS-install.lock" ]] || why+=" lock-not-released"
      np=$(calls '^pkill '); [[ $np -eq 1 ]] || why+=" pkill-calls($np)"
      grep -Fxq "mv#2 $C/apps/.OpenNTFS-install.new $C/apps/OpenNTFS.app" "$C/calls.log" || why+=" into-place-mv-args-wrong"
      grep -Fxq "mv#3 $C/apps/.OpenNTFS-install.previous $C/apps/OpenNTFS.app" "$C/calls.log" || why+=" restore-mv-args-wrong"
      nlo=$(calls 'lsregister|open'); [[ $nlo -eq 0 ]] || why+=" lsregister/open-called($nlo)" ;;
    ok|okrestore)
      [[ $rc -eq 0 ]] || why+=" exit=$rc(want 0)"
      [[ $marker == NEW ]] || why+=" new-app-not-installed(marker=$marker)"
      [[ $listing == "OpenNTFS.app," ]] || why+=" install-location-has:$listing"
      [[ ! -e "$C/tree/build/dd/Build/Products/$cfg/OpenNTFS.app" ]] || why+=" build-copy-not-removed"
      local seq want
      seq=$(grep -E '^(xcodegen|xcodebuild|pkill|lsregister|open) ' "$C/calls.log" | awk '{print $1, $2}' | tr '\n' ',')
      want="xcodegen generate,xcodebuild -project,pkill -x,lsregister -u,lsregister -f,open -g,"
      [[ $seq == "$want" ]] || why+=" call-order($seq)"
      grep -q '^pkill -x OpenNTFS stage=complete$' "$C/calls.log" || why+=" pkill-not-after-complete-copy"
      grep -Fxq "lsregister -u $C/tree/build/dd/Build/Products/$cfg/OpenNTFS.app" "$C/calls.log" || why+=" no-lsregister-u-on-build-copy"
      grep -Fxq "lsregister -f $C/apps/OpenNTFS.app" "$C/calls.log" || why+=" no-lsregister-f-on-installed-app"
      grep -Fxq "open -g $C/apps/OpenNTFS.app" "$C/calls.log" || why+=" no-open-on-installed-app"
      if [[ $expect == okrestore ]]; then
        grep -Fxq "mv#1 $C/apps/.OpenNTFS-install.previous $C/apps/OpenNTFS.app" "$C/calls.log" || why+=" restore-mv-args-wrong"
        mv1=$(first_call_line '^mv#1 ')
        xcb1=$(first_call_line '^xcodebuild ')
        [[ -n "$mv1" && -n "$xcb1" && "$mv1" -lt "$xcb1" ]] || why+=" restore-not-before-build(mv=$mv1 xcb=$xcb1)"
      fi ;;
    keptlock)
      [[ $rc -eq 0 ]] || why+=" exit=$rc(want 0)"
      [[ $marker == NEW ]] || why+=" new-app-not-installed(marker=$marker)"
      [[ ! -e "$C/tree/build/dd/Build/Products/$cfg/OpenNTFS.app" ]] || why+=" build-copy-not-removed"
      nent=$(ls -A "$C/apps" | wc -l | tr -d ' ')
      [[ $nent -eq 2 && -d "$C/apps/.OpenNTFS-install.lock" ]] || why+=" lock-not-kept(has=$listing)"
      [[ "$(cat "$C/apps/.OpenNTFS-install.lock/owner" 2>&1)" == foreign-token ]] || why+=" owner-token-changed"
      local seq want
      seq=$(grep -E '^(xcodegen|xcodebuild|pkill|lsregister|open) ' "$C/calls.log" | awk '{print $1, $2}' | tr '\n' ',')
      want="xcodegen generate,xcodebuild -project,pkill -x,lsregister -u,lsregister -f,open -g,"
      [[ $seq == "$want" ]] || why+=" call-order($seq)"
      grep -q '^pkill -x OpenNTFS stage=complete$' "$C/calls.log" || why+=" pkill-not-after-complete-copy"
      grep -Fxq "lsregister -u $C/tree/build/dd/Build/Products/$cfg/OpenNTFS.app" "$C/calls.log" || why+=" no-lsregister-u-on-build-copy"
      grep -Fxq "lsregister -f $C/apps/OpenNTFS.app" "$C/calls.log" || why+=" no-lsregister-f-on-installed-app"
      grep -Fxq "open -g $C/apps/OpenNTFS.app" "$C/calls.log" || why+=" no-open-on-installed-app" ;;
    *) why+=" bad-expect($expect)" ;;
  esac
  if [[ -z "$why" ]]; then echo "PASS $name (exit $rc)"; else echo "FAIL $name:$why"; FAILS=$((FAILS+1)); fi
  sed "s#$W#<work>#g; s/^/    | /" "$C/out.txt" | tail -3
}
run_case A-bad-config         Bogus      ok            64   -     'CONFIG must be Debug or Release'
run_case B-partial-product    Debug   fail-partial     fail -     'xcodebuild failed \(exit 65\); nothing installed'
run_case C-stale-product      Debug   fail-none        fail stale 'xcodebuild failed \(exit 65\); nothing installed'
run_case D-incomplete-success Debug   ok-incomplete    fail -     'incomplete product, nothing installed; missing: Contents/MacOS/OpenNTFSHelper$'
run_case E-success            Release ok               ok   -     '^installed .*/apps/OpenNTFS.app \(Release\)$'
run_case F-copy-fails         Debug   ok-uncopyable    fail -     'copying the new app failed; installed app left in place'
run_case G-no-appex-plist     Debug   ok-noplist       fail -     'missing: Contents/Extensions/OpenNTFSModule.appex/Contents/Info.plist$'
run_case G2-no-app-plist      Debug   ok-noappplist    fail -     'missing: Contents/Info.plist$'
run_case H-relative-apps-dir  Debug   ok               64   -     'OPENNTFS_APPS_DIR must be an absolute path' OPENNTFS_APPS_DIR=apps
run_case I-relative-lsreg     Debug   ok               64   -     'OPENNTFS_LSREGISTER must be an absolute path' OPENNTFS_LSREGISTER=lsregister
run_case J-missing-apps-dir   Debug   ok               64   -     'install location .* is not a directory' OPENNTFS_APPS_DIR=@C@/no-such-dir
run_case R-lsreg-not-exec     Debug   ok               64   nonexec 'lsregister .* is not an executable file' OPENNTFS_LSREGISTER=@C@/not-exec
run_case K-staging-leftovers  Release ok               ok   leftover '^installed .*/apps/OpenNTFS.app \(Release\)$'
run_case L-lock-held          Debug   ok               locked locked 'another install is running'
run_case L2-lock-foreign-owner Debug  ok               locked locked-owner 'another install is running'
run_case M-interrupted-copy-fails Debug ok-uncopyable  restored interrupted 'restored the app left in
copying the new app failed'
run_case N-interrupted-success Release ok              okrestore interrupted 'restored the app left in'
run_case S-mv-aside-fails     Debug   ok               asidefail - 'moving the installed app aside failed; it is left in place' STUB_MV_FAIL=1
run_case O-mv-into-place-fails Debug  ok               intofail -  'moving the new app into place failed; previous app restored$' STUB_MV_FAIL=2
run_case P-mv-and-restore-fail Debug  ok               stranded -  'restoring failed too; the previous app is in .*\.OpenNTFS-install\.previous' STUB_MV_FAIL=2,3
run_case Q-after-P            Release ok               okrestore from:P-mv-and-restore-fail 'restored the app left in'
run_case OV-inside-build-tree Debug   ok               overlap64 overlap 'install location .* is inside the source tree'
run_case OV2-via-symlink      Debug   ok               overlap64 overlap-link 'install location .* is inside the source tree'
run_case RF-restore-mv-fails  Debug   ok               restorefail interrupted 'cannot restore.*it is still in.*\.OpenNTFS-install\.previous$' STUB_MV_FAIL=1
run_case FF-first-install-mv-fails Debug ok            firstfail fresh 'moving the new app into place failed; there was no previous app$' STUB_MV_FAIL=1
run_case KL-stolen-lock-kept  Debug   ok-steal-lock    keptlock - 'belongs to another install; left in place$'
run_case PL-products-link     Debug   ok               preflight64 prod-link  'overlaps the build products directory'
run_case DL-dest-symlink      Debug   ok               preflight64 dest-link 'is a symlink'
run_case SI-source-inside    Debug   ok               preflight64 src-inside 'the source tree .* is inside the install location'
# CI needs a volume that resolves paths without regard to letter case (the
# usual macOS system volume); on a case-sensitive volume the case-only alias
# cannot be constructed and the case is skipped with a reason, not faked.
mkdir "$W/ci-case-probe"
if [ -d "$W/CI-CASE-PROBE" ]; then
  run_case CI-case-alias       Debug   ok               preflight64 case-alias 'install location .* is inside the source tree'
else
  echo "SKIP CI-case-alias: this volume resolves paths case-sensitively; a case-only alias of the tree cannot be constructed"
fi
if [[ $FAILS -ne 0 ]]; then echo "FAILED: $FAILS case(s)"; exit 1; fi
echo "ALL PASS: install-selftest"
