// Offline unit tests for the maintenance lease store (Helper/DeviceLeaseStore.swift),
// the tri-state mount query (Shared/MountQuery.swift) and the remount policy
// (Shared/MaintenancePolicy.swift).
//
// All external effects (stat/chown/chmod, journal IO, timers, os_log, mount
// queries) are injected via LeaseEffects / MountQuery.probe. No real device
// node, file, timer, or the real mount table is ever touched; the harness
// fails closed if any code path unexpectedly queries the real mount table.
//
// SPDX-License-Identifier: GPL-2.0-or-later

import Darwin
import Foundation

// MARK: - Harness

var failures = 0
var currentTest = ""

func expect(_ cond: Bool, _ msg: String, line: UInt = #line) {
    if !cond {
        failures += 1
        print("FAIL [\(currentTest)] line \(line): \(msg)")
    }
}

func runTest(_ name: String, _ body: () throws -> Void) {
    currentTest = name
    // Offline fail-closed default: any code path that forgets to stub the
    // mount query gets a query failure (and the tests assert prepare then
    // refuses), never a real getmntinfo call.
    MountQuery.probe = { _ in .queryFailed("harness default: offline tests must not query the real mount table") }
    let before = failures
    activeScenes = []
    do {
        try body()
    } catch {
        failures += 1
        print("FAIL [\(name)]: threw \(error)")
    }
    // Scene management: scenes are removed ONLY when the whole
    // test passed — `expect` merely increments `failures`, so the failure
    // decision must be based on the failure COUNT, not on throws alone.
    if failures == before {
        for scene in activeScenes {
            do {
                try FileManager.default.removeItem(at: scene)
            } catch {
                print("NOTE [\(name)]: success-path scene cleanup failed for \(scene.path): \(error.localizedDescription)")
            }
        }
    } else {
        for scene in activeScenes where FileManager.default.fileExists(atPath: scene.path) {
            print("SCENE KEPT [\(name)]: \(scene.path)")
        }
    }
    activeScenes = []
    if failures == before {
        print("PASS: \(name)")
    } else {
        print("TEST FAILED: \(name)")
    }
}

final class Recorder {
    var statCalls: [String] = []
    var chowns: [(path: String, uid: uid_t, gid: gid_t)] = []
    var chmods: [(path: String, mode: mode_t)] = []
    var journalWrites: [Data] = []
    var journalWriteError: Error?
    var journalData: Data?
    var journalReadError: Error?
    var logs: [(isError: Bool, message: String)] = []
    var timers: [(id: Int, repeating: Bool, handler: () -> Void, canceled: Bool)] = []

    // Scriptable outcomes.
    var statResults: [String: stat?] = [:]      // key absent → node missing
    var daFactsCalls: [String] = []
    var daFactsOverride: ((String) -> DACollectionResult)?
    var chownOutcome: (String, uid_t) -> Int32 = { _, _ in 0 }
    var chmodOutcome: (String) -> Int32 = { _ in 0 }

    func fire(_ id: Int) {
        guard id >= 0, id < timers.count, !timers[id].canceled else { return }
        timers[id].handler()
    }

    /// Simulates a handler already in flight when its timer was canceled
    /// (the race the leaseID guard exists for).
    func fireIgnoringCancel(_ id: Int) {
        guard id >= 0, id < timers.count else { return }
        timers[id].handler()
    }

    func fireLast() { fire(timers.count - 1) }
}

final class StubTimer: LeaseCancellable {
    let rec: Recorder
    let id: Int
    init(rec: Recorder, id: Int) { self.rec = rec; self.id = id }
    func cancel() {
        if id < rec.timers.count { rec.timers[id].canceled = true }
    }
}

func makeEffects(_ rec: Recorder) -> LeaseEffects {
    LeaseEffects(
        statNode: { path in
            rec.statCalls.append(path)
            return rec.statResults[path] ?? nil
        },
        collectDAFacts: { bsd in
            rec.daFactsCalls.append(bsd)
            if let o = rec.daFactsOverride { return o(bsd) }
            return .facts(syntheticQualifyingFacts(bsd: bsd, rec: rec))
        },
        chownNode: { path, uid, gid in
            rec.chowns.append((path, uid, gid))
            return rec.chownOutcome(path, uid)
        },
        chmodNode: { path, mode in
            rec.chmods.append((path, mode))
            return rec.chmodOutcome(path)
        },
        readJournal: {
            if let e = rec.journalReadError { throw e }
            return rec.journalData
        },
        writeJournal: { data in
            if let e = rec.journalWriteError { throw e }
            rec.journalWrites.append(data)
        },
        schedule: { _, repeating, handler in
            let id = rec.timers.count
            rec.timers.append((id, repeating, handler, false))
            return StubTimer(rec: rec, id: id)
        },
        log: { isError, message in
            rec.logs.append((isError, message))
        })
}

/// Default offline DA view: qualifying facts whose major/minor are derived
/// from the block node's stubbed st_rdev (a consistent simulated DA cache).
/// Tests override via rec.daFactsOverride for gate scenarios.
func syntheticQualifyingFacts(bsd: String, rec: Recorder) -> DeviceDAFacts {
    var major = 18, minor = 3_432_568  // devStat() default rdev 0x1234_5678
    if let st = rec.statResults["/dev/\(bsd)"] ?? nil {
        major = Int((st.st_rdev >> 24) & 0xff)
        minor = Int(st.st_rdev & 0xffffff)
    }
    return DeviceDAFacts(volumeKind: .present("openntfs"), volumePath: .absent,
                         mediaBSDName: .present(bsd),
                         mediaBSDMajor: .present(String(major)),
                         mediaBSDMinor: .present(String(minor)),
                         mediaLeaf: .present("true"))
}

func devStat(uid: uid_t = 501, gid: gid_t = 20, perm: mode_t = 0o640,
             fileType: mode_t = mode_t(S_IFBLK), rdev: dev_t = 0x1234_5678,
             ino: UInt64 = 4242, dev: dev_t = 77,
             birthSec: Int64 = 1_700_000_000, birthNsec: Int32 = 5) -> stat {
    var st = stat()
    st.st_mode = fileType | perm
    st.st_uid = uid
    st.st_gid = gid
    st.st_rdev = rdev
    st.st_ino = ino
    st.st_dev = dev
    st.st_birthtimespec.tv_sec = __darwin_time_t(birthSec)
    st.st_birthtimespec.tv_nsec = Int(birthNsec)
    return st
}

func makeNode(path: String, uid: uid_t = 501, gid: gid_t = 20, perm: mode_t = 0o640,
              fileType: mode_t = mode_t(S_IFBLK), rdev: dev_t = 0x1234_5678,
              ino: UInt64 = 4242, dev: dev_t = 77,
              birthSec: Int64 = 1_700_000_000, birthNsec: Int32 = 5) -> SavedNode {
    SavedNode(path: path, mode: fileType | perm, uid: uid, gid: gid, rdev: rdev,
              fileType: fileType, ino: ino, dev: dev,
              birthSec: birthSec, birthNsec: birthNsec)
}

func makeEntry(key: String, leaseID: UUID = UUID(), nodes: [SavedNode],
               phase: String = "recovering", clientUID: UInt32 = 1000,
               grantMode: UInt32 = 0o600, version: Int = DeviceLeaseStore.journalVersion)
    -> DeviceLeaseStore.JournalEntry {
    DeviceLeaseStore.JournalEntry(version: version, leaseID: leaseID.uuidString, key: key,
                                  clientUID: clientUID, grantMode: grantMode,
                                  phase: phase, nodes: nodes)
}

func journalData(_ entries: [DeviceLeaseStore.JournalEntry]) -> Data {
    try! JSONEncoder().encode(entries)
}

/// Fail-closed "journal cleared" for CAPTURED writes (Recorder), mirroring
/// expectJournalCleared for on-disk reads: requires at least one SUCCESSFUL
/// write to exist and the LAST write to decode; a Recorder with no writes
/// or an undecodable last write yields nil — never [].
func clearedJournal(_ rec: Recorder) -> [DeviceLeaseStore.JournalEntry]? {
    guard let last = rec.journalWrites.last else { return nil }
    return decodeEntries(last)
}

func decodeEntries(_ data: Data) -> [DeviceLeaseStore.JournalEntry]? {
    try? JSONDecoder().decode([DeviceLeaseStore.JournalEntry].self, from: data)
}

let nodeA = makeNode(path: "/dev/disk9s1")
let nodeB = makeNode(path: "/dev/rdisk9s1", fileType: mode_t(S_IFCHR))
let nodeC = makeNode(path: "/dev/disk10s1", rdev: 0x1111_2222, ino: 5151)

func prepareHelper(_ store: DeviceLeaseStore, key: String, nodes: [String],
                   owner: UUID, writeAccess: Bool,
                   timeout: TimeInterval = 60) -> (Bool, String) {
    store.prepare(key: key, nodes: nodes, owner: owner, clientUID: 1000, clientGID: 20,
                  writeAccess: writeAccess, timeout: timeout)
}

// MARK: - Tests

// a first journal persist failure must refuse prepare with ZERO
// node modifications.
func testFirstJournalWriteFailureBlocksAllNodeModification() {
    let rec = Recorder()
    rec.statResults["/dev/disk9s1"] = devStat()
    rec.statResults["/dev/rdisk9s1"] = devStat(fileType: mode_t(S_IFCHR), rdev: nodeB.rdev)
    rec.journalWriteError = NSError(domain: "test", code: 28,
                                    userInfo: [NSLocalizedDescriptionKey: "No space left on device"])
    MountQuery.probe = { _ in .unmounted }
    let store = DeviceLeaseStore(effects: makeEffects(rec))
    let boot = store.bootstrapAndRecover()
    expect(boot == .clean, "clean bootstrap expected, got \(boot)")
    let (ok, msg) = prepareHelper(store, key: "/dev/disk9s1",
                                  nodes: ["/dev/disk9s1", "/dev/rdisk9s1"],
                                  owner: UUID(), writeAccess: false)
    expect(!ok, "prepare must fail, got ok=\(ok)")
    expect(msg.contains("cannot persist lease journal"), "message must name the persist failure: \(msg)")
    expect(rec.chowns.isEmpty, "no chown may run: \(rec.chowns)")
    expect(rec.chmods.isEmpty, "no chmod may run: \(rec.chmods)")
    expect(rec.journalWrites.isEmpty, "no journal write may be recorded")
}

// multi-record recovery — ALL records are loaded before the first
// restore/writeback. The scenario is ORDER-INDEPENDENT (Dictionary iteration
// order is unspecified): both restores fail, so whichever record is processed
// first, every persisted snapshot must retain both obligations.
func testMultiEntryRecoveryInterruptKeepsUnprocessedRecords() {
    let rec = Recorder()
    rec.statResults["/dev/disk9s1"] = devStat()
    rec.statResults["/dev/disk10s1"] = devStat(rdev: 0x1111_2222, ino: 5151)
    rec.journalData = journalData([
        makeEntry(key: "/dev/disk9s1", nodes: [nodeA]),
        makeEntry(key: "/dev/disk10s1", nodes: [nodeC]),
    ])
    rec.chownOutcome = { _, _ in 1 }
    let store = DeviceLeaseStore(effects: makeEffects(rec))
    let boot = store.bootstrapAndRecover()
    expect(boot == .recovered, "recovered bootstrap expected, got \(boot)")
    expect(!rec.journalWrites.isEmpty, "recovery must have persisted snapshots")
    // Every persisted snapshot is a possible crash boundary: each must retain
    // BOTH records (none has been removed at this point).
    for (i, w) in rec.journalWrites.enumerated() {
        let entries = decodeEntries(w) ?? []
        let keys = Set(entries.map(\.key))
        expect(keys == ["/dev/disk9s1", "/dev/disk10s1"],
               "write #\(i) must retain BOTH records (order-independent), got \(keys.sorted())")
    }
    // Boundary-injected interrupt: crash right after the FIRST writeback and
    // restart from exactly that snapshot; both retained records still recover.
    let rec2 = Recorder()
    rec2.statResults["/dev/disk9s1"] = devStat()
    rec2.statResults["/dev/disk10s1"] = devStat(rdev: 0x1111_2222, ino: 5151)
    rec2.journalData = rec.journalWrites[0]
    let store2 = DeviceLeaseStore(effects: makeEffects(rec2))
    let boot2 = store2.bootstrapAndRecover()
    expect(boot2 == .recovered, "restart bootstrap expected .recovered, got \(boot2)")
    guard let final = clearedJournal(rec2) else {
        return expect(false, "restart produced no decodable successful journal write (absent/undecodable ≠ cleared)")
    }
    expect(final.isEmpty, "all retained records restored on restart, journal now: \(final.map(\.key))")
    expect(rec2.chowns.contains { $0.path == "/dev/disk9s1" && $0.uid == 501 }
        && rec2.chowns.contains { $0.path == "/dev/disk10s1" && $0.uid == 501 },
        "restart must restore ownership on both retained nodes")
}

// journal missing vs corrupt vs unreadable vs duplicate key vs
// invalid entries — each with a DISTINCT result, no journal overwrite.
func testJournalMissingIsCleanStart() {
    let rec = Recorder()
    let store = DeviceLeaseStore(effects: makeEffects(rec))
    expect(store.bootstrapAndRecover() == .clean, "missing journal → clean")
    expect(rec.journalWrites.isEmpty, "nothing written on clean start")
    expect(rec.chowns.isEmpty && rec.chmods.isEmpty, "no node ops on clean start")
}

