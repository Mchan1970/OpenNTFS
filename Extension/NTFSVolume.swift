// OpenNTFS - FSKit volume implementation on top of the libntfs-3g bridge.
// SPDX-License-Identifier: GPL-2.0-or-later

import FSKit
import Foundation

/// One file, directory or symlink known to the kernel.
final class NTFSItem: FSItem {
    let ino: UInt64
    var isDirectory: Bool
    /// Set when the file was written through us and not yet released.
    var needsRelease = false

    /// Directory listing captured when an enumeration starts at cookie 0.
    var listing: [DirEntry]?
    /// Bumped whenever the directory content changes.
    var generation: UInt64 = 1
    /// `generation` at the time `listing` was captured.
    var listingGeneration: UInt64 = 0

    init(ino: UInt64, isDirectory: Bool) {
        self.ino = ino
        self.isDirectory = isDirectory
        super.init()
    }
}

struct DirEntry {
    let name: String
    let ino: UInt64
    var type: FSItem.ItemType
}

/// Collects directory entries from the C callback.
private final class DirCollector {
    var entries: [DirEntry] = []
}

private final class NameCollector {
    var names: [String] = []
}

final class NTFSVolume: FSVolume {

    private var handle: OpaquePointer?
    private let device: BlockDevice
    private var items: [UInt64: NTFSItem] = [:]
    /// Flush/release error handoff state; every access
    /// happens under `Core.sync`, like the bridge calls it dispatches.
    private let errorState = VolumeErrorState()
    private let root: NTFSItem
    private(set) var isReadOnly: Bool
    private var clusterSize: UInt64 = 4096

    /// Files on a removable disk belong to whoever plugged it in.
    private let unknownUID: UInt32 = 99
    private let unknownGID: UInt32 = 99

    init(handle: OpaquePointer, device: BlockDevice) {
        self.handle = handle
        self.device = device
        var info = ntfsb_info()
        ntfsb_get_info(handle, &info)
        isReadOnly = info.read_only != 0
        clusterSize = UInt64(max(info.cluster_size, 512))
        root = NTFSItem(ino: UInt64(NTFSB_ROOT_INO), isDirectory: true)
        let label = labelString(info)
        super.init(volumeID: FSVolume.Identifier(uuid: UUID(ntfsSerial: info.serial)),
                   volumeName: FSFileName(string: label.isEmpty ? "Untitled" : label))
        items[root.ino] = root
        if isReadOnly {
            log.notice("volume is read-only, reason \(info.ro_reason)")
        }
    }

    /// Flush, release and unmount the NTFS volume, combining the unmount
    /// result with the error ledger, where a stored error outranks a
    /// fresh one. Safe to call more than
    /// once. Returns the positive errno to report, or 0.
    func shutdown() -> Int32 {
        Core.sync {
            guard let h = handle else { return 0 }
            let status = errorState.shutdownResult(
                releasePending: { releasePending(h, clearAlways: true) },
                unmount: { ntfsb_unmount(h) })
            handle = nil
            items.removeAll()
            if status != 0 { log.error("shutdown finished with error \(status)") }
            return status
        }
    }

    // MARK: - Helpers

    /// Runs `body` with the volume handle under the global lock; replies
    /// ENXIO when the volume is already gone.
    private func withVolume<R>(_ reply: (R?, (any Error)?) -> Void,
                               _ body: (OpaquePointer) throws -> R) {
        Core.sync {
            guard let h = handle else {
                reply(nil, posixError(ENXIO))
                return
            }
            do {
                reply(try body(h), nil)
            } catch {
                reply(nil, error)
            }
        }
    }

    private func check(_ r: Int32) throws {
        if r != 0 { throw posixError(r) }
    }

    private func node(_ item: FSItem) throws -> NTFSItem {
        guard let n = item as? NTFSItem else { throw posixError(EINVAL) }
        return n
    }

    private func itemID(_ ino: UInt64) -> FSItem.Identifier {
        ino == UInt64(NTFSB_ROOT_INO) ? .rootDirectory : FSItem.Identifier(ino)
    }

    private func itemType(mode: UInt32) -> FSItem.ItemType {
        switch mode & UInt32(S_IFMT) {
        case UInt32(S_IFDIR): return .directory
        case UInt32(S_IFLNK): return .symlink
        case UInt32(S_IFIFO): return .fifo
        case UInt32(S_IFSOCK): return .socket
        case UInt32(S_IFCHR): return .charDevice
        case UInt32(S_IFBLK): return .blockDevice
        default: return .file
        }
    }

