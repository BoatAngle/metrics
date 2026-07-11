import Foundation
import IOKit

/// Live disk read/write throughput from the IORegistry. Every
/// `IOBlockStorageDriver` node carries a `Statistics` dictionary of cumulative
/// byte counters; summing them across physical drives and diffing between
/// samples yields aggregate B/s (the same diff approach NetworkSampler uses).
final class DiskIOSampler {
    private var previous: (read: UInt64, write: UInt64)?
    private var previousTime: DispatchTime?

    // Keys inside the driver's "Statistics" sub-dictionary.
    private static let bytesReadKey = "Bytes (Read)"
    private static let bytesWriteKey = "Bytes (Write)"

    func sample() -> DiskIOSnapshot {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOBlockStorageDriver"),
                                           &iterator) == KERN_SUCCESS else {
            return .empty
        }
        defer { IOObjectRelease(iterator) }

        var totalRead: UInt64 = 0
        var totalWrite: UInt64 = 0
        while true {
            let entry = IOIteratorNext(iterator)
            if entry == 0 { break }
            defer { IOObjectRelease(entry) }

            var propsRef: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(entry, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let props = propsRef?.takeRetainedValue() as? [String: Any],
                  let stats = props["Statistics"] as? [String: Any] else {
                continue
            }
            if let r = stats[Self.bytesReadKey] as? NSNumber { totalRead &+= r.uint64Value }
            if let w = stats[Self.bytesWriteKey] as? NSNumber { totalWrite &+= w.uint64Value }
        }

        let now = DispatchTime.now()
        var snapshot = DiskIOSnapshot()
        if let prev = previous, let prevTime = previousTime {
            // Counters only ever climb; a decrease means a driver detached, so
            // clamp to zero rather than report a bogus negative burst.
            let dRead = totalRead >= prev.read ? totalRead - prev.read : 0
            let dWrite = totalWrite >= prev.write ? totalWrite - prev.write : 0
            snapshot.deltaReadBytes = dRead
            snapshot.deltaWriteBytes = dWrite
            let elapsed = Double(now.uptimeNanoseconds &- prevTime.uptimeNanoseconds) / 1_000_000_000
            if elapsed > 0 {
                snapshot.readBytesPerSec = Double(dRead) / elapsed
                snapshot.writeBytesPerSec = Double(dWrite) / elapsed
            }
        }
        previous = (totalRead, totalWrite)
        previousTime = now
        return snapshot
    }
}
