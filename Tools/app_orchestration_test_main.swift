// Offline orchestration tests for the App maintenance flow: Mounter.check,
// Mounter.remountAfterMaintenance, runMaintenanceFlow and the
// MaintenanceReport text pipeline (the SAME implementation AppModel.check
// calls — no parallel test-only flow).
//
// Isolation contract (fail-closed seams; production defaults are the real
// calls, but the harness installs STRICT stubs for every external effect
// before each test): Shell.runHook records tool/arguments/order and fails
// unscripted calls; the helper port is a recording stub; MountQuery.probe
// returns a FINITE scripted sequence (exhaustion = violation, no infinite
// polling); Mounter.waitHook is a counting no-op (no real sleep);
// MountTable.entriesHook returns a scripted table; mount points live under
// a per-run temp scene (never the real home). No diskutil/mount/umount/
// fsck_fskit/newfs_fskit is ever executed; no App, Helper, NSXPC, DA
// session or real mount query is ever started.
//
// SPDX-License-Identifier: GPL-2.0-or-later

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

// MARK: - Shared event trace + unified stub acceptance
//
// Every stub (Shell / Helper / Probe / Wait / MountTable) appends typed
// events to ONE trace, so cross-dependency ORDER (gate → fsck → prepare →
// gate → fsck2 → restore …) is asserted globally, not per-stub. Each stub
// also registers an acceptance check on install(); runTest runs ALL checks
// automatically — a test can no longer "forget" assertClean, unconsumed
// required steps, extra calls, or probe exhaustion fail the test.

struct TraceEvent: CustomStringConvertible {
    let kind: String
    let detail: String
    var description: String { "\(kind)(\(detail))" }
}
var trace: [TraceEvent] = []
func traced(_ kind: String, _ detail: String) { trace.append(TraceEvent(kind: kind, detail: detail)) }
func traceKinds() -> [String] { trace.map(\.kind) }
func traceIndexes(of kind: String) -> [Int] {
    trace.enumerated().compactMap { $0.element.kind == kind ? $0.offset : nil }
}

var stubChecks: [(String) -> Void] = []
/// Optional whole-test order contract: when set, unified acceptance requires
/// the exact kind sequence.
var expectedTraceKinds: [String]?
/// MountTable (mount-point bookkeeping) reads are declared per test; an
/// undeclared read fails acceptance instead of being masked by [].
var allowMountTableQueries = false
var mountTableQueries = 0

/// Scene registry (failure scenes are kept): kept+printed on failure, removed on success.
private let sceneRunToken = UUID().uuidString.prefix(8)
private var sceneCounter = 0
var activeScenes: [URL] = []

