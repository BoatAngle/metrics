import Foundation
import IOKit

/// Battery levels of connected Bluetooth HID devices, read from the
/// IORegistry only. Deliberately avoids IOBluetooth: its first call blocks
/// the calling thread on the Bluetooth TCC permission dialog, which froze
/// the whole sampler queue (and ad-hoc re-signing re-prompts every build).
final class BluetoothSampler {

    func sample() -> [BluetoothDeviceSample] {
        var byName: [String: BluetoothDeviceSample] = [:]

        var iterator: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault,
                                        IOServiceMatching("AppleDeviceManagementHIDEventService"),
                                        &iterator) == KERN_SUCCESS {
            defer { IOObjectRelease(iterator) }
            var entry = IOIteratorNext(iterator)
            while entry != 0 {
                if let sample = hidSample(from: entry), byName[sample.name] == nil {
                    byName[sample.name] = sample
                }
                IOObjectRelease(entry)
                entry = IOIteratorNext(iterator)
            }
        }

        return byName.values.sorted { $0.name < $1.name }
    }

    private func hidSample(from entry: io_registry_entry_t) -> BluetoothDeviceSample? {
        var propsRef: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = propsRef?.takeRetainedValue() as? [String: Any] else { return nil }
        guard let percent = props["BatteryPercent"] as? NSNumber,
              let product = props["Product"] as? String, !product.isEmpty else { return nil }
        let id = (props["SerialNumber"] as? String)
            ?? (props["DeviceAddress"] as? String)
            ?? product
        return BluetoothDeviceSample(id: id,
                                     name: product,
                                     batteryPercent: percent.intValue,
                                     kind: Self.classify(product))
    }

    private static func classify(_ name: String) -> String? {
        let lower = name.lowercased()
        if lower.contains("airpods") || lower.contains("headphone") || lower.contains("beats")
            || lower.contains("buds") || lower.contains("earphone") { return "Headphones" }
        if lower.contains("keyboard") { return "Keyboard" }
        if lower.contains("trackpad") { return "Trackpad" }
        if lower.contains("mouse") { return "Mouse" }
        if lower.contains("pencil") { return "Pencil" }
        if lower.contains("speaker") || lower.contains("homepod") { return "Speaker" }
        if lower.contains("controller") || lower.contains("dualsense") || lower.contains("dualshock")
            || lower.contains("xbox") || lower.contains("joy-con") { return "Controller" }
        if lower.contains("watch") { return "Watch" }
        return nil
    }
}
