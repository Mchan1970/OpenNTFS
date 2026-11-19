// OpenNTFS - device qualification gate.
// SPDX-License-Identifier: GPL-2.0-or-later
//
// The Helper must independently decide whether the requested BSD device is a
// maintainable NTFS volume BEFORE any node modification or journal write.
// This file holds:
//   * a PURE judgment function over DA facts + node stats (fully testable
//     offline; no DA session, no syscall), and
//   * a minimal read-only DiskArbitration collector that produces those
//     facts with the SAME SDK-constant keys and strict typing approach as
//     Tools/da_qual_sample/main.swift (a facts-only sampling tool, not a framework).
//
// Judgment inputs distinguish, per field: present(value) / absent /
// wrongType(observed type) — plus ONE separate query-failure state for the
// whole collection. Unknown is NEVER flattened into a default.
//
// The six conditions (derived from what DiskArbitration reports for an
// openntfs volume that the Helper may safely hand to the user):
//   1. the DA collection itself succeeded (query failure rejects);
//   2. MediaBSDName is present and equals the REQUESTED BSD name;
//   3. VolumeKind is present with the exact value "openntfs" (the FSKit
//      module's own kind; the raw "ntfs" value, absent and wrongType reject);
//   4. MediaLeaf is present and true;
//   5. VolumePath is absent (a present mount path or a wrong-typed one
//      rejects — mounted or unknown both refuse);
//   6. every requested node's stat matches the DA identity: block-form
//      (/dev/disk…) nodes must be S_IFBLK and raw-form (/dev/rdisk…)
//      nodes S_IFCHR, and each node's st_rdev major/minor must equal the DA
//      MediaBSDMajor/MediaMinor. Topology is NOT inferred from name
//      prefixes; the block/raw FORM check is device-node pairing syntax
//      only.
// No other conditions are added here.

import Darwin
import DiskArbitration
import Foundation

// MARK: - Fact model

/// One DA field: present (with its raw string rendering), absent, or
/// present with the wrong CF type (observed type name recorded).
enum DAFieldValue: Equatable {
    case present(String)
    case absent
    case wrongType(String)
}

/// Exactly the six fields the gate reads. Nothing else is collected.
struct DeviceDAFacts: Equatable {
    var volumeKind: DAFieldValue
    var volumePath: DAFieldValue
    var mediaBSDName: DAFieldValue
    var mediaBSDMajor: DAFieldValue
    var mediaBSDMinor: DAFieldValue
    var mediaLeaf: DAFieldValue
}

/// Result of collecting facts for one BSD name. `.queryFailed` covers
/// session/disk-object/description failures — distinct from any per-field
/// state, and never representable as "all fields absent".
enum DACollectionResult: Equatable {
    case facts(DeviceDAFacts)
    case queryFailed(String)
}

// MARK: - Pure judgment

enum DeviceQualification {

    enum Decision: Equatable {
        case grant
        case reject(String)
    }

    /// The ONLY accept/reject function. Pure: no I/O, no DA, no syscalls.
    /// - Parameters:
    ///   - requestedBSDName: the BSD name derived from the canonical request
    ///     (e.g. "disk7s1"), WITHOUT any "/dev/" prefix.
    ///   - collection: the collected DA facts or the query failure.
    ///   - nodeStats: stat results for the requested node paths, keyed by
    ///     full path. A path missing here simply has no stat; condition 6
    ///     judges the ones present.
    static func judge(requestedBSDName: String,
                      collection: DACollectionResult,
                      nodeStats: [String: stat?]) -> Decision {
        // 1. the collection itself must have succeeded.
        guard case .facts(let facts) = collection else {
            if case .queryFailed(let why) = collection {
                return .reject("DA query failed: \(why)")
            }
            return .reject("DA query failed: unknown collection state")
        }
        // 2. BSD name binding.
        if case .present(let name) = facts.mediaBSDName {
            guard name == requestedBSDName else {
                return .reject("DA BSD name \(name) != requested \(requestedBSDName)")
            }
        } else if case .wrongType(let t) = facts.mediaBSDName {
            return .reject("DA BSD name wrong type (\(t))")
        } else {
            return .reject("DA BSD name absent")
        }
        // 3. VolumeKind: exactly the FSKit module's own kind. The raw
        //    "ntfs" kind seen on un-managed volumes REJECTS — maintenance is
        //    only for volumes this system's module claims.
        switch facts.volumeKind {
        case .present(let kind):
            guard kind == "openntfs" else {
                return .reject("VolumeKind \(kind) is not openntfs")
            }
        case .wrongType(let t):
            return .reject("VolumeKind wrong type (\(t))")
        case .absent:
            return .reject("VolumeKind absent (DA has not probed this volume)")
        }
        // 4. Leaf media (partition or whole-disk-without-partition-map).
        switch facts.mediaLeaf {
        case .present(let v):
            guard v == "true" else {
                return .reject("MediaLeaf=\(v) (not a leaf medium)")
            }
        case .wrongType(let t):
            return .reject("MediaLeaf wrong type (\(t))")
        case .absent:
            return .reject("MediaLeaf absent")
        }
        // 5. Not mounted (and not unknown-but-mountable here: a wrong-typed
        //    VolumePath is just as refusing as a present one).
        switch facts.volumePath {
        case .absent:
            break
        case .present(let p):
            return .reject("VolumePath present (\(p)): volume is mounted")
        case .wrongType(let t):
            return .reject("VolumePath wrong type (\(t))")
        }
        // 6. Node identity: DA major/minor must be present numbers, and
        //    every requested node's st_rdev must decompose to them, with
        //    the block/raw form's file type.
        guard case .present(let majorStr) = facts.mediaBSDMajor,
              let daMajor = Int32(majorStr) else {
            if case .present(let rawMajor) = facts.mediaBSDMajor {
                return .reject("MediaBSDMajor unparseable: \(rawMajor)")
            }
            return .reject("MediaBSDMajor absent/wrongType")
        }
        guard case .present(let minorStr) = facts.mediaBSDMinor,
              let daMinor = Int32(minorStr) else {
            if case .present(let rawMinor) = facts.mediaBSDMinor {
                return .reject("MediaBSDMinor unparseable: \(rawMinor)")
            }
            return .reject("MediaBSDMinor absent/wrongType")
        }
        for (path, maybeStat) in nodeStats {
            guard let st = maybeStat else {
                return .reject("node \(path) has no stat")
            }
            let ft = st.st_mode & S_IFMT
            if path.hasPrefix("/dev/rdisk") {
                guard ft == S_IFCHR else {
                    return .reject("raw node \(path) is not a character device")
                }
            } else if path.hasPrefix("/dev/disk") {
                guard ft == S_IFBLK else {
                    return .reject("block node \(path) is not a block device")
                }
            } else {
                return .reject("node path \(path) is not a /dev/disk… or /dev/rdisk… form")
            }
            // Darwin makedev layout: major in the high byte, low 24 bits
            // minor (sys/types.h; same spelling as da_qual_sample dev-stat).
            let major = Int32((st.st_rdev >> 24) & 0xff)
            let minor = Int32(st.st_rdev & 0xffffff)
            guard major == daMajor, minor == daMinor else {
                return .reject("node \(path) major/minor (\(major)/\(minor)) != DA (\(daMajor)/\(daMinor))")
            }
        }
        return .grant
    }
}

