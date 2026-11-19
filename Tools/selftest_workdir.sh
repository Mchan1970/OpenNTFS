# Sourced by the offline self-tests. Creates the test's work directory
# safely and prints its path:
#   WORKDIR="$(selftest_workdir "$ROOT" maint-repair-selftest)"
# 1. The parent must be <repo>/build with no symlink anywhere in between:
#    realpath(<repo>/build) == realpath(<repo>) + "/build", and it must not
#    resolve under /Applications, /Volumes, /dev or /System.
# 2. The directory is created with mktemp -d (exclusive: never an existing
#    path, mode 0700) and must resolve to a direct child of that parent.
# Nothing is created before check 1 except <repo>/build itself, which is the
# repository's own build output directory (.gitignore).
# SPDX-License-Identifier: GPL-2.0-or-later
selftest_workdir() {
  local root="${1:?repo root}" prefix="${2:?prefix}" parent dir
  mkdir -p "$root/build"
  parent="$(python3 -I - "$root" <<'PY'
import os, sys
root = os.path.realpath(sys.argv[1])
parent = os.path.realpath(os.path.join(sys.argv[1], "build"))
if parent != os.path.join(root, "build"):
    raise SystemExit(f"FAIL: build dir is redirected: {parent}")
for bad in ("/Applications", "/Volumes", "/dev", "/System"):
    if parent == bad or parent.startswith(bad + "/"):
        raise SystemExit(f"FAIL: build dir under forbidden path: {parent}")
print(parent)
PY
)" || return 1
  dir="$(mktemp -d "$parent/$prefix.XXXXXX")" || return 1
  python3 -I - "$dir" "$parent" <<'PY' || { echo "FAIL: workdir check" >&2; return 1; }
import os, sys
d, parent = os.path.realpath(sys.argv[1]), sys.argv[2]
if os.path.dirname(d) != parent or os.path.islink(sys.argv[1]):
    raise SystemExit(f"FAIL: workdir is not a direct child of {parent}: {d}")
PY
  printf '%s\n' "$dir"
}