func testJournalCorruptDegradesAndKeepsFile() {
    let rec = Recorder()
    rec.journalData = Data("{not json".utf8)
    let store = DeviceLeaseStore(effects: makeEffects(rec))
    let boot = store.bootstrapAndRecover()
    guard case .degraded(let problems) = boot else {
        return expect(false, "corrupt journal must degrade, got \(boot)")
    }
    expect(problems.joined().contains("corrupt"), "problem must say corrupt: \(problems)")
    expect(rec.journalWrites.isEmpty, "corrupt journal must never be overwritten")
    MountQuery.probe = { _ in .unmounted }
    rec.statResults["/dev/disk9s1"] = devStat()
    let (ok, msg) = prepareHelper(store, key: "/dev/disk9s1", nodes: ["/dev/disk9s1"],
                                  owner: UUID(), writeAccess: false)
    expect(!ok, "degraded store must refuse new grants")
    expect(msg.contains("untrusted"), "refusal must say why: \(msg)")
    expect(rec.chowns.isEmpty, "degraded store must not touch nodes")
}

func testJournalUnreadableDegrades() {
    let rec = Recorder()
    rec.journalReadError = NSError(domain: "test", code: 13,
                                   userInfo: [NSLocalizedDescriptionKey: "Permission denied"])
    let store = DeviceLeaseStore(effects: makeEffects(rec))
    let boot = store.bootstrapAndRecover()
    guard case .degraded(let problems) = boot else {
        return expect(false, "unreadable journal must degrade, got \(boot)")
    }
    expect(problems.joined().contains("unreadable"), "problem must say unreadable: \(problems)")
    expect(rec.journalWrites.isEmpty, "unreadable journal must never be overwritten")
}

func testJournalDuplicateKeyDegrades() {
    let rec = Recorder()
    rec.journalData = journalData([
        makeEntry(key: "/dev/disk9s1", nodes: [nodeA]),
        makeEntry(key: "/dev/disk9s1", nodes: [nodeB]),   // same key, own leaseID
    ])
    let store = DeviceLeaseStore(effects: makeEffects(rec))
    let boot = store.bootstrapAndRecover()
    guard case .degraded(let problems) = boot else {
        return expect(false, "duplicate key must degrade, got \(boot)")
    }
    expect(problems.joined().contains("duplicate key"), "problem must name duplicate key: \(problems)")
    expect(rec.journalWrites.isEmpty, "invalid journal must never be overwritten")
    expect(rec.chowns.isEmpty && rec.chmods.isEmpty, "invalid journal must not drive chown/chmod")
}

func testJournalInvalidEntriesDegrade() {
    let rawBadLeaseID = DeviceLeaseStore.JournalEntry(
        version: DeviceLeaseStore.journalVersion, leaseID: "not-a-uuid",
        key: "/dev/disk9s1", clientUID: 1000, grantMode: 0o600,
        phase: "recovering", nodes: [nodeA])
    let cases: [(String, DeviceLeaseStore.JournalEntry, String)] = [
        ("nonDeviceNodePath",
         makeEntry(key: "/dev/disk9s1", nodes: [makeNode(path: "/etc/passwd")]),
         "not an allowed node"),
        ("invalidLeaseID", rawBadLeaseID, "invalid leaseID"),
        ("wrongVersion",
         makeEntry(key: "/dev/disk9s1", nodes: [nodeA], version: 1),
         "unsupported journal version"),
        ("rdevZero",
         makeEntry(key: "/dev/disk9s1", nodes: [makeNode(path: "/dev/disk9s1", rdev: 0)]),
         "missing device identity"),
    ]
    for (name, entry, needle) in cases {
        let rec = Recorder()
        rec.journalData = journalData([entry])
        let store = DeviceLeaseStore(effects: makeEffects(rec))
        let boot = store.bootstrapAndRecover()
        guard case .degraded(let problems) = boot else {
            expect(false, "\(name): must degrade, got \(boot)")
            continue
        }
        expect(problems.joined().contains(needle), "\(name): problem must contain \"\(needle)\": \(problems)")
        expect(rec.journalWrites.isEmpty, "\(name): journal must not be overwritten")
        expect(rec.chowns.isEmpty && rec.chmods.isEmpty, "\(name): no node ops")
    }
}

// chown ok + chmod fail on the CURRENT node — the current node is
// rolled back too, its rollback result is checked, and anything not verified
// restored stays journaled as recovering.
func testChmodFailureCurrentNodeRolledBackAndRetained() {
    let rec = Recorder()
    rec.statResults["/dev/disk9s1"] = devStat()
    rec.statResults["/dev/rdisk9s1"] = devStat(fileType: mode_t(S_IFCHR), rdev: nodeB.rdev)
    // Grant chowns succeed; chmod on rdisk fails; the FIRST rollback chown of
    // rdisk (back to 501) also fails — later retries succeed. (The stub
    // appends the current call before consulting chownOutcome, hence dropLast.)
    rec.chmodOutcome = { path in path == "/dev/rdisk9s1" ? 1 : 0 }
    rec.chownOutcome = { path, uid in
        // Grant chowns (uid 1000) succeed; the first ROLLBACK chown of
        // rdisk (uid 501) fails.
        guard path == "/dev/rdisk9s1", uid == 501 else { return 0 }
        let priorRollbacks = rec.chowns.dropLast()
            .filter { $0.path == path && $0.uid == 501 }.count
        return priorRollbacks == 0 ? 1 : 0
    }
    MountQuery.probe = { _ in .unmounted }
    let store = DeviceLeaseStore(effects: makeEffects(rec))
    _ = store.bootstrapAndRecover()
    let (ok, msg) = prepareHelper(store, key: "/dev/disk9s1",
                                  nodes: ["/dev/disk9s1", "/dev/rdisk9s1"],
                                  owner: UUID(), writeAccess: true)
    expect(!ok, "prepare must fail")
    expect(msg.contains("chmod /dev/rdisk9s1 failed"), "message must name chmod failure: \(msg)")
    expect(msg.contains("restore incomplete"), "message must say restore incomplete: \(msg)")
    // D-core: the CURRENT (partially granted) node got a rollback attempt.
    expect(rec.chowns.contains { $0.path == "/dev/rdisk9s1" && $0.uid == 501 && $0.gid == 20 },
           "current node rollback chown must be attempted: \(rec.chowns)")
    // The fully-granted first node was restored and dropped from the record.
    guard let last = rec.journalWrites.last.flatMap(decodeEntries) else {
        return expect(false, "no journal write after abort")
    }
    expect(last.count == 1 && last[0].key == "/dev/disk9s1" && last[0].phase == "recovering",
           "unrecovered node must stay journaled recovering: \(last)")
    expect(last[0].nodes.map(\.path) == ["/dev/rdisk9s1"],
           "only the not-verified-restored node remains: \(last[0].nodes.map(\.path))")
    // Retry succeeds → lease cleared, journal emptied. The retry must
    // produce a NEW successful write after fault clearance (not reuse an
    // old .last), and that write must decode to exactly [].
    let writesBeforeRetry = rec.journalWrites.count
    rec.chownOutcome = { _, _ in 0 }
    rec.chmodOutcome = { _ in 0 }
    rec.fireLast()
    expect(rec.journalWrites.count > writesBeforeRetry,
           "retry after fault clearance produced a NEW journal write")
    guard let final = clearedJournal(rec) else {
        return expect(false, "the new last write must exist and decode (absent/undecodable ≠ cleared)")
    }
    expect(final.isEmpty, "after successful retry the journal must be empty, got \(final.map(\.key))")
}

// restore fails after timeout (and after connection drop);
// a later retry succeeds and clears the journal.
func testTimeoutRecoveryFailsThenRetrySucceeds() {
    let rec = Recorder()
    rec.statResults["/dev/disk9s1"] = devStat()
    MountQuery.probe = { _ in .unmounted }
    let store = DeviceLeaseStore(effects: makeEffects(rec))
    _ = store.bootstrapAndRecover()
    let owner = UUID()
    let (ok, _) = prepareHelper(store, key: "/dev/disk9s1", nodes: ["/dev/disk9s1"],
                                owner: owner, writeAccess: false)
    expect(ok, "prepare ok")
    expect(rec.timers.count == 1 && !rec.timers[0].repeating, "one one-shot timeout timer")
    rec.chownOutcome = { _, _ in 1 }                       // restore fails
    rec.fire(0)                                          // lease timeout fires
    let recovering = rec.journalWrites.last.flatMap(decodeEntries) ?? []
    expect(recovering.count == 1 && recovering[0].phase == "recovering",
           "failed timeout restore keeps the record: \(recovering.map(\.key))")
    expect(rec.timers.last?.repeating == true, "retry timer must be repeating")
    let writesBeforeRetry = rec.journalWrites.count
    rec.chownOutcome = { _, _ in 0 }                       // retry succeeds
    rec.fireLast()
    expect(rec.journalWrites.count > writesBeforeRetry,
           "retry after fault clearance produced a NEW journal write")
    guard let final = clearedJournal(rec) else {
        return expect(false, "the new last write must exist and decode (absent/undecodable ≠ cleared)")
    }
    expect(final.isEmpty, "successful retry clears the journal")
}

func testDisconnectReleaseAllFailsThenRetrySucceeds() {
    let rec = Recorder()
    rec.statResults["/dev/disk9s1"] = devStat()
    MountQuery.probe = { _ in .unmounted }
    let store = DeviceLeaseStore(effects: makeEffects(rec))
    _ = store.bootstrapAndRecover()
    let owner = UUID()
    let (ok, _) = prepareHelper(store, key: "/dev/disk9s1", nodes: ["/dev/disk9s1"],
                                owner: owner, writeAccess: false)
    expect(ok, "prepare ok")
    rec.chownOutcome = { _, _ in 1 }
    store.releaseAll(ownedBy: owner)                     // connection dropped
    let recovering = rec.journalWrites.last.flatMap(decodeEntries) ?? []
    expect(recovering.count == 1 && recovering[0].phase == "recovering",
           "failed release restore keeps the record")
    let writesBeforeRetry = rec.journalWrites.count
    rec.chownOutcome = { _, _ in 0 }
    rec.fireLast()
    expect(rec.journalWrites.count > writesBeforeRetry,
           "retry after fault clearance produced a NEW journal write")
    guard let final = clearedJournal(rec) else {
        return expect(false, "the new last write must exist and decode (absent/undecodable ≠ cleared)")
    }
    expect(final.isEmpty, "successful retry clears the journal")
}

// a recovering lease is never reused; a stale timer callback
// carrying an old leaseID must not touch a newer lease.
func testRecoveringNotReusedAndStaleTimerIgnored() {
    let rec = Recorder()
    rec.statResults["/dev/disk9s1"] = devStat()
    MountQuery.probe = { _ in .unmounted }
    let store = DeviceLeaseStore(effects: makeEffects(rec))
    _ = store.bootstrapAndRecover()
    let owner = UUID()
    let (ok1, _) = prepareHelper(store, key: "/dev/disk9s1", nodes: ["/dev/disk9s1"],
                                 owner: owner, writeAccess: false)
    expect(ok1, "first prepare ok")
    rec.chownOutcome = { _, _ in 1 }
    rec.fire(0)                                          // timeout → recovering
    let (reuse, reuseMsg) = prepareHelper(store, key: "/dev/disk9s1", nodes: ["/dev/disk9s1"],
                                          owner: owner, writeAccess: false)
    expect(!reuse && reuseMsg.contains("recovering"), "recovering lease must not be reused: \(reuseMsg)")
    rec.chownOutcome = { _, _ in 0 }
    rec.fireLast()                                       // retry succeeds
    let (ok2, _) = prepareHelper(store, key: "/dev/disk9s1", nodes: ["/dev/disk9s1"],
                                 owner: owner, writeAccess: false)
    expect(ok2, "prepare again ok after recovery")
    let chownsBefore = rec.chowns.count
    // Old repeating retry timer (canceled but in flight) fires late.
    rec.fireIgnoringCancel(1)
    expect(rec.chowns.count == chownsBefore,
           "stale leaseID callback must not touch the new lease (chowns grew)")
}

// a failed mount query refuses prepare before any node work.
func testMountQueryFailureRefusesPrepare() {
    let rec = Recorder()
    rec.statResults["/dev/disk9s1"] = devStat()
    MountQuery.probe = { _ in .queryFailed("boom") }
    let store = DeviceLeaseStore(effects: makeEffects(rec))
    _ = store.bootstrapAndRecover()
    let (ok, msg) = prepareHelper(store, key: "/dev/disk9s1", nodes: ["/dev/disk9s1"],
                                  owner: UUID(), writeAccess: false)
    expect(!ok, "prepare must refuse on query failure")
    expect(msg.contains("mount table query failed"), "refusal must name the query failure: \(msg)")
    expect(rec.statCalls.isEmpty && rec.chowns.isEmpty && rec.chmods.isEmpty,
           "no node access at all on query failure")
}

