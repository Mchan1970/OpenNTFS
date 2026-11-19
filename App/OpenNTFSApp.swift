// OpenNTFS - menu bar application.
// SPDX-License-Identifier: GPL-2.0-or-later

import FSKit
import OSLog
import ServiceManagement
import SwiftUI

private let appMaintLog = Logger(subsystem: "io.github.mchan1970.OpenNTFS", category: "maintenance")

@MainActor
final class AppModel: ObservableObject {
    let monitor = DiskMonitor()
    let mounter: Mounter

    @Published var moduleEnabled = true
    @Published var busy: Set<String> = []
    @Published var message: String?
    @AppStorage("autoMount") var autoMount = false {
        willSet { objectWillChange.send() }
    }
    @AppStorage("openAfterMount") var openAfterMount = false {
        willSet { objectWillChange.send() }
    }

    /// Volumes the user unmounted by hand: do not grab them again.
    private var declined: Set<String> = []
    private var timer: Timer?

    init() {
        mounter = Mounter(monitor: monitor)
        monitor.onChange = { [weak self] disk in
            Task { @MainActor in self?.diskChanged(disk) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.monitor.refresh()
                await self?.refreshModuleState()
            }
        }
        Task { await refreshModuleState() }
    }

    func refreshModuleState() async {
        let enabled = await mounter.moduleEnabled()
        if enabled != moduleEnabled { moduleEnabled = enabled }
    }

    private func diskChanged(_ disk: NTFSDisk) {
        guard autoMount, moduleEnabled, !disk.isOurs, !disk.isInternal,
              !busy.contains(disk.id), !declined.contains(disk.id) else { return }
        // Take over: either unmounted, or mounted by a read-only driver.
        if !disk.isMounted || disk.readOnly {
            mount(disk, automatic: true)
        }
    }

    private func perform(_ disk: NTFSDisk, _ work: @escaping () async throws -> Void) {
        guard !busy.contains(disk.id) else { return }
        busy.insert(disk.id)
        Task {
            do {
                try await work()
            } catch {
                message = "\(disk.label): \(error.localizedDescription)"
            }
            busy.remove(disk.id)
            monitor.refresh()
        }
    }

    func mount(_ disk: NTFSDisk, automatic: Bool = false) {
        declined.remove(disk.id)
        perform(disk) { [self] in
            do {
                let url = try await mounter.mountReadWrite(disk)
                if openAfterMount && !automatic { NSWorkspace.shared.open(url) }
            } catch {
                if automatic { declined.insert(disk.id) }  // do not retry in a loop
                throw error
            }
        }
    }

    func unmount(_ disk: NTFSDisk) {
        declined.insert(disk.id)
        perform(disk) { [self] in try await mounter.unmount(disk) }
    }

    func eject(_ disk: NTFSDisk) {
        declined.insert(disk.id)
        perform(disk) { [self] in try await mounter.eject(disk) }
    }

    func check(_ disk: NTFSDisk, repair: Bool) {
        perform(disk) { [self] in
            // Single real orchestration path (also exercised offline):
            // unmount (never force) → check/repair → policy remount →
            // composed text with fsck result / restore failure / remount
            // outcome kept separately expressable.
            let statusText = await mounter.runMaintenanceFlow(disk, repair: repair)
            message = statusText
            appMaintLog.info("UI check result mode=\(repair ? "repair" : "verify", privacy: .public) message=\(statusText, privacy: .public)")
        }
    }

    func reveal(_ disk: NTFSDisk) {
        if let url = disk.mountPoint { NSWorkspace.shared.open(url) }
    }

    func openExtensionSettings() {
        if !FSClient.shared.openFileSystemExtensionsSettings() {
            NSWorkspace.shared.open(URL(string:
                "x-apple.systempreferences:com.apple.LoginItems-Settings.extension?ExtensionItems")!)
        }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                message = error.localizedDescription
            }
        }
    }

    /// Privileged helper for 检查卷 / 修复卷 (raw `/dev` access as root).
    var privilegedHelperEnabled: Bool {
        get { HelperClient.shared.isReady }
        set {
            objectWillChange.send()
            do {
                if newValue {
                    try HelperClient.shared.register()
                    if HelperClient.shared.status == .requiresApproval {
                        HelperClient.shared.openApprovalSettings()
                        message = L(
                            "Approve “OpenNTFS Helper” under Login Items & Extensions, then try again.",
                            "请在「登录项与扩展」中批准 “OpenNTFS Helper”，然后再试。")
                    }
                } else {
                    try HelperClient.shared.unregister()
                }
            } catch {
                message = error.localizedDescription
            }
            objectWillChange.send()
        }
    }

    var privilegedHelperStatusText: String {
        switch HelperClient.shared.status {
        case .enabled:
            return L("Helper ready (root)", "Helper 已就绪（root）")
        case .requiresApproval:
            return L("Needs approval in System Settings", "需在系统设置中批准")
        case .notFound:
            return L("Helper not installed in this build", "此构建未包含 Helper")
        case .notRegistered:
            return L("Not registered", "未注册")
        @unknown default:
            return L("Unknown helper status", "Helper 状态未知")
        }
    }
}

