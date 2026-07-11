import Foundation
import IOKit

/// Static device/OS info. Everything but uptime is cached at init.
final class DeviceInfoProvider {

    private let osVersionString: String
    private let buildVersion: String
    private let modelName: String
    private let chipName: String
    private let hostname: String
    private let bootDate: Date?

    init() {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        osVersionString = v.patchVersion > 0
            ? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
            : "\(v.majorVersion).\(v.minorVersion)"
        buildVersion = Self.sysctlString("kern.osversion") ?? ""
        chipName = Self.sysctlString("machdep.cpu.brand_string") ?? ""
        modelName = Self.marketingModelName() ?? Self.sysctlString("hw.model") ?? ""
        hostname = ProcessInfo.processInfo.hostName
        bootDate = Self.bootTime()
    }

    func sample() -> DeviceSnapshot {
        let uptime: TimeInterval
        if let bootDate {
            uptime = max(0, Date().timeIntervalSince(bootDate))
        } else {
            uptime = ProcessInfo.processInfo.systemUptime
        }
        return DeviceSnapshot(
            osVersionString: osVersionString,
            buildVersion: buildVersion,
            modelName: modelName,
            chipName: chipName,
            hostname: hostname,
            bootDate: bootDate,
            uptimeSeconds: uptime
        )
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
    }

    /// On Apple Silicon the marketing name ("MacBook Pro") lives in the
    /// device tree at IODeviceTree:/product, property "product-name".
    private static func marketingModelName() -> String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        guard entry != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(entry) }
        guard let raw = IORegistryEntryCreateCFProperty(
            entry, "product-name" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue(), let data = raw as? Data else { return nil }
        let bytes = data.prefix(while: { $0 != 0 })
        guard !bytes.isEmpty else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func bootTime() -> Date? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.stride
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0, tv.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
    }
}