// MARK: - Real DA collector (read-only)

enum DAFactCollector {

    /// Minimal read-only collection: DASessionCreate →
    /// DADiskCreateFromBSDName → DADiskCopyDescription → strict per-field
    /// extraction of EXACTLY the six gate fields. Lookup goes through the
    /// SDK constant strings themselves (kDADiskDescription…Key), never a
    /// hand-built key. No enumeration, no verdicts, nothing written.
    static func collect(bsdName: String) -> DACollectionResult {
        guard let session = DASessionCreate(nil) else {
            return .queryFailed("DASessionCreate failed")
        }
        guard let disk = DADiskCreateFromBSDName(nil, session, bsdName) else {
            return .queryFailed("DADiskCreateFromBSDName(\(bsdName)) failed")
        }
        guard let desc = DADiskCopyDescription(disk) else {
            return .queryFailed("DADiskCopyDescription failed")
        }
        guard CFGetTypeID(desc) == CFDictionaryGetTypeID(),
              let dict = desc as? NSDictionary as? [String: CFTypeRef] else {
            return .queryFailed("DA description is not a dictionary")
        }
        // VolumePath is the one CFURL field among the six.
        let volumePath: DAFieldValue
        if let v = dict[kDADiskDescriptionVolumePathKey as String] {
            if let url = v as? URL {
                volumePath = .present(url.path)
            } else {
                let t = CFCopyTypeIDDescription(CFGetTypeID(v)) as String? ?? "unknown"
                volumePath = .wrongType(t)
            }
        } else {
            volumePath = .absent
        }
        func stringField(_ key: CFString) -> DAFieldValue {
            guard let v = dict[key as String] else { return .absent }
            if let s = v as? String { return .present(s) }
            let t = CFCopyTypeIDDescription(CFGetTypeID(v)) as String? ?? "unknown"
            return .wrongType(t)
        }
        func boolField(_ key: CFString) -> DAFieldValue {
            guard let v = dict[key as String] else { return .absent }
            if CFGetTypeID(v) == CFBooleanGetTypeID(), let b = v as? Bool {
                return .present(b ? "true" : "false")
            }
            let t = CFCopyTypeIDDescription(CFGetTypeID(v)) as String? ?? "unknown"
            return .wrongType(t)
        }
        func numberField(_ key: CFString) -> DAFieldValue {
            guard let v = dict[key as String] else { return .absent }
            if CFGetTypeID(v) != CFBooleanGetTypeID(), let n = v as? NSNumber {
                return .present(n.stringValue)
            }
            let t = CFCopyTypeIDDescription(CFGetTypeID(v)) as String? ?? "unknown"
            return .wrongType(t)
        }
        return .facts(DeviceDAFacts(
            volumeKind: stringField(kDADiskDescriptionVolumeKindKey),
            volumePath: volumePath,
            mediaBSDName: stringField(kDADiskDescriptionMediaBSDNameKey),
            mediaBSDMajor: numberField(kDADiskDescriptionMediaBSDMajorKey),
            mediaBSDMinor: numberField(kDADiskDescriptionMediaBSDMinorKey),
            mediaLeaf: boolField(kDADiskDescriptionMediaLeafKey)))
    }
}
