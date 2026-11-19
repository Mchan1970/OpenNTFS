// OpenNTFS - prepare/restore leases for raw device nodes.
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Unclosed trust boundary (documented, not claimed solved): grants are
// UID-scoped (chown to the caller + chmod 0400/0600). While a lease is open,
// ANY process of that UID — and any root process — can open the node; the
// modes are the initial state for the normal call path, not a boundary
// against hostile same-UID code. Restoring ownership/mode does not revoke
// file descriptors already opened during the lease. The lease window is
// bounded by client restore, connection drop, or the lease timeout; crash
// recovery re-runs from the journal on the next helper start. These limits
// are listed under "Known limitations" in the README.

import Darwin
import Foundation
import OSLog

private let leaseLog = Logger(subsystem: HelperConstants.machServiceName, category: "lease")

/// One saved node under a prepare lease. `rdev`/`fileType`/`ino`/`dev`/`birth`
/// together identify the *device node instance*: recovery refuses to
/// chown/chmod when the path now names a different node (replug, reboot,
// number reuse) and quarantines the record instead.
struct SavedNode: Codable, Equatable {
    let path: String
    let mode: mode_t          // full st_mode including file type
    let uid: uid_t
    let gid: gid_t
    let rdev: dev_t           // st_rdev; must be non-zero for a device node
    let fileType: mode_t      // S_IFCHR / S_IFBLK
    let ino: UInt64           // devfs node identity (stable within one boot)
    let dev: dev_t            // st_dev of the node's filesystem (same boot)
    let birthSec: Int64       // st_birthtimespec; 0 when unavailable
    let birthNsec: Int32
}

/// All external effects of the lease store. Production uses `LeaseEffects()`
/// (real stat/chown/chmod, durable journal file, Dispatch timers, os_log);
/// offline tests inject recording stubs so no real node, file, timer or
/// mount query is ever touched.
struct LeaseEffects {
    var statNode: (String) -> stat? = { path in
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return st
    }
    /// Read-only DA fact collection for the qualification gate (the six
    /// conditions in DeviceQualification.swift). Default = the real collector
    /// (DAFactCollector in DeviceQualification.swift); offline tests inject
    /// a recording stub so no DA session is ever created in tests.
    var collectDAFacts: (String) -> DACollectionResult = { bsdName in
        DAFactCollector.collect(bsdName: bsdName)
    }
    var chownNode: (String, uid_t, gid_t) -> Int32 = { path, uid, gid in
        chown(path, uid, gid)
    }
    var chmodNode: (String, mode_t) -> Int32 = { path, mode in
        chmod(path, mode)
    }
    /// Reads the journal. Returns nil when it does not exist. Throws when
    /// unreadable — the caller must keep the file in place and stop granting.
    var readJournal: () throws -> Data? = {
        try JournalFile.read(path: HelperConstants.leaseJournalPath)
    }
    /// Durably replaces the journal (fsync of file and directory). A return
    /// without throwing is the only definition of "persisted" used here.
    var writeJournal: (Data) throws -> Void = { data in
        try JournalFile.write(path: HelperConstants.leaseJournalPath, data: data)
    }
    var schedule: (_ delay: TimeInterval, _ repeating: Bool, _ handler: @escaping () -> Void)
        -> LeaseCancellable = { delay, repeating, handler in
        let timer = DispatchSource.makeTimerSource(queue: LeaseEffects.timerQueue)
        if repeating {
            timer.schedule(deadline: .now() + delay, repeating: delay)
        } else {
            timer.schedule(deadline: .now() + delay)
        }
        timer.setEventHandler(handler: handler)
        timer.resume()
        return LeaseTimer(timer)
    }
    var log: (_ isError: Bool, _ message: String) -> Void = { isError, message in
        if isError { leaseLog.error("\(message, privacy: .public)") }
        else { leaseLog.info("\(message, privacy: .public)") }
    }
    static let timerQueue = DispatchQueue(label: HelperConstants.machServiceName + ".lease")
}

protocol LeaseCancellable: AnyObject {
    func cancel()
}

final class LeaseTimer: LeaseCancellable {
    let timer: DispatchSourceTimer
    init(_ timer: DispatchSourceTimer) { self.timer = timer }
    func cancel() { timer.cancel() }
}

/// Durable journal file IO, used by the default `LeaseEffects`.
///
/// Persistence policy — "atomic replace" and "durable" are different claims
/// and both are done explicitly:
/// * the write path is temp file → fsync → rename → fsync(directory). The
///   rename makes the *name* swap atomic (no torn journal); the fsyncs make
///   the *contents* survive power loss. `Data.write(.atomic)` alone only
///   gives the first half and is NOT used.
/// * JSON encoding succeeding is not persistence; only this function
///   returning without throwing counts.
///
/// Path security policy (trust, not just shape): an EXISTING directory or
/// journal file must ALREADY conform — owned by `trustedUID` (root in
/// production) with no group/other write bits — and is only VERIFIED, never
/// "legitimized" by tightening its permissions: a location that was ever
/// writable by other subjects means the journal contents cannot be trusted,
/// and fixing the mode now would not retroactively make them trustworthy.
/// Violations are reported and block new grants (store degrades). Only
/// entries WE create are set to the strict modes. The file identity check
/// runs on the open descriptor (fstat), not on a separate lstat.
enum JournalFile {
    enum IOError: LocalizedError {
        case notRegularFile(String)
        case badDirectory(String)
        case untrusted(String)
        case degradedRefusal(String)
        case posix(String, Int32)