// Pure layer: MountQuery.reduce is tri-state and never picks a first match.
func testMountQueryReduceTriState() {
    let e1 = MountEntry(device: "/dev/disk4s1", path: "/Volumes/A", fstype: "openntfs", readOnly: false)
    expect(MountQuery.reduce(device: "/dev/disk4s1", entries: []) == .unmounted,
           "no match → unmounted")
    if case .mounted(let m) = MountQuery.reduce(device: "/dev/disk4s1", entries: [e1]) {
        expect(m.path == "/Volumes/A" && !m.readOnly, "single match → mounted entry")
    } else {
        expect(false, "single match must be .mounted")
    }
    let e2 = MountEntry(device: "/dev/disk4s1", path: "/Volumes/B", fstype: "ntfs", readOnly: true)
    if case .queryFailed(let why) = MountQuery.reduce(device: "/dev/disk4s1", entries: [e1, e2]) {
        expect(why.contains("2 times"), "ambiguous table must fail closed: \(why)")
    } else {
        expect(false, "two matches must be .queryFailed, not first-match")
    }
    // Prefix-less alias (unverified assumption) still reports mounted.
    let e3 = MountEntry(device: "disk4s1", path: "/Volumes/C", fstype: "ntfs", readOnly: true)
    if case .mounted = MountQuery.reduce(device: "/dev/disk4s1", entries: [e3]) {
        expect(true, "alias match → mounted")
    } else {
        expect(false, "prefix-less alias should map to mounted")
    }
}

// Policy layer: an existing read-write mount never bypasses a
// read-only policy; a failed corrective unmount is reported as
// still-mounted, never as unmounted.
func testRemountPolicyDecisions() {
    // Foreign RW volume remounted RW by someone else → must correct, never accept.
    expect(MaintenancePolicy.decisionForExistingMount(wasOurs: false, wasReadOnly: false,
                                                      mountedByOurs: false, mountedReadOnly: false)
           == .unmountAndRemountReadOnly,
           "foreign-origin RW: existing RW mount must not be accepted")
    expect(MaintenancePolicy.decisionForExistingMount(wasOurs: true, wasReadOnly: true,
                                                      mountedByOurs: false, mountedReadOnly: false)
           == .unmountAndRemountReadOnly,
           "was-RO-ours: existing RW mount must not be accepted")
    // Compliant existing mounts are accepted.
    expect(MaintenancePolicy.decisionForExistingMount(wasOurs: false, wasReadOnly: true,
                                                      mountedByOurs: false, mountedReadOnly: true)
           == .accept, "RO expected + RO mounted → accept")
    expect(MaintenancePolicy.decisionForExistingMount(wasOurs: true, wasReadOnly: false,
                                                      mountedByOurs: true, mountedReadOnly: false)
           == .accept, "ours-RW expected + ours-RW mounted → accept")
    // RW expected but mount is not ours-RW → takeover, never accept.
    expect(MaintenancePolicy.decisionForExistingMount(wasOurs: true, wasReadOnly: false,
                                                      mountedByOurs: false, mountedReadOnly: false)
           == .takeoverReadWrite, "foreign RW where ours-RW expected → takeover")
    expect(MaintenancePolicy.decisionForExistingMount(wasOurs: true, wasReadOnly: false,
                                                      mountedByOurs: true, mountedReadOnly: true)
           == .takeoverReadWrite, "ours mounted RO where RW expected → takeover")

    // Read-only ceiling.
    expect(!MaintenancePolicy.expectsReadOnly(wasOurs: true, wasReadOnly: false),
           "ours RW → RW allowed")
    expect(MaintenancePolicy.expectsReadOnly(wasOurs: true, wasReadOnly: true),
           "ours RO → RO")
    expect(MaintenancePolicy.expectsReadOnly(wasOurs: false, wasReadOnly: false),
           "foreign RW → conservative RO")

    // Corrective-unmount reporting.
    expect(MaintenancePolicy.afterCorrectiveUnmount(unmountSucceeded: false)
           == .reportStillMountedReadWrite,
           "failed corrective unmount must report still-mounted-RW")
    expect(MaintenancePolicy.afterCorrectiveUnmount(unmountSucceeded: true)
           == .remountPerPolicy,
           "successful corrective unmount proceeds per policy")
}

// Helper side: restore failures return details the caller can
// surface (the app maps them into the maintenance result).
func testRestoreFailureReturnsNodeDetails() {
    let rec = Recorder()
    rec.statResults["/dev/disk9s1"] = devStat()
    MountQuery.probe = { _ in .unmounted }
    let store = DeviceLeaseStore(effects: makeEffects(rec))
    _ = store.bootstrapAndRecover()
    let owner = UUID()
    let (ok, _) = prepareHelper(store, key: "/dev/disk9s1", nodes: ["/dev/disk9s1"],
                                owner: owner, writeAccess: false)
    expect(ok, "prepare ok")
    rec.chownOutcome = { _, _ in 1 }
    let (rok, rmsg) = store.restore(key: "/dev/disk9s1", owner: owner)
    expect(!rok, "restore must fail while chown fails")
    expect(rmsg.contains("restore incomplete") && rmsg.contains("/dev/disk9s1"),
           "restore failure must name the node: \(rmsg)")
}

// identity change (node replaced) quarantines the record and stops all
// automatic chown/chmod; a clear diagnostic is logged; manual restore and
// new prepares on that key are refused while the record is kept.
func testIdentityChangeQuarantinesAndStopsAutoRestore() {
    let rec = Recorder()
    rec.statResults["/dev/disk9s1"] = devStat()
    MountQuery.probe = { _ in .unmounted }
    let store = DeviceLeaseStore(effects: makeEffects(rec))
    _ = store.bootstrapAndRecover()
    let owner = UUID()
    let (ok, _) = prepareHelper(store, key: "/dev/disk9s1", nodes: ["/dev/disk9s1"],
                                owner: owner, writeAccess: false)
    expect(ok, "prepare ok")
    // The device is unplugged and a DIFFERENT device reuses the same node
    // name (new ino/rdev/birthtime).
    rec.statResults["/dev/disk9s1"] = devStat(rdev: 0x2222_3333, ino: 9999,
                                               birthSec: 1_700_000_999)
    rec.fire(0)                                          // timeout fires
    guard let last = rec.journalWrites.last.flatMap(decodeEntries) else {
        return expect(false, "journal write expected after quarantine")
    }
    expect(last.count == 1 && last[0].phase == "quarantined",
           "identity change must persist a quarantined record: \(last)")
    let restoreChownCount = rec.chowns.filter { $0.uid == 501 }.count
    expect(restoreChownCount == 0,
           "no restore chown may run against a mismatched identity (got \(restoreChownCount))")
    expect(rec.logs.contains { $0.isError && $0.message.contains("QUARANTINED") },
           "a clear quarantine diagnostic must be logged")
    // Manual restore RPC is also refused while identity is unconfirmed.
    let (rok, rmsg) = store.restore(key: "/dev/disk9s1", owner: owner)
    expect(!rok && rmsg.contains("quarantined"), "manual restore must refuse quarantined lease: \(rmsg)")
    // New prepares on the quarantined key are refused (record is not lost).
    let (pok, pmsg) = prepareHelper(store, key: "/dev/disk9s1", nodes: ["/dev/disk9s1"],
                                    owner: UUID(), writeAccess: false)
    expect(!pok && pmsg.contains("quarantined"), "prepare must refuse quarantined key: \(pmsg)")
}

// same identity (helper restart within one boot) → recovery proceeds.
func testIdentityMatchAcrossHelperRestartRecovers() {
    let rec = Recorder()
    rec.statResults["/dev/disk9s1"] = devStat()
    rec.journalData = journalData([makeEntry(key: "/dev/disk9s1", nodes: [nodeA])])
    let store = DeviceLeaseStore(effects: makeEffects(rec))
    let boot = store.bootstrapAndRecover()
    expect(boot == .recovered, "journal recovery runs")
    guard let final = clearedJournal(rec) else {
        return expect(false, "restart produced no decodable successful journal write (absent/undecodable ≠ cleared)")
    }
    expect(final.isEmpty, "matching identity → restore proceeds and clears: \(final.map(\.key))")
}

// Follow-up writes: journal persist failure AFTER nodes were restored
// keeps the record (never silently dropped); a later retry re-persists.
func testPersistFailureAfterRestoreKeepsRecord() {
    let rec = Recorder()
    rec.statResults["/dev/disk9s1"] = devStat()
    rec.journalData = journalData([makeEntry(key: "/dev/disk9s1", nodes: [nodeA])])
    rec.journalWriteError = NSError(domain: "test", code: 5)   // all writes fail
    let store = DeviceLeaseStore(effects: makeEffects(rec))
    let boot = store.bootstrapAndRecover()
    expect(boot == .recovered, "recovery attempt still runs (persist failure is reported, not hidden)")
    expect(rec.chowns.contains { $0.path == "/dev/disk9s1" && $0.uid == 501 },
           "nodes are still restored even though journal persist fails")
    // Record kept: retry timer armed; with writes working again the next
    // retry re-persists and clears.
    let writesBeforeRetry = rec.journalWrites.count   // 0: every write failed so far
    rec.journalWriteError = nil
    rec.fireLast()
    expect(rec.journalWrites.count > writesBeforeRetry,
           "retry after fault clearance produced a NEW SUCCESSFUL journal write")
    guard let final = clearedJournal(rec) else {
        return expect(false, "the new last write must exist and decode (absent/undecodable ≠ cleared)")
    }
    expect(final.isEmpty, "retry must re-persist and clear: \(final.map(\.key))")
}

// rollback after a failed grant must check node identity BEFORE any
// modification — a replaced node is quarantined untouched, never chown'ed.
func testAbortRollbackChecksIdentityBeforeModify() {
    let rec = Recorder()
    rec.statResults["/dev/disk9s1"] = devStat()
    rec.statResults["/dev/rdisk9s1"] = devStat(fileType: mode_t(S_IFCHR), rdev: nodeB.rdev)
    MountQuery.probe = { _ in .unmounted }
    // chmod on rdisk fails mid-grant; AT THAT MOMENT the rdisk node is
    // replaced by a different device (identity changes between grant and
    // rollback).
    rec.chmodOutcome = { path in
        if path == "/dev/rdisk9s1" {
            rec.statResults["/dev/rdisk9s1"] = devStat(fileType: mode_t(S_IFCHR), rdev: 0x2222_3333, ino: 9999,
                                                       birthSec: 1_700_000_999)
            return 1
        }
        return 0
    }
    let store = DeviceLeaseStore(effects: makeEffects(rec))
    _ = store.bootstrapAndRecover()
    let (ok, msg) = prepareHelper(store, key: "/dev/disk9s1",
                                  nodes: ["/dev/disk9s1", "/dev/rdisk9s1"],
                                  owner: UUID(), writeAccess: true)
    expect(!ok, "prepare must fail")
    expect(msg.contains("QUARANTINED"), "identity mismatch during rollback must quarantine: \(msg)")
    // The replaced node was granted to the client earlier, but rollback must
    // NOT chown/chmod it back (identity checked before modification).
    expect(rec.chowns.contains { $0.path == "/dev/rdisk9s1" && $0.uid == 1000 },
           "sanity: rdisk was granted to the client before the failure")
    expect(!rec.chowns.contains { $0.path == "/dev/rdisk9s1" && $0.uid == 501 },
           "rollback must not modify the replaced node: \(rec.chowns)")
    guard let last = rec.journalWrites.last.flatMap(decodeEntries) else {
        return expect(false, "journal write expected after quarantine")
    }
    expect(last.count == 1 && last[0].phase == "quarantined"
           && last[0].nodes.map(\.path) == ["/dev/rdisk9s1"],
           "replaced node must be journaled quarantined: \(last)")
}

// MARK: JournalFile (real file IO on temp directories; trustedUID = current
// user so the ownership policy is exercised with the same code path
// production uses with root). No production journal path is ever touched.

// Scene management: temp dirs created by tests are REGISTERED here
// and owned by the enclosing runTest — removed only when the whole test
// passed; kept (path printed) on any assertion failure or throw. Names are
// unique per process (run token + counter); an existing path is never
// deleted or reused, so prior failure scenes cannot be overwritten.
private let sceneRunToken = UUID().uuidString.prefix(8)
private var sceneCounter = 0
var activeScenes: [URL] = []