    private func attributes(_ st: ntfsb_stat) -> FSItem.Attributes {
        let a = FSItem.Attributes()
        a.type = itemType(mode: st.mode)
        a.mode = st.mode
        a.uid = unknownUID
        a.gid = unknownGID
        a.linkCount = st.nlink
        a.flags = st.bsd_flags
        a.size = st.size
        a.allocSize = st.alloc_size
        a.fileID = itemID(st.ino)
        if st.ino == UInt64(NTFSB_ROOT_INO) {
            a.parentID = .parentOfRoot
        } else if st.parent_ino != 0 {
            a.parentID = itemID(st.parent_ino)
        }
        a.accessTime = st.atime
        a.modifyTime = st.mtime
        a.changeTime = st.ctime
        a.birthTime = st.btime
        a.inhibitKernelOffloadedIO = true
        a.supportsLimitedXAttrs = false
        return a
    }

    private func stat(_ h: OpaquePointer, _ ino: UInt64) throws -> ntfsb_stat {
        var st = ntfsb_stat()
        try check(ntfsb_getattr(h, ino, &st))
        return st
    }

    private func attributes(_ h: OpaquePointer, of ino: UInt64) throws -> FSItem.Attributes {
        attributes(try stat(h, ino))
    }

    /// The item object for an inode. The kernel must always see the same
    /// object for the same file until it reclaims it.
    private func item(for st: ntfsb_stat) -> NTFSItem {
        let isDir = (st.mode & UInt32(S_IFMT)) == UInt32(S_IFDIR)
        if let existing = items[st.ino] {
            existing.isDirectory = isDir
            return existing
        }
        let n = NTFSItem(ino: st.ino, isDirectory: isDir)
        // a release that failed during a reclaim is still owed for this
        // ino: the fresh item inherits it
        if errorState.lookupInheritsPendingRelease(st.ino) {
            n.needsRelease = true
        }
        items[st.ino] = n
        return n
    }

    private func freeSpace(_ h: OpaquePointer) -> FSFreeSpace {
        var info = ntfsb_info()
        ntfsb_get_info(h, &info)
        let fs = FSFreeSpace()
        fs.populate(bytes: info.free_clusters * UInt64(info.cluster_size))
        return fs
    }

    private func string(_ name: FSFileName) throws -> String {
        guard let s = name.string, !s.isEmpty else { throw posixError(EILSEQ) }
        return s
    }

    /// Names are stored composed (NFC), which is what Windows writes.
    private func diskName(_ name: FSFileName) throws -> String {
        try string(name).precomposedStringWithCanonicalMapping
    }

    private func touch(_ dir: NTFSItem) {
        dir.generation &+= 1
    }

    /// Looks a name up; returns the stat and the on-disk spelling.
    private func lookup(_ h: OpaquePointer, _ dir: UInt64, _ name: String)
        throws -> (ntfsb_stat, String) {
        var st = ntfsb_stat()
        var actual: UnsafeMutablePointer<CChar>?
        var r = ntfsb_lookup(h, dir, name, &st, &actual)
        if r == -ENOENT {
            // The caller may have used a decomposed spelling of a composed name.
            let composed = name.precomposedStringWithCanonicalMapping
            if composed != name {
                r = ntfsb_lookup(h, dir, composed, &st, &actual)
            }
        }
        defer { free(actual) }
        try check(r)
        return (st, actual.map { String(cString: $0) } ?? name)
    }

    /// One release pass: flagged items first, then the inos
    /// whose release failed during a reclaim. `clearAlways` is the
    /// shutdown exception: item flags are cleared regardless of the
    /// outcome and the error goes to the ledger.
    private func releasePending(_ h: OpaquePointer, clearAlways: Bool = false) {
        let flagged = items.values.filter(\.needsRelease).map { n in
            (ino: n.ino, clear: { n.needsRelease = false })
        }
        errorState.releasePending(flagged: flagged, clearAlways: clearAlways,
                                  release: { ntfsb_release(h, $0) })
    }

