import Foundation
import IOKit

/// Reads the internal SSD's health via the NVMe SMART user client.
///
/// macOS exposes NVMe SMART through a CFPlugIn COM interface on the NVMe
/// controller service (the same path `smartmontools` uses). We open the
/// plugin, `QueryInterface` for the SMART interface, then `SMARTReadData`
/// fills the 512-byte NVMe SMART / Health Information log (log page 0x02),
/// which we parse for wear, endurance, spare and temperature.
///
/// Everything is guarded on return codes: a machine without the interface
/// (or an external drive that doesn't pass SMART through) simply yields no
/// drives, and the Disk card degrades to hiding the health block. The COM
/// method offsets are fixed by the IOKit plugin ABI, so a failed
/// `QueryInterface` bails before any method is ever called — no crash.
final class DriveHealthSampler {

    // GUIDs from Apple's IONVMeFamily (IONVMeSMARTLibExternal.h), stable across
    // releases and vendored verbatim by smartmontools.
    private static let userClientTypeID = CFUUIDGetConstantUUIDWithBytes(nil,
        0xAA, 0x0F, 0xA6, 0xF9, 0xC2, 0xD6, 0x45, 0x7F,
        0xB1, 0x0B, 0x59, 0xA1, 0x32, 0x53, 0x29, 0x2F)
    private static let interfaceID = CFUUIDGetConstantUUIDWithBytes(nil,
        0xCC, 0xD1, 0xDB, 0x19, 0xFD, 0x9A, 0x4D, 0xAF,
        0xBF, 0x95, 0x12, 0x45, 0x4B, 0x23, 0x0A, 0xB6)
    // kIOCFPlugInInterfaceID is a header macro Swift can't import; rebuild it
    // from the UUID published in <IOKit/IOCFPlugIn.h>.
    private static let cfPlugInInterfaceID = CFUUIDGetConstantUUIDWithBytes(nil,
        0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4,
        0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F)

    // The NVMe SMART user client hangs off different classes by platform:
    // IOEmbeddedNVMeBlockDevice on Apple Silicon, IONVMeController on Intel.
    // Both carry the same IOCFPlugInTypes entry for the SMART library.
    private static let controllerClasses = ["IOEmbeddedNVMeBlockDevice", "IONVMeController"]

