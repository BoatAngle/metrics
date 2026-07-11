import Foundation
import IOKit

/// GPU utilization from the IORegistry accelerator node's
/// PerformanceStatistics dictionary (AGXAccelerator on Apple Silicon,
/// IOAccelerator subclasses on Intel). No privileges required.
final class GPUSampler {
    func sample() -> GPUSnapshot {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOAccelerator"),
                                           &iterator) == KERN_SUCCESS else {
            return .empty
        }
        defer { IOObjectRelease(iterator) }

        while true {
            let entry = IOIteratorNext(iterator)
            if entry == 0 { break }
            defer { IOObjectRelease(entry) }

            var propsRef: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(entry, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let props = propsRef?.takeRetainedValue() as? [String: Any],
                  let stats = props["PerformanceStatistics"] as? [String: Any] else {
                continue
            }

            func percent(_ keys: String...) -> Double? {
                for key in keys {
                    if let n = stats[key] as? NSNumber {
                        return min(max(n.doubleValue / 100.0, 0), 1)
                    }
                }
                return nil
            }

            let device = percent("Device Utilization %", "GPU Activity(%)")
            let renderer = percent("Renderer Utilization %")
            let tiler = percent("Tiler Utilization %")
            guard device != nil || renderer != nil else { continue }

            var snap = GPUSnapshot()
            snap.available = true
            snap.deviceUtilization = device
            snap.rendererUtilization = renderer
            snap.tilerUtilization = tiler
            if let model = props["model"] as? String {
                snap.name = model
            } else if let modelData = props["model"] as? Data,
                      let s = String(data: modelData, encoding: .utf8) {
                snap.name = s.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
            }
            return snap
        }
        return .empty
    }
}
