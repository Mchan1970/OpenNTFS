#!/bin/bash
# Build OpenNTFS and install it to /Applications.
# The build product is removed afterwards: a second registered copy of the
# app makes System Settings refuse to enable the file system extension.
#
# Only a product built successfully by THIS run is ever installed:
#   * CONFIG must be Debug or Release;
#   * the previous product is deleted before the build;
#   * xcodebuild must exit 0 and print "BUILD SUCCEEDED" (full log kept in
#     build/install-<CONFIG>.log);
#   * the bundle must contain the app, helper and extension executables, the
#     app and extension Info.plist files and exactly one LaunchDaemon plist
#     (the layout of a release build).
#
# Install location (all names below are inside it):
#   * .OpenNTFS-install.lock (a directory) makes runs mutually exclusive; it
#     is created before the build. It holds an owner file with a token unique
#     to this run and is removed when the script exits, but only while that
#     token is still the run's own (a lock recreated by someone else is kept
#     and a warning is printed). A lock left by a killed run must be removed
#     by hand; the script refuses to run while it exists.
#   * If an earlier run was interrupted after moving the installed app aside,
#     .OpenNTFS-install.previous is the only copy of it: it is moved back to
#     OpenNTFS.app before anything else. If that move fails, the copy is left
#     in .OpenNTFS-install.previous, the run stops, and the next run retries.
#   * The new app is copied to .OpenNTFS-install.new first. Only after that
#     copy succeeds is OpenNTFS stopped, the installed app renamed to
#     .OpenNTFS-install.previous and the new one renamed into place. A failed
#     copy leaves the installed app in place and this script does not stop it.
#   * Between the two renames OpenNTFS.app briefly does not exist; there is no
#     atomic swap from the shell. If the second rename fails, the previous app
#     is renamed back; if that fails too, it stays in .OpenNTFS-install.previous
#     and the next run restores it.
#   * The staging names do not end in .app. Whether LaunchServices ever
#     registers them anyway has not been verified.
# Before the lock is taken, the three locations this run deletes, moves or
# writes -- the install location, the source tree and the build products
# directory -- are resolved to physical paths (pwd -P resolves symlinks) and
# cross-checked pairwise, lowercased: no two of them may be equal or contain
# each other in either direction, and the build products directory must
# resolve to exactly build/dd/Build/Products/$CONFIG inside the tree. The
# lowercased comparison may falsely reject distinct case-only paths on a
# case-sensitive volume, but a false rejection only refuses the run, it never
# destroys anything. The four reserved names must not be symlinks (dangling
# links included), and from here on the install location is used via its
# resolved physical path, so the checks and the operations below cannot be
# about two different places. With these preconditions verified, apart from
# the lock and the restore, nothing in the install location is touched before
# the build and the checks above have passed.
#
# Test seams (used by Tools/install-selftest.sh; defaults are the real paths):
#   OPENNTFS_APPS_DIR     install location            (default /Applications)
#   OPENNTFS_LSREGISTER   lsregister executable       (default system path)
# Both must be absolute paths; the install location must be an existing
# directory and lsregister an executable file.
# xcodegen, xcodebuild, pkill, open and mv are taken from PATH.
#
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
cd "$(dirname "$0")/.."
APPS="${OPENNTFS_APPS_DIR:-/Applications}"
LSR="${OPENNTFS_LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}"
CONFIG="${CONFIG:-Debug}"
case "$CONFIG" in
  Debug|Release) ;;
  *) echo "install.sh: CONFIG must be Debug or Release (got '$CONFIG')" >&2; exit 64 ;;
