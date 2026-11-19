// OpenNTFS - shared identifiers for the privileged maintenance helper.
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

enum HelperConstants {
    /// LaunchDaemon Label and Mach service name (must match the embedded plist).
    static let machServiceName = "io.github.mchan1970.OpenNTFS.Helper"
    /// Filename under Contents/Library/LaunchDaemons/ (include .plist).
    static let daemonPlistName = "io.github.mchan1970.OpenNTFS.Helper.plist"
    /// Main app bundle id; used when validating XPC clients.
    static let appBundleID = "io.github.mchan1970.OpenNTFS"
    /// DEVELOPMENT_TEAM from project.yml.
    static let teamID = "265UPCYPZ6"
    /// FSKit type name passed to fsck_fskit / newfs_fskit.
    static let fsTypeName = "openntfs"
    /// Max time an active prepare lease may stay open before the helper restores.
    static let prepareLeaseTimeoutSeconds: TimeInterval = 120
    /// Retry interval while a restore/rollback remains incomplete.
    static let restoreRetrySeconds: TimeInterval = 5
    /// Durable lease journal (survives Helper crash; restored on next launch).
    static let leaseJournalPath = "/var/db/OpenNTFSHelper/leases.json"
}
