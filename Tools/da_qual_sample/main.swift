// da_qual_sample — minimal read-only DiskArbitration qualification FACT sampler.
//
// Scope: this tool only OBSERVES and reports raw facts; it renders NO
// accept/reject verdict (the Helper's own gate in
// Helper/DeviceQualification.swift makes that decision).
//
// Hard constraints honored:
// * No service registration, no LaunchDaemon/SM usage, no XPC.
// * Only reads: DASessionCreate / DADiskCreateFromBSDName /
//   DADiskCopyDescription / DADiskGetBSDName, or stat(2) for dev-stat.
// * Never enumerates disks and never picks a device implicitly: the object
//   must be named explicitly on the command line; no arguments → usage error.
// * Distinguishes: property ABSENT vs WRONG TYPE vs query-layer failure
//   (session / disk object / description each reported separately).
// * Unknown is never flattened to false/""/0 — statuses carry raw values or
//   explicit absent/wrong-type markers.
//
// Modes:
//   da-facts <bsd-name>          real DA sampling (not exercised by the offline checks)
//   dev-stat <device-node-path>  stat(2) facts of a device node (not exercised by the offline checks)
//   offline-fixture <json>       offline mode: feeds a synthetic description
//                                through the SAME extraction/typing pipeline
//
// SPDX-License-Identifier: GPL-2.0-or-later

import Darwin
import DiskArbitration
import Foundation

// MARK: - Fact model

/// One sampled property: status distinguishes absent / wrong-type / present,
/// and a present value keeps its raw rendering.
struct Fact {
    enum Status: String {
        case present
        case absent
        case wrongType
    }
    let key: String
    let status: Status
    /// Raw rendering for .present; the OBSERVED CF type name for .wrongType.
    let detail: String
}

/// Expected CF type per key — from the SDK header annotations
/// (SDKROOT/System/Library/Frameworks/DiskArbitration.framework/Headers/DADisk.h),
/// NOT from runtime observation.
enum Kind: String {
    case string, bool, number, url, uuid, data
}

/// OUTPUT label vs actual lookup key are deliberately SEPARATE: real DA
/// dictionaries are keyed by the full SDK constant strings
/// (kDADiskDescription…Key — e.g. "DAVolumeKind", per Apple's
/// diskarbitrationd/DAInternal.c). Output keeps the short label; lookup
/// always goes through the SDK constant itself — no hand-prepended "DA"
/// prefix, no second mapping.
let sampledKeys: [(label: String, kind: Kind, key: CFString)] = [
    ("VolumeKind", .string, kDADiskDescriptionVolumeKindKey),
    ("VolumeName", .string, kDADiskDescriptionVolumeNameKey),
    ("VolumeType", .string, kDADiskDescriptionVolumeTypeKey),
    ("VolumeUUID", .uuid, kDADiskDescriptionVolumeUUIDKey),
    ("VolumePath", .url, kDADiskDescriptionVolumePathKey),
    ("VolumeMountable", .bool, kDADiskDescriptionVolumeMountableKey),
    ("VolumeNetwork", .bool, kDADiskDescriptionVolumeNetworkKey),
    ("MediaBSDName", .string, kDADiskDescriptionMediaBSDNameKey),
    ("MediaBSDMajor", .number, kDADiskDescriptionMediaBSDMajorKey),
    ("MediaBSDMinor", .number, kDADiskDescriptionMediaBSDMinorKey),
    ("MediaBSDUnit", .number, kDADiskDescriptionMediaBSDUnitKey),
    ("MediaBlockSize", .number, kDADiskDescriptionMediaBlockSizeKey),
    ("MediaContent", .string, kDADiskDescriptionMediaContentKey),
    ("MediaLeaf", .bool, kDADiskDescriptionMediaLeafKey),
    ("MediaWhole", .bool, kDADiskDescriptionMediaWholeKey),
    ("MediaName", .string, kDADiskDescriptionMediaNameKey),
    ("MediaPath", .string, kDADiskDescriptionMediaPathKey),
    ("MediaUUID", .uuid, kDADiskDescriptionMediaUUIDKey),
    ("MediaSize", .number, kDADiskDescriptionMediaSizeKey),
    ("MediaType", .string, kDADiskDescriptionMediaTypeKey),
    ("MediaWritable", .bool, kDADiskDescriptionMediaWritableKey),
    ("MediaEjectable", .bool, kDADiskDescriptionMediaEjectableKey),
    ("MediaRemovable", .bool, kDADiskDescriptionMediaRemovableKey),
    ("MediaEncrypted", .bool, kDADiskDescriptionMediaEncryptedKey),
    ("DevicePath", .string, kDADiskDescriptionDevicePathKey),
    ("DeviceInternal", .bool, kDADiskDescriptionDeviceInternalKey),
    ("DeviceModel", .string, kDADiskDescriptionDeviceModelKey),
    ("DeviceProtocol", .string, kDADiskDescriptionDeviceProtocolKey),
    ("DeviceVendor", .string, kDADiskDescriptionDeviceVendorKey),
    ("DeviceGUID", .data, kDADiskDescriptionDeviceGUIDKey),
    ("BusName", .string, kDADiskDescriptionBusNameKey),
    ("BusPath", .string, kDADiskDescriptionBusPathKey),
]

