// OpenNTFS - shared device-path validation for the maintenance helper.
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

enum DevicePathRules {
    /// `/dev/diskN`, `/dev/diskNsM`, `/dev/rdiskN`, `/dev/rdiskNsM` only.
    static func isAllowed(_ path: String) -> Bool {
        path.range(of: #"^/dev/r?disk[0-9]+(s[0-9]+)?$"#, options: .regularExpression) != nil
    }

    /// Prefer the block device name as the lease key (`/dev/rdisk…` → `/dev/disk…`).
    static func canonicalKey(_ path: String) -> String? {
        guard isAllowed(path) else { return nil }
        if path.hasPrefix("/dev/rdisk") {
            return "/dev/disk" + path.dropFirst("/dev/rdisk".count)
        }
        return path
    }

    /// Companion raw node for a block device path, if any.
    static func rdiskCompanion(for path: String) -> String? {
        guard let key = canonicalKey(path), key.hasPrefix("/dev/disk") else { return nil }
        return "/dev/rdisk" + key.dropFirst("/dev/disk".count)
    }

    /// Volume label safe for newfs_fskit `-v` (kept for future format UI).
    static func isAllowedLabel(_ label: String) -> Bool {
        guard !label.isEmpty, label.count <= 32 else { return false }
        return label.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F
                && scalar != "/" && scalar != "\\" && scalar != ":"
        }
    }
}
