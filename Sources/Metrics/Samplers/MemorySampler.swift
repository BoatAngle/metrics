import Foundation
import Darwin

/// Activity-Monitor-style memory accounting from Mach VM statistics.
final class MemorySampler {

    private let pageSize: UInt64
    private let totalBytes: UInt64

    init() {
        var size: vm_size_t = 0
        if host_page_size(mach_host_self(), &size) == KERN_SUCCESS, size > 0 {
            pageSize = UInt64(size)
        } else {
            pageSize = UInt64(vm_kernel_page_size)
        }

        var memsize: UInt64 = 0
        var len = MemoryLayout<UInt64>.size
        if sysctlbyname("hw.memsize", &memsize, &len, nil, 0) == 0 {
            totalBytes = memsize
        } else {
            totalBytes = 0
        }
    }

    func sample() -> MemorySnapshot {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS, totalBytes > 0 else { return .empty }

        let internalPages = UInt64(stats.internal_page_count)
        let purgeablePages = UInt64(stats.purgeable_count)
        let wiredPages = UInt64(stats.wire_count)
        let compressedPages = UInt64(stats.compressor_page_count)
        let externalPages = UInt64(stats.external_page_count)

        var snapshot = MemorySnapshot()
        snapshot.totalBytes = totalBytes
        snapshot.appBytes = internalPages > purgeablePages
            ? (internalPages - purgeablePages) * pageSize
            : 0
        snapshot.wiredBytes = wiredPages * pageSize
        snapshot.compressedBytes = compressedPages * pageSize
        snapshot.cachedBytes = (externalPages + purgeablePages) * pageSize
        snapshot.usedBytes = snapshot.appBytes + snapshot.wiredBytes + snapshot.compressedBytes

        var swap = xsw_usage()
        var swapLen = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapLen, nil, 0) == 0 {
            snapshot.swapUsedBytes = swap.xsu_used
            snapshot.swapTotalBytes = swap.xsu_total
        }

        // kern.memorystatus_level reports the percentage of memory still
        // considered available; pressure is its complement.
        var level: Int32 = 0
        var levelLen = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_level", &level, &levelLen, nil, 0) == 0 {
            snapshot.pressurePercent = min(max(Double(100 - level), 0), 100)
        } else {
            let pressed = Double(snapshot.wiredBytes + snapshot.compressedBytes)
            snapshot.pressurePercent = min(max(pressed / Double(totalBytes) * 100, 0), 100)
        }
        return snapshot
    }
}