/// Actual dictionary key string for a table entry (SDK constant value).
func keyString(_ entry: (label: String, kind: Kind, key: CFString)) -> String {
    (entry.key as NSString) as String
}

// MARK: - Description adaptation (shared by the real DA path and the offline fixture path)

/// Adapt a raw DA description object into the lookup dictionary. BOTH the
/// real DA path (DADiskCopyDescription output) and the offline fixture path
/// (constructed CF objects) call THIS function — never separate conversions.
///
/// Returns nil when the object cannot be adapted: not a CFDictionary, or any
/// key is not a CFString. An adapt failure must stay distinct from field
/// absence (an empty-but-valid dictionary adapts fine and reports every field
/// absent); falling back to [:] here would masquerade a broken description as
/// "description ok, all fields absent, exit 0".
///
/// A single WRONG-TYPED VALUE never fails this function: values are adapted
/// as CFTypeRef whatever they are; per-field typing is judged later by
/// extract() (absent / wrongType / present per key).
func adaptDescription(_ raw: CFTypeRef?) -> [String: CFTypeRef]? {
    guard let raw, CFGetTypeID(raw) == CFDictionaryGetTypeID() else { return nil }
    return (raw as? NSDictionary) as? [String: CFTypeRef]
}

// MARK: - Extraction (shared by the real DA path and the offline fixture path)

func typeName(_ value: CFTypeRef) -> String {
    guard let cf = CFCopyTypeIDDescription(CFGetTypeID(value)) else { return "unknown-CF-type" }
    return cf as String
}

