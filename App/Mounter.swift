// OpenNTFS - mounting, unmounting and maintenance of NTFS volumes.
// SPDX-License-Identifier: GPL-2.0-or-later

import DiskArbitration
import FSKit
import Foundation
import OSLog

private let maintLog = Logger(subsystem: "io.github.mchan1970.OpenNTFS", category: "maintenance")

struct CommandResult {
    let status: Int32
    let output: String
    /// Set when fsck finished but helper mode restore failed (or was skipped after error).
    var restoreWarning: String? = nil
    var ok: Bool { status == 0 }
}

/// Outcome of verify/repair, including remount policy hints for the UI.
struct MaintenanceOutcome {
    let result: CommandResult
    let repaired: Bool
    /// Repair was requested but never run: the read-only precheck decided
    /// the writable pass must not touch the volume.
    var repairSkipped: Bool = false
}

enum Shell {
    /// Injectable external-command executor for offline orchestration tests.
    /// Production default (nil) spawns the real process. A test that
    /// installs a hook gets NO fallback to the real implementation — the
    /// harness stub records unscripted calls as violations and fails.
    static var runHook: ((String, [String]) async -> CommandResult)?

    /// Runs a tool and captures stdout + stderr. Never goes through a shell.
    static func run(_ tool: String, _ args: [String]) async -> CommandResult {
        if let hook = runHook { return await hook(tool, args) }
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: tool)
                p.arguments = args
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                do {
                    try p.run()
                } catch {
                    cont.resume(returning: CommandResult(status: -1, output: error.localizedDescription))
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: CommandResult(
                    status: p.terminationStatus,
                    output: String(decoding: data, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
    }
}

struct MountError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// A mount failure after which NO fallback mount may be attempted (the
/// volume is still mounted by another driver). Typed — never classified by
/// matching message strings. Both strategies propagate it unchanged.
struct MountStopError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Helper access used by the maintenance flow. Production default is
/// `HelperClient.shared` (conformance in App/HelperClient.swift); offline
/// orchestration tests inject a recording stub.
protocol MaintenanceHelperPort {
    func prepareRawDevice(devicePath: String, writeAccess: Bool) async throws
    func restoreRawDevice(devicePath: String) async throws
}

final class Mounter {
    static let moduleID = "io.github.mchan1970.OpenNTFS.FSModule"

    /// Injectable wait used by ensureUnmounted (production: Task.sleep).
    /// Tests install a no-op counter so no real sleeping happens and the
    /// bounded retry loop is observable.
    static var waitHook: ((UInt64) async -> Void)?

    /// Mount-point root override for offline tests (production: nil → the
    /// user's home directory). Tests point this at a temp scene directory.
    static var mountRootOverride: URL?

    /// Unused by the maintenance paths (kept for the app's other callers);
    /// optional so offline tests can construct a Mounter without a live
    /// DiskArbitration session.
    let monitor: DiskMonitor?
    /// Helper access; production default wraps `HelperClient.shared`.
    var helper: MaintenanceHelperPort

    init(monitor: DiskMonitor? = nil,
         helper: MaintenanceHelperPort = HelperClient.shared) {
        self.monitor = monitor
        self.helper = helper
    }

    /// Whether the FSKit module is installed and switched on in System Settings.
    func moduleEnabled() async -> Bool {
        await withCheckedContinuation { cont in
            FSClient.shared.fetchInstalledExtensions { modules, _ in
                let ours = modules?.first { $0.bundleIdentifier == Mounter.moduleID }
                cont.resume(returning: ours?.isEnabled ?? false)
            }
        }
    }

    /// Normal unmount. Does **not** escalate to `diskutil unmount force` when the
    /// volume is busy — callers must decide whether force is appropriate.
    func unmount(_ disk: NTFSDisk, force: Bool = false) async throws {
        guard disk.isMounted else { return }
        let r = await Shell.run("/usr/sbin/diskutil", ["unmount", disk.devicePath])
        if r.ok {
            if let path = disk.mountPoint?.path { cleanupMountPoint(path) }
            return
        }
        // mounts made with mount(8) outside /Volumes
        if let path = disk.mountPoint?.path {
            let r2 = await Shell.run("/sbin/umount", [path])
            if r2.ok { cleanupMountPoint(path); return }
        }
        if force {
            let forced = await Shell.run("/usr/sbin/diskutil", ["unmount", "force", disk.devicePath])
            if forced.ok {
                maintLog.info("unmount force ok device=\(disk.devicePath, privacy: .public)")
                if let path = disk.mountPoint?.path { cleanupMountPoint(path) }
                return
            }
            throw MountError(message: r.output.isEmpty ? forced.output : r.output)
        }
        throw MountError(message: r.output.isEmpty
            ? L("Volume is busy; unmount refused without force.",
                "卷正忙；未强制卸载。")
            : r.output)
    }

    func eject(_ disk: NTFSDisk) async throws {
        try await unmount(disk)
        _ = await Shell.run("/usr/sbin/diskutil", ["eject", disk.devicePath])
    }

    /// How to choose the mount path when attaching read-write.
    enum MountStrategy {
        /// Prefer `diskutil mount` under `/Volumes` (Finder-friendly).
        case preferDiskArbitration
        /// Prefer `mount -F` under `~/NTFS Volumes/<label>`.
        /// Used after check/repair: `diskutil mount` often races to
        /// `/Volumes/Untitled` before DA sees the real NTFS label.
        case preferLabeledPath
    }

    /// Mounts the volume read-write through the OpenNTFS module, taking it
    /// over from whichever driver currently has it.
    @discardableResult
    func mountReadWrite(_ disk: NTFSDisk,
                        preferredLabel: String? = nil,
                        strategy: MountStrategy = .preferDiskArbitration) async throws -> URL {
        let label = Self.resolvedLabel(preferredLabel ?? disk.label, mountPoint: disk.mountPoint)
        if disk.isOurs, let mp = disk.mountPoint,
           !Self.isPlaceholderVolumeName(mp.lastPathComponent) || Self.isPlaceholderVolumeName(label) {
            return mp
        }
        if disk.isMounted { try await unmount(disk) }

        switch strategy {
        case .preferLabeledPath:
            // After check/repair: prefer diskutil; never force-unmount on retry.
            return try await mountViaDiskArbitration(devicePath: disk.devicePath, label: label,
                                                     rejectPlaceholder: true, allowForceRetry: false)
        case .preferDiskArbitration:
            do {
                return try await mountViaDiskArbitration(devicePath: disk.devicePath, label: label,
                                                         rejectPlaceholder: true, allowForceRetry: true)
            } catch let stop as MountStopError {
                // Hand-off unmount failed: the volume is STILL mounted by
                // the other driver. No fallback mount point, no mount -F,
                // never force — rethrow unchanged.
                maintLog.error("mount stopped (no fallback): \(stop.message, privacy: .public)")
                throw stop
            } catch {
                // Any OTHER failure keeps the pre-existing labeled-path
                // fallback (interactive takeover semantics).
                maintLog.info("diskutil mount failed (\(error.localizedDescription, privacy: .public)); trying labeled path")
                if let url = await mountWithLabeledPath(devicePath: disk.devicePath, label: label) {
                    return url
                }
                throw error
            }
        }
    }

    /// `diskutil mount`. Placeholder rejection can retry without force; force is
    /// opt-in for interactive takeover only (never used on the maintenance remount path).
    /// Why the previous mount attempt did not succeed — the maintenance
    /// stop message reports WHAT WAS ACTUALLY OBSERVED, never a guess.
    /// Local to this function; not a state machine.
    private enum AttemptOutcome {
        case notYetRun
        /// The mount COMMAND itself failed (exit status / tool output kept).
        case mountCommandFailed(String)
        /// The command reported success but the mount state could not be
        /// confirmed (query failed, or the volume was not mounted).
        case mountStateUnconfirmed(String)
        /// Ours WAS observed mounted — at a placeholder path; observation
        /// values are from the mount-table query at that moment.
        case observedPlaceholder(path: String, driver: String, readOnly: Bool)
    }

    private func mountViaDiskArbitration(devicePath: String, label: String,
                                         rejectPlaceholder: Bool,
                                         allowForceRetry: Bool) async throws -> URL {
        var lastError = "mount failed"
        var lastOutcome: AttemptOutcome = .notYetRun
        let attempts = rejectPlaceholder && !Self.isPlaceholderVolumeName(label) ? 3 : 1
        for attempt in 1...attempts {
            if attempt > 1 {
                if !allowForceRetry {
                    // Maintenance policy: stop retrying, never force. Report
                    // the OBSERVED reason — three distinguishable cases.
                    switch lastOutcome {
                    case .mountCommandFailed(let original):
                        // (a) the mount command failed: keep the ACTUAL
                        // error; claim nothing about paths or mounts.
                        throw MountStopError(message: L(
                            "Remount command failed; retries stopped to avoid a forced remount. Original error: \(original)",
                            "重挂载命令失败；已停止重试以避免强制重挂载。原始错误：\(original)"))
                    case .mountStateUnconfirmed(let why):
                        // (b) the command succeeded but the mount state is
                        // UNKNOWN/unconfirmed — no success claim.
                        throw MountStopError(message: L(
                            "Remount command completed but the mount state could not be confirmed (\(why)); retries stopped. Current mount state is unknown.",
                            "重挂载命令已执行，但挂载状态未能确认（\(why)）；已停止重试。当前挂载状态未知。"))
                    case .observedPlaceholder(let path, let driver, let readOnly):
                        // (c) ours WAS observed mounted at a placeholder
                        // path — report the observation (point-in-time) and
                        // never imply the volume was unmounted.
                        let mode = readOnly ? L("read-only", "只读") : L("read-write", "可读写")
                        throw MountStopError(message: L(
                            "Mounted at an unexpected path (\(path)); retries stopped to avoid a forced remount; at the last observation: \(driver), \(mode) — the volume may still be mounted.",
                            "挂载路径不符合预期（\(path)）；已停止重试以避免强制重挂载；最后一次观察为 \(driver)、\(mode)——卷可能仍处于挂载状态。"))
                    case .notYetRun:
                        // Unreachable in practice (attempt 1 always runs);
                        // kept fail-closed rather than guessing a reason.
                        throw MountStopError(message: L(
                            "Remount retries stopped to avoid a forced remount; no mount attempt was recorded.",
                            "已停止重试以避免强制重挂载；未记录到挂载尝试。"))
                    }
                }
                maintLog.info("diskutil mount retry \(attempt) after Untitled for \(label, privacy: .public)")
                let u = await Shell.run("/usr/sbin/diskutil", ["unmount", "force", devicePath])
                if !u.ok {
                    throw MountError(message: u.output.isEmpty
                        ? L("Force unmount failed during remount retry.",
                            "重挂载重试时强制卸载失败。")
                        : u.output)
                }
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
            let da = await Shell.run("/usr/sbin/diskutil", ["mount", devicePath])
            if !da.ok {
                lastError = da.output.isEmpty ? "mount failed (\(da.status))" : da.output
                lastOutcome = .mountCommandFailed(lastError)
                continue
            }
            // Tri-state verification (F): a failed mount-table query cannot
            // confirm the mount — treat it as a failed attempt, not success.
            // ONE query: classify the stop reason and obtain the entry.
            let mountState = MountQuery.state(forDevice: devicePath)
            guard case .mounted(let m) = mountState else {
                if case .queryFailed(let why) = mountState {
                    lastOutcome = .mountStateUnconfirmed(L("mount-table query failed: \(why)",
                                                           "挂载表查询失败：\(why)"))
                } else {
                    lastOutcome = .mountStateUnconfirmed(L("the volume was not mounted",
                                                           "卷未被挂载"))
                }
                continue
            }
            lastOutcome = .observedPlaceholder(path: m.path, driver: m.fstype, readOnly: m.readOnly)
            if m.fstype != DiskMonitor.fsTypeName {
                // Another driver won the probe: hand the volume to our module.
                // The hand-off unmount result is CHECKED — if it fails, the
                // volume is STILL mounted by the other driver: stop here with
                // the original error preserved. No fallback mount point is
                // created, no further mount is attempted, never force.
                let handoff = await Shell.run("/usr/sbin/diskutil", ["unmount", devicePath])
                guard handoff.ok else {
                    maintLog.error("foreign-driver hand-off unmount failed: \(handoff.output, privacy: .public)")
                    throw MountStopError(message: handoff.output.isEmpty
                        ? L("Another driver mounted the volume and unmounting it failed (exit \(handoff.status)); not remounting.",
                           "其他驱动挂载了该卷且卸载失败（退出码 \(handoff.status)）；不再重新挂载。")
                        : L("Another driver mounted the volume and unmounting it failed; not remounting: ",
                           "其他驱动挂载了该卷且卸载失败；不再重新挂载：") + handoff.output)
                }
                if let url = await mountWithLabeledPath(devicePath: devicePath, label: label) {
                    return url
                }
                continue
            }
            let mounted = URL(fileURLWithPath: m.path)
            if rejectPlaceholder,
               Self.isPlaceholderVolumeName(mounted.lastPathComponent),
               !Self.isPlaceholderVolumeName(label) {
                maintLog.info("diskutil used placeholder \(mounted.path, privacy: .public)")
                continue
            }
            maintLog.info("diskutil mount ok path=\(mounted.path, privacy: .public)")
            return mounted
        }
        if let url = await mountWithLabeledPath(devicePath: devicePath, label: label) {
            return url
        }
        throw MountError(message: lastError)
    }

    /// Explicit FSKit mount to `~/NTFS Volumes/<label>` (stable display name).
    private func mountWithLabeledPath(devicePath: String, label: String) async -> URL? {
        let dir: URL
        do {
            dir = try makeMountPoint(label: label)
        } catch {
            maintLog.error("makeMountPoint failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let r = await Shell.run("/sbin/mount", ["-F", "-t", DiskMonitor.fsTypeName,
                                                devicePath, dir.path])
        if r.ok {
            maintLog.info("mount -F ok path=\(dir.path, privacy: .public) label=\(label, privacy: .public)")
            return dir
        }
        maintLog.error("mount -F failed status=\(r.status)")
        cleanupMountPoint(dir.path)
        return nil
    }

    /// Empty / "Untitled" / "NO NAME" — not a real preserved volume label.
    static func isPlaceholderVolumeName(_ name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty { return true }
        if n.caseInsensitiveCompare("Untitled") == .orderedSame { return true }
        if n.caseInsensitiveCompare("NO NAME") == .orderedSame { return true }
        return false
    }

    /// Prefer a non-placeholder label; fall back to the last path component.
    static func resolvedLabel(_ label: String, mountPoint: URL?) -> String {
        if !isPlaceholderVolumeName(label) { return label }
        if let last = mountPoint?.lastPathComponent, !isPlaceholderVolumeName(last) {
            return last
        }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }

    func check(_ disk: NTFSDisk, repair: Bool) async -> MaintenanceOutcome {
        let mode = repair ? "repair" : "verify"
        maintLog.info("check begin mode=\(mode, privacy: .public) device=\(disk.devicePath, privacy: .public) label=\(disk.label, privacy: .public)")
        guard await ensureUnmounted(disk.devicePath, stage: "before-check") else {
            let msg = L("Volume is still mounted; check/repair aborted.",
                        "卷仍被挂载；已中止检查/修复。")
            return MaintenanceOutcome(
                result: CommandResult(status: 16, output: msg),
                repaired: false)
        }
        // Verify uses -q (matches working diskutil/mount path); repair uses -y.
        let flag = repair ? "-y" : "-q"
        let args = ["-t", DiskMonitor.fsTypeName, flag, disk.devicePath]

        // 1) Try as the GUI user (sees OpenNTFS via fskit_agent).
        let first = await Shell.run("/sbin/fsck_fskit", args)
        if first.ok || !isPermissionFailure(first) {
            maintLog.info("check(\(mode, privacy: .public)) direct status=\(first.status)")
            return MaintenanceOutcome(result: first, repaired: repair && first.ok)
        }

        // 2) Helper grants this user node access; fsck still runs here so fskitd
        //    uses the user agent (root cannot see user FSModules).
        guard await ensureUnmounted(disk.devicePath, stage: "before-prepare") else {
            let msg = L("Volume remounted before prepare; aborted.",
                        "prepare 前卷被重新挂载；已中止。")
            return MaintenanceOutcome(result: CommandResult(status: 16, output: msg),
                                      repaired: false)
        }
        maintLog.info("check(\(mode, privacy: .public)) direct denied; prepare device via helper")
        do {
            try await helper.prepareRawDevice(devicePath: disk.devicePath,
                                             writeAccess: repair)
        } catch let e as HelperError {
            guard case .timedOut = e else {
                maintLog.error("prepareRawDevice failed: \(e.localizedDescription, privacy: .public)")
                return MaintenanceOutcome(
                    result: CommandResult(status: -1, output: e.localizedDescription),
                    repaired: false)
            }
            // Timeout ≠ refused: the authorization state is UNKNOWN — the
            // helper may have granted and only the reply was lost. No fsck
            // (escalated), ONE restore attempt with the same timeout, then
            // report honestly; a timed-out restore surfaces through the
            // existing "restore outcome unconfirmed" wording, never as
            // success. No automatic retry anywhere on this path.
            maintLog.error("prepareRawDevice timed out (authorization unknown); one restore attempt")
            var result = CommandResult(status: -1, output: e.localizedDescription)
            do {
                try await helper.restoreRawDevice(devicePath: disk.devicePath)
            } catch {
                maintLog.error("restoreRawDevice failed after prepare timeout: \(error.localizedDescription, privacy: .public)")
                result.restoreWarning = error.localizedDescription
            }
            return MaintenanceOutcome(result: result, repaired: false)
        } catch {
            maintLog.error("prepareRawDevice failed: \(error.localizedDescription, privacy: .public)")
            return MaintenanceOutcome(
                result: CommandResult(status: -1, output: error.localizedDescription),
                repaired: false)
        }
        guard await ensureUnmounted(disk.devicePath, stage: "before-fsck-escalated") else {
            // We are already authorized: the restore result MUST reach the
            // caller even though we abort (a swallowed restore failure here
            // would leave the device node user-owned with no report).
            var result = CommandResult(status: 16,
                                       output: L("Volume remounted before fsck; aborted.",
                                                 "fsck 前卷被重新挂载；已中止。"))
            do {
                try await helper.restoreRawDevice(devicePath: disk.devicePath)
            } catch {
                maintLog.error("restoreRawDevice failed after remount abort: \(error.localizedDescription, privacy: .public)")
                result.restoreWarning = error.localizedDescription
            }
            return MaintenanceOutcome(result: result, repaired: false)
        }
        let second = await Shell.run("/sbin/fsck_fskit", args)
        var outcome = CommandResult(status: second.status, output: second.output)
        do {
            try await helper.restoreRawDevice(devicePath: disk.devicePath)
        } catch {
            let warn = error.localizedDescription
            maintLog.error("restoreRawDevice failed: \(warn, privacy: .public)")
            outcome.restoreWarning = warn
        }
        maintLog.info("check(\(mode, privacy: .public)) after-prepare status=\(second.status)")
        return MaintenanceOutcome(result: outcome, repaired: repair && second.ok)
    }

    private func isPermissionFailure(_ r: CommandResult) -> Bool {
        r.output.localizedCaseInsensitiveContains("permission denied")
            || r.output.localizedCaseInsensitiveContains("operation not permitted")
            || r.status == 13
    }

    /// Wait until the mount table confirms the device is unmounted. Fails
    /// closed: both `mounted` and `queryFailed` keep the answer "not
    /// confirmed unmounted" (F-issue: a failed query is never "unmounted").
    /// Does not force-unmount. NOTE: repeated checks narrow — do not
    /// eliminate — the remount race; the window after the last check
    /// remains until fsck has the device open.
    private func ensureUnmounted(_ devicePath: String, stage: String) async -> Bool {
        var lastState = MountQuery.state(forDevice: devicePath)
        for _ in 0..<25 {
            switch lastState {
            case .unmounted: return true
            case .mounted, .queryFailed: break
            }
            if let wait = Self.waitHook {
                await wait(100_000_000)
            } else {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            lastState = MountQuery.state(forDevice: devicePath)
        }
        maintLog.error("device not confirmed unmounted (\(stage, privacy: .public)): \(devicePath, privacy: .public) state=\(String(describing: lastState), privacy: .public)")
        return false
    }

    /// Result of the post-maintenance remount. Distinct outcomes so the UI
    /// can say "still mounted read-write", "already mounted (compliant)",
    /// "remounted", and "failed: <detail>" instead of a single blur
    /// (G-issue). `.failed` never claims an unmount that did not happen, and
    /// a read-only result is never reported as read-write success.
    enum RemountOutcome {
        case remountedReadOnly(path: String, downgradedFromForeignReadWrite: Bool)
        case remountedReadWrite(path: String)
        /// Mounted by our module but READ-ONLY (e.g. dirty NTFS after
        /// Windows hibernation) where read-write was the goal — reported as
        /// what it is, not as RW success.
        case remountedButReadOnly(path: String)
        case alreadyMounted(path: String, readOnly: Bool, byOurs: Bool)
        case failed(String)
    }

    /// Remount after maintenance using the **pre-check** access policy:
    /// - `wasOurs && !wasReadOnly` → OpenNTFS RW (never force)
    /// - otherwise → `diskutil mount readOnly` (never escalate to RW)
    ///
    /// An externally remounted volume is NOT skipped: it is verified against
    /// the same policy, and a policy-violating read-write mount is corrected
    /// with a NON-force unmount whose result is reported honestly. A failed
    /// mount-table query is reported as an unknown state, never as
    /// "unmounted".
    func remountAfterMaintenance(_ disk: NTFSDisk,
                                 preferredLabel: String,
                                 wasOurs: Bool,
                                 wasReadOnly: Bool) async -> RemountOutcome {
        let device = disk.devicePath
        let expectReadOnly = MaintenancePolicy.expectsReadOnly(wasOurs: wasOurs,
                                                               wasReadOnly: wasReadOnly)

        // Observe first: someone (Finder, another driver, our own auto-mount
        // timer) may already have remounted the volume.
        switch MountQuery.state(forDevice: device) {
        case .queryFailed(let e):
            return .failed(L("Mount-table query failed; current mount state unknown: ",
                             "查询挂载表失败，当前挂载状态未知：") + e)
        case .mounted(let m):
            switch MaintenancePolicy.decisionForExistingMount(
                wasOurs: wasOurs, wasReadOnly: wasReadOnly,
                mountedByOurs: m.fstype == DiskMonitor.fsTypeName,
                mountedReadOnly: m.readOnly) {
            case .accept:
                return .alreadyMounted(path: m.path, readOnly: m.readOnly,
                                       byOurs: m.fstype == DiskMonitor.fsTypeName)
            case .unmountAndRemountReadOnly:
                maintLog.error("post-maintenance mount is policy-violating read-write at \(m.path, privacy: .public); correcting")
                // Maintenance path NEVER uses force.
                let u = await Shell.run("/usr/sbin/diskutil", ["unmount", device])
                guard case .remountPerPolicy = MaintenancePolicy.afterCorrectiveUnmount(
                    unmountSucceeded: u.ok) else {
                    let detail = u.output.isEmpty ? "exit \(u.status)" : u.output
                    return .failed(L(
                        "Volume was remounted read-write at \(m.path); corrective unmount FAILED — it is still mounted read-write: ",
                        "卷在 \(m.path) 被重新挂载为可写；纠正卸载失败——它仍以可写状态挂载：") + detail)
                }
                // Corrected; fall through to the policy remount below.
                break
            case .takeoverReadWrite:
                return await remountReadWriteViaOurs(disk, preferredLabel: preferredLabel)
            }
        case .unmounted:
            break
        }

        if expectReadOnly {
            let da = await Shell.run("/usr/sbin/diskutil", ["mount", "readOnly", device])
            guard da.ok else {
                let detail = da.output.isEmpty ? "exit \(da.status)" : da.output
                return .failed(L("Read-only remount failed: ", "只读重新挂载失败：") + detail)
            }
            var mounted: MountEntry
            switch MountQuery.state(forDevice: device) {
            case .queryFailed(let e):
                return .failed(L("Mount-table query failed after remount; state unknown: ",
                                 "重新挂载后查询挂载表失败，状态未知：") + e)
            case .unmounted:
                return .failed(L("Remount command succeeded but the volume is not mounted.",
                                 "重新挂载命令成功，但卷未被挂载。"))
            case .mounted(let m):
                mounted = m
            }
            if !mounted.readOnly {
                maintLog.error("remount expected read-only but got read-write at \(mounted.path, privacy: .public)")
                let u = await Shell.run("/usr/sbin/diskutil", ["unmount", device])
                guard case .remountPerPolicy = MaintenancePolicy.afterCorrectiveUnmount(
                    unmountSucceeded: u.ok) else {
                    return .failed(L(
                        "Remount came back read-write at \(mounted.path) and the corrective unmount FAILED — it is still mounted read-write.",
                        "重新挂载在 \(mounted.path) 变成了可写，且纠正卸载失败——它仍以可写状态挂载。"))
                }
                return .failed(L(
                    "Remount came back read-write; unmounted again to avoid escalating access.",
                    "重新挂载变成了可写；已再次卸载以避免扩大写权限。"))
            }
            // A foreign volume that was read-write before maintenance is
            // conservatively remounted read-only — a deliberate downgrade,
            // surfaced as such, not a "restored original state".
            let downgraded = !wasOurs && !wasReadOnly
            return .remountedReadOnly(path: mounted.path,
                                      downgradedFromForeignReadWrite: downgraded)
        }

        return await remountReadWriteViaOurs(disk, preferredLabel: preferredLabel)
    }

    /// OpenNTFS read-write remount (labeled path, never force). Maps throws
    /// to `.failed`, and — after a successful mount — verifies the ACTUAL
    /// access mode via the mount table: our module legitimately mounts a
    /// dirty NTFS volume read-only, and that outcome must be reported as
    /// read-only, never as read-write success.
    private func remountReadWriteViaOurs(_ disk: NTFSDisk,
                                         preferredLabel: String) async -> RemountOutcome {
        var d = disk
        d.label = preferredLabel
        d.mountPoint = nil
        d.isOurs = false
        d.readOnly = false
        do {
            let _ = try await mountReadWrite(d, preferredLabel: preferredLabel,
                                             strategy: .preferLabeledPath)
            switch MountQuery.state(forDevice: disk.devicePath) {
            case .mounted(let m):
                return m.readOnly
                    ? .remountedButReadOnly(path: m.path)
                    : .remountedReadWrite(path: m.path)
            case .unmounted:
                return .failed(L("Mount command succeeded but the volume is not mounted.",
                                 "挂载命令成功，但卷未被挂载。"))
            case .queryFailed(let e):
                return .failed(L("Mount-table query failed after remount; actual access mode unknown: ",
                                 "重新挂载后查询挂载表失败，实际访问模式未知：") + e)
            }
        } catch {
            return .failed(L("Read-write remount through OpenNTFS failed: ",
                             "通过 OpenNTFS 重新可写挂载失败：") + error.localizedDescription)
        }
    }

    /// Full UI maintenance flow, called by AppModel.check AND by the offline
    /// orchestration tests (the single real implementation — the app does
    /// not keep a parallel copy): capture pre-unmount state → unmount
    /// (never force) → check/repair → remount per the pre-check policy →
    /// composed status text. The three failure kinds (fsck result /
    /// permission-restore failure / remount outcome) stay separately
    /// expressable in the returned text.
    ///
    /// Repair on a volume OpenNTFS itself had mounted read-write is
    /// preceded by a read-only precheck: only there does a clean `-n` pass
    /// prove the writable repair has nothing left to do (`-n` skips the log
    /// and hibernation checks that a read-write mount already settled), and
    /// skipping the repair keeps ntfsfix from setting VOLUME_IS_DIRTY on a
    /// healthy volume. A restore warning on the precheck blocks the repair
    /// too — no write grant on top of an unresolved permission state.
    @discardableResult
    func runMaintenanceFlow(_ disk: NTFSDisk, repair: Bool) async -> String {
        let preservedLabel = Self.resolvedLabel(disk.label, mountPoint: disk.mountPoint)
        let shouldRemount = disk.isMounted
        let wasOurs = disk.isOurs
        let wasReadOnly = disk.readOnly
        let precheckBeforeRepair = repair && shouldRemount && wasOurs && !wasReadOnly
        maintLog.info("maintenance flow mode=\(repair ? "repair" : "verify", privacy: .public) device=\(disk.devicePath, privacy: .public) label=\(preservedLabel, privacy: .public) wasOurs=\(wasOurs) wasReadOnly=\(wasReadOnly)")
        if disk.isMounted {
            do {
                try await unmount(disk, force: false)
            } catch {
                // Same surface as the previous AppModel behavior: the error
                // becomes the message and NOTHING else runs — no fsck, no
                // helper, no remount, no force.
                return "\(disk.label): \(error.localizedDescription)"
            }
        }
        let outcome: MaintenanceOutcome
        if precheckBeforeRepair {
            let pre = await check(disk, repair: false)
            if let warn = pre.result.restoreWarning, !warn.isEmpty {
                maintLog.info("precheck restore warning, repair not run device=\(disk.devicePath, privacy: .public)")
                outcome = MaintenanceOutcome(result: pre.result, repaired: false,
                                              repairSkipped: true)
            } else if pre.result.ok {
                maintLog.info("precheck clean, repair skipped device=\(disk.devicePath, privacy: .public)")
                outcome = MaintenanceOutcome(result: pre.result, repaired: false,
                                              repairSkipped: true)
            } else {
                maintLog.info("precheck failed, repairing device=\(disk.devicePath, privacy: .public)")
                outcome = await check(disk, repair: true)
            }
        } else {
            outcome = await check(disk, repair: repair)
        }
        var text = MaintenanceReport.checkStatusMessage(label: preservedLabel, repair: repair,
                                                        outcome: outcome)
        if shouldRemount {
            let remount = await remountAfterMaintenance(disk, preferredLabel: preservedLabel,
                                                        wasOurs: wasOurs,
                                                        wasReadOnly: wasReadOnly)
            maintLog.info("maintenance remount outcome=\(String(describing: remount), privacy: .public)")
            text += " — " + MaintenanceReport.remountMessage(remount)
        }
        return text
    }

    /// Format stays user-process only; root format RPC was removed until gated UI exists.
    func format(_ disk: NTFSDisk, label: String) async -> CommandResult {
        maintLog.info("format begin device=\(disk.devicePath, privacy: .public) label=\(label, privacy: .public)")
        let args = ["-t", DiskMonitor.fsTypeName, "-v", label, disk.devicePath]
        return await Shell.run("/sbin/newfs_fskit", args)
    }

    // MARK: Mount points

    /// Fallback location for mounts made with mount(8): a directory owned
    /// by the user, because /Volumes itself is only writable by root.
    static var mountRoot: URL {
        if let override = mountRootOverride { return override }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("NTFS Volumes", isDirectory: true)
    }

    private func makeMountPoint(label: String) throws -> URL {
        let fm = FileManager.default
        let safe = label.replacingOccurrences(of: "/", with: ":")
            .trimmingCharacters(in: .whitespaces)
        let base = safe.isEmpty ? "Untitled" : safe
        try fm.createDirectory(at: Mounter.mountRoot, withIntermediateDirectories: true)
        let busy = Set(MountTable.entries().map(\.path))
        for i in 0..<100 {
            let url = Mounter.mountRoot.appendingPathComponent(i == 0 ? base : "\(base) \(i)")
            if busy.contains(url.path) { continue }
            if fm.fileExists(atPath: url.path) {
                // a stale, empty mount point from an earlier session is fine
                if (try? fm.contentsOfDirectory(atPath: url.path))?.isEmpty == true { return url }
                continue
            }
            try fm.createDirectory(at: url, withIntermediateDirectories: false)
            return url
        }
        throw MountError(message: "no free mount point")
    }

    private func cleanupMountPoint(_ path: String) {
        guard path.hasPrefix(Mounter.mountRoot.path + "/") else { return }
        rmdir(path)  // only succeeds when empty and not a mount point
    }
}

/// User-facing composition of a maintenance run (moved verbatim from
/// AppModel's private statics so the offline orchestration tests exercise
/// the SAME text pipeline the app shows). The fsck result, permission
/// restore failure and remount outcome are separately expressable; success
/// text never masks a restore or remount problem.
enum MaintenanceReport {
    /// Never show a blank failure like "Label:" when fsck returns nothing.
    static func checkStatusMessage(label: String, repair: Bool,
                                   outcome: MaintenanceOutcome) -> String {
        let result = outcome.result
        var text: String
        if result.ok {
            if outcome.repairSkipped {
                text = L("\(label): check passed; no repair needed, nothing was changed.",
                         "\(label)：检查通过，未发现需要修复的问题，未做改动。")
            } else if repair {
                text = L("\(label): repair finished. Windows may offer to scan this disk next time; let it scan.",
                         "\(label)：修复完成。Windows 下次插入时可能提示扫描，按提示扫描即可。")
            } else {
                text = L("\(label): check passed; no problems found.",
                         "\(label)：检查通过，未发现问题。")
            }
        } else {
            let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                text = "\(label): \(trimmed)"
            } else {
                let hint: String
                switch result.status {
                case 13:
                    hint = L("Permission denied.", "权限被拒绝。")
                case 16:
                    hint = L("Volume is busy (still mounted?).", "卷正忙（可能仍被挂载）。")
                case 22:
                    hint = L("Check failed (exit 22). The FSKit module may be unavailable to this process.",
                             "检查失败（退出码 22）。当前进程可能看不到文件系统扩展。")
                default:
                    hint = L("failed with exit status \(result.status).",
                             "失败（退出状态 \(result.status)）。")
                }
                text = "\(label): \(hint)"
            }
        }
        if let warn = result.restoreWarning, !warn.isEmpty {
            // NEUTRAL wording: the App cannot reliably distinguish "the
            // helper already restored the lease (e.g. after its timeout)
            // and has no lease left" from a real restore failure — the RPC
            // surfaces both as an error message. Never claim success, never
            // claim definite failure; preserve the original detail.
            text += " — " + L("Device permission restore outcome unconfirmed: \(warn)",
                              "设备权限恢复结果未确认：\(warn)")
        }
        return text
    }

    /// Remount outcome as a user-visible sentence, kept distinct from the
    /// fsck result and from permission-restore warnings.
    /// Wording rule (no-diagnosis-no-attribution): the mount table only
    /// carries a read-only BIT — it carries no evidence of WHY, so the
    /// read-only remount message stays neutral and never attributes the
    /// cause (e.g. to Windows not being shut down cleanly).
    static func remountMessage(_ outcome: Mounter.RemountOutcome) -> String {
        switch outcome {
        case .remountedReadOnly(let path, false):
            return L("Remounted read-only: \(path)", "已重新挂载（只读）：\(path)")
        case .remountedReadOnly(let path, true):
            return L("Was mounted read-write by another driver; conservatively remounted read-only: \(path)",
                     "原由其他驱动挂载为可写；已按保守策略只读重新挂载：\(path)")
        case .remountedReadWrite(let path):
            return L("Remounted read-write: \(path)", "已重新挂载（可读写）：\(path)")
        case .remountedButReadOnly(let path):
            return L("Remounted, but the volume is read-only; read-write was not obtained: \(path)",
                     "已重新挂载，但卷为只读；未获得可写挂载：\(path)")
        case .alreadyMounted(let path, let readOnly, let byOurs):
            let who = byOurs ? "OpenNTFS" : L("an external mount", "外部挂载")
            let mode = readOnly ? L("read-only", "只读") : L("read-write", "可读写")
            return L("Already \(mode) again by \(who); matches the pre-check policy: \(path)",
                     "卷已被\(who)重新挂载（\(mode)），符合维护前策略：\(path)")
        case .failed(let detail):
            return L("Remount problem: \(detail)", "重新挂载异常：\(detail)")
        }
    }
}
