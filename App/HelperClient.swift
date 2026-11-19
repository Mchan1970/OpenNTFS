// OpenNTFS - registers and talks to the privileged maintenance helper.
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import ServiceManagement

enum HelperError: LocalizedError {
    case notEnabled
    case requiresApproval
    case connectionFailed(String)
    case remoteFailed(String)
    /// The helper never replied within the RPC timeout. This only means "no
    /// reply arrived" — what the helper actually did (e.g. whether a
    /// prepare grant went through) is UNKNOWN; callers must treat a timed-
    /// out prepare as authorization-unknown.
    case timedOut(TimeInterval)

    var errorDescription: String? {
        switch self {
        case .notEnabled:
            return L("Enable “Privileged helper for Verify / Repair” in the menu, then approve it in Login Items.",
                     "请先在菜单里打开「检查卷 / 修复卷特权助手」，并在登录项中批准。")
        case .requiresApproval:
            return L("Approve the OpenNTFS helper under System Settings → Login Items & Extensions.",
                     "请在系统设置 → 登录项与扩展 中批准 OpenNTFS Helper。")
        case .connectionFailed(let s):
            return L("Helper connection failed: \(s)", "无法连接 Helper：\(s)")
        case .remoteFailed(let s):
            return s
        case .timedOut(let s):
            return L("Helper did not reply within \(Int(s)) s; the call was abandoned — what the helper actually did is unknown.",
                      "Helper 未在 \(Int(s)) 秒内回复；调用已放弃——Helper 实际做了什么未知。")
        }
    }
}

/// Thin wrapper around SMAppService.daemon + NSXPCConnection.
/// @unchecked Sendable: all mutable state (connection / generation) is
/// guarded by `lock`; the timeout handler only calls lock-protected paths.
final class HelperClient: @unchecked Sendable {
    static let shared = HelperClient()

    /// The ONE RPC timeout constant (production default). Every helper call
    /// (ping/prepare/restore) fails with `HelperError.timedOut` after this
    /// many seconds without a reply. Tests may shorten the per-instance
    /// `rpcTimeoutSeconds`; the production default never changes here.
    static let rpcTimeoutDefaultSeconds: TimeInterval = 20
    var rpcTimeoutSeconds: TimeInterval = HelperClient.rpcTimeoutDefaultSeconds

    private let service = SMAppService.daemon(plistName: HelperConstants.daemonPlistName)
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var connectionGeneration: UInt64 = 0

    var status: SMAppService.Status { service.status }

    var isReady: Bool { status == .enabled }

    func register() throws {
        try service.register()
    }

    func unregister() throws {
        try service.unregister()
        invalidate()
    }

    func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func invalidate() {
        lock.lock()
        let c = connection
        connection = nil
        connectionGeneration += 1
        lock.unlock()
        c?.invalidate()
    }

    private func ensureConnection() throws {
        guard status == .enabled else {
            if status == .requiresApproval { throw HelperError.requiresApproval }
            throw HelperError.notEnabled
        }
        lock.lock()
        defer { lock.unlock() }
        if connection == nil {
            let generation = connectionGeneration + 1
            connectionGeneration = generation
            let c = NSXPCConnection(machServiceName: HelperConstants.machServiceName,
                                    options: .privileged)
            c.remoteObjectInterface = NSXPCInterface(with: OpenNTFSHelperProtocol.self)
            c.invalidationHandler = { [weak self] in
                self?.clearConnection(ifGeneration: generation)
            }
            c.interruptionHandler = { [weak self] in
                self?.clearConnection(ifGeneration: generation)
            }
            c.resume()
            connection = c
        }
    }

    private func clearConnection(ifGeneration generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard connectionGeneration == generation else { return }
        connection = nil
    }

    func ping() async throws -> (pid: Int32, uid: UInt32) {
        try ensureConnection()
        return try await withRPCTimeout { once in
            lock.lock()
            let conn = connection
            lock.unlock()
            guard let remote = conn?.remoteObjectProxyWithErrorHandler({ error in
                once.fail(HelperError.connectionFailed(error.localizedDescription))
            }) as? OpenNTFSHelperProtocol else {
                once.fail(HelperError.connectionFailed("no remote proxy"))
                return
            }
            remote.ping { pid, uid in
                once.finish((pid, uid))
            }
        }
    }

    /// Grant this user temporary access on device nodes for fsck_fskit.
    /// `writeAccess` false → verify (0400); true → repair (0600).
    /// UNCLOSED RISK (see OpenNTFSHelperProtocol): the grant is UID-scoped —
    /// same-UID peers can open the node during the lease window, and restore
    /// does not revoke already-open descriptors. Verify never escalates to
    /// a write grant.
    func prepareRawDevice(devicePath: String, writeAccess: Bool) async throws {
        try await withBoolProxy { remote, once in
            remote.prepareRawDevice(atDevicePath: devicePath, writeAccess: writeAccess) { ok, message in
                if ok { once.finish(()) }
                else { once.fail(HelperError.remoteFailed(message)) }
            }
        }
    }

    func restoreRawDevice(devicePath: String) async throws {
        try await withBoolProxy { remote, once in
            remote.restoreRawDevice(atDevicePath: devicePath) { ok, message in
                if ok { once.finish(()) }
                else { once.fail(HelperError.remoteFailed(message)) }
            }
        }
    }

    private func withBoolProxy(
        _ body: (OpenNTFSHelperProtocol, OnceResume<Void>) -> Void
    ) async throws {
        try ensureConnection()
        try await withRPCTimeout { (once: OnceResume<Void>) in
            lock.lock()
            let conn = connection
            lock.unlock()
            guard let remote = conn?.remoteObjectProxyWithErrorHandler({ error in
                once.fail(HelperError.connectionFailed(error.localizedDescription))
            }) as? OpenNTFSHelperProtocol else {
                once.fail(HelperError.connectionFailed("no remote proxy"))
                return
            }
            body(remote, once)
        }
    }

    /// Races `body`'s once-resume against the RPC timeout. On timeout the
    /// continuation fails with `HelperError.timedOut` and the CURRENT
    /// connection is invalidated (a dead launchd-spawn loop would otherwise
    /// leave every later call hanging on the same broken connection too).
    /// A reply that arrives late is dropped by `OnceResume` — it can never
    /// change the already-reported outcome. Internal so the offline tests
    /// can drive a never-replying body with a shortened timeout.
    func withRPCTimeout<T>(_ body: (OnceResume<T>) -> Void) async throws -> T {
        let seconds = rpcTimeoutSeconds
        return try await withCheckedThrowingContinuation { cont in
            let once = OnceResume(cont)
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [weak self] in
                if once.fail(HelperError.timedOut(seconds)) {
                    self?.invalidate()
                }
            }
            body(once)
        }
    }
}

/// One-shot continuation wrapper shared by every helper reply path. Exactly
/// ONE of finish/fail ever resumes; later calls are dropped (their return
/// value says whether THIS call was the one that resumed).
final class OnceResume<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<T, Error>?

    init(_ cont: CheckedContinuation<T, Error>) { self.cont = cont }

    func finish(_ value: T) {
        lock.lock()
        let c = cont; cont = nil
        lock.unlock()
        c?.resume(returning: value)
    }

    /// Returns true when this call resumed the continuation (i.e. it was
    /// still pending — the timeout uses this to invalidate only on ITS win).
    @discardableResult
    func fail(_ error: Error) -> Bool {
        lock.lock()
        let c = cont; cont = nil
        lock.unlock()
        guard let c else { return false }
        c.resume(throwing: error)
        return true
    }
}

extension HelperClient: MaintenanceHelperPort {}
