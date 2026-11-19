# OpenNTFS

Read-write NTFS for macOS 27+ on Apple silicon, built as an FSKit file system extension
(no kernel extension, no macFUSE, SIP stays on). The NTFS engine is
[libntfs-3g](https://github.com/tuxera/ntfs-3g); this project adds a C bridge,
the FSKit module and a menu bar app.

## Layout

| Path | What |
|---|---|
| `Vendor/ntfs-3g` | upstream ntfs-3g sources (unmodified) |
| `Core/` | `ntfs_bridge` (inode based API over libntfs-3g), `ntfs_maint` (in-process mkntfs / ntfsfix), hand written `config.h` |
| `Extension/` | FSKit module (`openntfs`) |
| `App/` | menu bar app: volume list, mount / unmount / verify / repair |
| `Tools/ntfstool.c` | command line tool that drives the bridge on a disk image, incl. a randomized stress test |
| `Tools/install.sh` | build, install to /Applications, avoid duplicate registrations |

## Install a release

Requires macOS 27 or later on a Mac with Apple silicon (arm64 only).

Download `OpenNTFS-<version>.zip` from the GitHub release (Developer ID signed
and notarized), unzip it, move `OpenNTFS-<version>/OpenNTFS.app` to
`/Applications` and open it. The archive also contains the license and a
`SOURCE.txt` that points to the matching source code. Then, once:

1. Enable the file system extension (see below).
2. In the app, turn on "Privileged helper for Verify / Repair" and allow
   OpenNTFS under System Settings → General → Login Items & Extensions →
   Allow in the Background.
3. Add `/Applications/OpenNTFS.app` under System Settings → Privacy &
   Security → Full Disk Access. Without it the helper cannot change the
   owner of USB device nodes and Verify / Repair fails with "Operation not
   permitted".

These grants are tied to the app's code signature. Switching between a
release and a locally built copy (different signature) requires doing all
three again. After replacing the app, eject and re-plug any mounted NTFS
disk so it is served by the new extension.

### Upgrading from 0.1.1

0.2.0 has a new app identifier, so macOS treats it as a different app and
none of the 0.1.1 grants carry over. Upgrade in this order:

1. Eject every NTFS disk.
2. In OpenNTFS 0.1.1, turn off "Privileged helper for Verify / Repair",
   then quit the app.
3. Delete the old `OpenNTFS.app` from `/Applications`, install 0.2.0 as
   above and restart the Mac.
4. Do the three grants above again. Under Full Disk Access, remove the old
   OpenNTFS entry. If two entries with the same name are listed and you
   cannot tell which one is the old one, remove both and add
   `/Applications/OpenNTFS.app` again.

## Build and install from source

    brew install xcodegen
    Tools/install.sh

Then enable the module: System Settings → General → Login Items & Extensions →
Extensions **By Category** → File System Extensions → OpenNTFS.
(The toggle in the "By App" view fails with EPERM on macOS 27.2.)

Once enabled, DiskArbitration mounts NTFS volumes with OpenNTFS automatically
under `/Volumes`. Turn the module off in the same panel to go back to the
system's read-only driver.

For a release build use `CONFIG=Release Tools/install.sh`.

### Building with your own Apple developer team

The project is set up for its maintainer's signing team. Bundle identifiers
are unique across teams, so to build it yourself you must replace both the
team ID and the bundle ID prefix, and keep them consistent everywhere:

| What | Where |
|---|---|
| Team ID `265UPCYPZ6` | `project.yml` (`DEVELOPMENT_TEAM`), `Shared/HelperConstants.swift` (`teamID`; the helper only accepts XPC clients signed by this team) |
| Bundle ID prefix `io.github.mchan1970` | `project.yml` (`bundleIdPrefix` and the three `PRODUCT_BUNDLE_IDENTIFIER`s), `Shared/HelperConstants.swift` (`machServiceName`, `daemonPlistName`, `appBundleID`), `App/Mounter.swift` (`moduleID`), the file name and the contents (`Label`, `AssociatedBundleIdentifiers`, `MachServices`) of `Helper/LaunchDaemons/io.github.mchan1970.OpenNTFS.Helper.plist` |
| Log subsystem (optional) | `Logger(subsystem:)` in `App/Mounter.swift`, `App/OpenNTFSApp.swift`, `Extension/Support.swift` |

`git grep -n -e 265UPCYPZ6 -e io.github.mchan1970` lists every occurrence.
The extension needs the `com.apple.developer.fskit.fsmodule` entitlement
(`Extension/Extension.entitlements`), so your team must be able to provision
it; the project has only been built with the maintainer's team.

## Verify / repair helper

The app first runs `fsck_fskit` as the logged-in user. When the device node is
not accessible (normal for USB disks, which belong to `root:operator`), it asks
a privileged helper (a LaunchDaemon registered through the app's settings; you
approve it under Login Items) to grant the current user temporary access to
that volume's block and raw nodes: read-only for verify, read-write for repair.
The helper restores the original owner and mode right after the check. Grants
are journaled first, so an interrupted grant is restored the next time the
helper starts.

Before granting, the helper asks DiskArbitration itself and only accepts an
unmounted leaf volume (a partition, or an unpartitioned whole disk) that the
OpenNTFS module has recognised (`VolumeKind` = `openntfs`), whose device
numbers match the requested nodes. Parent disks with a partition map, other
file systems, mounted volumes and unknown devices are refused.

## Known limitations

These are accepted design limits, not bugs. None of them comes into play in
normal use; the first three only matter if malware is already running under
your user account.

- The temporary grant goes to your user ID, not to one process. During the
  grant (about 0.1 s for a verify on a USB stick; longer for a repair, capped
  by a timeout) another program running as you could open the raw device.
- The read-only grant (mode 0400) is not enforced against the owner: such a
  program could change the mode while it owns the node.
- Restoring the original permissions does not close file descriptors that
  were opened during the grant.
- The helper trusts DiskArbitration's last probe of the volume. A volume
  that was just reformatted by a raw tool and not yet re-probed is refused
  ("device qualification failed"); unplug and replug it, or mount it once.
- Unplugging and plugging in another disk in the middle of a verify/repair is
  detected by an identity check on restore; the grant is then quarantined
  and reported instead of being applied to the new disk.
- Back up important data before repairing. If Windows was not fully shut down
  (fast startup or hibernation), shut it down fully in Windows first.

## Command line

    mount -F -t openntfs /dev/diskXsY /some/dir
    newfs_fskit -t openntfs -v LABEL /dev/diskXsY      # format (-c bytes, -z full)
    fsck_fskit  -t openntfs -n|-y /dev/diskXsY         # verify / repair (unmounted)

## Testing the core without FSKit

    make
    mkfile -n 256m t.img
    build/ntfstool t.img format Test
    build/ntfstool t.img stress 1 3000

## Behaviour notes

- Case insensitive, case preserving. Names are stored NFC.
- Characters Windows forbids (`" * : < > ? \ |`, trailing space or dot) are
  stored with the same private-use mapping Apple's SMB client uses.
- Extended attributes are stored as NTFS named streams (no `._` files).
- Ownership and POSIX modes are not mapped to NTFS ACLs; chmod/chown succeed
  and are ignored.
- A volume from a hibernated / fast-startup Windows, or with a journal that
  cannot be reset, is mounted read-only.
- Verify / repair is ntfsfix, not a full chkdsk. After a **repair**, Windows
  may ask to "scan and fix" the drive the next time it is plugged in. This is
  intended: like upstream ntfsfix, the repair marks the volume dirty so that
  Windows runs its full chkdsk once. Let it scan. (A verify does not set the
  flag.)
- File data goes through user space; FSKit kernel-offloaded I/O is not
  implemented yet.

## License

GPL-2.0-or-later (required by libntfs-3g).
