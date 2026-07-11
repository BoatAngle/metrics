import Foundation
import IOKit

// MARK: - SMC wire structs

// Mirrors the kernel's SMCParamStruct (80 bytes). The explicit `padding`
// field reproduces C's tail padding of the embedded keyInfo struct so that
// result/status/data8/data32/bytes land at offsets 40/41/42/44/48.
struct SMCVers {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

struct SMCKeyInfo {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

struct SMCKeyData {
    var key: UInt32 = 0
    var vers = SMCVers()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    )
}

// MARK: - Value

public struct SMCValue {
    public let type: String    // FourCC data type, e.g. "flt ", "sp78"
    public let bytes: [UInt8]

    public var doubleValue: Double? {
        func be16(_ a: UInt8, _ b: UInt8) -> UInt16 { UInt16(a) << 8 | UInt16(b) }
        switch type {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8
                | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            let f = Float(bitPattern: bits)
            return f.isFinite ? Double(f) : nil
        case "sp78":
            guard bytes.count >= 2 else { return nil }
            return Double(Int16(bitPattern: be16(bytes[0], bytes[1]))) / 256.0
        case "fpe2":
            guard bytes.count >= 2 else { return nil }
            return Double(be16(bytes[0], bytes[1])) / 4.0
        case "ui8 ", "flag":
            guard bytes.count >= 1 else { return nil }
            return Double(bytes[0])
        case "ui16":
            guard bytes.count >= 2 else { return nil }
            return Double(be16(bytes[0], bytes[1]))
        case "ui32":
            guard bytes.count >= 4 else { return nil }
            let v = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16
                | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
            return Double(v)
        case "si8 ":
            guard bytes.count >= 1 else { return nil }
            return Double(Int8(bitPattern: bytes[0]))
        case "si16":
            guard bytes.count >= 2 else { return nil }
            return Double(Int16(bitPattern: be16(bytes[0], bytes[1])))
        case "ioft":
            // 8-byte little-endian unsigned fixed point, 16 fractional bits
            guard bytes.count >= 8 else { return nil }
            var v: UInt64 = 0
            for i in (0..<8).reversed() { v = v << 8 | UInt64(bytes[i]) }
            return Double(v) / 65536.0
        default:
            return nil
        }
    }
}

// MARK: - Connection

public final class SMCConnection {
    private let connection: io_connect_t

    private static let kSMCHandleYPCEvent: UInt32 = 2
    private static let kSMCReadKey: UInt8 = 5
    private static let kSMCWriteKey: UInt8 = 6
    private static let kSMCGetKeyFromIndex: UInt8 = 8
    private static let kSMCGetKeyInfo: UInt8 = 9

    public init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        var conn: io_connect_t = 0
        let kr = IOServiceOpen(service, mach_task_self_, 0, &conn)
        IOObjectRelease(service)
        guard kr == kIOReturnSuccess, conn != 0 else { return nil }
        connection = conn
    }

    deinit {
        IOServiceClose(connection)
    }

    private func call(_ input: inout SMCKeyData) -> SMCKeyData? {
        var output = SMCKeyData()
        var outSize = MemoryLayout<SMCKeyData>.stride
        let kr = IOConnectCallStructMethod(
            connection, Self.kSMCHandleYPCEvent,
            &input, MemoryLayout<SMCKeyData>.stride,
            &output, &outSize
        )
        guard kr == kIOReturnSuccess, output.result == 0 else { return nil }
        return output
    }

    public func keyCount() -> Int {
        guard let v = readKey("#KEY")?.doubleValue, v > 0 else { return 0 }
        return Int(v)
    }

    public func fanCount() -> Int {
        guard let n = readKey("FNum")?.doubleValue, n > 0 else { return 0 }
        return min(Int(n), 10)
    }

    public func keyName(atIndex index: Int) -> String? {
        guard index >= 0, index <= Int(UInt32.max) else { return nil }
        var input = SMCKeyData()
        input.data8 = Self.kSMCGetKeyFromIndex
        input.data32 = UInt32(index)
        guard let output = call(&input) else { return nil }
        let name = Self.string(fromFourCC: output.key)
        return name.isEmpty ? nil : name
    }

    public func readKey(_ name: String) -> SMCValue? {
        let key = Self.fourCC(name)
        guard key != 0, let info = keyInfo(name) else { return nil }

        var readInput = SMCKeyData()
        readInput.key = key
        readInput.keyInfo.dataSize = UInt32(info.size)
        readInput.data8 = Self.kSMCReadKey
        guard let output = call(&readInput) else { return nil }

        var raw = output.bytes
        let bytes = withUnsafeBytes(of: &raw) { Array($0.prefix(info.size)) }
        return SMCValue(type: info.type, bytes: bytes)
    }

    public func keyInfo(_ name: String) -> (size: Int, type: String)? {
        let key = Self.fourCC(name)
        guard key != 0 else { return nil }

        var input = SMCKeyData()
        input.key = key
        input.data8 = Self.kSMCGetKeyInfo
        guard let info = call(&input) else { return nil }

        let dataSize = Int(info.keyInfo.dataSize)
        guard dataSize > 0, dataSize <= 32 else { return nil }
        return (size: dataSize, type: Self.string(fromFourCC: info.keyInfo.dataType))
    }

    public func writeKey(_ name: String, bytes: [UInt8]) -> Bool {
        let key = Self.fourCC(name)
        guard key != 0 else { return false }
        guard let info = keyInfo(name), bytes.count == info.size else { return false }

        var input = SMCKeyData()
        input.key = key
        input.keyInfo.dataSize = UInt32(bytes.count)
        input.data8 = Self.kSMCWriteKey
        withUnsafeMutableBytes(of: &input.bytes) { dest in
            for (i, b) in bytes.enumerated() where i < 32 {
                dest[i] = b
            }
        }
        return call(&input) != nil
    }

    public static func encode(_ value: Double, as type: String) -> [UInt8]? {
        switch type {
        case "flt ":
            let bits = Float(value).bitPattern
            return [
                UInt8(bits & 0xFF),
                UInt8(bits >> 8 & 0xFF),
                UInt8(bits >> 16 & 0xFF),
                UInt8(bits >> 24 & 0xFF)
            ]
        case "fpe2":
            guard value >= 0, value * 4 <= Double(UInt16.max) else { return nil }
            let v = UInt16(value * 4)
            return [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
        case "ui8 ", "flag":
            guard value >= 0, value <= Double(UInt8.max) else { return nil }
            return [UInt8(value)]
        case "ui16":
            guard value >= 0, value <= Double(UInt16.max) else { return nil }
            let v = UInt16(value)
            return [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
        default:
            return nil
        }
    }

    // MARK: FourCC

    public static func fourCC(_ string: String) -> UInt32 {
        var result: UInt32 = 0
        var count = 0
        for byte in string.utf8 {
            guard count < 4 else { break }
            result = result << 8 | UInt32(byte)
            count += 1
        }
        while count < 4 {
            result = result << 8 | UInt32(UInt8(ascii: " "))
            count += 1
        }
        return result
    }

    public static func string(fromFourCC value: UInt32) -> String {
        let bytes: [UInt8] = [
            UInt8(value >> 24 & 0xFF),
            UInt8(value >> 16 & 0xFF),
            UInt8(value >> 8 & 0xFF),
            UInt8(value & 0xFF)
        ]
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return "" }
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }
}