func makeScene(_ name: String) -> URL {
    sceneCounter += 1
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("lease-store-scene-\(sceneRunToken)-\(name)-\(sceneCounter)",
                                isDirectory: true)
    // Startup self-check: the test must only ever operate inside the
    // per-process temporary directory.
    precondition(dir.path.hasPrefix(NSTemporaryDirectory()),
                 "scene escapes the temporary directory: \(dir.path)")
    precondition(!FileManager.default.fileExists(atPath: dir.path),
                 "scene path already exists; refusing to reuse/overwrite: \(dir.path)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    activeScenes.append(dir)
    return dir
}

func expectThrows(_ body: () throws -> Void, _ needle: String, _ what: String,
                  line: UInt = #line) {
    do {
        try body()
        expect(false, "\(what): expected a throw containing \"\(needle)\"", line: line)
    } catch {
        expect(error.localizedDescription.contains(needle),
               "\(what): error must contain \"\(needle)\", got: \(error.localizedDescription)", line: line)
    }
}

func testJournalFileRoundtripAndModes() throws {
    let dir = makeScene("jf-roundtrip")
    let path = dir.appendingPathComponent("leases.json").path
    let payload = Data("{\"a\":1}".utf8)
    try JournalFile.write(path: path, data: payload, trustedUID: getuid())
    let back = try JournalFile.read(path: path, trustedUID: getuid())
    expect(back == payload, "roundtrip content equal")
    var st = stat()
    expect(Darwin.lstat(path, &st) == 0, "journal lstat")
    expect(st.st_mode & S_IFMT == S_IFREG, "journal is a regular file")
    expect((st.st_mode & 0o777) == 0o600,
           "journal mode must be 0600, got 0\(String(st.st_mode & 0o777, radix: 8))")
    expect(st.st_uid == getuid(), "journal owned by the trusted uid")
    expect(Darwin.lstat(dir.path, &st) == 0, "dir lstat")
    expect((st.st_mode & 0o777) == 0o755,
           "journal dir mode must be 0755, got 0\(String(st.st_mode & 0o777, radix: 8))")
}

func testJournalFileMissingReturnsNil() throws {
    let dir = makeScene("jf-missing")
    let path = dir.appendingPathComponent("leases.json").path
    let data = try JournalFile.read(path: path, trustedUID: getuid())
    expect(data == nil, "missing journal reads as nil")
}

func testJournalFileRejectsLooseExistingFile() throws {
    let dir = makeScene("jf-loosefile")
    let path = dir.appendingPathComponent("leases.json").path
    try JournalFile.write(path: path, data: Data("x".utf8), trustedUID: getuid())
    // Group-writable journal: contents not trusted, read refuses.
    expect(chmod(path, 0o666) == 0, "chmod 0666")
    expectThrows({ _ = try JournalFile.read(path: path, trustedUID: getuid()) },
                 "writable by group/others", "group-writable journal")
    // Owner-only modes remain readable (0640: group read, no group write).
    expect(chmod(path, 0o640) == 0, "chmod 0640")
    expect((try JournalFile.read(path: path, trustedUID: getuid())) != nil,
           "0640 journal (no group write) is trusted")
}

func testJournalFileRejectsForeignOwner() throws {
    let dir = makeScene("jf-owner")
    let path = dir.appendingPathComponent("leases.json").path
    try JournalFile.write(path: path, data: Data("x".utf8), trustedUID: getuid())
    // Claim a DIFFERENT trusted uid: the existing owner no longer matches.
    expectThrows({ _ = try JournalFile.read(path: path, trustedUID: getuid() + 1) },
                 "owned by uid", "foreign-owned journal")
}

func testJournalFileRejectsLooseExistingDir() throws {
    let dir = makeScene("jf-loosedir")
    let path = dir.appendingPathComponent("leases.json").path
    expect(chmod(dir.path, 0o777) == 0, "chmod dir 0777")
    // Pre-existing loose directory is verified and REJECTED, never tightened
    // and then trusted (neither for reading nor for writing).
    expectThrows({ _ = try JournalFile.read(path: path, trustedUID: getuid()) },
                 "writable by group/others", "loose existing dir (read)")
    expectThrows({ try JournalFile.write(path: path, data: Data("x".utf8), trustedUID: getuid()) },
                 "writable by group/others", "loose existing dir (write)")
    // And it was NOT silently tightened: still 0777 afterwards.
    var st = stat()
    _ = Darwin.lstat(dir.path, &st)
    expect((st.st_mode & 0o777) == 0o777, "loose dir must not be auto-tightened")
}

func testJournalFileRejectsSymlinks() throws {
    let dir = makeScene("jf-symlink")
    let target = dir.appendingPathComponent("real.json")
    try Data("x".utf8).write(to: target)
    let linkPath = dir.appendingPathComponent("leases.json").path
    try FileManager.default.createSymbolicLink(atPath: linkPath,
                                               withDestinationPath: target.path)
    expectThrows({ _ = try JournalFile.read(path: linkPath, trustedUID: getuid()) },
                 "symlink refused", "symlinked journal file")
    // A symlinked journal DIRECTORY is also rejected (lstat, not followed).
    let realDir = dir.appendingPathComponent("realdir", isDirectory: true)
    try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
    let linkDir = dir.appendingPathComponent("linkdir")
    try FileManager.default.createSymbolicLink(atPath: linkDir.path,
                                               withDestinationPath: realDir.path)
    expectThrows({ _ = try JournalFile.read(path: linkDir.appendingPathComponent("leases.json").path,
                                            trustedUID: getuid()) },
                 "failed safety checks", "symlinked journal directory")
}

func testJournalFileFailedWritePreservesOriginalAndCleansTemp() throws {
    let dir = makeScene("jf-writefail")
    let path = dir.appendingPathComponent("leases.json").path
    let original = Data("original".utf8)
    try JournalFile.write(path: path, data: original, trustedUID: getuid())
    // Failure position: the temp file cannot even be created (read-only
    // directory) — i.e. before/at rename. The original journal must survive
    // and no *.tmp* leftovers may remain.
    expect(chmod(dir.path, 0o500) == 0, "chmod dir read-only")
    expectThrows({ try JournalFile.write(path: path, data: Data("new".utf8), trustedUID: getuid()) },
                 "failed", "write into read-only dir")
    expect(chmod(dir.path, 0o755) == 0, "restore dir perms")
    let back = try JournalFile.read(path: path, trustedUID: getuid())
    expect(back == original, "original journal preserved after failed write")
    let leftovers = (try FileManager.default.contentsOfDirectory(atPath: dir.path))
        .filter { $0.contains(".tmp.") }
    expect(leftovers.isEmpty, "no temp-file leftovers after failed write: \(leftovers)")
}

// MARK: JournalFile write-trust + mkdir EEXIST race

private func restoreMkdirHook() {
    JournalFile.mkdirHook = { path, mode in Darwin.mkdir(path, mode) }
}

func fileMode(_ path: String) -> mode_t {
    var st = stat()
    _ = Darwin.lstat(path, &st)
    return st.st_mode & 0o7777
}

// an existing 0666 journal is refused by write, content AND mode unchanged.
func testJournalFileWriteRefusesLooseExistingJournal() throws {
    let dir = makeScene("jf-write-loose")
    let path = dir.appendingPathComponent("leases.json").path
    try Data("old-content".utf8).write(to: URL(fileURLWithPath: path))
    precondition(chmod(path, 0o666) == 0, "chmod 0666")
    expectThrows({ try JournalFile.write(path: path, data: Data("new".utf8), trustedUID: getuid()) },
                 "writable by group/others", "write to 0666 journal")
    expect((try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)) == "old-content",
           "0666 journal content unchanged after refused write")
    expect(fileMode(path) == 0o666,
           "0666 journal mode unchanged (got 0\(String(fileMode(path), radix: 8)))")
}

// a LOOSE (0666) journal under a TRUSTED parent
// directory — the refusal must come from the FILE check, not be preempted by
// a directory error. The error message must name the journal FILE.
func testJournalFileWriteLooseFilePinnedToFileCheck() throws {
    let dir = makeScene("jf-write-loose-pinned")
    let path = dir.appendingPathComponent("leases.json").path
    let original = Data("keep-me".utf8)
    try original.write(to: URL(fileURLWithPath: path))
    precondition(chmod(path, 0o666) == 0, "chmod 0666")
    precondition(fileMode(dir.path) == 0o755, "parent dir trusted 0755")
    do {
        try JournalFile.write(path: path, data: Data("new".utf8), trustedUID: getuid())
        expect(false, "expected the file-level trust failure")
    } catch {
        let msg = error.localizedDescription
        expect(msg.contains("journal file"),
               "failure must be pinned to the journal FILE (not the directory): \(msg)")
        expect(msg.contains("writable by group/others"),
               "failure must be the trust check: \(msg)")
    }
    expect((try? Data(contentsOf: URL(fileURLWithPath: path))) == original,
           "journal content unchanged")
    expect(fileMode(path) == 0o666, "journal mode unchanged")
}

// REAL owner mismatch on the write path, with type and mode
// perfectly normal (regular file, 0600). The foreign owner is supplied by a
// METADATA-QUERY STUB (`existingEntryLstatHook`): the stub calls the real
// lstat and alters ONLY the returned st_uid for the journal path — no real
// cross-UID state exists on disk, and this is NOT a cross-UID exercise; the
// actual file keeps its real owner throughout. All trust judgments run the
// real JournalFile.write / verifyTrusted.
func testJournalFileWriteRefusesForeignOwnedJournalViaMetadataStub() throws {
    let dir = makeScene("jf-write-owner-stub")
    let path = dir.appendingPathComponent("leases.json").path
    let original = Data("keep-me".utf8)
    try original.write(to: URL(fileURLWithPath: path))
    precondition(chmod(path, 0o600) == 0, "normal mode 0600")
    precondition(fileMode(dir.path) == 0o755, "parent dir trusted 0755")
    JournalFile.existingEntryLstatHook = { p, st in
        let rc = Darwin.lstat(p, st)
        if rc == 0 && p == path {
            st.pointee.st_uid = getuid() + 1   // foreign owner — QUERY RESULT ONLY
        }
        return rc
    }
    defer { JournalFile.existingEntryLstatHook = nil }
    do {
        try JournalFile.write(path: path, data: Data("new".utf8), trustedUID: getuid())
        expect(false, "expected owner-mismatch refusal")
    } catch {
        let msg = error.localizedDescription
        expect(msg.contains("journal file"),
               "refusal pinned to the journal FILE check (no directory preemption): \(msg)")
        expect(msg.contains("owned by uid"),
               "refusal must be the ownership branch: \(msg)")
    }
    expect((try? Data(contentsOf: URL(fileURLWithPath: path))) == original,
           "content unchanged (no overwrite)")
    expect(fileMode(path) == 0o600, "mode unchanged")
    var realSt = stat()
    _ = Darwin.lstat(path, &realSt)
    expect(realSt.st_uid == getuid(),
           "real on-disk owner untouched (the stub was query-side only)")
    let entries = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    expect(entries == ["leases.json"],
           "no temp files or other side effects in the directory: \(entries)")
}

// a trusted journal updates normally; a missing journal is created.
func testJournalFileTrustedUpdateAndCreation() throws {
    let dir = makeScene("jf-write-ok")
    let path = dir.appendingPathComponent("leases.json").path
    try JournalFile.write(path: path, data: Data("first".utf8), trustedUID: getuid())
    try JournalFile.write(path: path, data: Data("second".utf8), trustedUID: getuid())
    expect((try? Data(contentsOf: URL(fileURLWithPath: path))) == Data("second".utf8),
           "trusted journal updated in place")
    expect(fileMode(path) == 0o600, "updated journal keeps 0600")
    // Missing journal (and missing directory) → normal first creation.
    let fresh = dir.appendingPathComponent("nested/leases.json").path
    try JournalFile.write(path: fresh, data: Data("created".utf8), trustedUID: getuid())
    expect((try? Data(contentsOf: URL(fileURLWithPath: fresh))) == Data("created".utf8),
           "missing journal created")
}

// lstat says ENOENT, mkdir says EEXIST (a create race lost to another
// subject — simulated by the hook creating the entry, then reporting
// EEXIST). The entry is then treated as PRE-EXISTING: verified, never
// modified.
func testJournalFileMkdirEEXISTRaceTreatedAsExisting() throws {
    // D1: racer created a trusted 0700 directory → verified and ALLOWED,
    // with ZERO modification (a retrofit chmod would have forced 0755).
    let dir1 = makeScene("jf-eexist-ok")
    let journal1 = dir1.appendingPathComponent("jd/leases.json").path
    JournalFile.mkdirHook = { path, _ in
        try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false,
                                                 attributes: [.posixPermissions: 0o700])
        errno = EEXIST
        return -1
    }
    defer { restoreMkdirHook() }
    try JournalFile.write(path: journal1, data: Data("x".utf8), trustedUID: getuid())
    expect(fileMode(dir1.appendingPathComponent("jd").path) == 0o700,
           "racer's 0700 directory must be used UNMODIFIED (no chmod to 0755)")
    expect(FileManager.default.fileExists(atPath: journal1), "journal written after verified EEXIST race")

    // D2: racer created an UNTRUSTED 0777 directory → refused, unmodified,
    // no journal created.
    let dir2 = makeScene("jf-eexist-loose")
    let journal2 = dir2.appendingPathComponent("jd/leases.json").path
    JournalFile.mkdirHook = { path, _ in
        try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false,
                                                 attributes: [.posixPermissions: 0o777])
        errno = EEXIST
        return -1
    }
    expectThrows({ try JournalFile.write(path: journal2, data: Data("x".utf8), trustedUID: getuid()) },
                 "writable by group/others", "EEXIST race with 0777 directory")
    expect(fileMode(dir2.appendingPathComponent("jd").path) == 0o777,
           "racer's 0777 directory must NOT be chmod'ed into trust")
    expect(!FileManager.default.fileExists(atPath: journal2), "no journal written into untrusted directory")

    // D3: racer created a SYMLINK at the directory path → refused, link intact.
    let dir3 = makeScene("jf-eexist-symlink")
    let realTarget = dir3.appendingPathComponent("real")
    try FileManager.default.createDirectory(at: realTarget, withIntermediateDirectories: true)
    let journal3 = dir3.appendingPathComponent("link/leases.json").path
    JournalFile.mkdirHook = { path, _ in
        try! FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: realTarget.path)
        errno = EEXIST
        return -1
    }
    expectThrows({ try JournalFile.write(path: journal3, data: Data("x".utf8), trustedUID: getuid()) },
                 "failed safety checks", "EEXIST race with symlink")
    var st = stat()
    _ = Darwin.lstat(dir3.appendingPathComponent("link").path, &st)
    expect(st.st_mode & S_IFMT == S_IFLNK, "symlink left intact (not followed, not replaced)")

    // D4: racer created a REGULAR FILE at the directory path → refused.
    let dir4 = makeScene("jf-eexist-file")
    let journal4 = dir4.appendingPathComponent("blocker/leases.json").path
    JournalFile.mkdirHook = { path, _ in
        try! Data("blocker".utf8).write(to: URL(fileURLWithPath: path))
        errno = EEXIST
        return -1
    }
    expectThrows({ try JournalFile.write(path: journal4, data: Data("x".utf8), trustedUID: getuid()) },
                 "failed safety checks", "EEXIST race with non-directory")
    expect((try? Data(contentsOf: dir4.appendingPathComponent("blocker"))) == Data("blocker".utf8),
           "blocking regular file left unchanged")
}