    private func readDirectory(_ h: OpaquePointer, _ dir: NTFSItem) throws -> [DirEntry] {
        let collector = DirCollector()
        let r = ntfsb_readdir(h, dir.ino, { ctx, name, len, ino, dtype in
            guard let ctx, let name else { return 0 }
            let c = Unmanaged<DirCollector>.fromOpaque(ctx).takeUnretainedValue()
            let s = String(decoding: UnsafeRawBufferPointer(start: name, count: len), as: UTF8.self)
            let type: FSItem.ItemType
            switch dtype {
            case Int32(NTFSB_DT_REG): type = .file
            case Int32(NTFSB_DT_DIR): type = .directory
            case Int32(NTFSB_DT_LNK): type = .symlink
            case Int32(NTFSB_DT_FIFO): type = .fifo
            case Int32(NTFSB_DT_SOCK): type = .socket
            case Int32(NTFSB_DT_CHR): type = .charDevice
            case Int32(NTFSB_DT_BLK): type = .blockDevice
            default: type = .unknown
            }
            c.entries.append(DirEntry(name: s, ino: ino, type: type))
            return 0
        }, Unmanaged.passUnretained(collector).toOpaque())
        try check(r)
        return collector.entries
    }
}

// MARK: - Volume life cycle and namespace