        var errorDescription: String? {
            switch self {
            case .notRegularFile(let p): return "\(p) is not a regular file"
            case .badDirectory(let p): return "journal directory \(p) failed safety checks"
            case .untrusted(let why): return "untrusted journal location: \(why)"
            case .degradedRefusal(let why): return "journal write refused: \(why)"
            case .posix(let what, let code):
                return "\(what) failed: \(String(cString: strerror(code)))"
            }
        }
    }

    static func read(path: String, trustedUID: uid_t = 0) throws -> Data? {
        let dir = (path as NSString).deletingLastPathComponent
        try ensureDirectory(dir, trustedUID: trustedUID)
        // O_NOFOLLOW refuses a symlink at the journal path at open time.
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            if errno == ELOOP {
                throw IOError.notRegularFile("\(path) (symlink refused)")
            }
            throw IOError.posix("open(\(path))", errno)
        }
        defer { close(fd) }
        // fstat on the OPEN descriptor: the identity check and the data we
        // read are guaranteed to be the same object (no lstat/open split).
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw IOError.posix("fstat(\(path))", errno) }
        guard st.st_mode & S_IFMT == S_IFREG else { throw IOError.notRegularFile(path) }
        try verifyTrusted(path: path, st: st, trustedUID: trustedUID, kind: "journal file")
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = Darwin.read(fd, &buf, buf.count)
            if n < 0 { throw IOError.posix("read(\(path))", errno) }
            if n == 0 { break }
            data.append(contentsOf: buf[0..<n])
        }
        return data
    }

    /// Optional lstat-result override for write()'s EXISTING-ENTRY trust
    /// check — the only offline way to construct an owner-mismatch scenario
    /// (making a file foreign-owned requires root). Production keeps nil =
    /// real lstat. The hook replaces a QUERY RESULT ONLY (the test calls the
    /// real lstat and alters returned metadata); every trust judgment stays
    /// the real `verifyTrusted` code. Tests must restore nil when done.
    static var existingEntryLstatHook: ((_ path: String, _ st: UnsafeMutablePointer<stat>) -> Int32)?

    /// Minimal syscall injection for offline tests of the sync/rename
    /// failure contract (these failures are not deterministically
    /// triggerable otherwise). Production keeps nil = REAL calls. Each hook
    /// replaces ONE external syscall and owns its return code + errno; a
    /// hook that wants "let it through" must call the real syscall itself.
    /// The file-sync hooks see the temp-file fd; the dir-sync hooks see the
    /// post-rename directory fd; renameHook sees (tmp, path).
    static var fileFullSyncHook: ((Int32) -> Int32)?
    static var fileSyncHook: ((Int32) -> Int32)?
    static var dirFullSyncHook: ((Int32) -> Int32)?
    static var dirSyncHook: ((Int32) -> Int32)?
    static var renameHook: ((String, String) -> Int32)?

    static func write(path: String, data: Data, trustedUID: uid_t = 0) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try ensureDirectory(dir, trustedUID: trustedUID)

        // Existing journal: type AND trust are checked BEFORE any write.
        // Check object vs operate object: lstat inspects the directory entry
        // currently at `path`, and rename(tmp, path) below replaces exactly
        // that entry — the same name. An untrusted existing journal (loose
        // mode / foreign owner) is refused UNMODIFIED: content, owner and
        // mode stay as they are, and no chmod/chown retrofit is attempted
        // (fixing the mode would not retroactively make the contents
        // trustworthy). NOTE: a TOCTOU window between this check and the
        // rename remains; this check narrows it, it does not eliminate it.
        var st = stat()
        let entryRC = existingEntryLstatHook.map { $0(path, &st) } ?? lstat(path, &st)
        if entryRC == 0 {
            guard st.st_mode & S_IFMT == S_IFREG else {
                throw IOError.notRegularFile(path)
            }
            try verifyTrusted(path: path, st: st, trustedUID: trustedUID, kind: "journal file")
        } else if errno != ENOENT {
            throw IOError.posix("lstat(\(path))", errno)
        }

        let tmp = path + ".tmp.\(getpid()).\(Int.random(in: 0..<1_000_000))"
        let fd = open(tmp, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard fd >= 0 else { throw IOError.posix("open(\(tmp))", errno) }
        var ok = false
        defer {
            close(fd)
            if !ok { unlink(tmp) }
        }
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n <= 0 { throw IOError.posix("write(\(tmp))", errno) }
                offset += n
            }
        }
        // File sync, full fallback chain: F_FULLFSYNC first, fsync only if
        // it fails. A test that fails only the FIRST stage does NOT count as
        // a sync failure here — the chain must reach a confirmed sync or
        // throw.
        let fileFullRC = JournalFile.fileFullSyncHook.map { $0(fd) } ?? fcntl(fd, F_FULLFSYNC)
        let fileSyncRC: Int32
        if fileFullRC == 0 {
            fileSyncRC = 0
        } else {
            fileSyncRC = JournalFile.fileSyncHook.map { $0(fd) } ?? fsync(fd)
        }
        guard fileSyncRC == 0 else {
            throw IOError.posix("fsync(\(tmp))", errno)
        }
        let renameRC = JournalFile.renameHook.map { $0(tmp, path) } ?? rename(tmp, path)
        guard renameRC == 0 else { throw IOError.posix("rename(\(tmp), \(path))", errno) }
        ok = true
        // These apply to the file WE just created via rename — never to a
        // pre-existing journal (that path is read-only-verified above).
        guard chmod(path, 0o600) == 0 else { throw IOError.posix("chmod(\(path), 0600)", errno) }
        guard chown(path, trustedUID, gid_t(bitPattern: -1)) == 0 else {
            throw IOError.posix("chown(\(path), uid \(trustedUID))", errno)
        }

        // Persist the rename itself (same fallback chain as the file sync).
        let dfd = open(dir, O_RDONLY)
        guard dfd >= 0 else { throw IOError.posix("open(\(dir))", errno) }
        defer { close(dfd) }
        let dirFullRC = JournalFile.dirFullSyncHook.map { $0(dfd) } ?? fcntl(dfd, F_FULLFSYNC)
        let dirSyncRC: Int32
        if dirFullRC == 0 {
            dirSyncRC = 0
        } else {
            dirSyncRC = JournalFile.dirSyncHook.map { $0(dfd) } ?? fsync(dfd)
        }
        guard dirSyncRC == 0 else {
            throw IOError.posix("fsync(\(dir))", errno)
        }
    }

    /// Trust check shared by the existing-file and existing-directory paths:
    /// owner must be `trustedUID` and group/other must have no write bits.
    private static func verifyTrusted(path: String, st: stat, trustedUID: uid_t, kind: String) throws {
        guard st.st_uid == trustedUID else {
            throw IOError.untrusted("\(kind) \(path) is owned by uid \(st.st_uid), expected \(trustedUID); contents not trusted")
        }
        guard st.st_mode & 0o022 == 0 else {
            throw IOError.untrusted("\(kind) \(path) is writable by group/others (mode 0\(String(st.st_mode & 0o7777, radix: 8))); contents not trusted")
        }
    }

    /// An EXISTING directory is verified (real directory via lstat — a
    /// symlink is rejected — trusted owner, no group/other write) and NEVER
    /// modified: no chmod/chown of pre-existing directories. Only when the
    /// directory does not exist do we create it with the strict mode, and
    /// only entries we created ourselves are trusted.
    ///
    /// Minimal syscall injection for offline tests: mkdir races (EEXIST
    /// after an ENOENT lstat) and other mkdir failures are not
    /// deterministically triggerable offline. Production default is the
    /// real mkdir. This is the ONLY injected syscall in JournalFile.
    static var mkdirHook: (String, mode_t) -> Int32 = { path, mode in
        Darwin.mkdir(path, mode)
    }

    private static func ensureDirectory(_ dir: String, trustedUID: uid_t) throws {
        var st = stat()
        if lstat(dir, &st) == 0 {
            guard st.st_mode & S_IFMT == S_IFDIR else {
                throw IOError.badDirectory(dir)
            }
            try verifyTrusted(path: dir, st: st, trustedUID: trustedUID, kind: "journal directory")
        } else if errno == ENOENT {
            if mkdirHook(dir, 0o755) == 0 {
                // Created by THIS call — trusted by construction; still set
                // the strict mode explicitly (do not rely on umask).
                guard lstat(dir, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else {
                    throw IOError.badDirectory(dir)
                }
                guard chmod(dir, 0o755) == 0 else { throw IOError.posix("chmod(\(dir), 0755)", errno) }
                guard chown(dir, trustedUID, gid_t(bitPattern: -1)) == 0 else {
                    throw IOError.posix("chown(\(dir), uid \(trustedUID))", errno)
                }
            } else if errno == EEXIST {
                // Lost a create race: the entry exists NOW but was NOT
                // created by this call. Treat it exactly like a
                // pre-existing directory: re-stat, verify type and trust,
                // and modify NOTHING — chmod/chown here would retroactively
                // "legitimize" an entry another subject created.
                guard lstat(dir, &st) == 0 else {
                    throw IOError.posix("lstat(\(dir)) after EEXIST", errno)
                }
                guard st.st_mode & S_IFMT == S_IFDIR else {
                    throw IOError.badDirectory(dir)   // covers symlinks and non-directories
                }
                try verifyTrusted(path: dir, st: st, trustedUID: trustedUID, kind: "journal directory")
            } else {
                throw IOError.posix("mkdir(\(dir))", errno)
            }
        } else {
            throw IOError.posix("lstat(\(dir))", errno)
        }
    }
}