// other mkdir errors propagate; no directory or journal is created.
func testJournalFileMkdirOtherErrorPropagates() throws {
    let dir = makeScene("jf-mkdir-err")
    let journal = dir.appendingPathComponent("jd/leases.json").path
    JournalFile.mkdirHook = { _, _ in
        errno = EACCES
        return -1
    }
    defer { restoreMkdirHook() }
    expectThrows({ try JournalFile.write(path: journal, data: Data("x".utf8), trustedUID: getuid()) },
                 "Permission denied", "mkdir EACCES propagation")
    expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("jd").path),
           "no directory created/modified after mkdir failure")
    expect(!FileManager.default.fileExists(atPath: journal), "no journal created after mkdir failure")
}

// MARK: - Sync/rename failure contract (JournalFile + store linkage)
//
// These tests use the REAL JournalFile read/write on real temp files (the
// store's effects closures call JournalFile directly at a temp path — the
// same implementation production uses), with device syscalls stubbed via
// the Recorder. Syscall failures (sync stages, rename) are injected through
// JournalFile's minimal hooks, which replace ONE external syscall each and
// must call the real syscall when simulating "let it through". Hooks are
// always restored. This is offline fault injection on ordinary temp files —
// NOT a real disk-full/power-loss/durability drill.

func restoreSyncHooks() {
    JournalFile.fileFullSyncHook = nil
    JournalFile.fileSyncHook = nil
    JournalFile.dirFullSyncHook = nil
    JournalFile.dirSyncHook = nil
    JournalFile.renameHook = nil
}

/// Effects with REAL JournalFile IO at `journalPath` and STATEFUL device
/// stubs: a SUCCESSFUL chown/chmod updates the stub node's uid/gid/mode
/// (failed calls change nothing), and statNode returns the current stub
/// state (identity fields stay under test control), so the real
/// restoreNode's post-restore verification checks actual modeled metadata.
/// Recording-only Recorder semantics for the older tests are unchanged.
func makeRealJournalEffects(_ rec: Recorder, journalPath: String) -> LeaseEffects {
    LeaseEffects(
        statNode: { path in
            rec.statCalls.append(path)
            return rec.statResults[path] ?? nil
        },
        collectDAFacts: { bsd in
            rec.daFactsCalls.append(bsd)
            if let o = rec.daFactsOverride { return o(bsd) }
            return .facts(syntheticQualifyingFacts(bsd: bsd, rec: rec))
        },
        chownNode: { path, uid, gid in
            rec.chowns.append((path, uid, gid))
            guard rec.chownOutcome(path, uid) == 0 else { return 1 }
            if var st = (rec.statResults[path] ?? nil) {
                st.st_uid = uid
                st.st_gid = gid
                rec.statResults[path] = st
            }
            return 0
        },
        chmodNode: { path, mode in
            rec.chmods.append((path, mode))
            guard rec.chmodOutcome(path) == 0 else { return 1 }
            if var st = (rec.statResults[path] ?? nil) {
                st.st_mode = (st.st_mode & ~mode_t(0o7777)) | (mode & 0o7777)
                rec.statResults[path] = st
            }
            return 0
        },
        readJournal: { try JournalFile.read(path: journalPath, trustedUID: getuid()) },
        writeJournal: { data in
            try JournalFile.write(path: journalPath, data: data, trustedUID: getuid())
        },
        schedule: { _, repeating, handler in
            let id = rec.timers.count
            rec.timers.append((id, repeating, handler, false))
            return StubTimer(rec: rec, id: id)
        },
        log: { isError, message in
            rec.logs.append((isError, message))
        })
}

/// Visible-journal probe with DISTINGUISHABLE, fail-closed states: a missing
/// file is `.absent` (NOT an empty journal); read failures (IO, trust) and
/// decode failures (corrupt content) THROW. Judged by the REAL JournalFile
/// reader + real JSON decode — no reimplementation.
enum VisibleJournal {
    /// The journal file does not exist — distinct from an empty journal.
    case absent
    /// Trusted read AND decode both succeeded.
    case present([DeviceLeaseStore.JournalEntry])
}

func describe(_ v: VisibleJournal) -> String {
    switch v {
    case .absent: return ".absent"
    case .present(let e): return ".present(\(e.map { "\($0.key):\($0.phase)" }))"
    }
}

func readVisibleJournal(_ path: String) throws -> VisibleJournal {
    guard let data = try JournalFile.read(path: path, trustedUID: getuid()) else {
        return .absent
    }
    do {
        return .present(try JSONDecoder().decode([DeviceLeaseStore.JournalEntry].self, from: data))
    } catch {
        throw NSError(domain: "readVisibleJournal", code: 1,
                      userInfo: [NSLocalizedDescriptionKey:
                        "journal visible but undecodable (corrupt): \(error.localizedDescription)"])
    }
}

/// "The journal is cleared" — ALL FOUR conditions: the file EXISTS, the
/// trusted read SUCCEEDS, decoding SUCCEEDS, and the records are exactly [].
/// A read/decode failure FAILS the test instead of reading as "empty".
func expectJournalCleared(_ path: String, _ what: String) throws {
    switch try readVisibleJournal(path) {
    case .absent:
        expect(false, "\(what): journal is ABSENT — that is not 'cleared'")
    case .present(let entries):
        expect(entries.isEmpty,
               "\(what): expected empty records, got \(entries.map { "\($0.key):\($0.phase)" })")
    }
}

/// Fail-closed temp-file probe: directory enumeration failures THROW (they
/// must fail the test), never masquerading as "no leftovers".
func tmpLeftovers(in dir: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: dir.path)
        .filter { $0.contains(".tmp.") }
}

// F_FULLFSYNC fails, fsync succeeds → the fallback chain completes the
// write; the call ORDER is full-sync-then-fsync, exactly once each.
func testJournalFileSyncFallbackChain() throws {
    let scene = makeScene("jfsync-s1")
    let path = scene.appendingPathComponent("leases.json").path
    defer { restoreSyncHooks() }
    var order: [String] = []
    JournalFile.fileFullSyncHook = { fd in
        order.append("fcntl")
        errno = EIO
        return -1
    }
    JournalFile.fileSyncHook = { fd in
        order.append("fsync")
        return Darwin.fsync(fd)
    }
    try JournalFile.write(path: path, data: Data("chain".utf8), trustedUID: getuid())
    expect(order == ["fcntl", "fsync"], "full fallback chain exercised in order: \(order)")
    expect((try? Data(contentsOf: URL(fileURLWithPath: path))) == Data("chain".utf8),
           "write completes when only the first sync stage fails")
}

// ALL temp-file sync paths fail → write fails, the OLD journal is
// untouched, rename is never reached, and no temp file is left behind.
func testJournalFileSyncAllPathsFail() throws {
    let scene = makeScene("jfsync-s2")
    let path = scene.appendingPathComponent("leases.json").path
    try JournalFile.write(path: path, data: Data("old".utf8), trustedUID: getuid())
    defer { restoreSyncHooks() }
    JournalFile.fileFullSyncHook = { _ in errno = EIO; return -1 }
    JournalFile.fileSyncHook = { _ in errno = EIO; return -1 }
    var renameCalls = 0
    JournalFile.renameHook = { from, to in
        renameCalls += 1
        return Darwin.rename(from, to)
    }
    expectThrows({ try JournalFile.write(path: path, data: Data("new".utf8), trustedUID: getuid()) },
                 "fsync(", "all sync paths failed")
    expect((try? Data(contentsOf: URL(fileURLWithPath: path))) == Data("old".utf8),
           "old journal content unchanged")
    expect(renameCalls == 0, "rename must NOT run after a confirmed sync failure")
    let leftovers2 = try tmpLeftovers(in: scene)
    expect(leftovers2.isEmpty, "no unexpected temp files left: \(leftovers2)")
}

// rename fails (injected BEFORE the real rename) → old journal intact,
// temp file cleaned up.
func testJournalFileRenameFail() throws {
    let scene = makeScene("jfsync-s3")
    let path = scene.appendingPathComponent("leases.json").path
    try JournalFile.write(path: path, data: Data("old".utf8), trustedUID: getuid())
    defer { restoreSyncHooks() }
    JournalFile.renameHook = { _, _ in errno = EINVAL; return -1 }   // real rename NOT called
    expectThrows({ try JournalFile.write(path: path, data: Data("new".utf8), trustedUID: getuid()) },
                 "rename(", "rename failure propagates")
    expect((try? Data(contentsOf: URL(fileURLWithPath: path))) == Data("old".utf8),
           "old journal content unchanged after rename failure")
    expect(try tmpLeftovers(in: scene).isEmpty, "temp file cleaned up after rename failure")
}

// the real rename COMPLETES, then every directory-sync path fails →
// write reports failure. The test OBSERVES the new version being visible by
// name; it does NOT claim the old version still exists, and it does NOT
// claim durability (that would need a real power-loss drill).
func testJournalFileDirSyncFailAfterRealRename() throws {
    let scene = makeScene("jfsync-s4")
    let path = scene.appendingPathComponent("leases.json").path
    try JournalFile.write(path: path, data: Data("old".utf8), trustedUID: getuid())
    defer { restoreSyncHooks() }
    JournalFile.renameHook = { from, to in Darwin.rename(from, to) }   // actually completes
    JournalFile.dirFullSyncHook = { _ in errno = EIO; return -1 }
    JournalFile.dirSyncHook = { _ in errno = EIO; return -1 }
    expectThrows({ try JournalFile.write(path: path, data: Data("new".utf8), trustedUID: getuid()) },
                 "fsync(", "directory sync failure after rename")
    expect((try? Data(contentsOf: URL(fileURLWithPath: path))) == Data("new".utf8),
           "NEW version is visible by name after the completed rename")
    expect(try tmpLeftovers(in: scene).isEmpty, "no temp leftovers (rename consumed the temp file)")
}

// Scenario 5: the FIRST persist of a prepare (the journal-first recovery
// record) fails — pre-rename AND post-rename — no device node may be
// touched, proved by the Recorder's call log.
func testStorePrepareJournalFirstPersistFailureZeroNodeMods() throws {
    defer { restoreSyncHooks() }

    // 5a: failure BEFORE rename (file sync fails on the first write).
    do {
        let scene = makeScene("jstore-s5a")
        let jp = scene.appendingPathComponent("leases.json").path
        let rec = Recorder()
        rec.statResults["/dev/disk9s1"] = devStat()
        MountQuery.probe = { _ in .unmounted }
        JournalFile.fileFullSyncHook = { _ in errno = EIO; return -1 }
        JournalFile.fileSyncHook = { _ in errno = EIO; return -1 }
        let store = DeviceLeaseStore(effects: makeRealJournalEffects(rec, journalPath: jp))
        expect(store.bootstrapAndRecover() == .clean, "clean start")
        let (ok, msg) = prepareHelper(store, key: "/dev/disk9s1", nodes: ["/dev/disk9s1"],
                                      owner: UUID(), writeAccess: false)
        expect(!ok, "prepare must refuse")
        expect(msg.contains("cannot persist lease journal"), "refusal names the persist failure: \(msg)")
        expect(rec.chowns.isEmpty && rec.chmods.isEmpty, "ZERO device modifications (pre-rename): \(rec.chowns)")
        if case .absent = try readVisibleJournal(jp) {
            expect(true, "no journal exists when the very first persist failed pre-rename")
        } else {
            expect(false, "journal must be ABSENT (distinct from empty) after the pre-rename first-persist failure")
        }
    }

    // 5b: failure AFTER rename (dir sync fails on the first write) — the
    // new record is VISIBLE but durability is unconfirmed; still zero node
    // modifications, and the visible record is the conservative (spurious
    // but safe) linkage a bootstrap would re-verify as a no-op.
    do {
        restoreSyncHooks()   // drop 5a's file-sync failures; this sub-scenario fails at dir-sync only
        let scene = makeScene("jstore-s5b")
        let jp = scene.appendingPathComponent("leases.json").path
        let rec = Recorder()
        rec.statResults["/dev/disk9s1"] = devStat()
        MountQuery.probe = { _ in .unmounted }
        JournalFile.renameHook = { from, to in Darwin.rename(from, to) }
        JournalFile.dirFullSyncHook = { _ in errno = EIO; return -1 }
        JournalFile.dirSyncHook = { _ in errno = EIO; return -1 }
        let store = DeviceLeaseStore(effects: makeRealJournalEffects(rec, journalPath: jp))
        expect(store.bootstrapAndRecover() == .clean, "clean start")
        let (ok, msg) = prepareHelper(store, key: "/dev/disk9s1", nodes: ["/dev/disk9s1"],
                                      owner: UUID(), writeAccess: false)
        expect(!ok, "prepare must refuse (post-rename persist failure)")
        expect(msg.contains("cannot persist lease journal"), "refusal names the persist failure: \(msg)")
        expect(rec.chowns.isEmpty && rec.chmods.isEmpty, "ZERO device modifications (post-rename): \(rec.chowns)")
        guard case .present(let entries) = try readVisibleJournal(jp),
              entries.count == 1, entries[0].key == "/dev/disk9s1", entries[0].phase == "recovering"
        else {
            return expect(false, "visible journal carries the conservative recovering record: \(describe(try readVisibleJournal(jp)))")
        }
    }
}

