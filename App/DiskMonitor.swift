// OpenNTFS - watches DiskArbitration for NTFS volumes.
// SPDX-License-Identifier: GPL-2.0-or-later

import DiskArbitration
import Foundation

struct NTFSDisk: Identifiable, Equatable {
    var id: String { bsdName }
    let bsdName: String          // disk4s1
    var label: String
    var size: UInt64
    var kind: String             // DiskArbitration volume kind: ntfs, openntfs, ufsd_NTFS ...
    var mountPoint: URL?
    var readOnly: Bool
    var isInternal: Bool
    var isOurs: Bool

    var devicePath: String { "/dev/" + bsdName }
    var isMounted: Bool { mountPoint != nil }
}

final class DiskMonitor: ObservableObject {
    static let fsTypeName = "openntfs"

    @Published private(set) var disks: [NTFSDisk] = []
    /// Called on the main queue whenever an NTFS disk appears or changes.
    var onChange: ((NTFSDisk) -> Void)?

    let session: DASession

    init() {
        session = DASessionCreate(kCFAllocatorDefault)!
        DASessionSetDispatchQueue(session, DispatchQueue.main)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(session, nil, { disk, ctx in
            DiskMonitor.from(ctx).update(disk)
        }, ctx)
        DARegisterDiskDescriptionChangedCallback(session, nil, nil, { disk, _, ctx in
            DiskMonitor.from(ctx).update(disk)
        }, ctx)
        DARegisterDiskDisappearedCallback(session, nil, { disk, ctx in
            DiskMonitor.from(ctx).remove(disk)
        }, ctx)
    }

    private static func from(_ ctx: UnsafeMutableRawPointer?) -> DiskMonitor {
        Unmanaged<DiskMonitor>.fromOpaque(ctx!).takeUnretainedValue()
    }

    func daDisk(for disk: NTFSDisk) -> DADisk? {
        DADiskCreateFromBSDName(kCFAllocatorDefault, session, disk.bsdName)
    }

    /// Re-reads the state of every known disk (mount state can change
    /// without a description callback when we mount through mount(8)).
    func refresh() {
        for d in disks {
            if let da = daDisk(for: d) { update(da) }
        }
    }

    private func remove(_ disk: DADisk) {
        guard let c = DADiskGetBSDName(disk) else { return }
        let name = String(cString: c)
        disks.removeAll { $0.bsdName == name }
    }

    private func update(_ disk: DADisk) {
        guard let c = DADiskGetBSDName(disk) else { return }
        let bsd = String(cString: c)
        guard let desc = DADiskCopyDescription(disk) as? [String: Any] else { return }

        var kind = (desc[kDADiskDescriptionVolumeKindKey as String] as? String) ?? ""
        var mountPoint = desc[kDADiskDescriptionVolumePathKey as String] as? URL
        var readOnly = !((desc[kDADiskDescriptionMediaWritableKey as String] as? Bool) ?? true)

        // The mount table is the truth for mounts made outside DiskArbitration.
        if let m = MountTable.entry(forDevice: "/dev/" + bsd) {
            kind = m.type
            mountPoint = URL(fileURLWithPath: m.path)
            readOnly = m.readOnly
        }
        guard kind.lowercased().contains("ntfs") else {
            disks.removeAll { $0.bsdName == bsd }
            return
        }
        let info = NTFSDisk(
            bsdName: bsd,
            label: (desc[kDADiskDescriptionVolumeNameKey as String] as? String)
                ?? mountPoint?.lastPathComponent ?? bsd,
            size: (desc[kDADiskDescriptionMediaSizeKey as String] as? NSNumber)?.uint64Value ?? 0,
            kind: kind,
            mountPoint: mountPoint,
            readOnly: readOnly,
            isInternal: (desc[kDADiskDescriptionDeviceInternalKey as String] as? Bool) ?? false,
            isOurs: kind == DiskMonitor.fsTypeName)
        if let i = disks.firstIndex(where: { $0.bsdName == bsd }) {
            if disks[i] == info { return }
            disks[i] = info
        } else {
            disks.append(info)
            disks.sort { $0.bsdName.localizedStandardCompare($1.bsdName) == .orderedAscending }
        }
        onChange?(info)
    }
}

/// Thin wrapper over getmntinfo(3).
enum MountTable {
    struct Entry {
        let device: String
        let path: String
        let type: String
        let readOnly: Bool
    }

    /// Injectable table source for offline orchestration tests (production
    /// default: the real getmntinfo_r_np query). A test stub returns scripted
    /// entries; there is no real query once a hook is installed.
    static var entriesHook: (() -> [Entry])?

    static func entries() -> [Entry] {
        if let hook = entriesHook { return hook() }
        var buf: UnsafeMutablePointer<statfs>?
        let n = getmntinfo_r_np(&buf, MNT_NOWAIT)
        guard n > 0, let buf else { return [] }
        defer { free(buf) }
        return (0..<Int(n)).map { i in
            var s = buf[i]
            let dev = withUnsafePointer(to: &s.f_mntfromname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            let path = withUnsafePointer(to: &s.f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            let type = withUnsafePointer(to: &s.f_fstypename) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
            }
            return Entry(device: dev, path: path, type: type,
                         readOnly: (s.f_flags & UInt32(MNT_RDONLY)) != 0)
        }
    }

    static func entry(forDevice device: String) -> Entry? {
        entries().first { $0.device == device }
    }
}