/// In-memory + journaled leases keyed by canonical `/dev/disk…` path.
///
/// Journal invariant (what is actually guaranteed — NOT "disk always keeps
/// the previous version"): a node modification is only ever attempted after
/// the record covering it was written to the journal; records only shrink
/// after the covered nodes are PHYSICALLY restored. A persist can fail at
/// several boundaries with different on-disk states:
/// * BEFORE rename: the visible journal is still the last confirmed version.
/// * AFTER rename (chmod/chown/dir-sync failure): the NEW version is already
///   visible by name, its durability is unconfirmed, and the old version no
///   longer exists — the previous-version claim would be false here.
/// In BOTH cases the visible journal OVER-APPROXIMATES the true outstanding
/// node obligations: added-before-modification means a spurious record can
/// only demand an idempotent no-op restore; shrink-after-restore means a
/// lost removal only re-runs an already-completed restore. A failed persist
/// never UNDER-represents what may still be owed. In-memory records are
/// kept (or the obligation never existed) so a later retry re-persists.
final class DeviceLeaseStore {
    static let journalVersion = 2

    /// Store-level trust state. `.degraded` = journal unreadable/corrupt/
    /// invalid: the file is kept in place, never overwritten, and all new
    /// grants are refused until a human resolves it.
    enum StoreState: Equatable {
        case ready
        case degraded([String])
    }

