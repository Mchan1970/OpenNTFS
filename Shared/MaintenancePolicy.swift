// OpenNTFS - pure remount-policy decisions shared by the app and offline tests.
// SPDX-License-Identifier: GPL-2.0-or-later
//
// G-issue contract: the pre-maintenance access policy is the ceiling for the
// post-maintenance state. An externally remounted volume is verified against
// it (never silently accepted), and a policy-violating read-write mount is
// corrected with a NON-force unmount whose result must be reported honestly.

import Foundation

enum MaintenancePolicy {
    /// Pre-maintenance access policy ceiling. Foreign or originally
    /// read-only volumes remount read-only; only a volume that was mounted
    /// read-write by *our* module may come back read-write.
    static func expectsReadOnly(wasOurs: Bool, wasReadOnly: Bool) -> Bool {
        wasReadOnly || !wasOurs
    }

    /// What to do with a mount that already exists when remount is requested
    /// (an external actor — Finder, another driver, our auto-mount timer —
    /// may have won the race).
    enum ExistingMountDecision: Equatable {
        /// Compliant with the pre-check policy; leave it alone.
        case accept
        /// Read-write (or foreign) mount where read-only is expected.
        /// Correct with a non-force unmount, then remount read-only.
        case unmountAndRemountReadOnly
        /// Was ours read-write; current mount is not ours-read-write.
        /// Take it back through the normal (never-force) OpenNTFS path.
        case takeoverReadWrite
    }

    static func decisionForExistingMount(wasOurs: Bool,
                                         wasReadOnly: Bool,
                                         mountedByOurs: Bool,
                                         mountedReadOnly: Bool) -> ExistingMountDecision {
        if expectsReadOnly(wasOurs: wasOurs, wasReadOnly: wasReadOnly) {
            return mountedReadOnly ? .accept : .unmountAndRemountReadOnly
        }
        return (mountedByOurs && !mountedReadOnly) ? .accept : .takeoverReadWrite
    }

    /// How to report a corrective (non-force) unmount of a policy-violating
    /// read-write mount. A failed corrective unmount MUST be reported as
    /// "still mounted read-write" — never as unmounted.
    enum CorrectiveUnmountOutcome: Equatable {
        case remountPerPolicy
        case reportStillMountedReadWrite
    }

    static func afterCorrectiveUnmount(unmountSucceeded: Bool) -> CorrectiveUnmountOutcome {
        unmountSucceeded ? .remountPerPolicy : .reportStillMountedReadWrite
    }
}
