// Offline driver for Shared/DevicePathRules.swift (compile with that file).
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

@main
struct DevicePathRulesMain {
    static func main() {
        let cases: [(String, Bool, String?)] = [
            ("/dev/disk4s1", true, "/dev/disk4s1"),
            ("/dev/rdisk4s1", true, "/dev/disk4s1"),
            ("/dev/disk4", true, "/dev/disk4"),
            ("/dev/rdisk4", true, "/dev/disk4"),
            ("/dev/disk4s1/../disk0", false, nil),
            ("/Volumes/x", false, nil),
            ("/dev/disk", false, nil),
        ]
        var failed = 0
        for (path, ok, key) in cases {
            let allowed = DevicePathRules.isAllowed(path)
            let canon = DevicePathRules.canonicalKey(path)
            if allowed != ok || canon != key {
                fputs("FAIL \(path): allowed=\(allowed) want \(ok); canon=\(String(describing: canon)) want \(String(describing: key))\n",
                      stderr)
                failed += 1
            }
        }
        if failed != 0 {
            fputs("DevicePathRules: \(failed) failure(s)\n", stderr)
            exit(1)
        }
        print("DevicePathRules: ALL PASS (\(cases.count) cases)")
    }
}