    enum Bootstrap: Equatable {
        case clean          // no journal existed; nothing to recover
        case recovered      // journal loaded; first restore attempts done
        case degraded([String])
    }

    static let shared = DeviceLeaseStore(effects: LeaseEffects())

    private enum Phase: String, Codable {
        /// Nodes successfully granted; client may use them.
        case active
        /// Restore/rollback incomplete; not reusable as a grant.
        case recovering
        /// Device identity could not be re-confirmed (node replaced, replug,
        /// reboot). No further automatic chown/chmod on these nodes; the
        /// record stays journaled for manual resolution.
        case quarantined
    }

    private struct Lease {
        let leaseID: UUID
        let key: String
        /// XPC connection owner while active; nil once orphaned for recovery.
        var owner: UUID?
        let clientUID: uid_t
        let grantMode: mode_t
        var nodes: [SavedNode]
        var phase: Phase
        var timer: LeaseCancellable?
    }

    struct JournalEntry: Codable {
        let version: Int
        let leaseID: String
        let key: String
        let clientUID: UInt32
        let grantMode: UInt32
        let phase: String
        let nodes: [SavedNode]
    }

    private let effects: LeaseEffects
    private let lock = NSLock()
    private var leases: [String: Lease] = [:]
    private var state: StoreState = .ready
    private var bootstrapped = false

    init(effects: LeaseEffects) {
        self.effects = effects
        // No implicit recovery here: startup recovery is explicit
        // (bootstrapAndRecover) so Helper.main cannot start accepting
        // maintenance RPCs before it finished.
    }

    /// Explicit startup recovery for the shared production store. Must be
    /// called before the XPC listener resumes. Never lazy.
    @discardableResult
    static func bootstrapShared() -> Bootstrap {
        DeviceLeaseStore.shared.bootstrapAndRecover()
    }