func extract(_ source: [String: CFTypeRef]) -> [Fact] {
    var facts: [Fact] = []
    for entry in sampledKeys {
        guard let value = source[keyString(entry)] else {
            facts.append(Fact(key: entry.label, status: .absent, detail: "-"))
            continue
        }
        let key = entry.label
        switch entry.kind {
        case .string:
            if let s = value as? String {
                facts.append(Fact(key: key, status: .present, detail: s))
            } else {
                facts.append(Fact(key: key, status: .wrongType, detail: "expected CFString, got \(typeName(value))"))
            }
        case .bool:
            // STRICT: CFBoolean only — a CFNumber 0/1 must be wrong-type,
            // never flattened into a boolean fact.
            if CFGetTypeID(value) == CFBooleanGetTypeID(), let b = value as? Bool {
                facts.append(Fact(key: key, status: .present, detail: b ? "true" : "false"))
            } else {
                facts.append(Fact(key: key, status: .wrongType, detail: "expected CFBoolean, got \(typeName(value))"))
            }
        case .number:
            // STRICT: CFNumber only — CFBoolean is not a number fact here.
            if CFGetTypeID(value) != CFBooleanGetTypeID(), let n = value as? NSNumber {
                facts.append(Fact(key: key, status: .present, detail: n.stringValue))
            } else {
                facts.append(Fact(key: key, status: .wrongType, detail: "expected CFNumber, got \(typeName(value))"))
            }
        case .url:
            if let u = value as? URL {
                facts.append(Fact(key: key, status: .present, detail: u.path))
            } else {
                facts.append(Fact(key: key, status: .wrongType, detail: "expected CFURL, got \(typeName(value))"))
            }
        case .uuid:
            if CFGetTypeID(value) == CFUUIDGetTypeID(),
               let s = CFUUIDCreateString(nil, unsafeBitCast(value, to: CFUUID.self)) as String? {
                facts.append(Fact(key: key, status: .present, detail: s))
            } else {
                facts.append(Fact(key: key, status: .wrongType, detail: "expected CFUUID, got \(typeName(value))"))
            }
        case .data:
            if let d = value as? Data {
                facts.append(Fact(key: key, status: .present,
                                  detail: d.map { String(format: "%02x", $0) }.joined()))
            } else {
                facts.append(Fact(key: key, status: .wrongType, detail: "expected CFData, got \(typeName(value))"))
            }
        }
    }
    return facts
}

// MARK: - Reporting

func reportHeader(mode: String, object: String, layers: (session: Bool, disk: Bool, description: Bool)) {
    print("mode=\(mode)")
    print("object=\(object)")
    print("uid=\(getuid()) euid=\(geteuid())")
    print("session=\(layers.session ? "ok" : "missing")")
    print("disk=\(layers.disk ? "ok" : "missing")")
    print("description=\(layers.description ? "ok" : "missing")")
    print("RAW-FACTS-ONLY no qualification verdict (this tool reports facts only)")
}

func report(_ facts: [Fact]) {
    for f in facts {
        print("\(f.key)\t\(f.status.rawValue)\t\(f.detail)")
    }
}

// MARK: - Real DA mode (not exercised by the offline checks)

func runDAFacts(_ bsdName: String) -> Int32 {
    guard let session = DASessionCreate(nil) else {
        reportHeader(mode: "da-facts", object: bsdName, layers: (false, false, false))
        return 4
    }
    guard let disk = DADiskCreateFromBSDName(nil, session, bsdName) else {
        reportHeader(mode: "da-facts", object: bsdName, layers: (true, false, false))
        return 4
    }
    let echoed = DADiskGetBSDName(disk).map { String(cString: $0) } ?? "<null>"
    guard let desc = DADiskCopyDescription(disk) else {
        reportHeader(mode: "da-facts", object: bsdName, layers: (true, true, false))
        print("echoBSDName=\(echoed)")
        return 4
    }
    reportHeader(mode: "da-facts", object: bsdName, layers: (true, true, true))
    print("echoBSDName=\(echoed)")
    // SHARED adaptation — same function the offline fixture path uses.
    guard let source = adaptDescription(desc) else {
        print("description-adapt=failed")
        print("RAW-FACTS-ONLY no qualification verdict (this tool reports facts only)")
        return 5
    }
    print("description-adapt=ok")
    report(extract(source))
    return 0
}

// MARK: - dev-stat mode (not exercised by the offline checks)