func makeScene(_ name: String) -> URL {
    sceneCounter += 1
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("app-orchestration-\(sceneRunToken)-\(name)-\(sceneCounter)",
                                isDirectory: true)
    precondition(dir.path.hasPrefix(NSTemporaryDirectory()),
                 "scene escapes the temporary directory: \(dir.path)")
    precondition(!FileManager.default.fileExists(atPath: dir.path),
                 "scene path already exists; refusing to reuse: \(dir.path)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    activeScenes.append(dir)
    return dir
}

func runTest(_ name: String, _ body: () async throws -> Void) async {
    currentTest = name
    // STRICT fail-closed defaults for every seam: an unscripted external
    // call produces a failing result, is recorded as a violation, and can
    // never fall back to a real implementation.
    var harnessViolations = 0
    Shell.runHook = { _, _ in
        harnessViolations += 1
        return CommandResult(status: 12600, output: "UNSCRIPTED shell call")
    }
    MountQuery.probe = { _ in
        harnessViolations += 1
        return .queryFailed("UNSCRIPTED mount query")
    }
    // Every test gets its OWN temp mount root — an accidental
    // mountWithLabeledPath can never write the real ~/NTFS Volumes. The
    // default wait stub records waits (never real sleep). The default
    // MountTable stub RECORDS every query and returns [] — undeclared
    // queries fail acceptance instead of being silently masked.
    let before = failures
    activeScenes = []
    // Per-test registries are reset FIRST: every default stub installed
    // below (Wait / MountTable / strict Shell / strict Probe) must keep its
    // registration until the unified acceptance runs — previously the
    // default Wait's check was wiped by a reset AFTER install().
    stubChecks = []
    trace = []
    expectedTraceKinds = nil
    allowMountTableQueries = false
    mountTableQueries = 0
    let rootScene = makeScene("mountroot")
    Mounter.mountRootOverride = rootScene
    let defaultWait = WaitCounter()
    defaultWait.install()
    MountTable.entriesHook = {
        mountTableQueries += 1
        traced("mounttable", "entries query #\(mountTableQueries)")
        return []
    }
    do {
        try await body()
    } catch {
        failures += 1
        print("FAIL [\(name)]: threw \(error)")
    }
    // Unified acceptance — runs for EVERY test, no manual assertClean:
    // stub violations, unconsumed REQUIRED steps, undeclared mount-table
    // queries, and (when declared) the global trace order.
    for check in stubChecks { check(name) }
    expect(harnessViolations == 0,
           "unscripted external calls must not happen (harnessViolations=\(harnessViolations))")
    expect(mountTableQueries == 0 || allowMountTableQueries,
           "\(name): \(mountTableQueries) UNDECLARED mount-table query(ies) — declare allowMountTableQueries")
    if let expected = expectedTraceKinds {
        expect(traceKinds() == expected,
               "\(name): trace order mismatch\n  expected \(expected)\n  actual   \(traceKinds())\n  events \(trace)")
    }
    if failures == before && harnessViolations == 0 {
        for scene in activeScenes {
            do { try FileManager.default.removeItem(at: scene) }
            catch { print("NOTE [\(name)]: scene cleanup failed for \(scene.path)") }
        }
    } else {
        for scene in activeScenes where FileManager.default.fileExists(atPath: scene.path) {
            print("SCENE KEPT [\(name)]: \(scene.path)")
        }
    }
    activeScenes = []
    // Restore production defaults for the seams this file controls.
    Shell.runHook = nil
    MountQuery.probe = MountQuery.systemProbe
    MountTable.entriesHook = nil
    Mounter.waitHook = nil
    Mounter.mountRootOverride = nil
    print(failures == before ? "PASS: \(name)" : "TEST FAILED: \(name)")
}

// MARK: - Strict scripted stubs

final class ScriptedShell {
    struct Step {
        let tool: String
        let args: [String]
        let status: Int32
        let output: String
        init(_ tool: String, _ args: [String], status: Int32 = 0, output: String = "") {
            self.tool = tool; self.args = args; self.status = status; self.output = output
        }
    }
    private var steps: [Step]
    private(set) var calls: [(tool: String, args: [String])] = []
    private(set) var violations: [String] = []
    /// Semantic declaration for tests exercising the INTERACTIVE strategy,
    /// whose retry loop legitimately force-unmounts (pre-existing opt-in
    /// semantics). Default false: maintenance flows must never force.
    var allowsForceUnmock = false
    init(_ script: [Step]) { steps = script }

    func install() {
        Shell.runHook = { [self] tool, args in
            self.calls.append((tool, args))
            traced("shell", "\(tool) \(args.joined(separator: " "))")
            guard !self.steps.isEmpty else {
                self.violations.append("UNEXPECTED call #\(self.calls.count): \(tool) \(args)")
                return CommandResult(status: 12601, output: "UNEXPECTED-CALL")
            }
            let next = self.steps.removeFirst()
            guard next.tool == tool, next.args == args else {
                self.violations.append(
                    "ORDER/PARAM mismatch: expected \(next.tool) \(next.args), got \(tool) \(args)")
                return CommandResult(status: 12602, output: "MISMATCH")
            }
            return CommandResult(status: next.status, output: next.output)
        }
        stubChecks.append { [self] what in self.accept(what) }
    }

    var fsckCalls: [(tool: String, args: [String])] { calls.filter { $0.tool.contains("fsck") } }
    var mountCalls: [(tool: String, args: [String])] { calls.filter { $0.args.first == "mount" } }

    /// Asserts no force-unmount was ever issued for any device.
    func assertNoForce(_ what: String) {
        let forced = calls.filter { $0.args.first == "unmount" && $0.args.contains("force") }
        expect(forced.isEmpty, "\(what): no `unmount force` (got \(forced))")
    }

    /// Registered automatically by install(); run by runTest for every test.
    private func accept(_ what: String) {
        expect(violations.isEmpty, "\(what): shell violations \(violations)")
        expect(steps.isEmpty, "\(what): unconsumed REQUIRED shell steps (never ran): \(steps)")
        if !allowsForceUnmock {
            assertNoForce("\(what) [unified]")
        }
    }
}

/// Scripted helper with REAL unified acceptance. Steps are consumed IN
/// ORDER; the DEFAULT script is EMPTY — any undeclared helper call is a
/// violation. Order, device path, writeAccess, extra calls and unconsumed
/// steps all fail the test through the registered acceptance; call records
/// and the shared event trace are kept.
final class ScriptedHelper: MaintenanceHelperPort {
    enum Step: CustomStringConvertible {
        case prepare(devicePath: String, writeAccess: Bool, error: String? = nil,
                     timedOut: Bool = false)
        case restore(devicePath: String, error: String? = nil, timedOut: Bool = false)

        var description: String {
            switch self {
            case .prepare(let d, let w, let e, _):
                return "prepare(\(d) writeAccess=\(w)\(e.map { " throws \($0)" } ?? ""))"
            case .restore(let d, let e, _):
                return "restore(\(d)\(e.map { " throws \($0)" } ?? ""))"
            }
        }
    }

    struct Prep { let devicePath: String; let writeAccess: Bool }
    private var steps: [Step]
    private(set) var preps: [Prep] = []
    private(set) var restores: [String] = []
    private(set) var violations: [String] = []

    init(_ script: [Step] = []) {
        self.steps = script
        stubChecks.append { [self] what in
            expect(self.violations.isEmpty, "\(what): helper violations \(self.violations)")
            expect(self.steps.isEmpty,
                   "\(what): unconsumed helper steps (required but never called): \(self.steps)")
        }
    }

    private func violation(_ msg: String) -> NSError {
        violations.append(msg)
        return NSError(domain: "scripted-helper", code: 1,
                       userInfo: [NSLocalizedDescriptionKey: msg])
    }

    func prepareRawDevice(devicePath: String, writeAccess: Bool) async throws {
        preps.append(Prep(devicePath: devicePath, writeAccess: writeAccess))
        traced("helper-prepare", "\(devicePath) writeAccess=\(writeAccess)")
        guard !steps.isEmpty else {
            throw violation("UNSCRIPTED helper call: prepare(\(devicePath) writeAccess=\(writeAccess))")
        }
        let next = steps[0]
        guard case .prepare = next else {
            throw violation("ORDER mismatch: expected \(next), got prepare(\(devicePath) writeAccess=\(writeAccess))")
        }
        guard case .prepare(let expDev, let expWrite, let expErr, let expTO) = next,
              expDev == devicePath, expWrite == writeAccess else {
            throw violation("PARAM mismatch: expected \(next), got prepare(\(devicePath) writeAccess=\(writeAccess))")
        }
        steps.removeFirst()
        if expTO {
            // Simulates what the REAL HelperClient surfaces when the helper
            // never replies: the RPC timeout error.
            throw HelperError.timedOut(HelperClient.rpcTimeoutDefaultSeconds)
        }
        if let msg = expErr {
            throw NSError(domain: "scripted-helper", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }

    func restoreRawDevice(devicePath: String) async throws {
        restores.append(devicePath)
        traced("helper-restore", devicePath)
        guard !steps.isEmpty else {
            throw violation("UNSCRIPTED helper call: restore(\(devicePath))")
        }
        let next = steps[0]
        guard case .restore = next else {
            throw violation("ORDER mismatch: expected \(next), got restore(\(devicePath))")
        }
        guard case .restore(let expDev, let expErr, let expTO) = next, expDev == devicePath else {
            throw violation("PARAM mismatch: expected \(next), got restore(\(devicePath))")
        }
        steps.removeFirst()
        if expTO {
            throw HelperError.timedOut(HelperClient.rpcTimeoutDefaultSeconds)
        }
        if let msg = expErr {
            throw NSError(domain: "scripted-helper", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }
}

final class ScriptedProbe {
    private var seq: [MountQueryState]
    private(set) var queries: [String] = []
    private(set) var violations: [String] = []
    init(_ seq: [MountQueryState]) { self.seq = seq }
    func install() {
        MountQuery.probe = { [self] device in
            self.queries.append(device)
            guard !self.seq.isEmpty else {
                self.violations.append("probe EXHAUSTED at query #\(self.queries.count) for \(device)")
                traced("probe", "EXHAUSTED")
                return .queryFailed("PROBE-EXHAUSTED")
            }
            let next = self.seq.removeFirst()
            traced("probe", "#\(self.queries.count) \(next)")
            return next
        }
        stubChecks.append { [self] what in
            expect(self.violations.isEmpty, "\(what): probe violations \(self.violations)")
            expect(self.seq.isEmpty, "\(what): unconsumed probe states: \(self.seq)")
        }
    }
}

final class WaitCounter {
    private(set) var count = 0
    func install() {
        Mounter.waitHook = { [self] nanos in
            self.count += 1
            traced("wait", "#\(self.count)")
        }
        stubChecks.append { [self] what in
            expect(self.count <= 25, "\(what): wait count \(self.count) exceeds the bounded loop")
        }
    }
}

func mounted(_ path: String, fstype: String = "openntfs", readOnly: Bool = false) -> MountQueryState {
    .mounted(MountEntry(device: "/dev/disk9s1", path: path, fstype: fstype, readOnly: readOnly))
}

func makeDisk(mounted isMounted: Bool = true,
              ours: Bool = true,
              readOnly: Bool = false,
              label: String = "TestDisk") -> NTFSDisk {
    NTFSDisk(bsdName: "disk9s1", label: label, size: 1000,
             kind: ours ? "openntfs" : "ntfs",
             mountPoint: isMounted ? URL(fileURLWithPath: "/Volumes/TestDisk") : nil,
             readOnly: readOnly, isInternal: false, isOurs: ours)
}

let dev = "/dev/disk9s1"
let epermOutput = "fsck_fskit: open(/dev/disk9s1): Operation not permitted"

// MARK: - A. Unmount failure stops everything

func testAUnmountFailureStopsEverything() async throws {
    let shell = ScriptedShell([
        .init("/usr/sbin/diskutil", ["unmount", dev], status: 1, output: "volume busy"),
        .init("/sbin/umount", ["/Volumes/TestDisk"], status: 1, output: "umount: busy"),
    ])
    shell.install()
    let probe = ScriptedProbe([])   // no mount queries may happen
    probe.install()
    let helper = ScriptedHelper()
    let mounter = Mounter(helper: helper)
    let text = await mounter.runMaintenanceFlow(makeDisk(), repair: false)
    expect(text.contains("volume busy"), "unmount error surfaced: \(text)")
    expect(shell.calls.count == 2
           && shell.calls[0].tool == "/usr/sbin/diskutil"
           && shell.calls[1].tool == "/sbin/umount",
           "unmount attempts diskutil then umount(8), nothing else: \(shell.calls)")
    expect(shell.fsckCalls.isEmpty && shell.mountCalls.isEmpty, "no fsck / no remount commands")
    expect(helper.preps.isEmpty && helper.restores.isEmpty, "no helper calls")
    expect(probe.queries.isEmpty, "no mount-table queries")
}

// MARK: - B. Mount-state gates

func testBQueryFailedBeforeCheckBlocksFsck() async throws {
    // 26 queryFailed answers = 1 initial + 25 loop iterations (bounded).
    let probe = ScriptedProbe(Array(repeating: MountQueryState.queryFailed("boom"), count: 26))
    probe.install()
    let waits = WaitCounter(); waits.install()
    let shell = ScriptedShell([])   // no command may run
    shell.install()
    let helper = ScriptedHelper()
    let text = await Mounter(helper: helper).runMaintenanceFlow(makeDisk(mounted: false), repair: false)
    expect(shell.calls.isEmpty, "gate failure must run zero commands: \(shell.calls)")
    expect(helper.preps.isEmpty && helper.restores.isEmpty, "no helper calls")
    expect(probe.queries.count == 26, "bounded retry loop (26 queries, not endless): \(probe.queries.count)")
    expect(waits.count == 25, "25 waits between the 26 probes: \(waits.count)")
    expect(text.contains("TestDisk"), "failure text still labels the volume: \(text)")
}

func testBRemountedBeforePrepareBlocksHelper() async throws {
    let shell = ScriptedShell([
        .init("/sbin/fsck_fskit", ["-t", "openntfs", "-q", dev], status: 13, output: epermOutput),
    ])
    shell.install()
    // Gate 1 unmounted; gate 2 (before-prepare) sees mounted for 26 probes.
    var seq: [MountQueryState] = [.unmounted]
    seq += Array(repeating: mounted("/Volumes/TestDisk"), count: 26)
    let probe = ScriptedProbe(seq); probe.install()
    WaitCounter().install()
    let helper = ScriptedHelper()
    let text = await Mounter(helper: helper).runMaintenanceFlow(makeDisk(mounted: false), repair: false)
    expect(shell.fsckCalls.count == 1, "only the first fsck ran: \(shell.calls)")
    expect(helper.preps.isEmpty, "prepare must NOT run after a remounted/failed gate")
    expect(helper.restores.isEmpty, "nothing authorized, nothing to restore")
    expect(text.contains("TestDisk"), "abort surfaced: \(text)")
}

func testBRemountedBeforeSecondFsckRestoresAndReportsRestoreFailure() async throws {
    let shell = ScriptedShell([
        .init("/sbin/fsck_fskit", ["-t", "openntfs", "-q", dev], status: 13, output: epermOutput),
    ])
    shell.install()
    var seq: [MountQueryState] = [.unmounted, .unmounted]
    seq += Array(repeating: MountQueryState.queryFailed("late failure"), count: 26)
    let probe = ScriptedProbe(seq); probe.install()
    WaitCounter().install()
    let helper = ScriptedHelper([
        .prepare(devicePath: dev, writeAccess: false),
        .restore(devicePath: dev, error: "restore exploded"),
    ])
    let text = await Mounter(helper: helper).runMaintenanceFlow(makeDisk(mounted: false), repair: false)
    expect(shell.fsckCalls.count == 1, "second fsck must NOT start: \(shell.calls)")
    expect(helper.preps.count == 1, "prepare ran (authorized path)")
    expect(helper.restores.count == 1, "restore attempted after the abort")
    expect(text.contains("restore exploded"),
           "restore failure preserved in the UI text: \(text)")
}

// MARK: - C. Direct execution and EPERM fallback

func testCVerifyArgsAndDirectSuccessSkipHelper() async throws {
    let shell = ScriptedShell([
        .init("/sbin/fsck_fskit", ["-t", "openntfs", "-q", dev], status: 0, output: ""),
    ])
    shell.install()
    let probe = ScriptedProbe([.unmounted]); probe.install()
    let helper = ScriptedHelper()
    let text = await Mounter(helper: helper).runMaintenanceFlow(makeDisk(mounted: false), repair: false)
    expect(shell.calls.count == 1
           && shell.calls[0].args == ["-t", "openntfs", "-q", dev],
           "verify args exact (-q, type openntfs): \(shell.calls)")
    expect(helper.preps.isEmpty && helper.restores.isEmpty, "no helper on direct success")
    expect(text.contains("TestDisk"), "labeled text: \(text)")
}

func testCRepairArgsDifferFromVerify() async throws {
    let shell = ScriptedShell([
        .init("/sbin/fsck_fskit", ["-t", "openntfs", "-q", dev], status: 0, output: ""),
    ])
    shell.install()
    let probe = ScriptedProbe([.unmounted]); probe.install()
    let helper = ScriptedHelper()
    let verifyText = await Mounter(helper: helper).runMaintenanceFlow(makeDisk(mounted: false, label: "V"), repair: false)
    // Re-run with repair: fresh stubs (verify flow above consumed its script).
    let shell2 = ScriptedShell([
        .init("/sbin/fsck_fskit", ["-t", "openntfs", "-y", dev], status: 0, output: ""),
    ])
    shell2.install()
    let probe2 = ScriptedProbe([.unmounted]); probe2.install()
    let repairText = await Mounter(helper: helper).runMaintenanceFlow(makeDisk(mounted: false, label: "V"), repair: true)
    expect(shell2.calls.count == 1 && shell2.calls[0].args.contains("-y")
           && !shell2.calls[0].args.contains("-q"), "repair uses -y: \(shell2.calls)")
    expect(verifyText != repairText, "verify and repair success texts differ")
    expect(helper.preps.isEmpty, "no helper on direct success")
}

func testCNonPermissionFailureKeptNoHelper() async throws {
    let shell = ScriptedShell([
        .init("/sbin/fsck_fskit", ["-t", "openntfs", "-q", dev], status: 8,
              output: "volume has corrupt metadata"),
    ])
    shell.install()
    let probe = ScriptedProbe([.unmounted]); probe.install()
    let helper = ScriptedHelper()
    let text = await Mounter(helper: helper).runMaintenanceFlow(makeDisk(mounted: false), repair: false)
    expect(text.contains("corrupt metadata"), "original failure kept: \(text)")
    expect(helper.preps.isEmpty, "non-permission failure must not call the helper")
}

func helperFallbackFlow(repair: Bool, secondResult: CommandResult,
                        restoreError: Error? = nil) async throws
    -> (text: String, shell: ScriptedShell, helper: ScriptedHelper) {
    let shell = ScriptedShell([
        .init("/sbin/fsck_fskit", ["-t", "openntfs", repair ? "-y" : "-q", dev],
              status: 13, output: epermOutput),
        .init("/sbin/fsck_fskit", ["-t", "openntfs", repair ? "-y" : "-q", dev],
              status: secondResult.status, output: secondResult.output),
    ])
    shell.install()
    let probe = ScriptedProbe([.unmounted, .unmounted, .unmounted]); probe.install()
    let helper = ScriptedHelper([
        .prepare(devicePath: dev, writeAccess: repair),
        .restore(devicePath: dev, error: restoreError?.localizedDescription),
    ])
    let text = await Mounter(helper: helper)
        .runMaintenanceFlow(makeDisk(mounted: false), repair: repair)
    return (text, shell, helper)
}

func testCVerifyEPERMFallsBackWithReadOnlyGrant() async throws {
    let (text, shell, helper) = try await helperFallbackFlow(
        repair: false, secondResult: CommandResult(status: 0, output: ""))
    expect(helper.preps.count == 1 && helper.preps[0].writeAccess == false,
           "verify grants are ALWAYS read-only (writeAccess=false): \(helper.preps)")
    expect(helper.restores.count == 1, "restore after second fsck")
    expect(shell.fsckCalls.count == 2, "both fsck passes ran")
    expect(text.contains("TestDisk"), "success text: \(text)")
}

func testCRepairEPERMRequestsWriteGrant() async throws {
    let (_, shell, helper) = try await helperFallbackFlow(
        repair: true, secondResult: CommandResult(status: 0, output: ""))
    expect(helper.preps.count == 1 && helper.preps[0].writeAccess == true,
           "repair requests the write grant: \(helper.preps)")
}

func testCPrepareFailureNoSecondFsckNoSuccess() async throws {
    let shell = ScriptedShell([
        .init("/sbin/fsck_fskit", ["-t", "openntfs", "-q", dev], status: 13, output: epermOutput),
    ])
    shell.install()
    let probe = ScriptedProbe([.unmounted, .unmounted]); probe.install()
    let helper = ScriptedHelper([
        .prepare(devicePath: dev, writeAccess: false, error: "helper refused"),
    ])
    let text = await Mounter(helper: helper).runMaintenanceFlow(makeDisk(mounted: false), repair: false)
    expect(shell.fsckCalls.count == 1, "no second fsck after prepare failure: \(shell.calls)")
    expect(helper.restores.isEmpty, "nothing granted → no restore expected")
    expect(!text.contains("no problems found"), "must not report success: \(text)")
    expect(text.contains("helper refused"), "prepare failure surfaced: \(text)")
}

func testCSecondFsckFailsStillRestores() async throws {
    let (text, shell, helper) = try await helperFallbackFlow(
        repair: false, secondResult: CommandResult(status: 8, output: "still corrupt"))
    expect(helper.restores.count == 1, "restore runs even when the second fsck fails")
    expect(text.contains("still corrupt"), "tool failure kept: \(text)")
}

func testCLaunchFailureStillRestores() async throws {
    let (text, shell, helper) = try await helperFallbackFlow(
        repair: false, secondResult: CommandResult(status: -1, output: "launch failed"))
    expect(helper.restores.count == 1, "restore runs even when the process fails to launch")
    expect(text.contains("launch failed"), "launch failure surfaced: \(text)")
}

func testCRestoreFailureReportedSeparatelyFromSuccess() async throws {
    let (text, _, helper) = try await helperFallbackFlow(
        repair: false, secondResult: CommandResult(status: 0, output: ""),
        restoreError: NSError(domain: "test", code: 7,
                              userInfo: [NSLocalizedDescriptionKey: "restore EIO"]))
    expect(helper.restores.count == 1, "restore attempted")
    // BOTH parts visible: tool success AND restore failure (not masked).
    expect(text.contains("TestDisk"), "tool result present: \(text)")
    expect(text.contains("restore EIO"), "restore failure present and separate: \(text)")
}

// MARK: - D. Post-maintenance mount policy (remountAfterMaintenance)

func testDRWPolicyAndNeutralReadOnlyWording() async throws {
    // D1: ours-RW volume remounts RW via diskutil mount (no force).
    do {
        let shell = ScriptedShell([.init("/usr/sbin/diskutil", ["mount", dev])])
        shell.install()
        let probe = ScriptedProbe([.unmounted, mounted("/Volumes/TestDisk"),
                                    mounted("/Volumes/TestDisk")]); probe.install()
        let outcome = await Mounter(helper: ScriptedHelper())
            .remountAfterMaintenance(makeDisk(mounted: false, ours: true, readOnly: false),
                                     preferredLabel: "TestDisk", wasOurs: true, wasReadOnly: false)
        if case .remountedReadWrite = outcome { expect(true, "D1 rw") }
        else { expect(false, "D1 expected remountedReadWrite, got \(outcome)") }
    }
    // D2: originally read-only (ours) → readOnly remount, explicit args.
    do {
        let shell = ScriptedShell([.init("/usr/sbin/diskutil", ["mount", "readOnly", dev])])
        shell.install()
        let probe = ScriptedProbe([.unmounted, mounted("/Volumes/TestDisk", readOnly: true)])
        probe.install()
        let outcome = await Mounter(helper: ScriptedHelper())
            .remountAfterMaintenance(makeDisk(mounted: false, ours: true, readOnly: true),
                                     preferredLabel: "TestDisk", wasOurs: true, wasReadOnly: true)
        if case .remountedReadOnly(_, let downgraded) = outcome {
            expect(!downgraded, "D2 same-policy RO, not a downgrade")
        } else { expect(false, "D2 expected remountedReadOnly, got \(outcome)") }
    }
    // D3: foreign originally-RW volume → conservative RO WITH downgrade flag.
    do {
        let shell = ScriptedShell([.init("/usr/sbin/diskutil", ["mount", "readOnly", dev])])
        shell.install()
        let probe = ScriptedProbe([.unmounted, mounted("/Volumes/TestDisk", readOnly: true)])
        probe.install()
        let outcome = await Mounter(helper: ScriptedHelper())
            .remountAfterMaintenance(makeDisk(mounted: false, ours: false, readOnly: false),
                                     preferredLabel: "TestDisk", wasOurs: false, wasReadOnly: false)
        if case .remountedReadOnly(_, let downgraded) = outcome {
            expect(downgraded, "D3 foreign RW conservatively downgraded to RO")
        } else { expect(false, "D3 expected remountedReadOnly(downgraded), got \(outcome)") }
    }
    // D4: RW request answered with a READ-ONLY mount → honest RO outcome and
    // NEUTRAL wording (the mount table has no cause evidence).
    do {
        let shell = ScriptedShell([.init("/usr/sbin/diskutil", ["mount", dev])])
        shell.install()
        let probe = ScriptedProbe([.unmounted, mounted("/Volumes/TestDisk", readOnly: true),
                                    mounted("/Volumes/TestDisk", readOnly: true)])
        probe.install()
        let mounter = Mounter(helper: ScriptedHelper())
        let outcome = await mounter.remountAfterMaintenance(
            makeDisk(mounted: false, ours: true, readOnly: false),
            preferredLabel: "TestDisk", wasOurs: true, wasReadOnly: false)
        if case .remountedButReadOnly(let path) = outcome {
            let text = MaintenanceReport.remountMessage(outcome)
            expect(!text.contains("Windows") && !text.contains("未正常关机") && !text.contains("关机"),
                   "D4 neutral wording, no unproven attribution: \(text)")
            expect(text.contains(path), "D4 message names the mount: \(text)")
        } else { expect(false, "D4 expected remountedButReadOnly, got \(outcome)") }
    }
    // D5: existing policy-violating RW mount → non-force corrective unmount
    // succeeds → policy RO remount follows.
    do {
        let shell = ScriptedShell([
            .init("/usr/sbin/diskutil", ["unmount", dev]),
            .init("/usr/sbin/diskutil", ["mount", "readOnly", dev]),
        ])
        shell.install()
        let probe = ScriptedProbe([
            mounted("/Volumes/TestDisk", fstype: "ntfs", readOnly: false),   // foreign RW (initial)
            mounted("/Volumes/TestDisk", readOnly: true),                    // post-mount verify
        ])
        probe.install()
        let outcome = await Mounter(helper: ScriptedHelper())
            .remountAfterMaintenance(makeDisk(mounted: false, ours: true, readOnly: true),
                                     preferredLabel: "TestDisk", wasOurs: true, wasReadOnly: true)
        if case .remountedReadOnly = outcome { expect(true, "D5 corrected to RO") }
        else { expect(false, "D5 expected remountedReadOnly, got \(outcome)") }
        expect(shell.calls.first?.args.first == "unmount" && !shell.calls[0].args.contains("force"),
               "D5 corrective unmount is non-force: \(shell.calls)")
    }
    // D6: corrective unmount FAILS → honest "still mounted read-write", no
    // further mount attempts, no false "unmounted" success.
    do {
        let shell = ScriptedShell([
            .init("/usr/sbin/diskutil", ["unmount", dev], status: 1, output: "busy"),
        ])
        shell.install()
        let probe = ScriptedProbe([mounted("/Volumes/TestDisk", fstype: "ntfs", readOnly: false)])
        probe.install()
        let outcome = await Mounter(helper: ScriptedHelper())
            .remountAfterMaintenance(makeDisk(mounted: false, ours: true, readOnly: true),
                                     preferredLabel: "TestDisk", wasOurs: true, wasReadOnly: true)
        if case .failed(let detail) = outcome {
            expect(detail.contains("/Volumes/TestDisk"),
                   "D6 reports the observed still-mounted path: \(detail)")
        } else { expect(false, "D6 expected .failed, got \(outcome)") }
        expect(shell.calls.count == 1, "D6 stops after the failed corrective unmount: \(shell.calls)")
        let text = MaintenanceReport.remountMessage(outcome)
        expect(!text.isEmpty, "D6 text present")
    }
    // D7: mount command succeeds but the state query fails / shows nothing
    // mounted → cannot report mount success.
    do {
        let shell = ScriptedShell([.init("/usr/sbin/diskutil", ["mount", "readOnly", dev])])
        shell.install()
        let probe = ScriptedProbe([.unmounted, .queryFailed("post-mount query failed")])
        probe.install()
        let outcome = await Mounter(helper: ScriptedHelper())
            .remountAfterMaintenance(makeDisk(mounted: false, ours: true, readOnly: true),
                                     preferredLabel: "TestDisk", wasOurs: true, wasReadOnly: true)
        if case .failed(let detail) = outcome {
            expect(detail.contains("post-mount query failed") || detail.contains("unknown"),
                   "D7 unknown state surfaced: \(detail)")
        } else { expect(false, "D7 expected .failed, got \(outcome)") }
    }
    do {
        let shell = ScriptedShell([.init("/usr/sbin/diskutil", ["mount", "readOnly", dev])])
        shell.install()
        let probe = ScriptedProbe([.unmounted, .unmounted])
        probe.install()
        let outcome = await Mounter(helper: ScriptedHelper())
            .remountAfterMaintenance(makeDisk(mounted: false, ours: true, readOnly: true),
                                     preferredLabel: "TestDisk", wasOurs: true, wasReadOnly: true)
        if case .failed = outcome { expect(true, "D8 not-mounted reported") }
        else { expect(false, "D8 expected .failed, got \(outcome)") }
    }
    // D9: Untitled placeholder under maintenance policy → NO force retry;
    // labeled-path fallback also fails → flow STOPS at the failure
    // condition instead of bypassing it (mount points live in the scene).
    do {
        let scene = makeScene("d9")
        Mounter.mountRootOverride = scene
        MountTable.entriesHook = { [] }
        // The maintenance strategy (.preferLabeledPath) has NO labeled-path
        // fallback inside mountReadWrite: the Untitled retry throws directly
        // and the flow stops at that failure condition.
        let shell = ScriptedShell([
            .init("/usr/sbin/diskutil", ["mount", dev]),                       // ok → Untitled
        ])
        shell.install()
        let probe = ScriptedProbe([
            .unmounted,
            mounted("/Volumes/Untitled", readOnly: false),
        ])
        probe.install()
        let outcome = await Mounter(helper: ScriptedHelper())
            .remountAfterMaintenance(makeDisk(mounted: false, ours: true, readOnly: false),
                                     preferredLabel: "TestDisk", wasOurs: true, wasReadOnly: false)
        if case .failed(let detail) = outcome {
            expect(detail.contains("/Volumes/Untitled"),
                   "D9 reports the OBSERVED mount path: \(detail)")
            expect(detail.contains("openntfs"),
                   "D9 reports the observed driver: \(detail)")
            expect(detail.contains("read-write") || detail.contains("可读写"),
                   "D9 reports the OBSERVED access mode: \(detail)")
            expect(!detail.contains("已卸载") && !detail.contains("was unmounted"),
                   "D9 must not imply the volume was unmounted: \(detail)")
        } else {
            expect(false, "D9 expected .failed, got \(outcome)")
        }
    }
}

// MARK: - A. Interactive strategy: hand-off unmount failure stops fallback

// Interactive path (.preferDiskArbitration): another driver won the probe,
// the hand-off unmount FAILS → MountStopError propagates; the outer catch
// must NOT fall back — no mount -F (unified shell acceptance fails on any
// extra/unscripted call), no fallback directory, no force.
func testInteractiveHandoffUnmountFailureStops() async throws {
    guard let scene = Mounter.mountRootOverride else {
        return expect(false, "harness must install a per-test temp mount root")
    }
    let shell = ScriptedShell([
        .init("/usr/sbin/diskutil", ["mount", dev]),
        .init("/usr/sbin/diskutil", ["unmount", dev], status: 1, output: "unmount failed: busy"),
    ])
    shell.install()
    let probe = ScriptedProbe([
        mounted("/Volumes/TestDisk", fstype: "ntfs", readOnly: false),
    ])
    probe.install()
    let disk = makeDisk(mounted: false, ours: true, readOnly: false)
    do {
        _ = try await Mounter(helper: ScriptedHelper())
            .mountReadWrite(disk, strategy: .preferDiskArbitration)
        expect(false, "interactive hand-off unmount failure must throw")
    } catch let stop as MountStopError {
        expect(stop.message.contains("unmount failed: busy"),
               "original unmount error preserved: \(stop.message)")
    } catch {
        expect(false, "expected MountStopError, got \(error)")
    }
    let entries = try FileManager.default.contentsOfDirectory(atPath: scene.path)
    expect(entries.isEmpty, "no fallback mount point created: \(entries)")
}

// Interactive path positive control: an ORDINARY failure (all diskutil
// attempts fail, inner labeled fallback also fails) still reaches the outer
// catch's labeled fallback and succeeds there.
func testInteractiveOrdinaryFailureStillFallsBack() async throws {
    guard let scene = Mounter.mountRootOverride else {
        return expect(false, "harness must install a per-test temp mount root")
    }
    allowMountTableQueries = true
    let mountF = ["-F", "-t", "openntfs", dev, scene.appendingPathComponent("TestDisk").path]
    let shell = ScriptedShell([
        .init("/usr/sbin/diskutil", ["mount", dev], status: 1, output: "mount failed"),  // attempt 1
        .init("/usr/sbin/diskutil", ["unmount", "force", dev], status: 0, output: ""),    // interactive retry unmounts with force (opt-in)
        .init("/usr/sbin/diskutil", ["mount", dev], status: 1, output: "mount failed"),  // attempt 2
        .init("/usr/sbin/diskutil", ["unmount", "force", dev], status: 0, output: ""),    // attempt 3
        .init("/usr/sbin/diskutil", ["mount", dev], status: 1, output: "mount failed"),  // attempt 3 mount
        .init("/sbin/mount", mountF, status: 1, output: "labeled failed"),                // inner fallback fails
        .init("/sbin/mount", mountF),                                                     // outer fallback succeeds
    ])
    shell.allowsForceUnmock = true   // interactive retry force-unmounts (pre-existing opt-in)
    shell.install()
    let probe = ScriptedProbe([])   // no successful diskutil mount → no probe reads
    probe.install()
    let disk = makeDisk(mounted: false, ours: true, readOnly: false)
    let url = try await Mounter(helper: ScriptedHelper())
        .mountReadWrite(disk, strategy: .preferDiskArbitration)
    expect(url.path.hasPrefix(scene.path), "outer fallback mounts under the temp root: \(url.path)")
}

// MARK: - D. Stop reasons: mount-command failure vs unconfirmed state vs observed placeholder

// (a) The FIRST diskutil mount FAILS → the maintenance stop preserves the
// ORIGINAL error/exit status, claims nothing about paths or mounts, and
// runs nothing further (the unified shell acceptance fails on any extra
// call; the probe script is empty because the state is never queried).
func testDStopMountCommandFailedKeepsOriginalError() async throws {
    guard let scene = Mounter.mountRootOverride else {
        return expect(false, "harness must install a per-test temp mount root")
    }
    let shell = ScriptedShell([
        .init("/usr/sbin/diskutil", ["mount", dev], status: 7,
              output: "diskutil-mount-failed-output"),
    ])
    shell.install()
    let probe = ScriptedProbe([.unmounted])   // initial state; da fails → no further query
    probe.install()
    let outcome = await Mounter(helper: ScriptedHelper())
        .remountAfterMaintenance(makeDisk(mounted: false, ours: true, readOnly: false),
                                 preferredLabel: "TestDisk", wasOurs: true, wasReadOnly: false)
    if case .failed(let detail) = outcome {
        expect(detail.contains("diskutil-mount-failed-output"),
               "original mount error preserved verbatim: \(detail)")
        expect(!detail.contains("/Volumes"),
               "must NOT claim any observed path: \(detail)")
    } else {
        expect(false, "expected .failed, got \(outcome)")
    }
    let entries = try FileManager.default.contentsOfDirectory(atPath: scene.path)
    expect(entries.isEmpty, "no fallback mount point created: \(entries)")
}

// (b) The mount COMMAND succeeds but the state query FAILS → the stop says
// the mount state is UNKNOWN/unconfirmed (with the query error), never a
// success claim and never a fabricated path.
func testDStopQueryFailedReportsUnknownState() async throws {
    let shell = ScriptedShell([
        .init("/usr/sbin/diskutil", ["mount", dev]),
    ])
    shell.install()
    let probe = ScriptedProbe([.unmounted, .queryFailed("query-boom")])
    probe.install()
    let outcome = await Mounter(helper: ScriptedHelper())
        .remountAfterMaintenance(makeDisk(mounted: false, ours: true, readOnly: false),
                                 preferredLabel: "TestDisk", wasOurs: true, wasReadOnly: false)
    if case .failed(let detail) = outcome {
        expect(detail.contains("query-boom"),
               "original query error preserved: \(detail)")
        expect(detail.contains("未知") || detail.contains("unknown"),
               "state explicitly reported unknown/unconfirmed: \(detail)")
        expect(!detail.contains("/Volumes"),
               "must NOT claim a mount path: \(detail)")
    } else {
        expect(false, "expected .failed, got \(outcome)")
    }
}

// MARK: - C. Restore "no active lease" is UNCONFIRMED, never "restore failed"

// The helper's lease may already have been restored (e.g. by its timeout)
// and removed; the restore RPC then fails with "no active lease". The App
// cannot reliably distinguish that from a real restore failure, so the
// wording must be neutral ("outcome unconfirmed"), preserve the original
// detail, and never claim success — while the fsck result stays separate.
func testCRestoreNoActiveLeaseIsUnconfirmed() async throws {
    let (text, _, helper) = try await helperFallbackFlow(
        repair: false,
        secondResult: CommandResult(status: 0, output: ""),
        restoreError: NSError(domain: "helper", code: 1,
                              userInfo: [NSLocalizedDescriptionKey:
                                "refused: no active lease for /dev/disk9s1"]))
    expect(helper.restores.count == 1, "restore was attempted")
    expect(text.contains("refused: no active lease for /dev/disk9s1"),
           "original detail preserved: \(text)")
    expect(!text.contains("权限恢复失败") && !text.contains("Device permission restore failed"),
           "must NOT claim a definite restore failure: \(text)")
    expect(text.contains("TestDisk"), "fsck result still independently present: \(text)")
}

// MARK: - Isolation: fallback mount point lives ONLY in the per-test temp root

// Positive control + isolation proof: a policy RW remount that ends in the
// labeled-path fallback. The REAL makeMountPoint runs (real FileManager)
// and may only create directories under the per-test TEMP mount root; the
// mount command itself goes through the stub; the mount-table read is
// DECLARED. No real home path is ever read to "prove" isolation — every
// assertion is scene-scoped by construction.
func testFallbackSceneIsolation() async throws {
    allowMountTableQueries = true
    guard let scene = Mounter.mountRootOverride else {
        return expect(false, "harness must install a per-test temp mount root")
    }
    let shell = ScriptedShell([
        .init("/usr/sbin/diskutil", ["mount", dev]),
        .init("/usr/sbin/diskutil", ["unmount", dev]),           // hand-off unmount OK
        .init("/sbin/mount", ["-F", "-t", "openntfs", dev,
                              scene.appendingPathComponent("TestDisk").path]),
    ])
    shell.install()
    let probe = ScriptedProbe([
        .unmounted,
        mounted("/Volumes/TestDisk", fstype: "ntfs", readOnly: true),   // foreign wins probe
        mounted(scene.appendingPathComponent("TestDisk").path, fstype: "openntfs",
               readOnly: false),                                        // final mode verify
    ])
    probe.install()
    let outcome = await Mounter(helper: ScriptedHelper())
        .remountAfterMaintenance(makeDisk(mounted: false, ours: true, readOnly: false),
                                 preferredLabel: "TestDisk", wasOurs: true, wasReadOnly: false)
    if case .remountedReadWrite(let path) = outcome {
        expect(path.hasPrefix(scene.path), "labeled path is inside the TEMP root: \(path)")
    } else {
        expect(false, "expected remountedReadWrite, got \(outcome)")
    }
    // The real makeMountPoint created the directory — under the temp root only.
    let entries = try FileManager.default.contentsOfDirectory(atPath: scene.path)
    expect(entries.contains("TestDisk"), "mount point created under the temp root: \(entries)")
    // The fallback mount command went through the STUB and targeted the temp dir.
    let mountF = shell.calls.first { $0.tool == "/sbin/mount" }
    expect(mountF != nil && mountF!.args[4].hasPrefix(scene.path),
           "mount -F targets the temp root (args[4] = mount dir): \(String(describing: mountF))")
    expect(mountTableQueries == 1, "exactly one declared mount-table query: \(mountTableQueries)")
}

// MARK: - Foreign-driver hand-off unmount failure stops the flow (product fix)

// mount ok → probe shows ANOTHER driver → non-force unmount FAILS → stop:
// original error preserved, no further mount of any kind (the unified shell
// acceptance fails the test on any unscripted/extra call), and no fallback
// mount point is created under the temp root.
func testForeignHandoffUnmountFailureStops() async throws {
    guard let scene = Mounter.mountRootOverride else {
        return expect(false, "harness must install a per-test temp mount root")
    }
    let shell = ScriptedShell([
        .init("/usr/sbin/diskutil", ["mount", dev]),
        .init("/usr/sbin/diskutil", ["unmount", dev], status: 1, output: "unmount failed: busy"),
    ])
    shell.install()
    let probe = ScriptedProbe([
        .unmounted,
        mounted("/Volumes/TestDisk", fstype: "ntfs", readOnly: false),
    ])
    probe.install()
    let outcome = await Mounter(helper: ScriptedHelper())
        .remountAfterMaintenance(makeDisk(mounted: false, ours: true, readOnly: false),
                                 preferredLabel: "TestDisk", wasOurs: true, wasReadOnly: false)
    if case .failed(let detail) = outcome {
        expect(detail.contains("unmount failed: busy"),
               "original unmount failure preserved in the outcome: \(detail)")
    } else {
        expect(false, "expected .failed, got \(outcome)")
    }
    // No fallback mount point creation leaked into the temp root.
    let entries = try FileManager.default.contentsOfDirectory(atPath: scene.path)
    expect(entries.isEmpty, "no fallback mount point created: \(entries)")
    // Cross-dependency order: mount → probe(foreign) → unmount(fail) → STOP.
    let kinds = traceKinds()
    expect(kinds == ["probe", "shell", "probe", "shell"],
           "exact event order for the failed hand-off: \(kinds)")
}

// MARK: - Cross-dependency event order (A–E) via the shared trace

func testTraceCrossDependencyOrder() async throws {
    // A: gate → fsck1 → gate → prepare → gate → fsck2 → restore.
    do {
        let shell = ScriptedShell([
            .init("/sbin/fsck_fskit", ["-t", "openntfs", "-q", dev], status: 13, output: epermOutput),
            .init("/sbin/fsck_fskit", ["-t", "openntfs", "-q", dev], status: 0, output: ""),
        ])
        shell.install()
        let probe = ScriptedProbe([.unmounted, .unmounted, .unmounted]); probe.install()
        _ = await Mounter(helper: ScriptedHelper([
            .prepare(devicePath: dev, writeAccess: false),
            .restore(devicePath: dev),
        ])).runMaintenanceFlow(makeDisk(mounted: false), repair: false)
        let kinds = traceKinds()
        expect(kinds == ["probe", "shell", "probe", "helper-prepare", "probe", "shell", "helper-restore"],
               "A exact order gate→fsck1→gate→prepare→gate→fsck2→restore: \(kinds)")
        let fscks = shell.calls.filter { $0.tool.contains("fsck") }
        expect(fscks.count == 2, "exactly two fsck passes: \(fscks.count)")
        let prep = trace.first { $0.kind == "helper-prepare" }
        expect(prep?.detail.contains("writeAccess=false") == true,
               "verify grant is read-only: \(String(describing: prep))")
    }
    // B: prepare fails → NO fsck2, NO restore.
    do {
        trace = []   // section-local trace; ALL stub checks stay registered
        let shell = ScriptedShell([
            .init("/sbin/fsck_fskit", ["-t", "openntfs", "-q", dev], status: 13, output: epermOutput),
        ])
        shell.install()
        let probe = ScriptedProbe([.unmounted, .unmounted]); probe.install()
        let helper = ScriptedHelper([
            .prepare(devicePath: dev, writeAccess: false, error: "refused"),
        ])
        _ = await Mounter(helper: helper).runMaintenanceFlow(makeDisk(mounted: false), repair: false)
        let kinds = traceKinds()
        expect(kinds == ["probe", "shell", "probe", "helper-prepare"],
               "B prepare-failure stops before fsck2/restore: \(kinds)")
    }
    // C: gate AFTER prepare fails → no fsck2, restore MUST happen.
    do {
        trace = []   // section-local trace; ALL stub checks stay registered
        let shell = ScriptedShell([
            .init("/sbin/fsck_fskit", ["-t", "openntfs", "-q", dev], status: 13, output: epermOutput),
        ])
        shell.install()
        var seq: [MountQueryState] = [.unmounted, .unmounted]
        seq += Array(repeating: MountQueryState.queryFailed("gate3"), count: 26)
        let probe = ScriptedProbe(seq); probe.install()
        _ = await Mounter(helper: ScriptedHelper([
            .prepare(devicePath: dev, writeAccess: false),
            .restore(devicePath: dev),
        ])).runMaintenanceFlow(makeDisk(mounted: false), repair: false)
        let kinds = traceKinds()
        expect(kinds.prefix(4) == ["probe", "shell", "probe", "helper-prepare"],
               "C prefix order: \(kinds)")
        expect(!kinds.dropFirst(4).contains("shell"), "C no second fsck: \(kinds)")
        expect(kinds.last == "helper-restore", "C restore happens after the aborted gate: \(kinds)")
    }
    // D: fsck2 fails (or launch fails) → restore comes AFTER the fsck2 event.
    do {
        trace = []   // section-local trace; ALL stub checks stay registered
        let shell = ScriptedShell([
            .init("/sbin/fsck_fskit", ["-t", "openntfs", "-q", dev], status: 13, output: epermOutput),
            .init("/sbin/fsck_fskit", ["-t", "openntfs", "-q", dev], status: 8, output: "corrupt"),
        ])
        shell.install()
        let probe = ScriptedProbe([.unmounted, .unmounted, .unmounted]); probe.install()
        _ = await Mounter(helper: ScriptedHelper([
            .prepare(devicePath: dev, writeAccess: false),
            .restore(devicePath: dev),
        ])).runMaintenanceFlow(makeDisk(mounted: false), repair: false)
        let shells = traceIndexes(of: "shell")
        let restores = traceIndexes(of: "helper-restore")
        expect(shells.count == 2 && restores.count == 1 && restores[0] > shells[1],
               "D restore strictly after the second fsck: shells=\(shells) restores=\(restores)")
    }
    // E: restore fails → warning preserved, policy remount still happens
    // (current product policy, unchanged), remount AFTER the restore event.
    do {
        trace = []   // section-local trace; ALL stub checks stay registered
        let shell = ScriptedShell([
            .init("/usr/sbin/diskutil", ["unmount", dev]),  // flow unmounts FIRST
            .init("/sbin/fsck_fskit", ["-t", "openntfs", "-q", dev], status: 13, output: epermOutput),
            .init("/sbin/fsck_fskit", ["-t", "openntfs", "-q", dev], status: 0, output: ""),
            .init("/usr/sbin/diskutil", ["mount", dev]),     // policy RW remount
        ])
        shell.install()
        let probe = ScriptedProbe([
            .unmounted, .unmounted, .unmounted,
            .unmounted,                                     // remount initial state
            mounted("/Volumes/TestDisk", readOnly: false),  // mount verify
            mounted("/Volumes/TestDisk", readOnly: false),  // final mode verify
        ])
        probe.install()
        let helper = ScriptedHelper([
            .prepare(devicePath: dev, writeAccess: false),
            .restore(devicePath: dev, error: "restore EIO"),
        ])
        let text = await Mounter(helper: helper)
            .runMaintenanceFlow(makeDisk(mounted: true, ours: true, readOnly: false), repair: false)
        expect(text.contains("restore EIO"), "E restore failure preserved in text: \(text)")
        let restores = traceIndexes(of: "helper-restore")
        let shells = traceIndexes(of: "shell")
        expect(restores.count == 1 && shells.count == 4 && restores[0] < shells[3],
               "E policy remount happens after the (failed) restore: shells=\(shells) restores=\(restores)")
    }
}

// MARK: - E. App-level aggregation

func testEAggregation() async throws {
    // E1/E3/E4: mounted volume, verify success, policy RW remount — label
    // preserved, remount text appended, parts separated by " — ".
    do {
        let shell = ScriptedShell([
            .init("/usr/sbin/diskutil", ["unmount", dev]),
            .init("/sbin/fsck_fskit", ["-t", "openntfs", "-q", dev], status: 0, output: ""),
            .init("/usr/sbin/diskutil", ["mount", dev]),
        ])
        shell.install()
        let probe = ScriptedProbe([
            .unmounted,                                   // before-check gate
            .unmounted,                                   // remount initial state
            mounted("/Volumes/TestDisk", readOnly: false),// mount verify
            mounted("/Volumes/TestDisk", readOnly: false),// final mode verify
        ])
        probe.install()
        let text = await Mounter(helper: ScriptedHelper())
            .runMaintenanceFlow(makeDisk(mounted: true, ours: true, readOnly: false, label: "MyVol"),
                                repair: false)
        expect(text.hasPrefix("MyVol"), "E1 preserved label leads the text: \(text)")
        expect(text.contains(" — "), "E1 remount part appended and separated: \(text)")
        expect(text.components(separatedBy: " — ").count == 2,
               "E1 exactly two parts (fsck result + remount): \(text)")
    }
    // E4b: NOT-mounted volume → no unmount, no remount commands at all.
    do {
        let shell = ScriptedShell([
            .init("/sbin/fsck_fskit", ["-t", "openntfs", "-q", dev], status: 0, output: ""),
        ])
        shell.install()
        let probe = ScriptedProbe([.unmounted]); probe.install()
        let text = await Mounter(helper: ScriptedHelper())
            .runMaintenanceFlow(makeDisk(mounted: false), repair: false)
        expect(shell.calls.count == 1, "E4 only the fsck ran: \(shell.calls)")
        expect(!text.contains(" — "), "E4 no remount clause: \(text)")
    }
    // E5: current policy — a FAILED check on a previously mounted volume
    // still attempts the policy remount (documented behavior, unchanged).
    do {
        let shell = ScriptedShell([
            .init("/usr/sbin/diskutil", ["unmount", dev]),
            .init("/sbin/fsck_fskit", ["-t", "openntfs", "-q", dev], status: 8, output: "corrupt"),
            .init("/usr/sbin/diskutil", ["mount", "readOnly", dev]),
        ])
        shell.install()
        let probe = ScriptedProbe([
            .unmounted,
            .unmounted,
            mounted("/Volumes/TestDisk", readOnly: true),
        ])
        probe.install()
        let text = await Mounter(helper: ScriptedHelper())
            .runMaintenanceFlow(makeDisk(mounted: true, ours: true, readOnly: true), repair: false)
        expect(text.contains("corrupt"), "E5 tool failure present: \(text)")
        expect(shell.calls.contains { $0.args.first == "mount" },
               "E5 current policy: remount attempted even after check failure")
    }
}

// MARK: - F. Repair precheck on a read-write volume (no write when clean)

// A: read-write mounted + clean precheck → the flow must run exactly ONE
// read-only (-q) fsck, never ask for a write grant, and report the
// no-repair-needed wording. Code that repairs unconditionally fails this
// (it runs -y on a volume the read-only check just cleared).
func testFRepairPrecheckCleanSkipsWrite() async throws {
    let shell = ScriptedShell([
        .init("/usr/sbin/diskutil", ["unmount", dev]),                 // flow unmounts FIRST
        .init("/sbin/fsck_fskit", ["-t", "openntfs", "-q", dev]),      // read-only precheck
        .init("/usr/sbin/diskutil", ["mount", dev]),                   // policy RW remount
    ])
    shell.install()
    let probe = ScriptedProbe([
        .unmounted,                                    // precheck before-check gate
        .unmounted,                                    // remount initial state
        mounted("/Volumes/TestDisk", readOnly: false), // mount verify
        mounted("/Volumes/TestDisk", readOnly: false), // final mode verify
    ])
    probe.install()
    let helper = ScriptedHelper()
    let text = await Mounter(helper: helper)
        .runMaintenanceFlow(makeDisk(mounted: true, ours: true, readOnly: false), repair: true)
    expect(shell.fsckCalls.count == 1
           && shell.fsckCalls[0].args.contains("-q")
           && !shell.fsckCalls[0].args.contains("-y"),
           "exactly one fsck, the read-only precheck: \(shell.calls)")
    expect(!shell.calls.contains { $0.args.contains("-y") },
           "a clean read-only precheck must not be followed by -y: \(shell.calls)")
    expect(helper.preps.isEmpty, "no helper grant on a clean precheck: \(helper.preps)")
    expect(text.contains("no repair needed") || text.contains("未发现需要修复的问题"),
           "no-repair-needed wording present: \(text)")
}

// B: read-write mounted + precheck FAILS (-q exit 8) → exactly one -y
// repair pass follows, reported with the repair-finished wording.
func testFRepairPrecheckFailedRunsRepair() async throws {
    let shell = ScriptedShell([
        .init("/usr/sbin/diskutil", ["unmount", dev]),
        .init("/sbin/fsck_fskit", ["-t", "openntfs", "-q", dev], status: 8,
              output: "corrupt metadata"),
        .init("/sbin/fsck_fskit", ["-t", "openntfs", "-y", dev], status: 0, output: ""),
        .init("/usr/sbin/diskutil", ["mount", dev]),
    ])
    shell.install()
    let probe = ScriptedProbe([
        .unmounted,                                   // precheck gate
        .unmounted,                                   // repair gate
        .unmounted,                                   // remount initial state
        mounted("/Volumes/TestDisk", readOnly: false), // mount verify
        mounted("/Volumes/TestDisk", readOnly: false), // final mode verify
    ])
    probe.install()
    let helper = ScriptedHelper()
    let text = await Mounter(helper: helper)
        .runMaintenanceFlow(makeDisk(mounted: true, ours: true, readOnly: false), repair: true)
    let yCalls = shell.fsckCalls.filter { $0.args.contains("-y") }
    expect(yCalls.count == 1, "exactly one -y after the failed precheck: \(shell.calls)")
    expect(shell.fsckCalls.count == 2, "precheck then repair, nothing else: \(shell.calls)")
    expect(helper.preps.isEmpty, "direct path needs no helper: \(helper.preps)")
    expect(text.contains("repair finished") || text.contains("修复完成"),
           "repair-finished wording: \(text)")
    expect(text.contains("Windows"), "repair-finished text carries the Windows scan note: \(text)")
}

// C: read-only mounted and NOT-mounted volumes do NOT precheck — one -y
// directly (the direct-repair behavior for volumes whose mount state
// proves nothing about log replay / hibernation cleanup).
func testFRepairReadOnlyMountedRunsRepairDirectly() async throws {
    let shell = ScriptedShell([
        .init("/usr/sbin/diskutil", ["unmount", dev]),
        .init("/sbin/fsck_fskit", ["-t", "openntfs", "-y", dev], status: 0, output: ""),
        .init("/usr/sbin/diskutil", ["mount", "readOnly", dev]),
    ])
    shell.install()
    let probe = ScriptedProbe([
        .unmounted,                                 // repair gate
        .unmounted,                                 // remount initial state
        mounted("/Volumes/TestDisk", readOnly: true), // post-mount verify
    ])
    probe.install()
    let helper = ScriptedHelper()
    let text = await Mounter(helper: helper)
        .runMaintenanceFlow(makeDisk(mounted: true, ours: true, readOnly: true), repair: true)
    expect(shell.fsckCalls.count == 1 && shell.fsckCalls[0].args.contains("-y"),
           "no precheck on a read-only mount; one -y directly: \(shell.calls)")
    expect(!shell.calls.contains { $0.args.contains("-q") },
           "no read-only precheck may run: \(shell.calls)")
    expect(text.contains("repair finished") || text.contains("修复完成"),
           "repair-finished wording: \(text)")
}

func testFRepairNotMountedRunsRepairDirectly() async throws {
    let shell = ScriptedShell([
        .init("/sbin/fsck_fskit", ["-t", "openntfs", "-y", dev], status: 0, output: ""),
    ])
    shell.install()
    let probe = ScriptedProbe([.unmounted])   // repair gate
    probe.install()
    let helper = ScriptedHelper()
    let text = await Mounter(helper: helper)
        .runMaintenanceFlow(makeDisk(mounted: false, ours: true, readOnly: false), repair: true)
    expect(shell.fsckCalls.count == 1 && shell.fsckCalls[0].args.contains("-y"),
           "no precheck when not mounted; one -y directly: \(shell.calls)")
    expect(!shell.calls.contains { $0.args.contains("-q") },
           "no read-only precheck may run: \(shell.calls)")
    expect(text.contains("repair finished") || text.contains("修复完成"),
           "repair-finished wording: \(text)")
}

// D: read-write mounted + precheck takes the helper path (first -q EPERM,
// read-only grant, second -q ok) but the permission restore FAILS → zero
// -y, the warning is preserved alongside the no-repair-needed result.
func testFRepairPrecheckRestoreFailureSkipsWriteKeepsWarning() async throws {
    let shell = ScriptedShell([
        .init("/usr/sbin/diskutil", ["unmount", dev]),
        .init("/sbin/fsck_fskit", ["-t", "openntfs", "-q", dev], status: 13, output: epermOutput),
        .init("/sbin/fsck_fskit", ["-t", "openntfs", "-q", dev], status: 0, output: ""),
        .init("/usr/sbin/diskutil", ["mount", dev]),
    ])
    shell.install()
    let probe = ScriptedProbe([
        .unmounted,                                    // precheck gate 1
        .unmounted,                                    // gate 2 (before-prepare)
        .unmounted,                                    // gate 3 (before-fsck-escalated)
        .unmounted,                                    // remount initial state
        mounted("/Volumes/TestDisk", readOnly: false), // mount verify
        mounted("/Volumes/TestDisk", readOnly: false), // final mode verify
    ])
    probe.install()
    let helper = ScriptedHelper([
        .prepare(devicePath: dev, writeAccess: false),
        .restore(devicePath: dev, error: "restore EIO"),
    ])
    let text = await Mounter(helper: helper)
        .runMaintenanceFlow(makeDisk(mounted: true, ours: true, readOnly: false), repair: true)
    expect(!shell.calls.contains { $0.args.contains("-y") },
           "a warned precheck must not be followed by -y: \(shell.calls)")
    expect(helper.preps.count == 1 && helper.preps[0].writeAccess == false,
           "the precheck grant is read-only: \(helper.preps)")
    expect(helper.restores.count == 1, "one restore attempt: \(helper.restores)")
    expect(text.contains("restore EIO"), "restore warning preserved: \(text)")
    expect(text.contains("unconfirmed") || text.contains("未确认"),
           "neutral unconfirmed wording: \(text)")
    expect(text.contains("no repair needed") || text.contains("未发现需要修复的问题"),
           "no-repair-needed wording present: \(text)")
}

// D2: as D, but the escalated precheck itself fails: the restore warning
// still wins over the repair, so no -y runs.
func testFRepairPrecheckFailedWithRestoreFailureSkipsWrite() async throws {
    let shell = ScriptedShell([
        .init("/usr/sbin/diskutil", ["unmount", dev]),
        .init("/sbin/fsck_fskit", ["-t", "openntfs", "-q", dev], status: 13, output: epermOutput),
        .init("/sbin/fsck_fskit", ["-t", "openntfs", "-q", dev], status: 8, output: "volume has corrupt metadata"),
        .init("/usr/sbin/diskutil", ["mount", dev]),
    ])
    shell.install()
    let probe = ScriptedProbe([
        .unmounted,                                    // precheck gate 1
        .unmounted,                                    // gate 2 (before-prepare)
        .unmounted,                                    // gate 3 (before-fsck-escalated)
        .unmounted,                                    // remount initial state
        mounted("/Volumes/TestDisk", readOnly: false), // mount verify
        mounted("/Volumes/TestDisk", readOnly: false), // final mode verify
    ])
    probe.install()
    let helper = ScriptedHelper([
        .prepare(devicePath: dev, writeAccess: false),
        .restore(devicePath: dev, error: "restore EIO"),
    ])
    let text = await Mounter(helper: helper)
        .runMaintenanceFlow(makeDisk(mounted: true, ours: true, readOnly: false), repair: true)
    expect(!shell.calls.contains { $0.args.contains("-y") },
           "a warned precheck must not be followed by -y: \(shell.calls)")
    expect(helper.preps.count == 1 && helper.preps[0].writeAccess == false,
           "the precheck grant is read-only: \(helper.preps)")
    expect(helper.restores.count == 1, "one restore attempt: \(helper.restores)")
    expect(text.contains("restore EIO"), "restore warning preserved: \(text)")
    expect(text.contains("unconfirmed") || text.contains("未确认"),
           "neutral unconfirmed wording: \(text)")
    expect(text.contains("volume has corrupt metadata"),
           "the failed precheck result is reported: \(text)")
}

// MARK: - Main

// MARK: - Deliberate-violation self-checks (run in SEPARATE processes)
//
// Prove the unified acceptance actually catches: (1) unconsumed REQUIRED
// steps, (2) extra external calls, (3) cross-dependency order errors. Each
// mode exits non-zero BY DESIGN; the runner below verifies the expected
// failures without polluting the normal suite.

func selfcheckUnconsumedStep() async throws {
    let shell = ScriptedShell([
        .init("/usr/bin/true", ["one"]),
        .init("/usr/bin/true", ["two"]),   // REQUIRED but never runs
    ])
    shell.install()
    _ = await Shell.run("/usr/bin/true", ["one"])
}

func selfcheckExtraCall() async throws {
    // No script installed → the strict default hook records a harness
    // violation for this unscripted external call.
    _ = await Shell.run("/usr/bin/true", ["unscripted"])
}

func selfcheckOrderError() async throws {
    expectedTraceKinds = ["probe", "shell"]   // declare the WRONG order
    let shell = ScriptedShell([.init("/usr/bin/true", ["a"])])
    shell.install()
    let probe = ScriptedProbe([.unmounted])
    probe.install()
    // Real hooked calls in the wrong cross-dependency order:
    _ = await Shell.run("/usr/bin/true", ["a"])
    _ = MountQuery.state(forDevice: dev)
}

// MARK: - Helper RPC timeout (HelperClient.withRPCTimeout + Mounter semantics)

/// Bounded race: runs `op` against a `bound`-second "HANG" sentinel; returns
/// whichever finishes FIRST. Used to prove the timeout actually fires (and,
/// against code without the timeout, that a never-replying call hangs).
func raceBound<T: Sendable>(_ bound: TimeInterval,
                            _ op: @escaping @Sendable () async -> T) async -> String {
    await withTaskGroup(of: String.self) { group in
        group.addTask { "\(await op())" }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(bound * 1_000_000_000))
            return "HANG-BOUND-REACHED"
        }
        let first = await group.next() ?? "none"
        group.cancelAll()
        return first
    }
}

func testHelperClientTimeoutFailsWithinBound() async throws {
    expect(HelperClient.rpcTimeoutDefaultSeconds == 20,
           "production default must stay 20 s: \(HelperClient.rpcTimeoutDefaultSeconds)")
    expect(HelperClient().rpcTimeoutSeconds == 20, "fresh client uses the production default")
    let client = HelperClient()
    client.rpcTimeoutSeconds = 0.05   // injected short value; production default untouched
    let started = Date()
    let outcome = await raceBound(2.0) {
        // NEVER replies — the "launchd spawn loop / AMFI kill" shape.
        _ = try? await client.withRPCTimeout { (_: OnceResume<Int>) in }
        return "returned"
    }
    expect(outcome == "returned", "call must NOT hang past the bound: \(outcome)")
    expect(Date().timeIntervalSince(started) < 1.5,
           "timeout fired quickly, not at the 2 s bound")
    // the timeout path THROWS (returned via try? nil means it threw)
    do {
        _ = try await client.withRPCTimeout { (_: OnceResume<Int>) in }
        expect(false, "never-replying body must throw, not return")
    } catch let e as HelperError {
        if case .timedOut = e { expect(true, "throws HelperError.timedOut") }
        else { expect(false, "wrong error: \(e)") }
    }
}

func testHelperClientLateReplyDropped() async throws {
    let client = HelperClient()
    client.rpcTimeoutSeconds = 0.05
    var lateOnce: OnceResume<Int>?
    do {
        _ = try await client.withRPCTimeout { once in lateOnce = once }
        expect(false, "must time out")
        return
    } catch { /* expected */ }
    try await Task.sleep(nanoseconds: 50_000_000)
    // The reply arrives LATE. OnceResume must drop it silently — the already
    // reported timeout outcome cannot change (and no double-resume crash).
    lateOnce?.finish(99)
    lateOnce?.fail(HelperError.connectionFailed("also late"))
    expect(true, "late finish+fail after timeout neither crashed nor changed the outcome")
}

func testHelperClientFinishesBeforeTimeout() async throws {
    let client = HelperClient()
    client.rpcTimeoutSeconds = 5
    let value = try await client.withRPCTimeout { (once: OnceResume<Int>) in
        once.finish(7)
    }
    expect(value == 7, "a prompt reply wins over the timeout: \(value)")
}

func prepareTimeoutFlow(restoreTimesOut: Bool) async throws
    -> (text: String, shell: ScriptedShell, helper: ScriptedHelper) {
    let shell = ScriptedShell([
        .init("/sbin/fsck_fskit", ["-t", "openntfs", "-q", dev], status: 13, output: epermOutput),
    ])
    shell.install()
    let probe = ScriptedProbe([.unmounted, .unmounted]); probe.install()
    let helper = ScriptedHelper([
        .prepare(devicePath: dev, writeAccess: false, timedOut: true),
        .restore(devicePath: dev, timedOut: restoreTimesOut),
    ])
    let text = await Mounter(helper: helper).runMaintenanceFlow(makeDisk(mounted: false), repair: false)
    return (text, shell, helper)
}

func testCPrepareTimeoutRunsNoFsckOneRestoreNotSuccess() async throws {
    let (text, shell, helper) = try await prepareTimeoutFlow(restoreTimesOut: false)
    expect(shell.fsckCalls.count == 1,
           "only the initial direct fsck ran; the ESCALATED fsck must not: \(shell.calls)")
    expect(helper.restores.count == 1,
           "authorization unknown → exactly ONE restore attempt: \(helper.restores)")
    expect(!text.contains("no problems found"), "must not report success: \(text)")
    expect(text.contains("did not reply") || text.contains("未在"),
           "prepare timeout surfaced honestly: \(text)")
}

func testCPrepareTimeoutRestoreAlsoTimesOutIsUnconfirmed() async throws {
    let (text, shell, helper) = try await prepareTimeoutFlow(restoreTimesOut: true)
    expect(shell.fsckCalls.count == 1, "no escalated fsck")
    expect(helper.restores.count == 1, "one restore attempt, no retry")
    expect(!text.contains("no problems found"), "must not report success: \(text)")
    expect(text.contains("unconfirmed") || text.contains("未确认"),
           "restore timeout must surface as unconfirmed, never success: \(text)")
}

func testCRestoreTimeoutAfterFsckReportedUnconfirmed() async throws {
    let (text, _, helper) = try await helperFallbackFlow(
        repair: false, secondResult: CommandResult(status: 0, output: ""),
        restoreError: HelperError.timedOut(HelperClient.rpcTimeoutDefaultSeconds))
    expect(helper.restores.count == 1, "restore attempted once")
    expect(text.contains("TestDisk"), "tool result still present: \(text)")
    expect(text.contains("unconfirmed") || text.contains("未确认"),
           "restore timeout surfaced as unconfirmed: \(text)")
}

func selfcheckHelperUnscriptedCall() async throws {
    let helper = ScriptedHelper()   // DEFAULT empty script: any call is a violation
    do { try await helper.prepareRawDevice(devicePath: dev, writeAccess: false) }
    catch { /* the violation itself fails acceptance; the throw is expected */ }
}

func selfcheckHelperUnconsumedStep() async throws {
    _ = ScriptedHelper([.prepare(devicePath: dev, writeAccess: false)])   // never called
}

func selfcheckHelperParamError() async throws {
    let helper = ScriptedHelper([.prepare(devicePath: dev, writeAccess: true)])
    do { try await helper.prepareRawDevice(devicePath: dev, writeAccess: false) }
    catch { }
}

func selfcheckDefaultWaitRegistration() async throws {
    // Do NOT replace the default Wait stub installed by runTest. Violate
    // its bounded-loop contract directly: its acceptance check — the one
    // previously wiped by the registration-order bug — must fire.
    for _ in 0..<30 {
        if let wait = Mounter.waitHook { await wait(100_000_000) }
    }
}

func runSelfcheckChild(_ args: [String]) -> (exitCode: Int32, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch {
        return (Int32(EXIT_FAILURE), "child failed to launch: \(error.localizedDescription)")
    }
    p.waitUntilExit()
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return (p.terminationStatus, out)
}

func stubSelfcheckRunner() -> Int32 {
    var bad = 0
    func check(_ cond: Bool, _ what: String) {
        print(cond ? "SELFCHECK PASS: \(what)" : "SELFCHECK FAIL: \(what)")
        if !cond { bad += 1 }
    }
    let modes: [(mode: String, why: String, needle: String)] = [
        ("--selfcheck-unconsumed-step", "unconsumed required step is caught",
         "unconsumed REQUIRED shell steps"),
        ("--selfcheck-extra-call", "extra external call is caught",
         "unscripted external calls must not happen"),
        ("--selfcheck-order-error", "cross-dependency order error is caught",
         "trace order mismatch"),
        ("--selfcheck-helper-unscripted-call", "default empty helper script rejects any call",
         "helper violations"),
        ("--selfcheck-helper-unconsumed-step", "unconsumed helper step is caught",
         "unconsumed helper steps"),
        ("--selfcheck-helper-param-error", "helper parameter error is caught",
         "PARAM mismatch"),
        ("--selfcheck-default-wait", "default wait acceptance registration survives and runs",
         "exceeds the bounded loop"),
    ]
    for m in modes {
        let r = runSelfcheckChild([m.mode])
        print("--- child \(m.mode) (exit \(r.exitCode)) ---")
        print(r.output.trimmingCharacters(in: .whitespacesAndNewlines))
        check(r.exitCode != 0, "\(m.why): child exits non-zero (got \(r.exitCode))")
        check(r.output.contains("TEST FAILED"), "\(m.why): child reports TEST FAILED")
        check(r.output.contains(m.needle),
              "\(m.why): diagnostic \(m.needle) present (not another error masquerading)")
    }
    print("stub selfcheck finished: \(bad) failure(s)")
    return bad == 0 ? 0 : 1
}

@main
enum AppOrchestrationTestMain {
    static func main() async {
        switch CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "" {
        case "--selfcheck-unconsumed-step":
            await runTest("SELF-CHECK unconsumed required step", selfcheckUnconsumedStep)
            exit(failures == 0 ? 0 : 1)   // non-zero BY DESIGN
        case "--selfcheck-extra-call":
            await runTest("SELF-CHECK extra external call", selfcheckExtraCall)
            exit(failures == 0 ? 0 : 1)
        case "--selfcheck-order-error":
            await runTest("SELF-CHECK cross-dependency order", selfcheckOrderError)
            exit(failures == 0 ? 0 : 1)
        case "--selfcheck-helper-unscripted-call":
            await runTest("SELF-CHECK helper unscripted call", selfcheckHelperUnscriptedCall)
            exit(failures == 0 ? 0 : 1)
        case "--selfcheck-helper-unconsumed-step":
            await runTest("SELF-CHECK helper unconsumed step", selfcheckHelperUnconsumedStep)
            exit(failures == 0 ? 0 : 1)
        case "--selfcheck-helper-param-error":
            await runTest("SELF-CHECK helper parameter error", selfcheckHelperParamError)
            exit(failures == 0 ? 0 : 1)
        case "--selfcheck-default-wait":
            await runTest("SELF-CHECK default wait registration", selfcheckDefaultWaitRegistration)
            exit(failures == 0 ? 0 : 1)
        case "--stub-selfcheck":
            exit(stubSelfcheckRunner())
        default:
            await runSuite()
        }
    }

    static func runSuite() async {
        await runTest("A_unmountFailureStopsEverything", testAUnmountFailureStopsEverything)
        await runTest("B_queryFailedBeforeCheckBlocksFsck", testBQueryFailedBeforeCheckBlocksFsck)
        await runTest("B_remountedBeforePrepareBlocksHelper", testBRemountedBeforePrepareBlocksHelper)
        await runTest("B_remountedBeforeSecondFsckRestoresAndReportsRestoreFailure",
                      testBRemountedBeforeSecondFsckRestoresAndReportsRestoreFailure)
        await runTest("C_verifyArgsAndDirectSuccessSkipHelper", testCVerifyArgsAndDirectSuccessSkipHelper)
        await runTest("C_repairArgsDifferFromVerify", testCRepairArgsDifferFromVerify)
        await runTest("C_nonPermissionFailureKeptNoHelper", testCNonPermissionFailureKeptNoHelper)
        await runTest("C_verifyEPERMFallsBackWithReadOnlyGrant", testCVerifyEPERMFallsBackWithReadOnlyGrant)
        await runTest("C_repairEPERMRequestsWriteGrant", testCRepairEPERMRequestsWriteGrant)
        await runTest("C_prepareFailureNoSecondFsckNoSuccess", testCPrepareFailureNoSecondFsckNoSuccess)
        await runTest("C_secondFsckFailsStillRestores", testCSecondFsckFailsStillRestores)
        await runTest("C_launchFailureStillRestores", testCLaunchFailureStillRestores)
        await runTest("C_restoreFailureReportedSeparatelyFromSuccess",
                      testCRestoreFailureReportedSeparatelyFromSuccess)
        await runTest("D_rwPolicyAndNeutralReadOnlyWording", testDRWPolicyAndNeutralReadOnlyWording)
        await runTest("fallbackSceneIsolation", testFallbackSceneIsolation)
        await runTest("foreignHandoffUnmountFailureStops", testForeignHandoffUnmountFailureStops)
        await runTest("traceCrossDependencyOrder", testTraceCrossDependencyOrder)
        await runTest("interactiveHandoffUnmountFailureStops (A)", testInteractiveHandoffUnmountFailureStops)
        await runTest("interactiveOrdinaryFailureStillFallsBack (A+)", testInteractiveOrdinaryFailureStillFallsBack)
        await runTest("helperClientTimeoutFailsWithinBound", testHelperClientTimeoutFailsWithinBound)
        await runTest("helperClientLateReplyDropped", testHelperClientLateReplyDropped)
        await runTest("helperClientFinishesBeforeTimeout", testHelperClientFinishesBeforeTimeout)
        await runTest("C_prepareTimeoutNoFsckOneRestoreNotSuccess",
                      testCPrepareTimeoutRunsNoFsckOneRestoreNotSuccess)
        await runTest("C_prepareTimeoutRestoreAlsoTimesOutIsUnconfirmed",
                      testCPrepareTimeoutRestoreAlsoTimesOutIsUnconfirmed)
        await runTest("C_restoreTimeoutAfterFsckReportedUnconfirmed",
                      testCRestoreTimeoutAfterFsckReportedUnconfirmed)
        await runTest("cRestoreNoActiveLeaseIsUnconfirmed (C)", testCRestoreNoActiveLeaseIsUnconfirmed)
        await runTest("dStopMountCommandFailedKeepsOriginalError (D-a)", testDStopMountCommandFailedKeepsOriginalError)
        await runTest("dStopQueryFailedReportsUnknownState (D-b)", testDStopQueryFailedReportsUnknownState)
        await runTest("E_aggregation", testEAggregation)
        await runTest("F_repairPrecheckCleanSkipsWrite", testFRepairPrecheckCleanSkipsWrite)
        await runTest("F_repairPrecheckFailedRunsRepair", testFRepairPrecheckFailedRunsRepair)
        await runTest("F_repairReadOnlyMountedRunsRepairDirectly", testFRepairReadOnlyMountedRunsRepairDirectly)
        await runTest("F_repairNotMountedRunsRepairDirectly", testFRepairNotMountedRunsRepairDirectly)
        await runTest("F_repairPrecheckRestoreFailureSkipsWriteKeepsWarning",
                      testFRepairPrecheckRestoreFailureSkipsWriteKeepsWarning)
        await runTest("F_repairPrecheckFailedWithRestoreFailureSkipsWrite",
                      testFRepairPrecheckFailedWithRestoreFailureSkipsWrite)
        print("app-orchestration tests finished: \(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