extension NTFSVolume: FSVolume.Handler {

    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let c = FSVolume.SupportedCapabilities()
        c.supportsPersistentObjectIDs = true
        c.supportsSymbolicLinks = true
        c.supportsHardLinks = true
        c.supportsSparseFiles = true
        c.supportsFastStatFS = true
        c.supports2TBFiles = true
        c.supportsHiddenFiles = true
        c.supports64BitObjectIDs = true
        c.doesNotSupportImmutableFiles = true
        c.doesNotSupportSettingFilePermissions = true
        c.caseFormat = .insensitiveCasePreserving
        return c
    }

    var volumeStatistics: FSStatFSResult {
        let s = FSStatFSResult(fileSystemTypeName: "openntfs")
        Core.sync {
            guard let h = handle else { return }
            var info = ntfsb_info()
            ntfsb_get_info(h, &info)
            let cs = UInt64(info.cluster_size)
            s.blockSize = Int(info.cluster_size)
            s.ioSize = 1 << 20
            s.totalBlocks = info.total_clusters
            s.freeBlocks = info.free_clusters
            s.availableBlocks = info.free_clusters
            s.usedBlocks = info.total_clusters - min(info.free_clusters, info.total_clusters)
            s.totalBytes = info.total_clusters * cs
            s.freeBytes = info.free_clusters * cs
            s.availableBytes = info.free_clusters * cs
            s.usedBytes = s.usedBlocks * cs
            s.totalFiles = info.total_files
            s.freeFiles = info.free_files
        }
        return s
    }

    var enableOpenUnlinkEmulation: Bool { true }

    var requestedMountOptions: FSVolume.MountOptions {
        return isReadOnly ? [.readOnly] : []
    }

    // PathConf

    var maximumLinkCount: Int { 1024 }
    var maximumNameLength: Int { 255 }
    var restrictsOwnershipChanges: Bool { true }
    var truncatesLongNames: Bool { false }
    var maximumFileSizeInBits: Int { 63 }
    var maximumXattrSizeInBits: Int { 32 }

    // Life cycle

    func activateVolume(options: FSTaskOptions,
                        replyHandler reply: @escaping (FSActivateResult?, (any Error)?) -> Void) {
        log.info("activate")
        reply(FSActivateResult(rootItem: root), nil)
    }

    func deactivateVolume(options: FSDeactivateOptions,
                          replyHandler reply: @escaping ((any Error)?) -> Void) {
        log.info("deactivate")
        var syncError: Int32 = 0
        Core.sync {
            if let h = handle {
                releasePending(h)
                // reporting boundary: a stored error outranks this attempt
                syncError = errorState.boundary(ntfsb_sync(h))
            }
        }
        reply(syncError == 0 ? nil : posixError(syncError))
    }

    func mount(options: FSTaskOptions, replyHandler reply: @escaping ((any Error)?) -> Void) {
        log.info("mount \(options.taskOptions, privacy: .public)")
        reply(nil)
    }

    func unmount(replyHandler reply: @escaping () -> Void) {
        log.info("unmount")
        Core.sync {
            if let h = handle {
                releasePending(h)
                let r = ntfsb_sync(h)
                if r != 0 {
                    log.error("unmount sync failed: \(r)")
                    // no error channel here: whichever of synchronize,
                    // deactivateVolume or unloadResource runs first
                    // reports it
                    errorState.record(r)
                }
            }
        }
        reply()
    }

    func synchronize(flags: FSSyncFlags, replyHandler reply: @escaping ((any Error)?) -> Void) {
        log.info("synchronize")
        let r: Int32 = Core.sync {
            guard let h = handle else { return 0 }
            releasePending(h)
            // reporting boundary: a stored error outranks this attempt
            return errorState.boundary(ntfsb_sync(h))
        }
        reply(r == 0 ? nil : posixError(r))
    }

    func reclaimItem(_ item: FSItem, replyHandler reply: @escaping ((any Error)?) -> Void) {
        // Per FSItem.h: cleanup runs inside tryReclaim, under the same
        // synchronization context as lookup; a DECLINED reclaim retains
        // all state and replies success.
        var reclaimError: (any Error)?
        var wasReclaimed = false
        Core.sync {
            guard let n = item as? NTFSItem else { return }
            wasReclaimed = n.tryReclaim {
                // the tested decision path: a failed
                // release is replied and the ino retried later; the
                // error itself is bookkept by the C ledger
                var err: Int32 = 0
                if let h = self.handle {
                    err = self.errorState.reclaimRelease(
                        ino: n.ino, needsRelease: n.needsRelease,
                        release: { ntfsb_release(h, $0) })
                }
                if err == 0 {
                    n.needsRelease = false
                }
                n.listing = nil
                if n !== self.root, self.items[n.ino] === n {
                    self.items[n.ino] = nil
                }
                if err != 0 { reclaimError = posixError(err) }
            }
        }
        reply(wasReclaimed ? reclaimError : nil)
    }

    // Namespace

    func lookupItem(named name: FSFileName, in directory: FSItem, context: FSContext,
                    replyHandler reply: @escaping (FSLookupItemResult?, (any Error)?) -> Void) {
        withVolume(reply) { h in
            let p = try lookupParts(h, named: name, in: directory)
            return FSLookupItemResult(foundItem: p.item, itemName: p.name,
                                      itemAttributes: p.attributes)!
        }
    }

    /// Shared lookup core.
    private func lookupParts(_ h: OpaquePointer, named name: FSFileName,
                             in directory: FSItem)
        throws -> (item: NTFSItem, name: FSFileName, attributes: FSItem.Attributes) {
        let dir = try node(directory)
        let (st, actual) = try lookup(h, dir.ino, try string(name))
        return (item(for: st), FSFileName(string: actual), attributes(st))
    }

    func createItem(named name: FSFileName, type: FSItem.ItemType, in directory: FSItem,
                    attributes newAttributes: FSItem.SetAttributesRequest, context: FSContext,
                    replyHandler reply: @escaping (FSCreateItemResult?, (any Error)?) -> Void) {
        withVolume(reply) { h in
            let p = try createParts(h, named: name, type: type, in: directory,
                                    attributes: newAttributes)
            return FSCreateItemResult(newItem: p.item, newItemName: p.name,
                                      newItemAttributes: p.attributes,
                                      directoryAttributes: p.directoryAttributes,
                                      freeSpace: p.freeSpace)!
        }
    }

    /// Shared create core.
    private func createParts(_ h: OpaquePointer, named name: FSFileName,
                             type: FSItem.ItemType, in directory: FSItem,
                             attributes newAttributes: FSItem.SetAttributesRequest)
        throws -> (item: NTFSItem, name: FSFileName, attributes: FSItem.Attributes,
                   directoryAttributes: FSItem.Attributes, freeSpace: FSFreeSpace) {
        let dir = try node(directory)
        let mode: mode_t
        switch type {
        case .file: mode = S_IFREG
        case .directory: mode = S_IFDIR
        default: throw posixError(ENOTSUP)
        }
        let diskName = try diskName(name)
        var st = ntfsb_stat()
        try check(ntfsb_create(h, dir.ino, diskName, mode, &st))
        touch(dir)
        items[st.ino] = nil  // a recycled MFT record is a brand new file
        if errorState.discardPendingRelease(st.ino) {
            log.error("MFT record \(st.ino) was recycled while one of its releases was still pending")
        }
        let n = item(for: st)
        st = try applyAttributes(h, newAttributes, to: n, initial: true) ?? st
        return (n, FSFileName(string: diskName), attributes(st),
                try attributes(h, of: dir.ino), freeSpace(h))
    }

    func createSymbolicLink(named name: FSFileName, in directory: FSItem,
                            attributes newAttributes: FSItem.SetAttributesRequest,
                            linkContents contents: FSFileName, context: FSContext,
                            replyHandler reply: @escaping (FSCreateSymlinkResult?, (any Error)?) -> Void) {
        withVolume(reply) { h in
            let dir = try node(directory)
            let diskName = try diskName(name)
            let target = try string(contents)
            var st = ntfsb_stat()
            try check(ntfsb_symlink(h, dir.ino, diskName, target, &st))
            touch(dir)
            items[st.ino] = nil
            if errorState.discardPendingRelease(st.ino) {
                log.error("MFT record \(st.ino) was recycled while one of its releases was still pending")
            }
            let n = item(for: st)
            newAttributes.consumedAttributes = [.mode, .uid, .gid]
            return FSCreateSymlinkResult(newItem: n,
                                         newItemName: FSFileName(string: diskName),
                                         newItemAttributes: attributes(st),
                                         directoryAttributes: try attributes(h, of: dir.ino),
                                         freeSpace: freeSpace(h))!
        }
    }

    func createLink(to item: FSItem, named name: FSFileName, in directory: FSItem,
                    context: FSContext,
                    replyHandler reply: @escaping (FSCreateLinkResult?, (any Error)?) -> Void) {
        withVolume(reply) { h in
            let dir = try node(directory)
            let n = try node(item)
            let diskName = try diskName(name)
            try check(ntfsb_link(h, n.ino, dir.ino, diskName))
            touch(dir)
            return FSCreateLinkResult(linkName: FSFileName(string: diskName),
                                      linkAttributes: try attributes(h, of: n.ino),
                                      directoryAttributes: try attributes(h, of: dir.ino),
                                      freeSpace: freeSpace(h))!
        }
    }

    func renameItem(_ item: FSItem, inDirectory sourceDirectory: FSItem,
                    named sourceName: FSFileName, to destinationName: FSFileName,
                    inDirectory destinationDirectory: FSItem, overItem: FSItem?,
                    context: FSContext,
                    replyHandler reply: @escaping (FSRenameItemResult?, (any Error)?) -> Void) {
        withVolume(reply) { h in
            let n = try node(item)
            let src = try node(sourceDirectory)
            let dst = try node(destinationDirectory)
            let over = try overItem.map { try node($0) }
            let newName = try diskName(destinationName)
            // Resolve the source spelling the same way lookup does.
            let (_, oldName) = try lookup(h, src.ino, try string(sourceName))

            var overStat: ntfsb_stat?
            if let over, over !== n {
                overStat = try? stat(h, over.ino)
            }
            // release the previous writer first; a failed release stops
            // the rename
            var renameR: Int32 = 0
            let pre = errorState.releaseBeforeAction(
                ino: over?.ino ?? 0,
                needsRelease: over.map { $0 !== n && $0.needsRelease } ?? false,
                release: { ntfsb_release(h, $0) }) {
                renameR = ntfsb_rename(h, src.ino, oldName, dst.ino, newName)
            }
            if pre != 0 { throw posixError(pre) }
            if let over, over !== n, over.needsRelease { over.needsRelease = false }
            try check(renameR)
            touch(src)
            touch(dst)

            var overAttrs: FSItem.Attributes?
            if let over, over !== n, var st = overStat {
                if st.nlink > 1, let now = try? stat(h, over.ino) {
                    st = now
                } else {
                    st.nlink = 0
                    items[over.ino] = nil
                }
                overAttrs = attributes(st)
            }
            return FSRenameItemResult(newName: FSFileName(string: newName),
                                      renamedItemAttributes: try attributes(h, of: n.ino),
                                      sourceDirectoryAttributes: try attributes(h, of: src.ino),
                                      destinationDirectoryAttributes: try attributes(h, of: dst.ino),
                                      overItemAttributes: overAttrs,
                                      freeSpace: freeSpace(h))!
        }
    }

    func removeItem(_ item: FSItem, named name: FSFileName, from directory: FSItem,
                    context: FSContext,
                    replyHandler reply: @escaping (FSRemoveItemResult?, (any Error)?) -> Void) {
        withVolume(reply) { h in
            let n = try node(item)
            let dir = try node(directory)
            let (found, actual) = try lookup(h, dir.ino, try string(name))
            guard found.ino == n.ino else { throw posixError(ESTALE) }
            // release the previous writer first; a failed release stops
            // the removal
            var removeR: Int32 = 0
            let pre = errorState.releaseBeforeAction(
                ino: n.ino, needsRelease: n.needsRelease,
                release: { ntfsb_release(h, $0) }) {
                removeR = ntfsb_remove(h, dir.ino, actual)
            }
            if pre != 0 { throw posixError(pre) }
            if n.needsRelease { n.needsRelease = false }
            var st = found
            try check(removeR)
            touch(dir)
            if st.nlink > 1, let now = try? stat(h, n.ino) {
                st = now
            } else {
                st.nlink = 0
                if items[n.ino] === n { items[n.ino] = nil }
            }
            return FSRemoveItemResult(itemAttributes: attributes(st),
                                      directoryAttributes: try attributes(h, of: dir.ino),
                                      freeSpace: freeSpace(h))!
        }
    }

    func readSymbolicLink(_ item: FSItem, context: FSContext,
                          replyHandler reply: @escaping (FSReadSymlinkResult?, (any Error)?) -> Void) {
        withVolume(reply) { h in
            let n = try node(item)
            var target: UnsafeMutablePointer<CChar>?
            try check(ntfsb_readlink(h, n.ino, &target))
            defer { free(target) }
            let s = target.map { String(cString: $0) } ?? ""
            return FSReadSymlinkResult(contents: FSFileName(string: s),
                                       symlinkAttributes: try attributes(h, of: n.ino))!
        }
    }

    // Attributes

    func getAttributes(_ desiredAttributes: FSItem.GetAttributesRequest, of item: FSItem,
                       context: FSContext,
                       replyHandler reply: @escaping (FSGetAttributesResult?, (any Error)?) -> Void) {
        withVolume(reply) { h in
            let n = try node(item)
            return FSGetAttributesResult(attributes: try attributes(h, of: n.ino))!
        }
    }

    func setAttributes(_ newAttributes: FSItem.SetAttributesRequest, on item: FSItem,
                       context: FSContext,
                       replyHandler reply: @escaping (FSSetAttributesResult?, (any Error)?) -> Void) {
        withVolume(reply) { h in
            let n = try node(item)
            let st = try applyAttributes(h, newAttributes, to: n, initial: false)
                ?? (try stat(h, n.ino))
            return FSSetAttributesResult(attributes: attributes(st), freeSpace: freeSpace(h))!
        }
    }

    /// Applies a set-attributes request. Returns the fresh stat when
    /// something was changed, nil when there was nothing to do.
    private func applyAttributes(_ h: OpaquePointer, _ req: FSItem.SetAttributesRequest,
                                 to n: NTFSItem, initial: Bool) throws -> ntfsb_stat? {
        var consumed: FSItem.Attribute = []
        var changed = false

        // NTFS ACLs are not mapped: ownership and mode are accepted and ignored,
        // so that copies with cp -p, Finder, rsync -a etc. do not fail.
        for bit in [FSItem.Attribute.mode, .uid, .gid] where req.isValid(bit) {
            consumed.insert(bit)
        }
        if req.isValid(.size) {
            consumed.insert(.size)
            if !n.isDirectory && !(initial && req.size == 0) {
                try check(ntfsb_truncate(h, n.ino, req.size))
                changed = true
            }
        }
        var at = timespec(), mt = timespec(), ct = timespec(), bt = timespec()
        var hasA = false, hasM = false, hasC = false, hasB = false
        if req.isValid(.accessTime) { at = req.accessTime; hasA = true; consumed.insert(.accessTime) }
        if req.isValid(.modifyTime) { mt = req.modifyTime; hasM = true; consumed.insert(.modifyTime) }
        if req.isValid(.changeTime) { ct = req.changeTime; hasC = true; consumed.insert(.changeTime) }
        if req.isValid(.birthTime) { bt = req.birthTime; hasB = true; consumed.insert(.birthTime) }
        if hasA || hasM || hasC || hasB {
            if isReadOnly { throw posixError(EROFS) }
            let r = withUnsafePointer(to: &at) { pa in
                withUnsafePointer(to: &mt) { pm in
                    withUnsafePointer(to: &ct) { pc in
                        withUnsafePointer(to: &bt) { pb in
                            ntfsb_set_times(h, n.ino, hasA ? pa : nil, hasM ? pm : nil,
                                            hasC ? pc : nil, hasB ? pb : nil)
                        }
                    }
                }
            }
            try check(r)
            changed = true
        }
        if req.isValid(.flags) {
            consumed.insert(.flags)
            try check(ntfsb_set_bsd_flags(h, n.ino, req.flags))
            changed = true
        }
        req.consumedAttributes = consumed
        return changed ? try stat(h, n.ino) : nil
    }

    // Directory enumeration

    func enumerateDirectory(_ directory: FSItem, startingAt cookie: FSDirectoryCookie,
                            verifier: FSDirectoryVerifier,
                            attributes wanted: FSItem.GetAttributesRequest?,
                            packer: FSDirectoryEntryPacker, context: FSContext,
                            replyHandler reply: @escaping (FSEnumerateDirectoryResult?, (any Error)?) -> Void) {
        withVolume(reply) { h in
            let dir = try node(directory)
            guard dir.isDirectory else { throw posixError(ENOTDIR) }

            // A fresh enumeration takes a new snapshot. A continued one keeps
            // using the snapshot it started with, so entries are neither
            // skipped nor repeated while the directory changes underneath
            // (think rm -rf).
            if cookie == .initial || dir.listing == nil {
                dir.listing = try readDirectory(h, dir)
                dir.listingGeneration = dir.generation
            }
            let listing = dir.listing ?? []
            let stale = dir.listingGeneration != dir.generation
            let withDots = (wanted == nil)
            let dots = withDots ? 2 : 0
            var index = Int(cookie.rawValue)

            if withDots {
                while index < 2 {
                    var id = itemID(dir.ino)
                    if index == 1 {
                        let st = try stat(h, dir.ino)
                        id = dir === root ? .rootDirectory : itemID(st.parent_ino)
                    }
                    guard packer.packEntry(name: FSFileName(string: index == 0 ? "." : ".."),
                                           itemType: .directory, itemID: id,
                                           nextCookie: FSDirectoryCookie(UInt64(index + 1)),
                                           attributes: nil) else {
                        return FSEnumerateDirectoryResult(verifier: dir.generation)!
                    }
                    index += 1
                }
            }

            while index - dots < listing.count {
                let e = listing[index - dots]
                var type = e.type
                var ino = e.ino
                var attrs: FSItem.Attributes?

                if wanted != nil || type == .unknown || stale {
                    // Need the real thing. When the directory changed since
                    // the snapshot, go by name: the inode may be gone or reused.
                    var st = ntfsb_stat()
                    let r = stale ? ntfsb_lookup(h, dir.ino, e.name, &st, nil)
                                  : ntfsb_getattr(h, e.ino, &st)
                    if r != 0 {
                        index += 1  // vanished meanwhile
                        continue
                    }
                    type = itemType(mode: st.mode)
                    ino = st.ino
                    if wanted != nil { attrs = attributes(st) }
                }
                guard packer.packEntry(name: FSFileName(string: e.name), itemType: type,
                                       itemID: itemID(ino),
                                       nextCookie: FSDirectoryCookie(UInt64(index + 1)),
                                       attributes: attrs) else { break }
                index += 1
            }
            return FSEnumerateDirectoryResult(verifier: dir.generation)!
        }
    }
}

