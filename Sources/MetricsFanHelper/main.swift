import Foundation
import SMCCore

// Bump on any behavior change so the app can prompt to reinstall an older
// installed copy. Must match FanControl.expectedHelperVersion.
let helperVersion = 3

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(code)
}

func requireRoot() {
    guard geteuid() == 0 else {
        fail("must run as root (install via Metrics settings)", code: 2)
    }
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    fail("usage: metrics-fan-helper version | status | set <index> <rpm> | auto <index|all> | chargelimit <0|1>", code: 1)
}

// Answerable without touching the SMC (and without root).
if args[1] == "version" {
    print(helperVersion)
    exit(0)
}

guard let smc = SMCConnection() else {
    fail("cannot open SMC connection", code: 1)
}

func parseIndex(_ raw: String, count: Int) -> Int {
    guard let i = Int(raw), i >= 0, i < count else {
        fail("invalid fan index '\(raw)' (have \(count) fans)", code: 1)
    }
    return i
}

func writeValue(_ key: String, _ value: Double) -> Bool {
    guard let info = smc.keyInfo(key),
          let bytes = SMCConnection.encode(value, as: info.type) else { return false }
    return smc.writeKey(key, bytes: bytes)
}

// Per-fan mode key. Apple Silicon uses lowercase "F<i>md"; older Macs use
// uppercase "F<i>Md". Whichever the SMC actually exposes is the one to write.
func modeKey(_ index: Int) -> String? {
    for candidate in ["F\(index)Md", "F\(index)md"] where smc.keyInfo(candidate) != nil {
        return candidate
    }
    return nil
}

// Intel fallback: manual-control bitmask.
func setForcedBit(_ index: Int, on: Bool) -> Bool {
    guard let v = smc.readKey("FS! ")?.doubleValue else { return false }
    var mask = UInt16(v)
    if on {
        mask |= UInt16(1) << index
    } else {
        mask &= ~(UInt16(1) << index)
    }
    return smc.writeKey("FS! ", bytes: [UInt8(mask >> 8 & 0xFF), UInt8(mask & 0xFF)])
}

func setMode(_ index: Int, manual: Bool) -> Bool {
    if let key = modeKey(index) {
        return writeValue(key, manual ? 1 : 0)
    }
    return setForcedBit(index, on: manual)
}

let command = args[1]
switch command {
case "status":
    let count = smc.fanCount()
    for i in 0..<count {
        let actual = smc.readKey("F\(i)Ac")?.doubleValue ?? 0
        let minRPM = smc.readKey("F\(i)Mn")?.doubleValue ?? 0
        let maxRPM = smc.readKey("F\(i)Mx")?.doubleValue ?? 0
        let mode: String
        if let key = modeKey(i), let md = smc.readKey(key)?.doubleValue {
            mode = md > 0 ? "manual" : "auto"
        } else {
            mode = "auto"
        }
        print("\(i) actual=\(Int(actual)) min=\(Int(minRPM)) max=\(Int(maxRPM)) mode=\(mode)")
    }
    // Battery charge-limit state (SMC "CHWA": 1 = cap ~80%, 0 = normal).
    if smc.keyInfo("CHWA") != nil, let chwa = smc.readKey("CHWA")?.doubleValue {
        print("chargelimit chwa=\(Int(chwa))")
    } else {
        print("chargelimit chwa=unsupported")
    }
    exit(0)

case "set":
    requireRoot()
    guard args.count == 4 else {
        fail("usage: metrics-fan-helper set <index> <rpm>", code: 1)
    }
    let count = smc.fanCount()
    guard count > 0 else { fail("no fans found", code: 1) }
    let index = parseIndex(args[2], count: count)
    guard let rpm = Double(args[3]), rpm.isFinite, rpm >= 0 else {
        fail("invalid rpm '\(args[3])'", code: 1)
    }
    guard let minRPM = smc.readKey("F\(index)Mn")?.doubleValue,
          let maxRPM = smc.readKey("F\(index)Mx")?.doubleValue,
          minRPM >= 0, maxRPM > minRPM else {
        fail("fan \(index) min/max unreadable; refusing to set speed", code: 3)
    }
    let clamped = min(max(rpm, minRPM), maxRPM)
    guard setMode(index, manual: true) else {
        fail("failed to switch fan \(index) to manual mode", code: 1)
    }
    guard writeValue("F\(index)Tg", clamped) else {
        fail("failed to write target speed for fan \(index)", code: 1)
    }
    print("ok \(Int(clamped))")
    exit(0)

case "auto":
    requireRoot()
    guard args.count == 3 else {
        fail("usage: metrics-fan-helper auto <index|all>", code: 1)
    }
    let count = smc.fanCount()
    guard count > 0 else { fail("no fans found", code: 1) }
    if args[2] == "all" {
        var ok = true
        for i in 0..<count where !setMode(i, manual: false) {
            ok = false
        }
        guard ok else { fail("failed to restore automatic control on all fans", code: 1) }
    } else {
        let index = parseIndex(args[2], count: count)
        guard setMode(index, manual: false) else {
            fail("failed to restore automatic control on fan \(index)", code: 1)
        }
    }
    print("ok")
    exit(0)

case "chargelimit":
    requireRoot()
    guard args.count == 3, let raw = Int(args[2]), raw == 0 || raw == 1 else {
        fail("usage: metrics-fan-helper chargelimit <0|1>", code: 1)
    }
    guard smc.keyInfo("CHWA") != nil else {
        fail("CHWA key not present on this Mac", code: 3)
    }
    guard writeValue("CHWA", Double(raw)) else {
        fail("failed to write CHWA", code: 1)
    }
    print("ok \(raw)")
    exit(0)

default:
    fail("unknown command '\(command)'", code: 1)
}
