import Foundation
import IOKit
import IOKit.ps

final class BatterySampler {

    func sample() -> BatterySnapshot {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() else {
            return .empty
        }
        let sources = list as [CFTypeRef]

        var batteryDesc: [String: Any]?
        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any] else { continue }
            if desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType {
                batteryDesc = desc
                break
            }
        }
        guard let desc = batteryDesc else { return .empty }

        var snap = BatterySnapshot()
        snap.hasBattery = true

        if let current = intValue(desc[kIOPSCurrentCapacityKey]),
           let max = intValue(desc[kIOPSMaxCapacityKey]), max > 0 {
            snap.percent = Double(current) / Double(max) * 100.0
        }
        snap.isCharging = (desc[kIOPSIsChargingKey] as? Bool) ?? false
        snap.isPluggedIn = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue

        let timeKey = snap.isCharging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
        if let minutes = intValue(desc[timeKey]), minutes >= 0 {
            snap.timeRemainingMinutes = minutes
        }

        applyRegistryDetail(to: &snap)

        if snap.isPluggedIn {
            snap.adapterDescription = adapterDescription()
        }
        return snap
    }

    private func applyRegistryDetail(to snap: inout BatterySnapshot) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }

        var propsRef: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = propsRef?.takeRetainedValue() as? [String: Any] else { return }

        if let mV = intValue(props["Voltage"]), mV > 0 {
            snap.voltage = Double(mV) / 1000.0
        }
        if let raw = props["Amperage"] as? NSNumber {
            // Apple Silicon reports Amperage as a 64-bit two's-complement value;
            // some machines wrap a signed 32-bit value into it instead.
            var mA = raw.int64Value
            if mA > 20000 || mA < -20000 {
                mA = Int64(Int32(truncatingIfNeeded: mA))
            }
            if mA >= -20000 && mA <= 20000 {
                snap.amperage = Double(mA) / 1000.0
            }
        }
        if let volts = snap.voltage, let amps = snap.amperage {
            snap.watts = volts * amps
        }
        if let cycles = intValue(props["CycleCount"]) {
            snap.cycleCount = cycles
        }

        // Newer macOS nests the mAh figures inside "BatteryData" instead of
        // publishing them at the top level.
        let batteryData = props["BatteryData"] as? [String: Any]

        var design = intValue(props["DesignCapacity"])
        if design == nil, let data = batteryData {
            design = intValue(data["DesignCapacity"])
        }
        snap.designCapacitymAh = design

        // "MaxCapacity" is a percent (100) on Apple Silicon; only trust it as a
        // fallback when it is plausibly a real mAh figure.
        var rawMax = intValue(props["AppleRawMaxCapacity"])
        if rawMax == nil, let data = batteryData {
            rawMax = intValue(data["FullChargeCapacity"])
        }
        if rawMax == nil, let fallback = intValue(props["MaxCapacity"]), fallback > 200 {
            rawMax = fallback
        }
        snap.maxCapacitymAh = rawMax
        if let rawMax, let design, design > 0 {
            snap.healthPercent = Double(rawMax) / Double(design) * 100.0
        }

        var centiDegrees = intValue(props["Temperature"])
        if centiDegrees == nil {
            centiDegrees = packTemperatureCentiDegrees()
        }
        if let centiDegrees, centiDegrees > 0 {
            snap.temperatureC = Double(centiDegrees) / 100.0
        }
    }

    // Newer macOS publishes the temperature inside the pack node's
    // "BatteryData" dictionary instead of on the AppleSmartBattery node.
    private func packTemperatureCentiDegrees() -> Int? {
        let pack = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBatteryPack"))
        guard pack != 0 else { return nil }
        defer { IOObjectRelease(pack) }
        guard let ref = IORegistryEntryCreateCFProperty(pack, "BatteryData" as CFString, kCFAllocatorDefault, 0),
              let data = ref.takeRetainedValue() as? [String: Any] else {
            return nil
        }
        return intValue(data["Temperature"]) ?? intValue(data["VirtualTemperature"])
    }

    private func adapterDescription() -> String? {
        guard let details = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] else {
            return nil
        }
        let watts = intValue(details[kIOPSPowerAdapterWattsKey])
        let name = details["Name"] as? String
        switch (watts, name) {
        case let (w?, n?): return "\(w)W \(n)"
        case let (w?, nil): return "\(w)W"
        case let (nil, n?): return n
        default: return nil
        }
    }

    private func intValue(_ any: Any?) -> Int? {
        if let n = any as? Int { return n }
        if let n = any as? NSNumber { return n.intValue }
        return nil
    }
}