    /// Loads, fully validates, installs ALL journal records, then attempts
    /// the first restore of each. Any journal problem degrades the store:
    /// the original file is preserved untouched and new grants are refused.
    @discardableResult
    func bootstrapAndRecover() -> Bootstrap {
        lock.lock()
        defer { lock.unlock() }
        if bootstrapped {
            return state == .ready ? (leases.isEmpty ? .clean : .recovered) : .degraded(stateProblems)
        }
        bootstrapped = true

        let data: Data?
        do {
            data = try effects.readJournal()
        } catch {
            return degrade("lease journal unreadable and kept in place; new grants refused: \(error.localizedDescription)")
        }
        guard let data else {
            state = .ready
            effects.log(false, "no lease journal; clean start")
            return .clean
        }

        let entries: [JournalEntry]
        do {
            entries = try JSONDecoder().decode([JournalEntry].self, from: data)
        } catch {
            return degrade("lease journal corrupt (kept in place; new grants refused): \(error.localizedDescription)")
        }

        // Validate EVERYTHING before the first restore attempt. Loading is
        // all-or-nothing: one invalid record means the journal cannot be
        // trusted as a root chown/chmod list.
        var problems: [String] = []
        var loaded: [String: Lease] = [:]
        var seenLeaseIDs = Set<UUID>()
        for e in entries {
            guard e.version == DeviceLeaseStore.journalVersion else {
                problems.append("entry key=\(e.key): unsupported journal version \(e.version)")
                continue
            }
            guard let leaseID = UUID(uuidString: e.leaseID) else {
                problems.append("entry key=\(e.key): invalid leaseID \"\(e.leaseID)\"")
                continue
            }
            guard seenLeaseIDs.insert(leaseID).inserted else {
                problems.append("entry key=\(e.key): duplicate leaseID \(e.leaseID)")
                continue
            }
            guard DevicePathRules.canonicalKey(e.key) == e.key else {
                problems.append("entry key=\(e.key): key is not an allowed canonical device path")
                continue
            }
            guard let phase = Phase(rawValue: e.phase) else {
                problems.append("entry key=\(e.key): invalid phase \"\(e.phase)\"")
                continue
            }
            guard [0, 0o400, 0o600].contains(Int(e.grantMode)) else {
                problems.append("entry key=\(e.key): invalid grantMode 0o\(String(e.grantMode, radix: 8))")
                continue
            }
            guard !e.nodes.isEmpty else {
                problems.append("entry key=\(e.key): no nodes")
                continue
            }
            var nodes: [SavedNode] = []
            var nodeProblems: [String] = []
            var seenPaths = Set<String>()
            for n in e.nodes {
                if !seenPaths.insert(n.path).inserted {
                    nodeProblems.append("duplicate node path \(n.path)")
                    continue
                }
                guard DevicePathRules.isAllowed(n.path),
                      DevicePathRules.canonicalKey(n.path) == e.key else {
                    nodeProblems.append("node \(n.path): not an allowed node for key \(e.key)")
                    continue
                }
                guard n.fileType == S_IFCHR || n.fileType == S_IFBLK else {
                    nodeProblems.append("node \(n.path): not a device node")
                    continue
                }
                guard n.rdev != 0 else {
                    nodeProblems.append("node \(n.path): missing device identity (rdev=0)")
                    continue
                }
                guard n.ino != 0 else {
                    nodeProblems.append("node \(n.path): missing node identity (ino=0)")
                    continue
                }
                guard (n.mode & S_IFMT) == n.fileType else {
                    nodeProblems.append("node \(n.path): mode/fileType mismatch")
                    continue
                }
                nodes.append(n)
            }
            if !nodeProblems.isEmpty {
                problems.append(contentsOf: nodeProblems.map { "entry key=\(e.key): \($0)" })
                continue
            }
            guard loaded[e.key] == nil else {
                problems.append("duplicate key \(e.key)")
                continue
            }
            // Whatever the on-disk phase was, a journaled lease owes a
            // restore — except quarantined records, which stay quarantined.
            loaded[e.key] = Lease(leaseID: leaseID, key: e.key, owner: nil,
                                  clientUID: uid_t(e.clientUID), grantMode: mode_t(e.grantMode),
                                  nodes: nodes,
                                  phase: phase == .quarantined ? .quarantined : .recovering,
                                  timer: nil)
        }
        if !problems.isEmpty {
            return degrade("lease journal invalid (kept in place; new grants refused): " +
                           problems.joined(separator: "; "))
        }

        // Install ALL records before the first restore, so the first
        // re-persist cannot drop not-yet-processed records.
        leases = loaded
        state = .ready

        let keys = Array(leases.keys)
        for key in keys {
            guard var lease = leases[key] else { continue }
            effects.log(true, "loaded journal lease key=\(key); attempting restore")
            _ = restoreLeaseUnlocked(&lease, removeOnSuccess: true, orphanOwner: true)
        }
        return .recovered
    }

    private func degrade(_ reason: String) -> Bootstrap {
        state = .degraded([reason])
        leases = [:]
        effects.log(true, reason)
        return .degraded([reason])
    }

    private var stateProblems: [String] {
        if case .degraded(let p) = state { return p }
        return []
    }

