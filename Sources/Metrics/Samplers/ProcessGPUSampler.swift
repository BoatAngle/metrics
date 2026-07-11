import Foundation
import IOKit

/// Best-effort per-process GPU utilization (feature #13).
///
/// Walks the IOAccelerator subtree looking for client nodes that expose BOTH a
/// `PerformanceStatistics` dictionary with a device-utilization figure AND an
/// owning pid (the pid embedded in `IOUserClientCreator`, or a numeric pid
/// property). On hardware that maps utilization to clients this yields a
/// `[pid: percent]` table; on Apple Silicon the accelerator publishes only a
/// single global utilization with no owning pid, so this returns an empty map
/// and callers omit the GPU column (documented in the package caveats).
final class ProcessGPUSampler {

    /// pid → GPU utilization percent (0…100). Empty when unmappable.
    func sample() -> [Int32: Double] {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOAccelerator"),
                                           &iterator) == KERN_SUCCESS else {
            return [:]
        }
        defer { IOObjectRelease(iterator) }

        var result: [Int32: Double] = [:]
        while true {
            let root = IOIteratorNext(iterator)
            if root == 0 { break }
            defer { IOObjectRelease(root) }
            collect(from: root, into: &result)
        }
        return result
    }

    /// Recursively inspect `entry` and its children for a (pid, utilization) pair.
    private func collect(from entry: io_registry_entry_t, into result: inout [Int32: Double]) {
        if let pid = owningPID(of: entry), let util = deviceUtilization(of: entry) {
            // Keep the largest reading when a pid owns several clients.
            result[pid] = max(result[pid] ?? 0, util)
        }

        var childIter = io_iterator_t()
        guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &childIter) == KERN_SUCCESS else {
            return
        }
        defer { IOObjectRelease(childIter) }
        while true {
            let child = IOIteratorNext(childIter)
            if child == 0 { break }
            defer { IOObjectRelease(child) }
            collect(from: child, into: &result)
        }
    }

    /// Device utilization (0…100) from a node's PerformanceStatistics, if any.
    private func deviceUtilization(of entry: io_registry_entry_t) -> Double? {
        var propsRef: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = propsRef?.takeRetainedValue() as? [String: Any],
              let stats = props["PerformanceStatistics"] as? [String: Any] else {
            return nil
        }
        for key in ["Device Utilization %", "GPU Activity(%)", "Renderer Utilization %"] {
            if let n = stats[key] as? NSNumber {
                return min(max(n.doubleValue, 0), 100)
            }
        }
        return nil
    }

    /// Owning pid of a client node: parsed from the "pid N, name" form of
    /// `IOUserClientCreator`, or a numeric pid-ish property.
    private func owningPID(of entry: io_registry_entry_t) -> Int32? {
        var propsRef: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = propsRef?.takeRetainedValue() as? [String: Any] else {
            return nil
        }
        if let creator = props["IOUserClientCreator"] as? String,
           let pid = Self.pid(fromCreator: creator) {
            return pid
        }
        for key in ["pid", "owner-pid", "task-pid"] {
            if let n = props[key] as? NSNumber, n.int32Value > 0 { return n.int32Value }
        }
        return nil
    }

    /// Extracts the pid from an `IOUserClientCreator` string like
    /// "pid 465, WindowServer".
    static func pid(fromCreator creator: String) -> Int32? {
        guard let range = creator.range(of: "pid ") else { return nil }
        let after = creator[range.upperBound...]
        let digits = after.prefix { $0.isNumber }
        return Int32(digits)
    }
}
