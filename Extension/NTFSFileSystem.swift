// OpenNTFS - the FSKit file system object: probing, loading, maintenance.
// SPDX-License-Identifier: GPL-2.0-or-later

import FSKit
import Foundation

final class NTFSFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations {

    private var volume: NTFSVolume?
    private var resource: FSBlockDeviceResource?

    override init() {
        super.init()
        _ = Core.installLogging
    }

    // MARK: Probe

    func probeResource(resource: FSResource,
                       replyHandler reply: @escaping (FSProbeResult?, (any Error)?) -> Void) {
        guard let block = resource as? FSBlockDeviceResource else {
            reply(.notRecognized, nil)
            return
        }
        let device = BlockDevice(resource: block, readOnly: true)
        var info = ntfsb_info()
        var io = device.io
        let r = Core.sync { ntfsb_probe(&io, &info) }
        guard r == 0 else {
            reply(.notRecognized, nil)
            return
        }
        let name = labelString(info)
        let id = FSContainerIdentifier(uuid: UUID(ntfsSerial: info.serial))
        reply(.usable(name: name.isEmpty ? "Untitled" : name, containerID: id), nil)
    }

    // MARK: Load / unload

    func loadResource(resource: FSResource, options: FSTaskOptions,
                      replyHandler reply: @escaping (FSVolume?, (any Error)?) -> Void) {
        guard let block = resource as? FSBlockDeviceResource else {
            reply(nil, fs_errorForPOSIXError(ENODEV))
            return
        }
        let opts = options.taskOptions.flatMap { $0.split(separator: ",").map(String.init) }
        let wantReadOnly = opts.contains { ["--rdonly", "rdonly", "ro", "-r"].contains($0) }
        let force = opts.contains("-f")
        log.info("loading \(block.bsdName, privacy: .public) options \(options.taskOptions, privacy: .public)")
        self.resource = block

        let device = BlockDevice(resource: block, readOnly: wantReadOnly)
        var err: Int32 = 0
        var io = device.io
        let flags: UInt32 = wantReadOnly ? UInt32(NTFSB_MOUNT_RDONLY) : 0
        let handle = Core.sync { ntfsb_mount(&io, flags, getuid(), getgid(), &err) }
        guard let handle else {
            if force {
                // Loaded only to be formatted or checked: there is no
                // usable NTFS volume to present (yet).
                log.info("no mountable volume on \(block.bsdName, privacy: .public) (\(err)), continuing for maintenance")
                containerStatus = .ready
                // FSKit insists on a volume object even for a format; this
                // placeholder is never activated.
                reply(FSVolume(volumeID: FSVolume.Identifier(),
                               volumeName: FSFileName(string: "Untitled")), nil)
                return
            }
            log.error("mount of \(block.bsdName, privacy: .public) failed: \(err)")
            let damaged = (err == -EIO || err == -EINVAL)
            reply(nil, damaged ? fs_errorForPOSIXError(EIO) : posixError(err))
            return
        }
        let vol = NTFSVolume(handle: handle, device: device)
        volume = vol
        containerStatus = .ready
        log.info("loaded volume '\(vol.name.string ?? "", privacy: .public)' readOnly=\(vol.isReadOnly)")
        reply(vol, nil)
    }

    func unloadResource(resource: FSResource, options: FSTaskOptions,
                        replyHandler reply: @escaping ((any Error)?) -> Void) {
        log.info("unloading")
        let status = volume?.shutdown() ?? 0
        volume = nil
        self.resource = nil
        reply(status == 0 ? nil : posixError(status))
    }

    func didFinishLoading() {
        log.debug("module finished loading")
    }
}

// MARK: - Format and check

/// Forwards tool output to the FSKit task (shown by Disk Utility, fsck, newfs).
private final class TaskOutput {
    let task: FSTask
    init(_ task: FSTask) { self.task = task }
}

extension NTFSFileSystem: FSManageableResourceMaintenanceOperations {

    private func maintenance(task: FSTask, name: String, needsWrite: Bool,
                             _ work: @escaping (inout ntfsb_device, UnsafeMutableRawPointer) -> Int32)
        throws -> Progress {
        guard let block = resource else { throw posixError(ENXIO) }
        if needsWrite && !block.isWritable { throw posixError(EROFS) }
        // The NTFS volume must not be open while a tool works on the
        // device, and a volume that did not shut down cleanly must not be
        // checked, repaired or formatted on top of its remains: the task
        // is only scheduled inside the gate.
        var scheduled: Progress?
        let gate = VolumeErrorState.gateMaintenance(shutdownResult: volume?.shutdown() ?? 0) {
            volume = nil
            let progress = Progress(totalUnitCount: 100)
            DispatchQueue.global(qos: .userInitiated).async {
                let device = BlockDevice(resource: block, readOnly: !needsWrite)
                let output = TaskOutput(task)
                var io = device.io
                let rc: Int32 = Core.sync {
                    work(&io, Unmanaged.passUnretained(output).toOpaque())
                }
                progress.completedUnitCount = 100
                log.info("\(name, privacy: .public) finished with status \(rc)")
                if rc == 0 {
                    task.didComplete(error: nil)
                } else {
                    task.logMessage("\(name) failed with status \(rc)")
                    task.didComplete(error: rc < 0 ? posixError(rc) : fs_errorForPOSIXError(EIO))
                }
            }
            scheduled = progress
        }
        if gate != 0 {
            volume = nil
            throw posixError(gate)
        }
        return scheduled ?? Progress(totalUnitCount: 100)
    }

    private static let forward: ntfsm_output_cb = { ctx, line in
        guard let ctx, let line else { return }
        Unmanaged<TaskOutput>.fromOpaque(ctx).takeUnretainedValue()
            .task.logMessage(String(cString: line))
    }

    func startCheck(task: FSTask, options: FSTaskOptions) throws -> Progress {
        // fsck conventions: -n never modify, -y / -p repair, -q quick check only.
        let opts = options.taskOptions
        let readOnly = opts.contains("-n") || opts.contains("-q")
            || !(resource?.isWritable ?? false)
        log.info("check options \(opts, privacy: .public) repair=\(!readOnly)")
        return try maintenance(task: task, name: "check", needsWrite: !readOnly) { io, ctx in
            ntfsm_check(&io, readOnly ? 0 : 1, NTFSFileSystem.forward, ctx)
        }
    }

    func startFormat(task: FSTask, options: FSTaskOptions) throws -> Progress {
        // Options: -v <label>   -c <cluster size in bytes>   -z (full format, zero the device)
        let opts = options.taskOptions
        func value(after flag: String) -> String? {
            guard let i = opts.firstIndex(of: flag), i + 1 < opts.count else { return nil }
            return opts[i + 1]
        }
        let label = value(after: "-v") ?? "Untitled"
        let cluster = UInt32(value(after: "-c") ?? "") ?? 0
        let quick: Int32 = opts.contains("-z") ? 0 : 1
        log.info("format options \(opts, privacy: .public)")
        return try maintenance(task: task, name: "format", needsWrite: true) { io, ctx in
            label.withCString { ntfsm_format(&io, $0, cluster, quick, NTFSFileSystem.forward, ctx) }
        }
    }
}