func runDevStat(_ path: String) -> Int32 {
    var st = stat()
    guard stat(path, &st) == 0 else {
        print("mode=dev-stat")
        print("object=\(path)")
        print("stat=failed errno=\(errno) \(String(cString: strerror(errno)))")
        return 4
    }
    let ft = st.st_mode & S_IFMT
    let typeDesc = ft == S_IFCHR ? "S_IFCHR" : (ft == S_IFBLK ? "S_IFBLK" : "other")
    print("mode=dev-stat")
    print("object=\(path)")
    print("uid=\(getuid()) euid=\(geteuid())")
    print("stat=ok")
    print("fileType\t\(typeDesc)")
    print("st_rdev\t\(st.st_rdev)")
    // BSD makedev layout on darwin: major in the high byte, low 24 bits minor
    // (sys/types.h makedev/major/minor macros; spelled out because Swift does
    // not import the macros).
    let majorVal = Int32((st.st_rdev >> 24) & 0xff)
    let minorVal = Int32(st.st_rdev & 0xffffff)
    print("major\t\(majorVal)")
    print("minor\t\(minorVal)")
    print("st_uid\t\(st.st_uid)")
    print("st_gid\t\(st.st_gid)")
    print("st_mode\t0\(String(st.st_mode & 0o7777, radix: 8))")
    print("st_size\t\(st.st_size)")
    print("RAW-FACTS-ONLY no qualification verdict (this tool reports facts only)")
    return 0
}

// MARK: - Offline fixture mode (the only mode exercised by the offline checks)