// Scenario 6: the ACTIVE-transition persist fails (post-rename) after the
// grant succeeded → the granted permissions go through the real rollback
// path; when the rollback's own persist also fails, the obligation is kept
// and internal recovery continues; prepare never reports success.
func testStoreActiveTransitionPersistFailureRollsBack() throws {
    let scene = makeScene("jstore-s6")
    let jp = scene.appendingPathComponent("leases.json").path
    defer { restoreSyncHooks() }
    let rec = Recorder()
    rec.statResults["/dev/disk9s1"] = devStat()
    MountQuery.probe = { _ in .unmounted }
    // Dir sync succeeds for write #1 (journal-first) and fails from write #2
    // (active transition) onward — post-rename failures via a REAL rename.
    let writes = Box(0)
    JournalFile.renameHook = { from, to in Darwin.rename(from, to) }
    JournalFile.dirFullSyncHook = { fd in
        writes.n += 1
        if writes.n >= 2 { errno = EIO; return -1 }
        return Darwin.fcntl(fd, F_FULLFSYNC)
    }
    JournalFile.dirSyncHook = { fd in
        if writes.n >= 2 { errno = EIO; return -1 }
        return Darwin.fsync(fd)
    }
    let store = DeviceLeaseStore(effects: makeRealJournalEffects(rec, journalPath: jp))
    _ = store.bootstrapAndRecover()
    let (ok, msg) = prepareHelper(store, key: "/dev/disk9s1", nodes: ["/dev/disk9s1"],
                                  owner: UUID(), writeAccess: true)
    expect(!ok, "prepare must NOT report success")
    expect(msg.contains("journal persist failed after grant"), "failure named: \(msg)")
    expect(msg.contains("rollback"), "message reports the rollback outcome: \(msg)")
    expect(rec.chowns.contains { $0.path == "/dev/disk9s1" && $0.uid == 1000 },
           "grant chown ran (journal-first record was durable)")
    expect(rec.chowns.contains { $0.path == "/dev/disk9s1" && $0.uid == 501 },
           "rollback chown ran through the shared restore path")
    if case .present(let entries) = try readVisibleJournal(jp) {
        expect(entries.isEmpty || (entries.count == 1 && entries[0].key == "/dev/disk9s1"),
               "visible journal only ever over-approximates the K1 obligation: \(entries.map(\.key))")
    } else {
        expect(false, "journal must be PRESENT after the durable journal-first write")
    }
    // Internal recovery continues: with sync healthy again the retry clears
    // the kept obligation and the lease disappears from memory.
    restoreSyncHooks()
    rec.fireLast()
    try expectJournalCleared(jp, "retry persist clears the journal (exists + trusted read + decode + empty)")
    let (rok, _) = store.restore(key: "/dev/disk9s1", owner: nil)
    expect(!rok, "lease removed from memory after the successful retry")
}

// Scenario 7: nodes are PHYSICALLY restored, but the record-REMOVAL persist
// fails post-rename → the result must distinguish "nodes restored" from
// "journal durability unconfirmed", and later retries must not lose the
// OTHER lease.
func testStoreRemovalPersistFailAfterRenameKeepsOtherLeases() throws {
    let scene = makeScene("jstore-s7")
    let jp = scene.appendingPathComponent("leases.json").path
    defer { restoreSyncHooks() }
    let rec = Recorder()
    rec.statResults["/dev/disk9s1"] = devStat()
    rec.statResults["/dev/disk10s1"] = devStat(rdev: 0x1111_2222, ino: 5151)
    MountQuery.probe = { _ in .unmounted }
    let store = DeviceLeaseStore(effects: makeRealJournalEffects(rec, journalPath: jp))
    _ = store.bootstrapAndRecover()
    let owner = UUID()
    let (ok1, _) = prepareHelper(store, key: "/dev/disk9s1", nodes: ["/dev/disk9s1"],
                                 owner: owner, writeAccess: false)
    let (ok2, _) = prepareHelper(store, key: "/dev/disk10s1", nodes: ["/dev/disk10s1"],
                                 owner: owner, writeAccess: false)
    expect(ok1 && ok2, "both leases prepared with durable journal-first records")
    // The K1-removal write (the FIRST write under this hook — both prepares
    // happened before hook installation) fails post-rename.
    let writes = Box(0)
    JournalFile.renameHook = { from, to in Darwin.rename(from, to) }
    JournalFile.dirFullSyncHook = { fd in
        writes.n += 1
        if writes.n >= 1 { errno = EIO; return -1 }
        return Darwin.fcntl(fd, F_FULLFSYNC)
    }
    JournalFile.dirSyncHook = { fd in
        if writes.n >= 1 { errno = EIO; return -1 }
        return Darwin.fsync(fd)
    }
    let (rok, rmsg) = store.restore(key: "/dev/disk9s1", owner: owner)
    expect(!rok, "restore must report the persist failure")
    expect(rmsg.contains("restore applied but journal persist failed"),
           "message distinguishes nodes-restored from durability-unconfirmed: \(rmsg)")
    expect(rec.chowns.contains { $0.path == "/dev/disk9s1" && $0.uid == 501 },
           "K1 nodes physically restored")
    guard case .present(let entries) = try readVisibleJournal(jp),
          entries.count == 1, entries[0].key == "/dev/disk10s1"
    else {
        return expect(false, "visible (unconfirmed) journal shows the removal, K2 still recorded: \(describe(try readVisibleJournal(jp)))")
    }
    // K2 must remain fully usable and restorable; the K1 retry must not
    // lose it.
    restoreSyncHooks()
    let (ok2r, msg2) = store.restore(key: "/dev/disk10s1", owner: owner)
    expect(ok2r, "other lease restores normally: \(msg2)")
    rec.fireLast()   // K1 retry: re-verify (idempotent) then persist
    try expectJournalCleared(jp, "retry re-persists the superset and clears (four-condition check)")
}

// Scenario 8: two leases; a write-boundary failure leaves a SURVIVING
// snapshot from which all outstanding obligations continue. The replay
// proves recovery FROM THAT SNAPSHOT — it is NOT a real power-loss or
// process-crash drill, and no Dictionary iteration order is relied
// upon.
func testStoreTwoLeasesWriteBoundaryFailureSnapshotReplay() throws {
    let scene = makeScene("jstore-s8")
    let jp = scene.appendingPathComponent("leases.json").path
    defer { restoreSyncHooks() }
    let rec = Recorder()
    rec.statResults["/dev/disk9s1"] = devStat()
    rec.statResults["/dev/disk10s1"] = devStat(rdev: 0x1111_2222, ino: 5151)
    MountQuery.probe = { _ in .unmounted }
    let store = DeviceLeaseStore(effects: makeRealJournalEffects(rec, journalPath: jp))
    _ = store.bootstrapAndRecover()
    let owner = UUID()
    _ = prepareHelper(store, key: "/dev/disk9s1", nodes: ["/dev/disk9s1"],
                      owner: owner, writeAccess: false)
    _ = prepareHelper(store, key: "/dev/disk10s1", nodes: ["/dev/disk10s1"],
                      owner: owner, writeAccess: false)
    // The K1-removal write (the FIRST write under this hook) fails BEFORE
    // rename → the OLD journal (both leases) remains the visible state.
    let writes = Box(0)
    JournalFile.fileFullSyncHook = { fd in
        writes.n += 1
        if writes.n >= 1 { errno = EIO; return -1 }
        return Darwin.fcntl(fd, F_FULLFSYNC)
    }
    JournalFile.fileSyncHook = { fd in
        if writes.n >= 1 { errno = EIO; return -1 }
        return Darwin.fsync(fd)
    }
    let (rok, rmsg) = store.restore(key: "/dev/disk9s1", owner: owner)
    expect(!rok && rmsg.contains("restore applied but journal persist failed"),
           "removal persist failed pre-rename: \(rmsg)")
    guard case .present(let entries) = try readVisibleJournal(jp) else {
        return expect(false, "normal visible snapshot must be PRESENT and readable after pre-rename failure")
    }
    expect(Set(entries.map(\.key)) == ["/dev/disk9s1", "/dev/disk10s1"],
           "normal visible snapshot after pre-rename failure still has BOTH records")
    // Simulated-crash surviving snapshot = the visible journal bytes above.
    // A fresh store bootstraps from a copy of exactly that snapshot and
    // recovers every outstanding obligation, order-independently. The
    // "post-crash" process has healthy syscalls again.
    restoreSyncHooks()
    let replayScene = makeScene("jstore-s8-replay")
    let replayJP = replayScene.appendingPathComponent("leases.json").path
    try Data(contentsOf: URL(fileURLWithPath: jp)).write(to: URL(fileURLWithPath: replayJP))
    let rec2 = Recorder()
    rec2.statResults["/dev/disk9s1"] = devStat()
    rec2.statResults["/dev/disk10s1"] = devStat(rdev: 0x1111_2222, ino: 5151)
    let store2 = DeviceLeaseStore(effects: makeRealJournalEffects(rec2, journalPath: replayJP))
    expect(store2.bootstrapAndRecover() == .recovered, "replay from surviving snapshot runs")
    expect(rec2.chowns.contains { $0.path == "/dev/disk9s1" && $0.uid == 501 }
        && rec2.chowns.contains { $0.path == "/dev/disk10s1" && $0.uid == 501 },
        "BOTH obligations recovered from the snapshot (order-independent)")
    try expectJournalCleared(replayJP, "replay store clears the journal after recovering both (four-condition check)")
}

/// Mutable counter shared with the stateful sync hooks.
final class Box {
    var n: Int
    init(_ initial: Int = 0) { n = initial }
}

// Fail-closed verification helpers: each failure input must FAIL a
// "cleared / no-leftovers" assertion instead of passing through a swallowed
// error. Judged by the real JournalFile reader and real JSON decode.
func testVerificationHelpersFailClosed() throws {
    let scene = makeScene("jfhc")
    // (a) missing journal → .absent — NOT present([]): a "cleared" check on
    // an absent file must fail (absence is asserted separately, never
    // conflated with an empty journal).
    if case .present = try readVisibleJournal(scene.appendingPathComponent("none.json").path) {
        expect(false, "absent journal must not read as present")
    } else if case .absent = try readVisibleJournal(scene.appendingPathComponent("none.json").path) {
        expect(true, "absent journal is distinguished from an empty journal")
    }
    // (b) corrupt journal → THROWS (can never satisfy "cleared").
    let corrupt = scene.appendingPathComponent("corrupt.json").path
    try Data("{corrupt".utf8).write(to: URL(fileURLWithPath: corrupt))
    expectThrows({ _ = try readVisibleJournal(corrupt) }, "undecodable", "corrupt journal")
    // (c) trust failure (group-writable journal) → THROWS via the real
    // trusted reader.
    let loose = scene.appendingPathComponent("loose.json").path
    try Data("[]".utf8).write(to: URL(fileURLWithPath: loose))
    precondition(chmod(loose, 0o666) == 0, "chmod 0666")
    expectThrows({ _ = try readVisibleJournal(loose) }, "untrusted journal location",
                 "untrusted journal fails the probe")
    // (d) directory enumeration failure → THROWS (never "zero leftovers").
    let notADir = scene.appendingPathComponent("plainfile")
    try Data("x".utf8).write(to: notADir)
    do {
        _ = try tmpLeftovers(in: notADir)
        expect(false, "directory enumeration failure must throw")
    } catch {
        expect(true, "directory enumeration failure throws (fails the test, not 'zero leftovers')")
    }
}

