// OpenNTFS - XPC protocol for the privileged maintenance helper.
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Methods the root LaunchDaemon exposes to the menu-bar app.
///
/// FSKit detail: a root daemon cannot see user FSModules; the GUI app can, but
/// cannot open `/dev/disk*` (EPERM). Flow: helper grants the *calling user*
/// temporary access → app runs `fsck_fskit` → helper restores.
///
/// Trust boundary (explicit; UNCLOSED RISK, not a solved property):
/// grants are **UID-scoped** (chown to the caller + chmod), not
/// process-scoped and not exclusivity-enforcing:
/// - While a lease is open, ANY process running as the granted UID — and any
///   root process — can open the node. `0400` (verify) / `0600` (repair) are
///   the initial modes for the normal call path; they do NOT stop a hostile
///   same-UID process from obtaining the same access.
/// - Restoring uid/gid/mode does not revoke file descriptors already opened
///   during the lease; the helper cannot recall them.
/// - The window is bounded by the client's restore RPC, connection drop, the
///   lease timeout, and (after a helper crash) journal-based recovery on the
///   next start — not by anything in this protocol.
///
/// Verify always requests a read-only grant (`writeAccess: false`); the app
/// never escalates a verify to a write grant on EPERM.
///
/// Destructive `format` is intentionally not in this protocol until a gated UI
/// and stronger device-identity checks exist.
@objc protocol OpenNTFSHelperProtocol {
    func ping(withReply reply: @escaping (_ pid: Int32, _ uid: UInt32) -> Void)

    /// Temporarily grant the calling user access to `/dev/disk…` (+ rdisk).
    /// `writeAccess` false → mode 0400 (verify); true → 0600 (repair).
    /// Idempotent for the same connection + same active lease; concurrent
    /// prepare from another client, reuse of a failed/restoring lease, a
    /// mounted or unqueryable device, or an untrusted lease journal are all
    /// refused.
    func prepareRawDevice(atDevicePath devicePath: String,
                          writeAccess: Bool,
                          withReply reply: @escaping (_ ok: Bool, _ message: String) -> Void)

    /// Restore modes/ownership saved by `prepareRawDevice` for this path.
    /// Returns ok=false if any restore chown/chmod failed (lease kept; helper
    /// continues internal recovery independently of the connection), if the
    /// lease is quarantined (device identity unconfirmed), or if there is no
    /// lease. The message always says which.
    func restoreRawDevice(atDevicePath devicePath: String,
                          withReply reply: @escaping (_ ok: Bool, _ message: String) -> Void)
}