    /// Prepare nodes for `key`. Idempotent only for the same owner + **active**
    /// lease. The recovery record is durably journaled BEFORE the first node
    /// modification; a journal that cannot be persisted means prepare fails
    /// with zero node modifications.
    func prepare(key: String,
                 nodes: [String],
                 owner: UUID,
                 clientUID: uid_t,
                 clientGID: gid_t,
                 writeAccess: Bool,
                 timeout: TimeInterval) -> (Bool, String) {
        lock.lock()
        defer { lock.unlock() }

        guard bootstrapped else {
            return (false, "refused: lease store not bootstrapped (startup recovery pending)")
        }
        if case .degraded(let problems) = state {
            return (false, "refused: lease journal untrusted; new grants refused (\(problems.joined(separator: "; ")))")
        }

        // Mount gate: both "mounted" and "cannot tell" block the grant.
        switch MountQuery.state(forDevice: key) {
        case .mounted:
            return (false, "refused: device is mounted")
        case .queryFailed(let e):
            return (false, "refused: mount table query failed: \(e)")
        case .unmounted:
            break
        }

        // Qualification gate (the six conditions in DeviceQualification.swift):
        // runs BEFORE the
        // active-lease reuse branch (so reuse is qualified too) and before
        // any node snapshot or journal write. A rejection performs ZERO
        // node modifications and ZERO journal writes; any existing lease is
        // left untouched. restore/recovery paths deliberately have NO such
        // gate — an outstanding obligation must remain restorable.
        let requestedBSDName = String(key.dropFirst("/dev/".count))
        var gateNodeStats: [String: stat?] = [:]
        for path in nodes { gateNodeStats[path] = effects.statNode(path) }
        switch DeviceQualification.judge(requestedBSDName: requestedBSDName,
                                         collection: effects.collectDAFacts(requestedBSDName),
                                         nodeStats: gateNodeStats) {
        case .grant:
            break
        case .reject(let reason):
            let msg = "refused: device qualification failed: \(reason)"
            effects.log(true, "prepare \(key): \(msg)")
            return (false, msg)
        }

        if let existing = leases[key] {
            switch existing.phase {
            case .recovering:
                return (false, "refused: device lease is recovering; wait for restore")
            case .quarantined:
                return (false, "refused: device lease quarantined (device identity unconfirmed); resolve manually")
            case .active:
                if existing.owner == owner,
                   existing.nodes.allSatisfy({ identityMatches(node: $0, stat: effects.statNode($0.path)) }),
                   existing.grantMode == (writeAccess ? mode_t(0o600) : mode_t(0o400)) {
                    effects.log(false, "prepare reuse key=\(key) lease=\(existing.leaseID.uuidString)")
                    return (true, "ok (reused lease)")
                }
                return (false, "refused: device already prepared by another client or identity changed")
            }
        }

        // Snapshot originals BEFORE any mutation.
        var saved: [SavedNode] = []
        for path in nodes {
            guard let st = effects.statNode(path) else {
                return (false, "refused: missing device node \(path)")
            }
            let ft = st.st_mode & S_IFMT
            guard ft == S_IFCHR || ft == S_IFBLK else {
                return (false, "refused: not a device node \(path)")
            }
            guard st.st_rdev != 0 else {
                return (false, "refused: device node \(path) has no rdev identity")
            }
            guard st.st_ino != 0 else {
                return (false, "refused: device node \(path) has no inode identity")
            }
            saved.append(SavedNode(path: path, mode: st.st_mode, uid: st.st_uid, gid: st.st_gid,
                                   rdev: st.st_rdev, fileType: ft,
                                   ino: UInt64(st.st_ino), dev: st.st_dev,
                                   birthSec: Int64(st.st_birthtimespec.tv_sec),
                                   birthNsec: Int32(st.st_birthtimespec.tv_nsec)))
        }
        guard !saved.isEmpty else {
            return (false, "refused: no device nodes prepared")
        }

        // Journal FIRST, as `recovering`, covering every node that may be
        // touched. A failed persist aborts prepare with zero modifications.
        let leaseID = UUID()
        let grantMode: mode_t = writeAccess ? 0o600 : 0o400
        leases[key] = Lease(leaseID: leaseID, key: key, owner: owner, clientUID: clientUID,
                            grantMode: grantMode, nodes: saved, phase: .recovering, timer: nil)
        do {
            try persistJournalUnlocked()
        } catch {
            leases[key] = nil
            let msg = "refused: cannot persist lease journal (\(error.localizedDescription)); no device nodes were modified"
            effects.log(true, "prepare \(key): \(msg)")
            return (false, msg)
        }

        // Grant. On any failure the rollback set includes the CURRENT node —
        // its chown may have succeeded even though chmod failed.
        var grantedCount = 0
        for node in saved {
            if effects.chownNode(node.path, clientUID, clientGID) != 0 {
                let err = String(cString: strerror(errno))
                let touched = Array(saved.prefix(grantedCount + 1))
                let rollback = rollbackViaSharedRestoreUnlocked(key: key, leaseID: leaseID, touched: touched)
                let msg = "chown \(node.path) failed: \(err); \(rollback)"
                effects.log(true, "prepare \(key): \(msg)")
                return (false, msg)
            }
            if effects.chmodNode(node.path, grantMode) != 0 {
                let err = String(cString: strerror(errno))
                let touched = Array(saved.prefix(grantedCount + 1))
                let rollback = rollbackViaSharedRestoreUnlocked(key: key, leaseID: leaseID, touched: touched)
                let msg = "chmod \(node.path) failed: \(err); \(rollback)"
                effects.log(true, "prepare \(key): \(msg)")
                return (false, msg)
            }
            grantedCount += 1
        }

        // Active transition must also be durable. If it cannot be persisted,
        // the grant is rolled back — never reported as success.
        var lease = leases[key]!
        lease.phase = .active
        leases[key] = lease
        do {
            try persistJournalUnlocked()
        } catch {
            let rollback = rollbackViaSharedRestoreUnlocked(key: key, leaseID: leaseID,
                                                            touched: Array(saved.prefix(grantedCount)))
            let msg = "journal persist failed after grant (\(error.localizedDescription)); \(rollback)"
            effects.log(true, "prepare \(key): \(msg)")
            return (false, msg)
        }
        armTimeoutUnlocked(key: key, leaseID: leaseID, timeout: timeout)
        effects.log(false, "prepare ok key=\(key) lease=\(leaseID.uuidString) mode=\(grantMode)")
        return (true, "ok")
    }

    /// Shared failure path for prepare: the lease covering every TOUCHED node
    /// (granted ones AND the CURRENT partially-modified one) goes through the
    /// SAME `restoreLeaseUnlocked` code as normal recovery — identity checked
    /// BEFORE any further modification, an identity mismatch quarantines
    /// (the replaced node is never touched), unverified nodes stay journaled
    /// as `recovering` with an internal retry. Returns a human-readable
    /// summary for the prepare error message.
    private func rollbackViaSharedRestoreUnlocked(key: String, leaseID: UUID,
                                                  touched: [SavedNode]) -> String {
        leases[key] = Lease(leaseID: leaseID, key: key, owner: nil, clientUID: 0,
                            grantMode: 0, nodes: touched, phase: .recovering, timer: nil)
        guard var lease = leases[key] else { return "internal error: lease missing after install" }
        let (_, msg) = restoreLeaseUnlocked(&lease, removeOnSuccess: true, orphanOwner: true)
        return msg == "ok" ? "all touched nodes verified restored" : "rollback: \(msg)"
    }

