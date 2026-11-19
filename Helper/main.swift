// OpenNTFS - privileged LaunchDaemon for raw-disk maintenance.
// SPDX-License-Identifier: GPL-2.0-or-later

import Darwin
import Foundation
import OSLog
import Security

private let log = Logger(subsystem: HelperConstants.machServiceName, category: "lifecycle")

private let clientRequirement =
    "identifier \"\(HelperConstants.appBundleID)\" and anchor apple generic " +
    "and certificate leaf[subject.OU] = \"\(HelperConstants.teamID)\""

private func clientIsAuthorized(_ connection: NSXPCConnection) -> Bool {
    var token = OpenNTFSConnectionAuditToken(connection)
    let tokenData = Data(bytes: &token, count: MemoryLayout<audit_token_t>.size)
    // kSecGuestAttributeAudit: CFData wrapping audit_token_t (preferred over PID).
    let attributes = [kSecGuestAttributeAudit as String: tokenData] as CFDictionary
    var code: SecCode?
    guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
          let code else { return false }

    var requirement: SecRequirement?
    guard SecRequirementCreateWithString(clientRequirement as CFString, [], &requirement) == errSecSuccess,
          let requirement else { return false }

    return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
}

final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection conn: NSXPCConnection) -> Bool {
        guard clientIsAuthorized(conn) else {
            log.error("rejected pid=\(conn.processIdentifier, privacy: .public)")
            return false
        }
        let owner = UUID()
        let service = HelperService(owner: owner, connection: conn)
        conn.exportedInterface = NSXPCInterface(with: OpenNTFSHelperProtocol.self)
        conn.exportedObject = service
        conn.invalidationHandler = {
            DeviceLeaseStore.shared.releaseAll(ownedBy: owner)
            log.info("connection invalidated; leases released owner=\(owner.uuidString, privacy: .public)")
        }
        conn.interruptionHandler = {
            DeviceLeaseStore.shared.releaseAll(ownedBy: owner)
            log.info("connection interrupted; leases released owner=\(owner.uuidString, privacy: .public)")
        }
        conn.resume()
        log.info("accepted pid=\(conn.processIdentifier, privacy: .public) owner=\(owner.uuidString, privacy: .public)")
        return true
    }
}

final class HelperService: NSObject, OpenNTFSHelperProtocol {
    private let owner: UUID
    private weak var connection: NSXPCConnection?

    init(owner: UUID, connection: NSXPCConnection) {
        self.owner = owner
        self.connection = connection
    }

    func ping(withReply reply: @escaping (Int32, UInt32) -> Void) {
        reply(getpid(), getuid())
    }

    func prepareRawDevice(atDevicePath devicePath: String,
                          writeAccess: Bool,
                          withReply reply: @escaping (Bool, String) -> Void) {
        guard let key = DevicePathRules.canonicalKey(devicePath) else {
            reply(false, "refused: invalid device path")
            return
        }
        guard let connection else {
            reply(false, "refused: no connection")
            return
        }
        // Defense in depth: the store checks this too, under its own lock.
        // Both "mounted" and "cannot tell" refuse the grant.
        switch MountQuery.state(forDevice: key) {
        case .mounted:
            reply(false, "refused: device is mounted")
            return
        case .queryFailed(let e):
            reply(false, "refused: mount table query failed: \(e)")
            return
        case .unmounted:
            break
        }
        let uid = OpenNTFSConnectionEUID(connection)
        let gid = OpenNTFSConnectionEGID(connection)
        var nodes = [key]
        if let r = DevicePathRules.rdiskCompanion(for: key) { nodes.append(r) }
        let (ok, message) = DeviceLeaseStore.shared.prepare(
            key: key,
            nodes: nodes,
            owner: owner,
            clientUID: uid,
            clientGID: gid,
            writeAccess: writeAccess,
            timeout: HelperConstants.prepareLeaseTimeoutSeconds)
        reply(ok, message)
    }

    func restoreRawDevice(atDevicePath devicePath: String,
                          withReply reply: @escaping (Bool, String) -> Void) {
        guard let key = DevicePathRules.canonicalKey(devicePath) else {
            reply(false, "refused: invalid device path")
            return
        }
        let (ok, message) = DeviceLeaseStore.shared.restore(key: key, owner: owner)
        reply(ok, message)
    }
}

log.info("OpenNTFSHelper starting pid=\(getpid(), privacy: .public) uid=\(getuid(), privacy: .public)")

guard getuid() == 0 else {
    log.error("refusing to run as non-root uid=\(getuid(), privacy: .public)")
    exit(1)
}

// Startup recovery is EXPLICIT and completes before the listener accepts any
// maintenance RPC (C-issue). A degraded journal (unreadable/corrupt/invalid,
// kept in place) does not exit the daemon: it stays up and refuses new
// grants with an explicit message instead of letting launchd restart-loop
// and the client see opaque connection failures.
switch DeviceLeaseStore.bootstrapShared() {
case .clean:
    log.info("lease journal: clean start (no journal)")
case .recovered:
    log.info("lease journal: loaded; first restore attempts completed; incomplete ones keep recovering")
case .degraded(let problems):
    log.error("lease journal DEGRADED; new grants refused: \(problems.joined(separator: "; "), privacy: .public)")
}

let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
let delegate = HelperListenerDelegate()
listener.delegate = delegate
listener.resume()
dispatchMain()