// COMBINED failure — journal-first durable, grant applied, active
// persist fails, and the ROLLBACK chown itself fails. The stateful stub
// models node metadata, so "restored to original" is checked against the
// modeled state by the real restoreNode verification. This is stub-metadata
// recovery + real journal I/O — NOT a real device-permission restore and
// NOT a power-loss drill.
func testStoreActiveFailRollbackFailRetryRestores() throws {
    let scene = makeScene("jstore-v6b")
    let jp = scene.appendingPathComponent("leases.json").path
    defer { restoreSyncHooks() }
    let rec = Recorder()
    rec.statResults["/dev/disk9s1"] = devStat()
    MountQuery.probe = { _ in .unmounted }
    // Sync: journal-first write (#1) healthy; every later write fails
    // POST-rename (real rename completes, directory sync fails).
    let writes = Box(0)
    JournalFile.renameHook = { from, to in Darwin.rename(from, to) }
    JournalFile.dirFullSyncHook = { fd in
        writes.n += 1
        if writes.n >= 2 { errno = EIO; return -1 }
        return Darwin.fcntl(fd, F_FULLFSYNC)
    }
    JournalFile.dirSyncHook = { fd in
        if writes.n >= 2 { errno = EIO; return -1 }
        return Darwin.fsync(fd)
    }
    // Grant chowns (uid 1000) succeed; the FIRST rollback chown back to the
    // original owner (uid 501) fails; later attempts succeed. (The stub
    // appends the current call before consulting chownOutcome → dropLast.)
    rec.chownOutcome = { path, uid in
        guard path == "/dev/disk9s1", uid == 501 else { return 0 }
        let prior = rec.chowns.dropLast().filter { $0.path == path && $0.uid == 501 }.count
        return prior == 0 ? 1 : 0
    }
    let store = DeviceLeaseStore(effects: makeRealJournalEffects(rec, journalPath: jp))
    _ = store.bootstrapAndRecover()
    // 1-2: durable journal-first record + successful grant.
    // 3: active-transition persist fails post-rename.
    // 4: rollback chown fails → obligation kept + internal retry scheduled.
    let (ok, msg) = prepareHelper(store, key: "/dev/disk9s1", nodes: ["/dev/disk9s1"],
                                  owner: UUID(), writeAccess: false)
    expect(!ok, "prepare must fail")
    expect(msg.contains("journal persist failed after grant"),
           "active persist failure reported: \(msg)")
    expect(msg.contains("restore incomplete"),
           "recovery-not-finished reported accurately: \(msg)")
    // 5/6: kept obligation visible in the journal via the STRICT probe — a
    // read failure here FAILS the test, it cannot read as "empty".
    guard case .present(let kept) = try readVisibleJournal(jp),
          kept.count == 1, kept[0].key == "/dev/disk9s1", kept[0].phase == "recovering"
    else {
        return expect(false, "kept obligation must be journaled recovering: \(describe(try readVisibleJournal(jp)))")
    }
    // Node metadata still GRANTED in the stateful stub (rollback failed).
    let grantedNow = rec.statResults["/dev/disk9s1"] ?? nil
    expect(grantedNow?.st_uid == 1000, "stub node still granted (uid 1000) after failed rollback")
    // 7: faults cleared → the real internal retry runs.
    restoreSyncHooks()
    rec.chownOutcome = { _, _ in 0 }
    rec.fireLast()
    // 8: stub metadata back to the ORIGINAL values, journal cleared under
    // the four-condition check, lease gone.
    let restoredNow = rec.statResults["/dev/disk9s1"] ?? nil
    expect(restoredNow?.st_uid == 501 && restoredNow?.st_gid == 20,
           "stub uid/gid restored to original")
    expect((restoredNow?.st_mode ?? 0) & 0o7777 == 0o640,
           "stub mode restored to 0o640 (was granted 0o400)")
    try expectJournalCleared(jp, "retry persist writes an empty journal (four-condition check)")
    let (rok, rmsg) = store.restore(key: "/dev/disk9s1", owner: nil)
    expect(!rok && rmsg.contains("no active lease"), "lease removed after retry: \(rmsg)")
}

// MARK: - Qualification gate

/// Gate facts builder. The values used below are examples with the same
/// shape as what DiskArbitration reports (BSD names, major/minor numbers);
/// the gate's decisions depend on the field combination, not on the numbers.
/// Granted cases:
///   whole disk, never mounted:   VolumeKind=openntfs, MediaBSDName=disk7,
///                                Major=1, Minor=20, MediaLeaf=true, no VolumePath
///   partition after unmount:     VolumeKind=openntfs, MediaBSDName=disk7s1,
///                                Major=1, Minor=21, MediaLeaf=true, no VolumePath
/// Refused cases:
///   parent whole disk:           VolumeKind absent, MediaLeaf=false
///   partition DA never probed:   VolumeKind absent, MediaLeaf=true
func gateFacts(kind: DAFieldValue = .present("openntfs"),
               path: DAFieldValue = .absent,
               name: String, major: String, minor: String,
               leaf: DAFieldValue = .present("true")) -> DACollectionResult {
    .facts(DeviceDAFacts(volumeKind: kind, volumePath: path,
                         mediaBSDName: .present(name),
                         mediaBSDMajor: .present(major),
                         mediaBSDMinor: .present(minor),
                         mediaLeaf: leaf))
}

/// rdev for the darwin makedev layout used by the gate (major<<24 | minor).
func gateRdev(_ major: Int32, _ minor: Int32) -> dev_t {
    dev_t(major) << 24 | dev_t(minor)
}

/// Whole disk: openntfs, BSD disk7, 1/20, leaf, no VolumePath.
let wholeDiskFacts = gateFacts(name: "disk7", major: "1", minor: "20")
/// Partition after unmount: openntfs, disk7s1, 1/21, leaf.
let partitionFacts = gateFacts(name: "disk7s1", major: "1", minor: "21")
/// Parent whole disk: VolumeKind absent, Leaf=false.
let parentDiskFacts = gateFacts(kind: .absent, name: "disk7",
                                major: "1", minor: "20", leaf: .present("false"))
/// Partition DA never probed: VolumeKind absent, Leaf=true.
let unprobedPartitionFacts = gateFacts(kind: .absent, name: "disk7s1",
                                       major: "1", minor: "21")

func wholeDiskNodeStats(rec: Recorder) {
    rec.statResults["/dev/disk7"] = devStat(fileType: mode_t(S_IFBLK),
                                            rdev: gateRdev(1, 20), ino: 6033, dev: 71)
    rec.statResults["/dev/rdisk7"] = devStat(fileType: mode_t(S_IFCHR),
                                             rdev: gateRdev(1, 20), ino: 6034, dev: 71)
}

func partitionNodeStats(rec: Recorder, rawMinor: Int32 = 21) {
    rec.statResults["/dev/disk7s1"] = devStat(fileType: mode_t(S_IFBLK),
                                              rdev: gateRdev(1, 21), ino: 6035, dev: 71)
    rec.statResults["/dev/rdisk7s1"] = devStat(fileType: mode_t(S_IFCHR),
                                               rdev: gateRdev(1, rawMinor), ino: 6036, dev: 71)
}

func gatePrepare(_ rec: Recorder) -> DeviceLeaseStore {
    MountQuery.probe = { _ in .unmounted }
    let store = DeviceLeaseStore(effects: makeEffects(rec))
    _ = store.bootstrapAndRecover()
    return store
}

func testQualificationGateAllowsWholeDiskFacts() {
    let rec = Recorder()
    wholeDiskNodeStats(rec: rec)
    rec.daFactsOverride = { _ in wholeDiskFacts }   // whole-disk example facts
    let store = gatePrepare(rec)
    let (ok, msg) = prepareHelper(store, key: "/dev/disk7",
                                  nodes: ["/dev/disk7", "/dev/rdisk7"],
                                  owner: UUID(), writeAccess: false)
    expect(ok, "whole-disk facts must be granted: \(msg)")
    expect(rec.daFactsCalls == ["disk7"], "gate must query DA for the requested BSD name: \(rec.daFactsCalls)")
    expect(rec.chowns.count == 2 && rec.chmods.count == 2, "both nodes granted: \(rec.chowns) \(rec.chmods)")
    expect(!rec.journalWrites.isEmpty, "grant must be journaled")
}

func testQualificationGateAllowsUnmountedPartition() {
    let rec = Recorder()
    partitionNodeStats(rec: rec)
    rec.daFactsOverride = { _ in partitionFacts }    // partition example facts
    let store = gatePrepare(rec)
    let (ok, msg) = prepareHelper(store, key: "/dev/disk7s1",
                                  nodes: ["/dev/disk7s1", "/dev/rdisk7s1"],
                                  owner: UUID(), writeAccess: true)
    expect(ok, "unmounted-partition facts must be granted: \(msg)")
    expect(rec.chowns.count == 2, "both nodes granted")
}

func testQualificationGateRejections() {
    // Each case is a REFUSAL with zero chown/chmod and zero journal writes.
    // The first two cases use the parent-disk / unprobed-partition facts.
    var cases: [(String, (Recorder) -> Void, String, String)] = []
    cases.append(("parent-whole-disk", { rec in
        wholeDiskNodeStats(rec: rec)                 // stats for disk7 (1/20)
        rec.daFactsOverride = { _ in parentDiskFacts }
    }, "/dev/disk7", "VolumeKind absent"))  // also Leaf=false; the gate's fixed order names VolumeKind first
    cases.append(("unprobed-partition", { rec in
        partitionNodeStats(rec: rec)
        rec.daFactsOverride = { _ in unprobedPartitionFacts }
    }, "/dev/disk7s1", "VolumeKind absent"))
    cases.append(("volume-kind-ntfs", { rec in
        wholeDiskNodeStats(rec: rec)
        rec.daFactsOverride = { _ in gateFacts(kind: .present("ntfs"),
                                               name: "disk7", major: "1", minor: "20") }
    }, "/dev/disk7", "not openntfs"))
    cases.append(("volume-kind-wrongtype", { rec in
        wholeDiskNodeStats(rec: rec)
        rec.daFactsOverride = { _ in gateFacts(kind: .wrongType("CFNumber"),
                                               name: "disk7", major: "1", minor: "20") }
    }, "/dev/disk7", "VolumeKind wrong type"))
    cases.append(("volumepath-present", { rec in
        wholeDiskNodeStats(rec: rec)
        rec.daFactsOverride = { _ in gateFacts(path: .present("/Volumes/EXAMPLE"),
                                               name: "disk7", major: "1", minor: "20") }
    }, "/dev/disk7", "VolumePath present"))
    cases.append(("bsdname-mismatch", { rec in
        wholeDiskNodeStats(rec: rec)
        rec.daFactsOverride = { _ in gateFacts(name: "disk8", major: "1", minor: "20") }
    }, "/dev/disk7", "!= requested"))
    cases.append(("raw-node-minor-mismatch", { rec in
        partitionNodeStats(rec: rec, rawMinor: 22)    // raw off by one
        rec.daFactsOverride = { _ in partitionFacts }
    }, "/dev/disk7s1", "major/minor"))
    cases.append(("da-query-failed", { rec in
        wholeDiskNodeStats(rec: rec)
        rec.daFactsOverride = { _ in .queryFailed("DADiskCopyDescription failed") }
    }, "/dev/disk7", "DA query failed"))
    cases.append(("leaf-absent", { rec in
        wholeDiskNodeStats(rec: rec)
        rec.daFactsOverride = { _ in gateFacts(name: "disk7", major: "1", minor: "20",
                                               leaf: .absent) }
    }, "/dev/disk7", "MediaLeaf absent"))
    for (name, setup, key, needle) in cases {
        currentTest = "qual-gate-reject/\(name)"
        let rec = Recorder()
        setup(rec)
        let store = gatePrepare(rec)
        let before = failures
        let (ok, msg) = prepareHelper(store, key: key,
                                      nodes: key == "/dev/disk7"
                                          ? ["/dev/disk7", "/dev/rdisk7"]
                                          : ["/dev/disk7s1", "/dev/rdisk7s1"],
                                      owner: UUID(), writeAccess: false)
        expect(!ok, "\(name): prepare must refuse, got ok")
        expect(msg.contains("device qualification failed"), "\(name): message must name the gate: \(msg)")
        expect(msg.contains(needle), "\(name): message must name \(needle): \(msg)")
        expect(rec.chowns.isEmpty, "\(name): ZERO chown allowed: \(rec.chowns)")
        expect(rec.chmods.isEmpty, "\(name): ZERO chmod allowed: \(rec.chmods)")
        expect(rec.journalWrites.isEmpty, "\(name): ZERO journal writes allowed")
        if failures == before { print("PASS: \(currentTest)") } else { print("TEST FAILED: \(currentTest)") }
    }
}

func testQualificationGateCoversLeaseReuse() {
    // An ACTIVE lease exists; the DA facts no longer qualify. The reuse
    // branch must be gated too: refused, original lease + journal unchanged.
    let rec = Recorder()
    partitionNodeStats(rec: rec)
    rec.daFactsOverride = { _ in partitionFacts }
    let store = gatePrepare(rec)
    let owner = UUID()
    let (ok1, _) = prepareHelper(store, key: "/dev/disk7s1",
                                 nodes: ["/dev/disk7s1", "/dev/rdisk7s1"],
                                 owner: owner, writeAccess: false)
    expect(ok1, "first grant must succeed")
    let writesAfterGrant = rec.journalWrites.count
    let chownsAfterGrant = rec.chowns.count
    rec.daFactsOverride = { _ in unprobedPartitionFacts }   // qualification lost
    let (ok2, msg) = prepareHelper(store, key: "/dev/disk7s1",
                                   nodes: ["/dev/disk7s1", "/dev/rdisk7s1"],
                                   owner: owner, writeAccess: false)  // same owner+mode
    expect(!ok2, "reuse must be refused when qualification no longer holds")
    expect(msg.contains("device qualification failed"), "refusal must come from the gate: \(msg)")
    expect(rec.journalWrites.count == writesAfterGrant, "journal must be unchanged")
    expect(rec.chowns.count == chownsAfterGrant, "no additional node ops")
    // The original lease survives and stays restorable.
    let (rok, rmsg) = store.restore(key: "/dev/disk7s1", owner: owner)
    expect(rok, "original lease must still restore: \(rmsg)")
    expect(rec.chowns.contains { $0.path == "/dev/disk7s1" && $0.uid == 501 },
           "restore returned the node to its original owner")
}

