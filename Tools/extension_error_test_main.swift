// Offline tests for the pure error-handoff logic in
// Extension/VolumeErrorState.swift, compiled without FSKit: every
// bridge call is injected as a closure. Every assertion prints ok/FAIL
// and the process exits non-zero on any failure.
//
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

var failures = 0
var currentTest = ""

func expect(_ cond: Bool, _ msg: String, line: UInt = #line) {
    if cond {
        print("ok: [\(currentTest)] \(msg)")
    } else {
        failures += 1
        print("FAIL: [\(currentTest)] line \(line): \(msg)")
    }
}

func runTest(_ name: String, _ body: () -> Void) {
    currentTest = name
    print("== \(name)")
    body()
}

@main
struct ExtensionErrorTest {
    static func main() {
        runTest("S1 unmount handoff") {
            // unmount(replyHandler:) has no error channel: the EIO of its
            // final sync is recorded.
            let s = VolumeErrorState()
            s.record(-EIO)
            // deactivateVolume: the sync succeeds, the stored error is
            // reported once.
            let deactivate = s.boundary(0)
            expect(deactivate == EIO,
                   "deactivateVolume returns the handed-off EIO once (got \(deactivate))")
            // unloadResource: nothing is left to report.
            let unload = s.shutdownResult(releasePending: {}, unmount: { 0 })
            expect(unload == 0,
                   "unloadResource afterwards returns 0, no double report (got \(unload))")
        }

        runTest("S2 ledger priority") {
            let s = VolumeErrorState()
            s.record(-EIO)                    // unreported EIO in the ledger
            let first = s.boundary(-ENOSPC)   // synchronize itself fails ENOSPC
            expect(first == EIO,
                   "synchronize reports the stored EIO, not the new ENOSPC (got \(first))")
            let second = s.boundary(0)        // next synchronize succeeds
            expect(second == ENOSPC,
                   "the next synchronize reports the kept ENOSPC (got \(second))")
            let third = s.boundary(0)
            expect(third == 0, "and after that 0 (got \(third))")
        }

        runTest("S3 retry after reclaim") {
            let s = VolumeErrorState()
            var calls: [UInt64] = []
            var failFirst = true
            let release: (UInt64) -> Int32 = { ino in
                calls.append(ino)
                if failFirst {
                    failFirst = false
                    return -EIO
                }
                return 0
            }
            // The reclaim cleanup releases ino 42 and fails; the reply
            // must carry the error and the ino must be remembered.
            let reply = s.reclaimRelease(ino: 42, needsRelease: true,
                                         release: release)
            expect(reply == EIO,
                   "the reclaim reply returns the release error (got \(reply))")
            expect(s.pendingReleases.contains(42),
                   "the failed release of the reclaimed ino is remembered")

            // releasePending: flagged items first, then the reclaimed ino.
            var cleared10 = false
            let passStart = calls.count
            s.releasePending(flagged: [(ino: 10, clear: { cleared10 = true })],
                             release: release)
            expect(Array(calls.dropFirst(passStart)) == [10, 42],
                   "releasePending retries the reclaimed ino after the items (got \(calls))")
            expect(cleared10, "a successful release clears the item flag")
            expect(!s.pendingReleases.contains(42),
                   "the successful retry removes the pending entry")
            let count = calls.count
            s.releasePending(flagged: [], release: release)
            expect(calls.count == count,
                   "a succeeded release is not called again (got \(calls.count - count) more)")

            // A release that keeps failing keeps the flag; the Swift
            // side no longer records it (the C ledger owns the error
            // and hands it out at the ntfsb_sync boundary).
            let s2 = VolumeErrorState()
            var cleared7 = false
            s2.releasePending(flagged: [(ino: 7, clear: { cleared7 = true })],
                              release: { _ in -EIO })
            expect(!cleared7, "needsRelease survives a failed release")
            expect(s2.boundary(0) == 0,
                   "the Swift side does not stash the release error (the "
                   + "C ledger owns it)")
        }

        runTest("S4 fail-stop pre-release") {
            let s = VolumeErrorState()
            var actionRan = false
            let stopped = s.releaseBeforeAction(ino: 5, needsRelease: true,
                                                release: { _ in -EIO }) {
                actionRan = true
            }
            expect(stopped == EIO && !actionRan,
                   "a failed pre-release stops the action and returns EIO "
                   + "(r=\(stopped), actionRan=\(actionRan))")
            var ran = false
            let passed = s.releaseBeforeAction(ino: 5, needsRelease: true,
                                               release: { _ in 0 }) {
                ran = true
            }
            expect(passed == 0 && ran,
                   "a successful pre-release lets the action run")
            var releaseCalls: [UInt64] = []
            var ranDirect = false
            let skipped = s.releaseBeforeAction(ino: 9, needsRelease: false,
                                                release: { releaseCalls.append($0); return 0 }) {
                ranDirect = true
            }
            expect(skipped == 0 && ranDirect && releaseCalls.isEmpty,
                   "with nothing to release the action runs directly")
        }

        runTest("S5 maintenance gate") {
            // the gated closure is the actual scheduling of the tool run
            var scheduled = 0
            let blocked = VolumeErrorState.gateMaintenance(shutdownResult: -EIO) {
                scheduled += 1
            }
            expect(blocked == EIO && scheduled == 0,
                   "a failed shutdown does not schedule the maintenance task "
                   + "and returns the error (g=\(blocked), scheduled=\(scheduled))")
            let allowed = VolumeErrorState.gateMaintenance(shutdownResult: 0) {
                scheduled += 1
            }
            expect(allowed == 0 && scheduled == 1,
                   "a clean shutdown schedules the maintenance task exactly once")
        }

        runTest("pending release bookkeeping") {
            // A re-lookup inherits the pending release and leaves the set.
            let s = VolumeErrorState()
            s.releaseFailedDuringReclaim(100)
            expect(s.lookupInheritsPendingRelease(100),
                   "a re-looked-up ino inherits needsRelease")
            expect(!s.pendingReleases.contains(100),
                   "and leaves the pending set")
            // A recycled MFT record drops its pending entry.
            s.releaseFailedDuringReclaim(101)
            expect(s.discardPendingRelease(101),
                   "a recycled MFT record drops its pending entry")
            expect(!s.pendingReleases.contains(101), "removed from the set")
        }

        runTest("pending entry covered by a flagged item") {
            // The same ino can be flagged on an item AND pending after a
            // failed reclaim: one successful release must settle both,
            // otherwise the pending entry could never be drained.
            let s = VolumeErrorState()
            s.releaseFailedDuringReclaim(42)
            var cleared = false
            var calls: [UInt64] = []
            s.releasePending(flagged: [(ino: 42, clear: { cleared = true })],
                             release: { calls.append($0); return 0 })
            expect(calls == [42],
                   "the ino is released exactly once (got \(calls))")
            expect(cleared, "the item flag is cleared")
            expect(!s.pendingReleases.contains(42),
                   "a successful release through the item also drops the "
                   + "pending entry")
        }

        runTest("S6 single handoff through the C ledger") {
            // releasePending inside a synchronize: the release fails once
            // and the C ledger (entering here as the boundary input)
            // hands out its EIO although its own retry already succeeded.
            // The Swift side must not record the release error again, or
            // the same one-time error is reported twice.
            let s = VolumeErrorState()
            var failOnce = true
            let release: (UInt64) -> Int32 = { _ in
                if failOnce {
                    failOnce = false
                    return -EIO
                }
                return 0
            }
            var cleared = false
            s.releasePending(flagged: [(ino: 5, clear: { cleared = true })],
                             release: release)
            expect(!cleared, "the flag survives the failed release")
            let first = s.boundary(-EIO)
            expect(first == EIO,
                   "the one-time error is reported once (got \(first))")
            s.releasePending(flagged: [(ino: 5, clear: { cleared = true })],
                             release: release)
            expect(cleared, "the retry clears the flag")
            let second = s.boundary(0)
            expect(second == 0,
                   "and is not reported a second time (got \(second))")
        }

        print("extension-error tests finished: \(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