esac
for v in "OPENNTFS_APPS_DIR=$APPS" "OPENNTFS_LSREGISTER=$LSR"; do
  case "${v#*=}" in
    /*) ;;
    *) echo "install.sh: ${v%%=*} must be an absolute path (got '${v#*=}')" >&2; exit 64 ;;
  esac
done
[ -d "$APPS" ] || { echo "install.sh: install location $APPS is not a directory" >&2; exit 64; }
[ -f "$LSR" ] && [ -x "$LSR" ] || { echo "install.sh: lsregister $LSR is not an executable file" >&2; exit 64; }

# Generic location preflight, before any lock, restore or deletion. The
# build products directory is created first (inside the tree only; the build
# below would create it anyway) so that its resolved location can be checked.
PROD_DIR="build/dd/Build/Products/$CONFIG"
mkdir -p "$PROD_DIR"
APPS_REAL="$(cd "$APPS" && pwd -P)"
SRC_REAL="$(pwd -P)"
PROD_REAL="$(cd "$PROD_DIR" && pwd -P)"
lower() { printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]'; }
a="$(lower "$APPS_REAL")"; s="$(lower "$SRC_REAL")"; p="$(lower "$PROD_REAL")"
# contains <outer> <inner>: inner is outer itself or a directory inside it.
contains() {
  if [ "$2" = "$1" ]; then return 0; fi
  if [ "$1" = "/" ]; then
    case "$2" in /*) return 0 ;; esac
  else
    case "$2" in "$1"/*) return 0 ;; esac
  fi
  return 1
}
# Pair (install location, source tree): neither equal nor contained either way.
if contains "$s" "$a"; then
  echo "install.sh: install location $APPS_REAL is inside the source tree $SRC_REAL (from $APPS)" >&2
  exit 64
fi
if contains "$a" "$s"; then
  echo "install.sh: the source tree $SRC_REAL is inside the install location $APPS_REAL (from $APPS)" >&2
  exit 64
fi
# Pair (install location, build products directory): neither equal nor
# contained either way; a symlinked products directory pointing into the
# install location would make the pre-build rm -rf delete the restored app.
if contains "$p" "$a" || contains "$a" "$p"; then
  echo "install.sh: install location $APPS_REAL overlaps the build products directory $PROD_REAL (from $APPS)" >&2
  exit 64
fi
# Pair (source tree, build products directory): the products directory is by
# construction a subdirectory of the tree, so the alias check for this pair is
# that it resolves to exactly that subdirectory; anything else (equal to the
# tree, containing it, or redirected somewhere else by a symlink) is refused.
if [ "$p" != "$(lower "$SRC_REAL/$PROD_DIR")" ]; then
  echo "install.sh: build products directory $PROD_REAL is not the expected $SRC_REAL/$PROD_DIR (symlink redirection?)" >&2
  exit 64
fi
# Reserved names in the install location must not be symlinks (a dangling
# link counts too): a symlink OpenNTFS.app -> .OpenNTFS-install.previous
# would make the restore below believe an app is installed while the only
# copy still sits in PREV, which is later deleted as redundant.
DEST_NAME=OpenNTFS.app
STAGE_NAME=.OpenNTFS-install.new
PREV_NAME=.OpenNTFS-install.previous
LOCK_NAME=.OpenNTFS-install.lock
for n in "$DEST_NAME" "$STAGE_NAME" "$PREV_NAME" "$LOCK_NAME"; do
  if [ -L "$APPS_REAL/$n" ]; then
    echo "install.sh: $APPS_REAL/$n is a symlink; refusing to run (reserved install name)" >&2
    exit 64
  fi
done
APPS="$APPS_REAL"
DEST="$APPS/$DEST_NAME"
STAGE="$APPS/$STAGE_NAME"
PREV="$APPS/$PREV_NAME"
LOCK="$APPS/$LOCK_NAME"
lockerr=""
if ! lockerr="$(mkdir "$LOCK" 2>&1)"; then
  if [ -e "$LOCK" ]; then
    echo "install.sh: another install is running, or a killed run left $LOCK (remove it by hand)" >&2
  else
    echo "install.sh: cannot create the lock directory $LOCK: $lockerr" >&2
  fi
  exit 1
fi
TOKEN="$$-$RANDOM$RANDOM"
trap 'if [ "$(cat "$LOCK/owner" 2>/dev/null)" = "$TOKEN" ]; then
        rm -f "$LOCK/owner"
        rmdir "$LOCK" || echo "install.sh: warning: cannot remove $LOCK" >&2
      else
        echo "install.sh: warning: $LOCK belongs to another install; left in place" >&2
      fi' EXIT
printf '%s\n' "$TOKEN" > "$LOCK/owner"
if [ ! -e "$DEST" ] && [ -e "$PREV" ]; then
  if mv "$PREV" "$DEST"; then
    echo "install.sh: restored the app left in $PREV by an interrupted run" >&2
  else
    echo "install.sh: cannot restore the app left in $PREV by an interrupted run; it is still in $PREV" >&2
    exit 1
  fi
fi

PRODUCT="$PWD/$PROD_DIR/OpenNTFS.app"
LOG="$PWD/build/install-$CONFIG.log"
rm -rf "$PRODUCT"            # never install a product this run did not build

xcodegen generate >/dev/null
rc=0
xcodebuild -project OpenNTFS.xcodeproj -scheme OpenNTFS -configuration "$CONFIG" \
	-derivedDataPath build/dd -allowProvisioningUpdates build > "$LOG" 2>&1 || rc=$?
# Show the interesting lines; grep finding none (exit 1) is fine, >1 is an error.
grc=0
grep -E "error|warning: .*(App|Extension|Core)/|BUILD (SUCCEEDED|FAILED)" "$LOG" || grc=$?
[ "$grc" -le 1 ] || { echo "install.sh: cannot read $LOG" >&2; exit 1; }
[ "$rc" -eq 0 ] || { echo "install.sh: xcodebuild failed (exit $rc); nothing installed; log: $LOG" >&2; exit 1; }
grep -q "BUILD SUCCEEDED" "$LOG" || { echo "install.sh: no BUILD SUCCEEDED in $LOG; nothing installed" >&2; exit 1; }

missing=""
for f in Contents/MacOS/OpenNTFS Contents/MacOS/OpenNTFSHelper \
         Contents/Extensions/OpenNTFSModule.appex/Contents/MacOS/OpenNTFSModule; do
  [ -f "$PRODUCT/$f" ] && [ -x "$PRODUCT/$f" ] || missing="$missing $f"
done
for f in Contents/Info.plist Contents/Extensions/OpenNTFSModule.appex/Contents/Info.plist; do
  [ -f "$PRODUCT/$f" ] || missing="$missing $f"
done
nplist=$(find "$PRODUCT/Contents/Library/LaunchDaemons" -maxdepth 1 -name '*.plist' -type f 2>/dev/null | wc -l | tr -d ' ')
[ "$nplist" -eq 1 ] || missing="$missing Contents/Library/LaunchDaemons/*.plist(found $nplist)"
[ -z "$missing" ] || { echo "install.sh: incomplete product, nothing installed; missing:$missing" >&2; exit 1; }

# If PREV still exists here, DEST exists too (restored above otherwise): PREV
# is the old app of a run that got the new one into place but did not finish,
# so it is redundant.
rm -rf "$STAGE" "$PREV"
if ! cp -R "$PRODUCT" "$STAGE"; then
  rm -rf "$STAGE"
  echo "install.sh: copying the new app failed; installed app left in place" >&2; exit 1
fi
# pkill: 0 = killed, 1 = no such process; anything else is an error.
prc=0; pkill -x OpenNTFS || prc=$?
[ "$prc" -le 1 ] || { rm -rf "$STAGE"; echo "install.sh: pkill failed (exit $prc); installed app left in place" >&2; exit 1; }
if [ -e "$DEST" ] && ! mv "$DEST" "$PREV"; then
  rm -rf "$STAGE"
  echo "install.sh: moving the installed app aside failed; it is left in place" >&2; exit 1
fi
if ! mv "$STAGE" "$DEST"; then
  if [ ! -e "$PREV" ]; then
    rm -rf "$STAGE"; echo "install.sh: moving the new app into place failed; there was no previous app" >&2; exit 1
  fi
  if mv "$PREV" "$DEST"; then
    rm -rf "$STAGE"; echo "install.sh: moving the new app into place failed; previous app restored" >&2; exit 1
  fi
  echo "install.sh: moving the new app into place failed and restoring failed too; the previous app is in $PREV and the next run restores it" >&2; exit 1
fi
rm -rf "$PREV"
# Unregister the build copy. Its exit status for a copy that was never
# registered is not documented, so it is reported, not judged.
urc=0; "$LSR" -u "$PRODUCT" || urc=$?
[ "$urc" -eq 0 ] || echo "install.sh: note: lsregister -u on the build copy exited $urc" >&2
rm -rf "$PRODUCT"
"$LSR" -f "$DEST"
open -g "$DEST"
echo "installed $DEST ($CONFIG)"
