// OpenNTFS - shared helpers for the FSKit module.
// SPDX-License-Identifier: GPL-2.0-or-later

import FSKit
import Foundation
import os

let log = Logger(subsystem: "io.github.mchan1970.OpenNTFS", category: "fs")

/// libntfs-3g keeps global state and is not thread safe, so every call into
/// the bridge, from any volume, runs under this one lock.
enum Core {
    private static let lock = NSRecursiveLock()

    static func sync<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    static let installLogging: Void = {
        ntfsb_set_log_callback({ level, message in
            guard let message else { return }
            let text = String(cString: message)
            switch level {
            case Int32(NTFSB_LOG_ERROR): log.error("\(text, privacy: .public)")
            case Int32(NTFSB_LOG_WARNING): log.warning("\(text, privacy: .public)")
            default: log.info("\(text, privacy: .public)")
            }
        }, Int32(NTFSB_LOG_INFO))
    }()
}

/// Turns a negative errno from the bridge into an NSError FSKit understands.
func posixError(_ code: Int32) -> NSError {
    fs_errorForPOSIXError(code < 0 ? -code : code) as NSError
}

func posixError(_ code: Int64) -> NSError {
    posixError(Int32(truncatingIfNeeded: code))
}

func errnoValue(of error: any Error) -> Int32 {
    let ns = error as NSError
    if ns.domain == NSPOSIXErrorDomain, ns.code > 0 {
        return Int32(ns.code)
    }
    return EIO
}

/// Adapts an FSBlockDeviceResource to the bridge's device callbacks.
final class BlockDevice {
    let resource: FSBlockDeviceResource
    private(set) var io = ntfsb_device()

    init(resource: FSBlockDeviceResource, readOnly: Bool) {
        self.resource = resource
        io.ctx = Unmanaged.passUnretained(self).toOpaque()
        io.size_bytes = resource.blockSize * resource.blockCount
        io.sector_size = UInt32(resource.blockSize)
        io.read_only = (readOnly || !resource.isWritable) ? 1 : 0
        io.pread = { ctx, buf, count, offset in
            guard let ctx, let buf, count >= 0 else { return -Int64(EINVAL) }
            let dev = Unmanaged<BlockDevice>.fromOpaque(ctx).takeUnretainedValue()
            do {
                let n = try dev.resource.read(
                    into: UnsafeMutableRawBufferPointer(start: buf, count: Int(count)),
                    startingAt: off_t(offset), length: Int(count))
                return Int64(n)
            } catch {
                return -Int64(errnoValue(of: error))
            }
        }
        if io.read_only == 0 {
            io.pwrite = { ctx, buf, count, offset in
                guard let ctx, let buf, count >= 0 else { return -Int64(EINVAL) }
                let dev = Unmanaged<BlockDevice>.fromOpaque(ctx).takeUnretainedValue()
                do {
                    let n = try dev.resource.write(
                        from: UnsafeRawBufferPointer(start: buf, count: Int(count)),
                        startingAt: off_t(offset), length: Int(count))
                    return Int64(n)
                } catch {
                    return -Int64(errnoValue(of: error))
                }
            }
        }
        io.sync = { ctx in
            guard let ctx else {
                log.info("io.sync -")
                return 0
            }
            let dev = Unmanaged<BlockDevice>.fromOpaque(ctx).takeUnretainedValue()
            log.info("io.sync \(dev.resource.bsdName, privacy: .public)")
            return 0
        }
    }
}

extension UUID {
    /// A stable identifier derived from the 64-bit NTFS volume serial number.
    init(ntfsSerial s: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)) {
        // "NTFS" namespace prefix + serial; version/variant bits set so the
        // result is a well formed (name based style) UUID.
        self.init(uuid: (0x4E, 0x54, 0x46, 0x53, 0x00, 0x00, 0x50, 0x00,
                         0x80 | (s.7 & 0x3F), s.6, s.5, s.4, s.3, s.2, s.1, s.0))
    }
}

func labelString(_ info: ntfsb_info) -> String {
    withUnsafeBytes(of: info.label) { raw in
        String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
}