// MARK: - Open / close

extension NTFSVolume: FSVolume.OpenCloseHandler {

    func openItem(_ item: FSItem, modes: FSVolume.OpenModes, context: FSContext,
                  replyHandler reply: @escaping ((any Error)?) -> Void) {
        if modes.contains(.write) && isReadOnly {
            reply(posixError(EROFS))
            return
        }
        reply(nil)
    }

    func closeItem(_ item: FSItem, modes: FSVolume.OpenModes, context: FSContext,
                   replyHandler reply: @escaping ((any Error)?) -> Void) {
        var releaseError: Int32 = 0
        Core.sync {
            if let n = item as? NTFSItem, n.needsRelease, !modes.contains(.write),
               let h = handle {
                let r = ntfsb_release(h, n.ino)
                if r != 0 {
                    // reported through the reply below; the flag stays
                    // set for a retry
                    releaseError = r
                } else {
                    n.needsRelease = false
                }
            }
        }
        reply(releaseError == 0 ? nil : posixError(releaseError))
    }
}

// MARK: - File data

extension NTFSVolume: FSVolume.ReadWriteHandler {

    func read(from item: FSItem, at offset: off_t, length: Int,
              into buffer: FSMutableFileDataBuffer,
              replyHandler reply: @escaping (FSReadFileResult?, (any Error)?) -> Void) {
        withVolume(reply) { h in
            let n = try node(item)
            let got: Int64 = buffer.withUnsafeMutableBytes { raw in
                ntfsb_read(h, n.ino, raw.baseAddress, min(length, raw.count), Int64(offset))
            }
            if got < 0 { throw posixError(got) }
            return FSReadFileResult(bytesRead: Int(got),
                                    itemAttributes: try attributes(h, of: n.ino))!
        }
    }