/// Fixture JSON schema (SYNTHETIC probe inputs for the extraction layer —
/// manual fault injection, NOT real-system samples):
/// {
///   "session": "ok"|"missing", "disk": ..., "description": ...,
///   "echoBSDName": "diskXsY",                       // optional
///   "values": { "<DAKey>": {"type": "string|bool|number|url|uuid|data",
///                            "value": ...}, ... }    // type may deliberately
///                                                  // mismatch the SDK expectation
///   "descriptionObject": "non-string-key-dict"|"non-dictionary"  // mutually
///                                                  // exclusive with "values":
///                                                  // builds a REAL CF object the
///                                                  // SHARED adaptation must reject
/// }
func runOfflineFixture(_ path: String) -> Int32 {
    guard let data = FileManager.default.contents(atPath: path) else {
        FileHandle.standardError.write("fixture not readable: \(path)\n".data(using: .utf8)!)
        return 3
    }
    guard let obj = try? JSONSerialization.jsonObject(with: data),
          let root = obj as? [String: Any] else {
        FileHandle.standardError.write("fixture not valid JSON object: \(path)\n".data(using: .utf8)!)
        return 3
    }
    func layer(_ name: String) -> Bool { (root[name] as? String) == "ok" }
    let sessionOK = layer("session"), diskOK = layer("disk"), descOK = layer("description")
    reportHeader(mode: "offline-fixture", object: path,
                 layers: (sessionOK, diskOK, descOK))
    if let echo = root["echoBSDName"] as? String { print("echoBSDName=\(echo)") }
    print("NOTE=fixture input (synthetic fault/typed probes; NOT a real DA sample)")
    guard sessionOK, diskOK, descOK else { return 4 }
    // Build REAL CF values (CFString/CFBoolean/CFNumber/CFURL/CFUUID/CFData)
    // so extraction is genuine. Two key modes:
    //  * "labels" (default): fixture values are keyed by the table LABEL;
    //    the tool translates to the real SDK key string via the SAME table
    //    used for lookup (single mapping, built from SDK constants).
    //  * "verbatim": fixture values are keyed by the REAL dictionary keys
    //    already (what a real DA description looks like); the tool copies
    //    them verbatim, so the lookup by SDK key constants is exercised
    //    against real-keyed dictionaries.
    // Illegal fixtures are INPUT ERRORS (exit 3, field named) — never
    // silently coerced, defaulted, or dropped to absent. A `values` key of
    // the wrong JSON shape is likewise an input error, never "no values".
    let keyMode = (root["keyMode"] as? String) ?? "labels"
    guard keyMode == "labels" || keyMode == "verbatim" else {
        FileHandle.standardError.write("fixture keyMode invalid: \(keyMode)\n".data(using: .utf8)!)
        return 3
    }
    // "descriptionObject" (mutually exclusive with "values") names a
    // SYNTHETIC description OBJECT to construct (manual fault injection for
    // the ADAPTATION layer). The switch below only selects WHICH real CF
    // object to build; the failure verdict itself is produced by the SHARED
    // adaptDescription() running on that object — never by printing a canned
    // "failed" result from the fixture switch.
    let hasValuesKey = root.keys.contains("values")
    let descriptionObject = root["descriptionObject"]
    if hasValuesKey, descriptionObject != nil {
        FileHandle.standardError.write("fixture cannot set both values and descriptionObject\n".data(using: .utf8)!)
        return 3
    }
    if hasValuesKey, root["values"] as? [String: [String: Any]] == nil {
        FileHandle.standardError.write("fixture values must be an object of per-key specs\n".data(using: .utf8)!)
        return 3
    }
    guard descriptionObject == nil || descriptionObject is String else {
        FileHandle.standardError.write("fixture descriptionObject must be a string\n".data(using: .utf8)!)
        return 3
    }
    // Accumulate into a REAL CF dictionary (like a DA description object),
    // then run it through the SAME adaptation as the real DA path.
    let labelToEntry = Dictionary(uniqueKeysWithValues: sampledKeys.map { ($0.label, $0) })
    let realKeyToEntry = Dictionary(uniqueKeysWithValues: sampledKeys.map { (keyString($0), $0) })
    let rawObject = NSMutableDictionary()
    if let values = root["values"] as? [String: [String: Any]] {
        for (fixtureKey, spec) in values {
            let entry: (label: String, kind: Kind, key: CFString)
            switch keyMode {
            case "verbatim":
                guard let e = realKeyToEntry[fixtureKey] else {
                    FileHandle.standardError.write("fixture value key not a known real DA key: \(fixtureKey)\n".data(using: .utf8)!)
                    return 3
                }
                entry = e
            default:
                guard let e = labelToEntry[fixtureKey] else {
                    FileHandle.standardError.write("fixture value key not a known label: \(fixtureKey)\n".data(using: .utf8)!)
                    return 3
                }
                entry = e
            }
            guard let t = spec["type"] as? String else {
                FileHandle.standardError.write("fixture entry missing type: \(fixtureKey)\n".data(using: .utf8)!)
                return 3
            }
            let dictKey = keyMode == "verbatim" ? fixtureKey : keyString(entry)
            // STRICT value construction per declared type — mismatch is an
            // input error naming the field, except where the probe is
            // explicitly about a type that disagrees with the SDK KIND
            // (that is the wrong-type probe: value type vs entry.kind).
            switch t {
            case "string":
                guard let str = spec["value"] as? String else {
                    FileHandle.standardError.write("fixture[\(fixtureKey)] type=string needs a JSON string\n".data(using: .utf8)!)
                    return 3
                }
                rawObject.setObject(str as NSString, forKey: dictKey as NSString)
            case "bool":
                guard let b = spec["value"] as? Bool else {
                    FileHandle.standardError.write("fixture[\(fixtureKey)] type=bool needs a JSON bool (missing/illegal never becomes false)\n".data(using: .utf8)!)
                    return 3
                }
                // CFBoolean (NOT a bridged NSNumber) so strict bool typing
                // in extract() sees a genuine CFBoolean.
                let cfBool: CFBoolean = b ? kCFBooleanTrue : kCFBooleanFalse
                rawObject.setObject(cfBool, forKey: dictKey as NSString)
            case "number":
                guard let n = spec["value"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else {
                    FileHandle.standardError.write("fixture[\(fixtureKey)] type=number needs a JSON number (bool is not a number)\n".data(using: .utf8)!)
                    return 3
                }
                rawObject.setObject(n, forKey: dictKey as NSString)
            case "url":
                guard let str = spec["value"] as? String,
                      let u = CFURLCreateWithFileSystemPath(nil, str as CFString,
                                                            CFURLPathStyle.cfurlposixPathStyle, true) else {
                    FileHandle.standardError.write("fixture[\(fixtureKey)] type=url needs a JSON string path\n".data(using: .utf8)!)
                    return 3
                }
                rawObject.setObject(u, forKey: dictKey as NSString)
            case "uuid":
                guard let str = spec["value"] as? String,
                      let u = CFUUIDCreateFromString(nil, str as CFString) else {
                    FileHandle.standardError.write("fixture[\(fixtureKey)] type=uuid needs a parseable UUID string\n".data(using: .utf8)!)
                    return 3
                }
                rawObject.setObject(u, forKey: dictKey as NSString)
            case "data":
                guard let str = spec["value"] as? String, let d = hexData(str) else {
                    FileHandle.standardError.write("fixture[\(fixtureKey)] type=data needs even-length hex\n".data(using: .utf8)!)
                    return 3
                }
                rawObject.setObject(d as NSData, forKey: dictKey as NSString)
            default:
                FileHandle.standardError.write("fixture[\(fixtureKey)] unknown type: \(t)\n".data(using: .utf8)!)
                return 3
            }
        }
    } else if let kind = descriptionObject as? String {
        // Construct the SYNTHETIC description OBJECT the fixture names. Both
        // alternatives are real CF objects that adaptation must reject:
        //  * non-string-key-dict: a CFDictionary whose key is a CFNumber —
        //    exactly the class of object the key adaptation refuses;
        //  * non-dictionary: a CFString where a description dictionary is
        //    expected.
        // The switch only selects which object to build; the failure verdict
        // comes from the SHARED adaptDescription below, never from here.
        switch kind {
        case "non-string-key-dict":
            rawObject.setObject("value" as NSString, forKey: NSNumber(value: 42))
        case "non-dictionary":
            return adaptAndReport("not-a-dictionary" as CFString)
        default:
            FileHandle.standardError.write("fixture descriptionObject unknown kind: \(kind)\n".data(using: .utf8)!)
            return 3
        }
    }
    return adaptAndReport(rawObject)
}

/// Shared offline tail: run the SHARED adaptation (the same function the real
/// DA path calls) and report through the same extraction. Adapt failure →
/// exit 5; success → per-field facts, exit 0.
func adaptAndReport(_ rawObject: CFTypeRef) -> Int32 {
    guard let source = adaptDescription(rawObject) else {
        print("description-adapt=failed")
        print("RAW-FACTS-ONLY no qualification verdict (this tool reports facts only)")
        return 5
    }
    print("description-adapt=ok")
    report(extract(source))
    return 0
}

/// Even-length lowercase hex string -> Data; nil on any malformed input.
/// Callers treat nil as an INPUT ERROR (never an empty/default value).
func hexData(_ hex: String?) -> Data? {
    guard let hex, hex.count % 2 == 0 else { return nil }
    var bytes: [UInt8] = []
    var i = hex.startIndex
    while i < hex.endIndex {
        let j = hex.index(i, offsetBy: 2)
        guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
        bytes.append(b)
        i = j
    }
    return Data(bytes)
}

// MARK: - Entry

@main
enum DAQualSample {
    static func main() {
        let args = CommandLine.arguments
        guard args.count == 3 else {
            FileHandle.standardError.write(
                "usage: da_qual_sample da-facts <bsd-name> | dev-stat <device-node-path> | offline-fixture <json>\n"
                    .data(using: .utf8)!)
            exit(2)   // no implicit device selection — ever
        }
        switch args[1] {
        case "da-facts": exit(runDAFacts(args[2]))
        case "dev-stat": exit(runDevStat(args[2]))
        case "offline-fixture": exit(runOfflineFixture(args[2]))
        default:
            FileHandle.standardError.write("unknown mode: \(args[1])\n".data(using: .utf8)!)
            exit(2)
        }
    }
}
