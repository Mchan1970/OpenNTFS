// OpenNTFS - tri-state mount-table lookup shared by app and helper.
// SPDX-License-Identifier: GPL-2.0-or-later
//
// F-issue contract: a failed mount-table query must never be interpreted as
// "not mounted". Callers gate raw-device work on this result and must treat
// `.queryFailed` as "do not proceed" (fail closed).

import Darwin
import Foundation

/// One row of the mount table as far as maintenance decisions need it.
struct MountEntry: Equatable {
    let device: String     // f_mntfromname, e.g. "/dev/disk4s1"
    let path: String       // f_mntonname
    let fstype: String     // f_fstypename
    let readOnly: Bool     // MNT_RDONLY
}

enum MountQueryState: Equatable {
    case unmounted
    case mounted(MountEntry)
    case queryFailed(String)
}

enum MountQuery {
    /// Mount-table provider, injectable so offline tests never read the real
    /// mount table (red line: tests must not touch real system state).
    /// Production default is `systemProbe` below.
    static var probe: (String) -> MountQueryState = MountQuery.systemProbe

    static func state(forDevice device: String) -> MountQueryState {
        probe(device)
    }

    /// Pure decision over an already-parsed table: exactly zero matches →
    /// unmounted, exactly one → mounted, more than one → failure (never
    /// silently take the first match).
    static func reduce(device: String, entries: [MountEntry]) -> MountQueryState {
        let matches = entries.filter { entry in
            if entry.device == device { return true }
            // UNVERIFIED ASSUMPTION: some mount sources are said to omit the
            // "/dev/" prefix in f_mntfromname. Keeping the alias match is the
            // conservative direction (it can only make us report "mounted"),
            // but no prefix-less disk entry has actually been observed.
            if device.hasPrefix("/dev/"), entry.device == String(device.dropFirst(5)) {
                return true
            }
            return false
        }
        switch matches.count {
        case 0: return .unmounted
        case 1: return .mounted(matches[0])
        default:
            return .queryFailed("device \(device) appears \(matches.count) times in the mount table; ambiguous")
        }
    }

    /// Real getmntinfo_r_np(3) query. `n <= 0` or a missing buffer is a
    /// *query failure* (on macOS at least `/` is always mounted, so an empty
    /// table also means the query misbehaved).
    static func systemProbe(_ device: String) -> MountQueryState {
        var buf: UnsafeMutablePointer<statfs>?
        let n = getmntinfo_r_np(&buf, MNT_NOWAIT)
        guard n > 0, let buf else {
            return .queryFailed("getmntinfo_r_np failed (n=\(n)): \(String(cString: strerror(errno)))")
        }
        defer { free(buf) }
        var entries: [MountEntry] = []
        entries.reserveCapacity(Int(n))
        for i in 0..<Int(n) {
            // Same field-reading idiom as App/DiskMonitor.swift MountTable.
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
            entries.append(MountEntry(device: dev, path: path, fstype: type,
                                      readOnly: (s.f_flags & UInt32(MNT_RDONLY)) != 0))
        }
        return reduce(device: device, entries: entries)
    }
}