    func write(contents: Data, to item: FSItem, at offset: off_t,
               replyHandler reply: @escaping (FSWriteFileResult?, (any Error)?) -> Void) {
        withVolume(reply) { h in
            let n = try node(item)
            let put: Int64 = contents.withUnsafeBytes { raw in
                ntfsb_write(h, n.ino, raw.baseAddress, raw.count, Int64(offset))
            }
            if put < 0 { throw posixError(put) }
            n.needsRelease = true
            return FSWriteFileResult(bytesWritten: Int(put),
                                     itemAttributes: try attributes(h, of: n.ino),
                                     freeSpace: freeSpace(h))!
        }
    }
}

// MARK: - Extended attributes (NTFS named data streams)

extension NTFSVolume: FSVolume.XattrHandler {

    func getXattr(named name: FSFileName, of item: FSItem, context: FSContext,
                  replyHandler reply: @escaping (FSGetXattrResult?, (any Error)?) -> Void) {
        withVolume(reply) { h in
            let n = try node(item)
            let key = try string(name)
            let size = ntfsb_getxattr(h, n.ino, key, nil, 0)
            if size < 0 { throw posixError(size) }
            var data = Data(count: Int(size))
            let got: Int64 = data.withUnsafeMutableBytes { raw in
                raw.count == 0 ? 0 : ntfsb_getxattr(h, n.ino, key, raw.baseAddress, raw.count)
            }
            if got < 0 { throw posixError(got) }
            if got < size { data.count = Int(got) }
            return FSGetXattrResult(xattrValue: data)!
        }
    }