    /// Client-requested restore. On failure, lease becomes recovering and
    /// the helper retries internally; the failure is returned, not swallowed.
    func restore(key: String, owner: UUID?) -> (Bool, String) {
        lock.lock()
        defer { lock.unlock() }
        guard var lease = leases[key] else {
            return (false, "refused: no active lease for \(key)")
        }
        if lease.phase == .quarantined {
            return (false, "refused: lease quarantined (device identity unconfirmed); no automatic or manual chown/chmod until identity is re-confirmed")
        }
        if let owner, let leaseOwner = lease.owner, leaseOwner != owner, lease.phase == .active {
            return (false, "refused: lease owned by another client")
        }
        return restoreLeaseUnlocked(&lease, removeOnSuccess: true, orphanOwner: false)
    }

    /// Connection dropped: attempt restore; on failure keep recovering without owner.
    func releaseAll(ownedBy owner: UUID) {
        lock.lock()
        defer { lock.unlock() }
        let keys = leases.compactMap { $0.value.owner == owner ? $0.key : nil }
        for key in keys {
            guard var lease = leases[key] else { continue }
            _ = restoreLeaseUnlocked(&lease, removeOnSuccess: true, orphanOwner: true)
        }
    }

    // MARK: - Internals

    private func expire(key: String, leaseID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard var lease = leases[key], lease.leaseID == leaseID else { return }
        effects.log(true, "lease timeout restore key=\(key) lease=\(leaseID.uuidString)")
        _ = restoreLeaseUnlocked(&lease, removeOnSuccess: true, orphanOwner: true)
    }

    private func retryRecovery(key: String, leaseID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard var lease = leases[key], lease.leaseID == leaseID, lease.phase == .recovering else { return }
        _ = restoreLeaseUnlocked(&lease, removeOnSuccess: true, orphanOwner: true)
    }

    /// Outcome of restoring ONE node. `.identityMismatch` means the path now
    /// names a different node instance — the caller must quarantine and must
    /// NOT attempt any modification of it.
    private enum NodeRestoreOutcome {
        case restored
        case missing
        case failed(String)
        case identityMismatch(String)
    }

    /// Single node-restore attempt shared by normal recovery, timeout/
    /// disconnect recovery, and prepare-abort rollback (one code path, one
    /// identity policy). Identity is checked BEFORE any modification: a
    /// mismatched node is never chown/chmod'ed. NOTE: stat-check → modify is
    /// still not atomic — the window between the check and the syscalls
    /// remains (same TOCTOU class as the mount gates); the post-modification
    /// `restoredExactly` verification is a second layer, not a substitute.
    private func restoreNode(_ node: SavedNode) -> NodeRestoreOutcome {
        guard let st = effects.statNode(node.path) else { return .missing }
        if let reason = Self.identityMismatchReason(node: node, st: st) {
            return .identityMismatch(reason)
        }
        if effects.chownNode(node.path, node.uid, node.gid) != 0 {
            return .failed("\(node.path): chown \(String(cString: strerror(errno)))")
        }
        if effects.chmodNode(node.path, node.mode & 0o7777) != 0 {
            return .failed("\(node.path): chmod \(String(cString: strerror(errno)))")
        }
        if !restoredExactly(node) {
            return .failed("\(node.path): post-restore verification mismatch")
        }
        return .restored
    }

    /// Restores one lease. Identity (rdev/fileType/ino/dev/birthtime) is
    /// re-checked per node; a mismatch quarantines the whole lease — no
    /// automatic chown/chmod on a node that may no longer be the one we
    /// modified. Missing nodes stay recovering (the device may return with
    /// its identity intact; if it returns as a different node, the next
    /// attempt quarantines).
    private func restoreLeaseUnlocked(_ lease: inout Lease,
                                      removeOnSuccess: Bool,
                                      orphanOwner: Bool) -> (Bool, String) {
        lease.timer?.cancel()
        lease.timer = nil
        if orphanOwner { lease.owner = nil }

        if lease.phase == .quarantined {
            leases[lease.key] = lease
            return (false, "refused: lease quarantined (device identity unconfirmed); no automatic restore will be attempted")
        }
        lease.phase = .recovering

        var failed: [String] = []
        var remaining: [SavedNode] = []
        var quarantined: [String] = []
        for node in lease.nodes {
            switch restoreNode(node) {
            case .restored:
                break
            case .missing:
                failed.append("\(node.path): missing (device gone; will retry)")
                remaining.append(node)
            case .failed(let why):
                failed.append(why)
                remaining.append(node)
            case .identityMismatch(let reason):
                quarantined.append("\(node.path): \(reason)")
                remaining.append(node)
            }
        }

        let key = lease.key
        if quarantined.isEmpty && failed.isEmpty {
            if removeOnSuccess { leases[key] = nil }
            do {
                try persistJournalUnlocked()
                effects.log(false, "restore ok key=\(key)")
                return (true, "ok")
            } catch {
                // Nodes are restored; the journal still lists them. Keep the
                // record and retry — never drop an unrecovered obligation.
                lease.phase = .recovering
                leases[key] = lease
                scheduleRecoveryUnlocked(key: key, leaseID: lease.leaseID)
                let msg = "restore applied but journal persist failed (\(error.localizedDescription)); record kept, recovery will re-verify"
                effects.log(true, "\(key): \(msg)")
                return (false, msg)
            }
        }

        if !quarantined.isEmpty {
            lease.nodes = remaining
            lease.phase = .quarantined
            leases[key] = lease
            do {
                try persistJournalUnlocked()
            } catch {
                effects.log(true, "\(key): quarantine persist failed (\(error.localizedDescription)); record kept in memory")
            }
            let msg = "device identity changed — lease QUARANTINED, automatic chown/chmod stopped for \(quarantined.joined(separator: "; ")); resolve manually (unplug/replug the original device, or inspect \(HelperConstants.leaseJournalPath))"
            effects.log(true, "\(key): \(msg)")
            return (false, msg)
        }

        lease.nodes = remaining
        lease.phase = .recovering
        leases[key] = lease
        do {
            try persistJournalUnlocked()
        } catch {
            effects.log(true, "\(key): recovery persist failed (\(error.localizedDescription)); in-memory record kept; disk keeps a superset")
        }
        scheduleRecoveryUnlocked(key: key, leaseID: lease.leaseID)
        let msg = "restore incomplete: " + failed.joined(separator: "; ")
        effects.log(true, "\(key): \(msg)")
        return (false, msg)
    }

