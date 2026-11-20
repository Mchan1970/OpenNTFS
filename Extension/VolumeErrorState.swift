// OpenNTFS - pure decision logic for flush/release error handoff.
//
// The volume's error-handoff decisions live here so they can be tested
// offline (make extension-error-test): the error ledger, the scheduling
// of pending releases, the fail-stop pre-release of rename/remove, and
// the maintenance gate. No FSKit and no bridge types:
// every C interaction is injected as a closure, errnos cross the API as
// plain Int32 values (positive), and negative errnos coming from the
// bridge are converted at the entry points.
//
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Decision core for one volume. All access must happen under the same
/// lock as the bridge calls it dispatches (`Core.sync`).
final class VolumeErrorState {

    /// The earliest error that has not been reported at a boundary yet
    /// (positive errno, 0 = none).
    private var stored: Int32 = 0

    /// Inodes whose release failed during a reclaim cleanup and must be
    /// retried by the next releasePending pass.
    private(set) var pendingReleases: Set<UInt64> = []

    // MARK: - Error ledger

    /// A failure at a position without an error channel. Only the
    /// unmount callback uses this: its ntfsb_sync error
    /// cannot be replied, so it is kept here for the next reporting
    /// boundary. Flush and release failures are bookkept by the C
    /// ledger of the bridge, not here. Only the earliest unreported
    /// error is kept.
    func record(_ error: Int32) {
        let e = abs(error)
        if stored == 0 && e != 0 {
            stored = e
        }
    }

    /// Reporting boundary (synchronize / deactivateVolume /
    /// unloadResource): combines this attempt's own result with the
    /// ledger, where a stored error outranks this attempt's own, and
    /// returns the errno to report.
    func boundary(_ current: Int32) -> Int32 {
        let cur = abs(current)
        if stored != 0 {
            // The stored error outranks this attempt; a failure of this
            // attempt becomes the next unreported one.
            let out = stored
            stored = cur
            return out
        }
        return cur
    }

    // MARK: - Pending releases

    /// A reclaim cleanup failed to release @ino: remember it for the
    /// next releasePending pass.
    func releaseFailedDuringReclaim(_ ino: UInt64) {
        pendingReleases.insert(ino)
    }

    /// A lookup recreated an item for @ino: when a release is still
    /// pending, the new item inherits needsRelease and the ino leaves
    /// the pending set. Returns whether a release was pending.
    func lookupInheritsPendingRelease(_ ino: UInt64) -> Bool {
        pendingReleases.remove(ino) != nil
    }

    /// An MFT record was recycled by create: a pending release for it
    /// can never be retried. Returns whether a release was pending (the
    /// caller logs that case).
    func discardPendingRelease(_ ino: UInt64) -> Bool {
        pendingReleases.remove(ino) != nil
    }

    /// One releasePending pass: every flagged item first, then every
    /// pending reclaimed ino, each exactly once. A successful release
    /// clears the flag / removes the pending entry; a failure survives
    /// for the next pass. Release failures are NOT recorded here: the
    /// bridge records every flush/release failure in its own C ledger,
    /// which hands the error out at the ntfsb_sync boundary
    /// - recording it here as well would report a one-time error twice.
    /// During shutdown the flags are cleared regardless of the outcome
    /// (`clearAlways`).
    func releasePending(flagged: [(ino: UInt64, clear: () -> Void)],
                        clearAlways: Bool = false,
                        release: (UInt64) -> Int32) {
        var done = Set<UInt64>()
        for f in flagged where !done.contains(f.ino) {
            done.insert(f.ino)
            if release(f.ino) != 0 {
                if !clearAlways { continue }  // the flag survives for a retry
            } else {
                // The same ino may also sit in pendingReleases (a reclaim
                // failed before this item reappeared): one successful
                // release settles both entries.
                pendingReleases.remove(f.ino)
            }
            f.clear()
        }
        for ino in pendingReleases.sorted() where !done.contains(ino) {
            done.insert(ino)
            if release(ino) == 0 {
                pendingReleases.remove(ino)
            }
        }
    }

    /// The reclaim cleanup decision: release the dying item
    /// once. On failure the errno is returned for the reclaim reply and
    /// the ino becomes pending for the next releasePending pass; on
    /// success 0 is returned.
    func reclaimRelease(ino: UInt64, needsRelease: Bool,
                        release: (UInt64) -> Int32) -> Int32 {
        guard needsRelease else { return 0 }
        let r = abs(release(ino))
        if r != 0 {
            pendingReleases.insert(ino)
            return r
        }
        return 0
    }

    // MARK: - Fail-stop pre-release

    /// A rename over an existing item and a removal must first release
    /// the previous writer. Runs `action` only when that release
    /// succeeded (or nothing needed releasing) and returns 0; on a
    /// failed release the action does not run and the release errno is
    /// returned.
    func releaseBeforeAction(ino: UInt64, needsRelease: Bool,
                             release: (UInt64) -> Int32,
                             _ action: () throws -> Void) rethrows -> Int32 {
        if needsRelease {
            let r = abs(release(ino))
            if r != 0 {
                return r
            }
        }
        try action()
        return 0
    }

    // MARK: - Maintenance gate

    /// Check, repair and format must not run on a volume that did not
    /// shut down cleanly. Runs `work` only for a clean shutdown result
    /// and returns 0; otherwise the work does not run and the shutdown
    /// errno is returned.
    static func gateMaintenance(shutdownResult: Int32,
                                _ work: () throws -> Void) rethrows -> Int32 {
        let err = abs(shutdownResult)
        if err != 0 {
            return err
        }
        try work()
        return 0
    }

    // MARK: - Shutdown

    /// The shutdown decision: release everything (failures recorded -
    /// there is no channel here), unmount, combine the unmount result
    /// with the ledger, and clear the pending set (the volume
    /// is gone). Returns the errno to report through unloadResource.
    func shutdownResult(releasePending: () -> Void, unmount: () -> Int32) -> Int32 {
        releasePending()               // failures are recorded above
        let out = boundary(unmount())  // consume the ledger, terminal boundary
        pendingReleases.removeAll()    // the volume is gone
        return out
    }
}