    func sample() -> DriveHealthSnapshot {
        var drives: [DriveHealth] = []
        var seen = Set<UInt64>()
        for className in Self.controllerClasses {
            var iterator = io_iterator_t()
            guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                               IOServiceMatching(className),
                                               &iterator) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }
            while true {
                let service = IOIteratorNext(iterator)
                if service == 0 { break }
                defer { IOObjectRelease(service) }
                guard seen.insert(registryID(service: service)).inserted else { continue }
                if let drive = readNVMe(service: service) { drives.append(drive) }
            }
        }
        return DriveHealthSnapshot(drives: drives)
    }

    // MARK: - NVMe SMART interface

    /// Mirrors the head of `IONVMeSMARTInterface`. The IUnknown slots are typed
    /// as opaque pointers (we never call them through this struct — QueryInterface
    /// runs on the plugin, Release we do call). Field order/alignment matches the
    /// C layout so `SMARTReadData` sits at the correct vtable offset.
    private struct NVMeSMARTInterface {
        var _reserved: UnsafeMutableRawPointer?
        var QueryInterface: UnsafeMutableRawPointer?
        var AddRef: UnsafeMutableRawPointer?
        var Release: (@convention(c) (UnsafeMutableRawPointer?) -> UInt32)?
        var version: UInt16
        var revision: UInt16
        var SMARTReadData: (@convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> IOReturn)?
        var GetLogPage: (@convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UInt32, UInt32) -> IOReturn)?
        var GetIdentifyData: UnsafeMutableRawPointer?
        var GetFieldCounters: UnsafeMutableRawPointer?
    }

    private func readNVMe(service: io_service_t) -> DriveHealth? {
        var pluginInterface: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0
        guard IOCreatePlugInInterfaceForService(service, Self.userClientTypeID,
                                                Self.cfPlugInInterfaceID,
                                                &pluginInterface, &score) == KERN_SUCCESS,
              let plugin = pluginInterface, plugin.pointee != nil else {
            return nil
        }
        defer { IODestroyPlugInInterface(plugin) }

        var interface: UnsafeMutablePointer<UnsafeMutablePointer<NVMeSMARTInterface>?>?
        let query = withUnsafeMutablePointer(to: &interface) { slot -> HRESULT in
            slot.withMemoryRebound(to: (UnsafeMutableRawPointer?).self, capacity: 1) { ref in
                plugin.pointee!.pointee.QueryInterface(
                    UnsafeMutableRawPointer(plugin),
                    CFUUIDGetUUIDBytes(Self.interfaceID),
                    ref)
            }
        }
        guard query == S_OK, let iface = interface, iface.pointee != nil else { return nil }
        defer {
            if let release = iface.pointee!.pointee.Release {
                _ = release(UnsafeMutableRawPointer(iface))
            }
        }

        guard let read = iface.pointee!.pointee.SMARTReadData else { return nil }
        var buffer = [UInt8](repeating: 0, count: 512)
        let result = buffer.withUnsafeMutableBytes { raw in
            read(UnsafeMutableRawPointer(iface), raw.baseAddress)
        }
        guard result == kIOReturnSuccess else { return nil }

        return parse(log: buffer, name: driveName(service: service),
                     id: "nvme:\(registryID(service: service))")
    }

    // MARK: - Parsing the NVMe SMART / Health log

    private func parse(log b: [UInt8], name: String, id: String) -> DriveHealth {
        func u16(_ o: Int) -> UInt16 { UInt16(b[o]) | UInt16(b[o + 1]) << 8 }
        func u64(_ o: Int) -> UInt64 {
            var v: UInt64 = 0
            for i in (0..<8).reversed() { v = v << 8 | UInt64(b[o + i]) }
            return v
        }

        let criticalWarning = b[0]
        let tempKelvin = u16(1)
        let availableSpare = Int(b[3])
        let spareThreshold = Int(b[4])
        let percentUsed = Int(b[5])
        let dataUnitsWritten = u64(48)   // low 64 bits; each unit = 1000 * 512 bytes
        let powerOnHours = u64(128)

        var drive = DriveHealth(id: id, name: name, status: .ok)
        drive.wearPercent = Double(percentUsed)
        drive.availableSparePercent = Double(availableSpare)

        // Composite temperature, Kelvin → °C; 0 (or absurd) means "not reported".
        if tempKelvin > 200, tempKelvin < 400 {
            drive.temperatureC = Double(tempKelvin) - 273.15
        }
        // Data Units Written → bytes, guarding the (extremely unlikely) overflow.
        let (written, overflow) = dataUnitsWritten.multipliedReportingOverflow(by: 512_000)
        drive.dataUnitsWrittenBytes = overflow ? nil : written
        if powerOnHours > 0, powerOnHours < 1_000_000 { drive.powerOnHours = Int(powerOnHours) }

        // Status: any NVMe critical-warning bit, exhausted endurance, or spare
        // under threshold is a failure; nearing either is a warning.
        if criticalWarning != 0 || percentUsed >= 100
            || (spareThreshold > 0 && availableSpare < spareThreshold) {
            drive.status = .failing
        } else if percentUsed >= 80 || availableSpare < 20 {
            drive.status = .warning
        } else {
            drive.status = .ok
        }
        return drive
    }

    // MARK: - Naming

    /// A model name for the drive: the SSD's product name from "Device
    /// Characteristics" (Apple Silicon) or "Model" (Intel), searched through the
    /// device subtree; else the registry-node name; else a generic fallback.
    private func driveName(service: io_service_t) -> String {
        let options = IOOptionBits(kIORegistryIterateRecursively)
        if let characteristics = IORegistryEntrySearchCFProperty(
            service, kIOServicePlane, "Device Characteristics" as CFString,
            kCFAllocatorDefault, options) as? [String: Any],
           let product = characteristics["Product Name"] as? String {
            let trimmed = product.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let model = IORegistryEntrySearchCFProperty(
            service, kIOServicePlane, "Model" as CFString, kCFAllocatorDefault,
            options) as? String {
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        var name = [CChar](repeating: 0, count: 128)
        if IORegistryEntryGetName(service, &name) == KERN_SUCCESS {
            let s = String(cString: name)
            if !s.isEmpty { return s }
        }
        return "Internal SSD"
    }

    private func registryID(service: io_service_t) -> UInt64 {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(service, &id)
        return id
    }
}