    private func armTimeoutUnlocked(key: String, leaseID: UUID, timeout: TimeInterval) {
        // The handler carries its own leaseID: an old timer firing after the
        // lease was replaced must not touch the new lease.
        let timer = effects.schedule(timeout, false) { [weak self] in
            self?.expire(key: key, leaseID: leaseID)
        }
        leases[key]?.timer = timer
    }

    private func scheduleRecoveryUnlocked(key: String, leaseID: UUID) {
        guard var lease = leases[key], lease.leaseID == leaseID else { return }
        lease.timer?.cancel()
        let timer = effects.schedule(HelperConstants.restoreRetrySeconds, true) { [weak self] in
            self?.retryRecovery(key: key, leaseID: leaseID)
        }
        lease.timer = timer
        lease.phase = .recovering
        lease.owner = nil
        leases[key] = lease
    }

    /// Full node-instance identity match (same devfs entry as at prepare).
    private func identityMatches(node: SavedNode, stat st: stat?) -> Bool {
        guard let st else { return false }
        return Self.identityMismatchReason(node: node, st: st) == nil
    }

    /// Reason the current node is NOT the one we saved, or nil when identity
    /// holds. UNVERIFIED ASSUMPTION (conservative direction): devfs inode /
    /// st_dev / birthtime are expected to change when a node is recreated
    /// (replug or reboot) and to stay stable while the same node persists
    /// within one boot. If that assumption is wrong in the reuse direction
    /// (a recreated node coincidentally matching all fields), restore could
    /// act on a new node. This is an accepted, documented risk.
    static func identityMismatchReason(node: SavedNode, st: stat) -> String? {
        let ft = st.st_mode & S_IFMT
        if node.fileType != 0, ft != node.fileType {
            return "file type changed"
        }
        if node.rdev != 0, st.st_rdev != node.rdev {
            return "device id (rdev) changed"
        }
        if node.ino != 0, UInt64(st.st_ino) != node.ino {
            return "node inode changed"
        }
        if node.dev != 0, st.st_dev != node.dev {
            return "node filesystem id changed"
        }
        if node.birthSec != 0 || node.birthNsec != 0 {
            if Int64(st.st_birthtimespec.tv_sec) != node.birthSec ||
               Int32(st.st_birthtimespec.tv_nsec) != node.birthNsec {
                return "node creation time changed"
            }
        }
        return nil
    }

    /// Post-restore verification: identity AND uid/gid/mode all back.
    private func restoredExactly(_ node: SavedNode) -> Bool {
        guard let st = effects.statNode(node.path) else { return false }
        guard Self.identityMismatchReason(node: node, st: st) == nil else { return false }
        return st.st_uid == node.uid && st.st_gid == node.gid
            && (st.st_mode & 0o7777) == (node.mode & 0o7777)
    }

    // MARK: - Journal

    /// Persist the current lease set. Encoding success is NOT persistence —
    /// only a non-throwing return is. Never called while degraded (a
    /// corrupt/untrusted journal must not be overwritten by new state).
    private func persistJournalUnlocked() throws {
        if case .degraded(let problems) = state {
            throw JournalFile.IOError.degradedRefusal(
                "store degraded: \(problems.joined(separator: "; "))")
        }
        let entries: [JournalEntry] = leases.values.map {
            JournalEntry(version: DeviceLeaseStore.journalVersion,
                         leaseID: $0.leaseID.uuidString, key: $0.key,
                         clientUID: UInt32($0.clientUID), grantMode: UInt32($0.grantMode),
                         phase: $0.phase.rawValue, nodes: $0.nodes)
        }
        let data = try JSONEncoder().encode(entries)
        try effects.writeJournal(data)
    }
}