@main
struct OpenNTFSApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("OpenNTFS", systemImage: "externaldrive.badge.checkmark") {
            VolumeListView()
                .environmentObject(model)
                .environmentObject(model.monitor)
        }
        .menuBarExtraStyle(.window)
    }
}

struct VolumeListView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var monitor: DiskMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("OpenNTFS").font(.headline)
                Spacer()
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if !model.moduleEnabled {
                VStack(alignment: .leading, spacing: 6) {
                    Label(L("The file system extension is turned off.",
                            "文件系统扩展尚未启用。"),
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(L("Enable OpenNTFS under General → Login Items & Extensions → File System Extensions.",
                           "请在「通用 → 登录项与扩展 → 文件系统扩展」中打开 OpenNTFS。"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(L("Open System Settings…", "打开系统设置…")) {
                        model.openExtensionSettings()
                    }
                }
                .padding(8)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }

            if monitor.disks.isEmpty {
                Text(L("No NTFS volumes connected.", "未连接 NTFS 卷。"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 14)
            } else {
                ForEach(monitor.disks) { disk in
                    VolumeRow(disk: disk)
                }
            }

            if let message = model.message {
                HStack(alignment: .top) {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Spacer()
                    Button {
                        model.message = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel(L("Dismiss", "关闭"))
                }
            }

            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Toggle(L("When a disk appears, take it over as read-write",
                         "插入磁盘时自动接管为可读写"),
                       isOn: $model.autoMount)
                Text(L("With the OpenNTFS extension enabled, macOS may already mount volumes as read-write. This option only controls whether this app remounts them automatically (for example if another driver mounted them read-only).",
                       "启用 OpenNTFS 扩展后，系统本身就可能已挂成可读写。此项只控制本 App 是否自动再接管（例如被其他驱动挂成只读时）。"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle(L("Open at login", "登录时启动"), isOn: Binding(
                get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
            VStack(alignment: .leading, spacing: 4) {
                Toggle(L("Privileged helper for Verify / Repair",
                         "检查卷 / 修复卷特权助手"),
                       isOn: Binding(
                        get: { model.privilegedHelperEnabled },
                        set: { model.privilegedHelperEnabled = $0 }))
                Text(model.privilegedHelperStatusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(L("Raw disk nodes need root and Full Disk Access. Enable the helper once, approve it in Login Items, and grant Full Disk Access to OpenNTFS if Verify still says Operation not permitted.",
                       "读写原始磁盘节点需要 root 与「完全磁盘访问权限」。请启用助手并在登录项中批准；若检查卷仍报 Operation not permitted，再给 OpenNTFS 授予完全磁盘访问权限。"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if HelperClient.shared.status == .requiresApproval {
                    Button(L("Open Login Items…", "打开登录项…")) {
                        HelperClient.shared.openApprovalSettings()
                    }
                    .font(.caption)
                }
            }
            HStack {
                Spacer()
                Button(L("Quit", "退出")) { NSApp.terminate(nil) }
            }
        }
        .toggleStyle(.checkbox)
        .padding(14)
        .frame(width: 380)
    }
}

struct VolumeRow: View {
    @EnvironmentObject var model: AppModel
    let disk: NTFSDisk

    private var status: (String, Color) {
        if !disk.isMounted { return (L("Not mounted", "未挂载"), .secondary) }
        if disk.isOurs {
            return disk.readOnly
                // No-diagnosis-no-attribution: the mount table carries only a
                // read-only bit, no cause — keep the row text neutral.
                ? (L("Read-only", "只读"), .orange)
                : (L("Read & write", "可读写"), .green)
        }
        return (disk.readOnly
            ? L("Read-only (\(disk.kind))", "只读（\(disk.kind)）")
            : L("Mounted by \(disk.kind)", "由 \(disk.kind) 挂载"), .secondary)
    }

    var body: some View {
        let busy = model.busy.contains(disk.id)
        HStack(spacing: 10) {
            Image(systemName: disk.isInternal ? "internaldrive" : "externaldrive")
                .font(.title2)
                .foregroundStyle(disk.isOurs ? Color.accentColor : .secondary)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(disk.label).fontWeight(.medium).lineLimit(1)
                HStack(spacing: 4) {
                    Circle().fill(status.1).frame(width: 7, height: 7)
                    Text(status.0)
                    Text("· " + ByteCountFormatter.string(fromByteCount: Int64(disk.size),
                                                          countStyle: .file))
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if busy {
                ProgressView().controlSize(.small)
            } else {
                if disk.isOurs {
                    Button {
                        model.reveal(disk)
                    } label: { Image(systemName: "folder") }
                    .help(L("Show in Finder", "在访达中显示"))
                } else {
                    Button(L("Mount", "挂载")) { model.mount(disk) }
                        .disabled(!model.moduleEnabled)
                }
                Menu {
                    if disk.isMounted {
                        Button(L("Unmount", "卸载")) { model.unmount(disk) }
                    }
                    if !disk.isInternal {
                        Button(L("Eject", "推出")) { model.eject(disk) }
                    }
                    Divider()
                    Button(L("Verify Volume", "检查卷")) { model.check(disk, repair: false) }
                    Button(L("Repair Volume", "修复卷")) { model.check(disk, repair: true) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel(L("More actions", "更多操作"))
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}