    func setXattr(named name: FSFileName, to value: Data?, on item: FSItem,
                  policy: FSVolume.SetXattrPolicy, context: FSContext,
                  replyHandler reply: @escaping (FSSetXattrResult?, (any Error)?) -> Void) {
        withVolume(reply) { h in
            let n = try node(item)
            let key = try string(name)
            if policy == .delete {
                try check(ntfsb_removexattr(h, n.ino, key))
            } else {
                let flags: Int32
                switch policy {
                case .mustCreate: flags = XATTR_CREATE
                case .mustReplace: flags = XATTR_REPLACE
                default: flags = 0
                }
                let data = value ?? Data()
                let r: Int32 = data.withUnsafeBytes { raw in
                    ntfsb_setxattr(h, n.ino, key, raw.baseAddress, raw.count, flags)
                }
                try check(r)
            }
            return FSSetXattrResult(freeSpace: freeSpace(h))!
        }
    }

    func listXattrs(of item: FSItem, context: FSContext,
                    replyHandler reply: @escaping (FSListXattrsResult?, (any Error)?) -> Void) {
        withVolume(reply) { h in
            let n = try node(item)
            let collector = NameCollector()
            let r = ntfsb_listxattr(h, n.ino, { ctx, name, _ in
                guard let ctx, let name else { return 0 }
                Unmanaged<NameCollector>.fromOpaque(ctx).takeUnretainedValue()
                    .names.append(String(cString: name))
                return 0
            }, Unmanaged.passUnretained(collector).toOpaque())
            try check(r)
            return FSListXattrsResult(xattrNames: collector.names.map { FSFileName(string: $0) })!
        }
    }
}

// MARK: - Volume label

extension NTFSVolume: FSVolume.RenameHandler {

    func setVolumeName(_ name: FSFileName, context: FSContext,
                       replyHandler reply: @escaping (FSVolumeRenameResult?, (any Error)?) -> Void) {
        withVolume(reply) { h in
            let label = try string(name)
            try check(ntfsb_set_label(h, label))
            self.name = FSFileName(string: label)
            return FSVolumeRenameResult(newName: FSFileName(string: label))!
        }
    }
}