func testRestoreHasNoQualificationGate() {
    // restore/recovery deliberately un-gated: even with a failing DA query
    // an outstanding obligation must remain restorable.
    let rec = Recorder()
    partitionNodeStats(rec: rec)
    rec.daFactsOverride = { _ in partitionFacts }
    let store = gatePrepare(rec)
    let owner = UUID()
    let (ok1, _) = prepareHelper(store, key: "/dev/disk7s1",
                                 nodes: ["/dev/disk7s1", "/dev/rdisk7s1"],
                                 owner: owner, writeAccess: false)
    expect(ok1, "grant must succeed")
    rec.daFactsOverride = { _ in .queryFailed("DA down") }
    let (rok, rmsg) = store.restore(key: "/dev/disk7s1", owner: owner)
    expect(rok, "restore must NOT consult the qualification gate: \(rmsg)")
}

// MARK: - Scene-preservation self-check
//
// Deliberate-failure entries, each run in its OWN PROCESS (via the runner
// below or directly): expected failures are NOT part of the normal suite
// (they are only reachable through these flags), and the runner judges the
// ACTUAL exit codes and on-disk scenes. Marker files are written by the
// test entries themselves.

func selfcheckAssertFailBody() throws {
    let scene = makeScene("selfcheck-assert")
    try Data("deliberate-assert-failure".utf8)
        .write(to: scene.appendingPathComponent("DELIBERATE-ASSERT-FAIL-MARKER"))
    print("SCENE CREATED: \(scene.path)")
    expect(false, "deliberate assertion failure — the scene above must be KEPT")
}

func selfcheckThrowFailBody() throws {
    let scene = makeScene("selfcheck-throw")
    try Data("deliberate-throw-failure".utf8)
        .write(to: scene.appendingPathComponent("DELIBERATE-THROW-MARKER"))
    print("SCENE CREATED: \(scene.path)")
    throw NSError(domain: "scene-selfcheck", code: 1,
                  userInfo: [NSLocalizedDescriptionKey: "deliberate throw — the scene above must be KEPT"])
}

func selfcheckSuccessBody() throws {
    let scene = makeScene("selfcheck-success")
    try Data("deliberate-success".utf8)
        .write(to: scene.appendingPathComponent("SUCCESS-MARKER"))
    print("SCENE CREATED: \(scene.path)")
    expect(true, "deliberate success — the scene above must be REMOVED by runTest")
}

func runSelfcheckChild(_ args: [String]) -> (exitCode: Int32, scenes: [String], output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do {
        try p.run()
    } catch {
        return (Int32(EXIT_FAILURE), [],
                "child failed to launch: \(error.localizedDescription)")
    }
    p.waitUntilExit()
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let scenes = out.split(separator: "\n")
        .filter { $0.hasPrefix("SCENE CREATED: ") }
        .map { String($0.dropFirst("SCENE CREATED: ".count)) }
    return (p.terminationStatus, scenes, out)
}

/// Runs the three deliberate modes in SEPARATE processes and verifies exit
/// codes + on-disk scenes. Scenes of the deliberately-failing children are
/// their kept evidence and are NOT deleted by this runner.
func sceneSelfcheckRunner() -> Int32 {
    var bad = 0
    func check(_ cond: Bool, _ what: String) {
        print(cond ? "SELFCHECK PASS: \(what)" : "SELFCHECK FAIL: \(what)")
        if !cond { bad += 1 }
    }

    let a = runSelfcheckChild(["--selfcheck-assert-fail"])
    print("--- child --selfcheck-assert-fail (exit \(a.exitCode)) ---")
    print(a.output.trimmingCharacters(in: .whitespacesAndNewlines))
    check(a.exitCode != 0, "assert-fail child exits non-zero (got \(a.exitCode))")
    check(a.scenes.count == 1, "assert-fail child reports exactly one scene")
    if let s = a.scenes.first {
        check(FileManager.default.fileExists(atPath: s), "assert-fail scene kept at \(s)")
        check(FileManager.default.fileExists(atPath: s + "/DELIBERATE-ASSERT-FAIL-MARKER"),
              "assert-fail scene contains the marker written by the test entry itself")
    }

    let t = runSelfcheckChild(["--selfcheck-throw-fail"])
    print("--- child --selfcheck-throw-fail (exit \(t.exitCode)) ---")
    print(t.output.trimmingCharacters(in: .whitespacesAndNewlines))
    check(t.exitCode != 0, "throw-fail child exits non-zero (got \(t.exitCode))")
    check(t.scenes.count == 1, "throw-fail child reports exactly one scene")
    if let s = t.scenes.first {
        check(FileManager.default.fileExists(atPath: s), "throw-fail scene kept at \(s)")
    }

    let ok = runSelfcheckChild(["--selfcheck-success"])
    print("--- child --selfcheck-success (exit \(ok.exitCode)) ---")
    print(ok.output.trimmingCharacters(in: .whitespacesAndNewlines))
    check(ok.exitCode == 0, "success child exits zero (got \(ok.exitCode))")
    check(ok.scenes.count == 1, "success child reports exactly one scene")
    if let s = ok.scenes.first {
        check(!FileManager.default.fileExists(atPath: s), "success scene removed by the child: \(s)")
    }

    print("scene selfcheck finished: \(bad) failure(s)")
    return bad == 0 ? 0 : 1
}

// The fail-closed captured-journal helper must reject
// "no successful write" and "undecodable last write" — the old
// `... ?? []` form read both as "cleared".
func testClearedJournalHelperRejectsAbsentWrites() {
    let noWrites = Recorder()
    expect(clearedJournal(noWrites) == nil,
           "zero successful journal writes must NOT read as cleared")
    let corruptLast = Recorder()
    corruptLast.journalWrites.append(Data("{not json".utf8))
    expect(clearedJournal(corruptLast) == nil,
           "an undecodable LAST write must NOT read as cleared")
    let healthy = Recorder()
    healthy.journalWrites.append(journalData([]))   // real encoded empty set
    guard let cleared = clearedJournal(healthy) else {
        return expect(false, "a real decodable empty write must read as cleared")
    }
    expect(cleared.isEmpty, "decodable empty write reads as cleared")
}

// MARK: - Main

@main
enum LeaseStoreTestMain {
    static func main() {
        switch CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "" {
        case "--selfcheck-assert-fail":
            runTest("SELF-CHECK deliberate assertion failure", selfcheckAssertFailBody)
            exit(failures == 0 ? 0 : 1)   // non-zero BY DESIGN (expected failure)
        case "--selfcheck-throw-fail":
            runTest("SELF-CHECK deliberate throw", selfcheckThrowFailBody)
            exit(failures == 0 ? 0 : 1)
        case "--selfcheck-success":
            runTest("SELF-CHECK success cleanup", selfcheckSuccessBody)
            exit(failures == 0 ? 0 : 1)
        case "--scene-selfcheck":
            exit(sceneSelfcheckRunner())
        default:
            runAllTests()
        }
    }

    static func runAllTests() {
        runTest("firstJournalWriteFailureBlocksAllNodeModification",
                testFirstJournalWriteFailureBlocksAllNodeModification)
        runTest("multiEntryRecoveryInterruptKeepsUnprocessedRecords",
                testMultiEntryRecoveryInterruptKeepsUnprocessedRecords)
        runTest("journalMissingIsCleanStart", testJournalMissingIsCleanStart)
        runTest("journalCorruptDegradesAndKeepsFile", testJournalCorruptDegradesAndKeepsFile)
        runTest("journalUnreadableDegrades", testJournalUnreadableDegrades)
        runTest("journalDuplicateKeyDegrades", testJournalDuplicateKeyDegrades)
        runTest("journalInvalidEntriesDegrade", testJournalInvalidEntriesDegrade)
        runTest("chmodFailureCurrentNodeRolledBackAndRetained",
                testChmodFailureCurrentNodeRolledBackAndRetained)
        runTest("timeoutRecoveryFailsThenRetrySucceeds",
                testTimeoutRecoveryFailsThenRetrySucceeds)
        runTest("disconnectReleaseAllFailsThenRetrySucceeds",
                testDisconnectReleaseAllFailsThenRetrySucceeds)
        runTest("recoveringNotReusedAndStaleTimerIgnored",
                testRecoveringNotReusedAndStaleTimerIgnored)
        runTest("mountQueryFailureRefusesPrepare", testMountQueryFailureRefusesPrepare)
        runTest("mountQueryReduceTriState", testMountQueryReduceTriState)
        runTest("remountPolicyDecisions", testRemountPolicyDecisions)
        runTest("restoreFailureReturnsNodeDetails", testRestoreFailureReturnsNodeDetails)
        runTest("identityChangeQuarantinesAndStopsAutoRestore",
                testIdentityChangeQuarantinesAndStopsAutoRestore)
        runTest("identityMatchAcrossHelperRestartRecovers",
                testIdentityMatchAcrossHelperRestartRecovers)
        runTest("clearedJournalHelperRejectsAbsentWrites", testClearedJournalHelperRejectsAbsentWrites)
        runTest("persistFailureAfterRestoreKeepsRecord",
                testPersistFailureAfterRestoreKeepsRecord)
        runTest("abortRollbackChecksIdentityBeforeModify",
                testAbortRollbackChecksIdentityBeforeModify)
        runTest("journalFileRoundtripAndModes", testJournalFileRoundtripAndModes)
        runTest("journalFileMissingReturnsNil", testJournalFileMissingReturnsNil)
        runTest("journalFileRejectsLooseExistingFile", testJournalFileRejectsLooseExistingFile)
        runTest("journalFileRejectsForeignOwner", testJournalFileRejectsForeignOwner)
        runTest("journalFileRejectsLooseExistingDir", testJournalFileRejectsLooseExistingDir)
        runTest("journalFileRejectsSymlinks", testJournalFileRejectsSymlinks)
        runTest("journalFileFailedWritePreservesOriginalAndCleansTemp",
                testJournalFileFailedWritePreservesOriginalAndCleansTemp)
        runTest("journalFileWriteRefusesLooseExistingJournal",
                testJournalFileWriteRefusesLooseExistingJournal)
        runTest("journalFileWriteLooseFilePinnedToFileCheck",
                testJournalFileWriteLooseFilePinnedToFileCheck)
        runTest("journalFileWriteRefusesForeignOwnedJournalViaMetadataStub",
                testJournalFileWriteRefusesForeignOwnedJournalViaMetadataStub)
        runTest("journalFileTrustedUpdateAndCreation",
                testJournalFileTrustedUpdateAndCreation)
        runTest("journalFileMkdirEEXISTRaceTreatedAsExisting",
                testJournalFileMkdirEEXISTRaceTreatedAsExisting)
        runTest("journalFileMkdirOtherErrorPropagates",
                testJournalFileMkdirOtherErrorPropagates)
        runTest("journalFileSyncFallbackChain", testJournalFileSyncFallbackChain)
        runTest("journalFileSyncAllPathsFail", testJournalFileSyncAllPathsFail)
        runTest("journalFileRenameFail", testJournalFileRenameFail)
        runTest("journalFileDirSyncFailAfterRealRename",
                testJournalFileDirSyncFailAfterRealRename)
        runTest("storePrepareJournalFirstPersistFailureZeroNodeMods",
                testStorePrepareJournalFirstPersistFailureZeroNodeMods)
        runTest("storeActiveTransitionPersistFailureRollsBack",
                testStoreActiveTransitionPersistFailureRollsBack)
        runTest("storeRemovalPersistFailAfterRenameKeepsOtherLeases",
                testStoreRemovalPersistFailAfterRenameKeepsOtherLeases)
        runTest("storeTwoLeasesWriteBoundaryFailureSnapshotReplay",
                testStoreTwoLeasesWriteBoundaryFailureSnapshotReplay)
        runTest("qualGateAllowsWholeDiskFacts", testQualificationGateAllowsWholeDiskFacts)
        runTest("qualGateAllowsUnmountedPartition", testQualificationGateAllowsUnmountedPartition)
        runTest("qualGateRejections", testQualificationGateRejections)
        runTest("qualGateCoversLeaseReuse", testQualificationGateCoversLeaseReuse)
        runTest("restoreHasNoQualificationGate", testRestoreHasNoQualificationGate)
        runTest("verificationHelpersFailClosed",
                testVerificationHelpersFailClosed)
        runTest("storeActiveFailRollbackFailRetryRestores",
                testStoreActiveFailRollbackFailRetryRestores)
        print("lease-store tests finished: \(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
