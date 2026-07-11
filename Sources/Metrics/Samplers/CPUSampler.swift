import Foundation
import Darwin

/// Per-core CPU usage from Mach processor load-info tick deltas.
final class CPUSampler {

    /// Previous sample's per-core ticks: [user, system, idle, nice].
    private var previousTicks: [[UInt32]] = []

    /// E/P cluster layout, computed once from the perflevel sysctls (fixed for
    /// the life of the process).
    private let clusters: [CPUCluster] = CPUSampler.readClusters()

    func sample() -> CPUSnapshot {
        var processorCount: natural_t = 0
        var infoArray: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0

        let kr = host_processor_info(mach_host_self(),
                                     PROCESSOR_CPU_LOAD_INFO,
                                     &processorCount,
                                     &infoArray,
                                     &infoCount)
        guard kr == KERN_SUCCESS, let info = infoArray, processorCount > 0 else {
            return .empty
        }
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }

        let coreCount = Int(processorCount)
        let stateMax = Int(CPU_STATE_MAX)
        guard Int(infoCount) >= coreCount * stateMax else { return .empty }

        var ticks: [[UInt32]] = []
        ticks.reserveCapacity(coreCount)
        for core in 0..<coreCount {
            let base = core * stateMax
            ticks.append([
                UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])
            ])
        }

        let previous = previousTicks
        previousTicks = ticks
        guard previous.count == coreCount else { return .empty }

        var perCore: [Double] = []
        perCore.reserveCapacity(coreCount)
        var userTicks: UInt64 = 0
        var systemTicks: UInt64 = 0
        var idleTicks: UInt64 = 0
        var totalTicks: UInt64 = 0

        for core in 0..<coreCount {
            let prev = previous[core]
            let cur = ticks[core]
            // Wrapping subtraction: kernel tick counters are 32-bit and roll over.
            let dUser = UInt64(cur[0] &- prev[0])
            let dSystem = UInt64(cur[1] &- prev[1])
            let dIdle = UInt64(cur[2] &- prev[2])
            let dNice = UInt64(cur[3] &- prev[3])
            let total = dUser + dSystem + dIdle + dNice

            perCore.append(total > 0 ? Double(total - dIdle) / Double(total) : 0)
            userTicks += dUser + dNice
            systemTicks += dSystem
            idleTicks += dIdle
            totalTicks += total
        }

        var snapshot = CPUSnapshot()
        snapshot.perCore = perCore
        // Only attach the cluster split when it exactly tiles the cores we read.
        if clusters.reduce(0, { $0 + $1.coreCount }) == coreCount {
            snapshot.clusters = clusters
        }
        snapshot.totalUsage = min(max(perCore.reduce(0, +) / Double(coreCount), 0), 1)
        if totalTicks > 0 {
            snapshot.userUsage = Double(userTicks) / Double(totalTicks)
            snapshot.systemUsage = Double(systemTicks) / Double(totalTicks)
            snapshot.idleUsage = Double(idleTicks) / Double(totalTicks)
        }
        return snapshot
    }

    // MARK: - Cluster layout

    /// Splits the logical cores into performance-level clusters from the
    /// `hw.perflevelN.*` sysctls. Apple Silicon numbers logical CPUs
    /// efficiency-first (the *last*, most-efficient perflevel takes the lowest
    /// indices in `host_processor_info`), while `perflevel0` is the highest
    /// performance level — so ranges are assigned from the last perflevel down,
    /// yielding clusters ordered by ascending core index.
    private static func readClusters() -> [CPUCluster] {
        guard let levelCount = sysctlInt("hw.nperflevels"), levelCount > 0 else { return [] }

        var levels: [(name: String, count: Int)] = []
        for i in 0..<levelCount {
            let count = sysctlInt("hw.perflevel\(i).logicalcpu") ?? 0
            let name = sysctlString("hw.perflevel\(i).name") ?? "Level \(i)"
            levels.append((name, count))
        }

        var clusters: [CPUCluster] = []
        var index = 0
        for level in levels.reversed() where level.count > 0 {
            clusters.append(CPUCluster(name: level.name,
                                       shortName: shortLabel(level.name),
                                       firstCoreIndex: index,
                                       coreCount: level.count))
            index += level.count
        }
        return clusters
    }

    /// One-letter badge from a perflevel name ("Efficiency" → "E").
    private static func shortLabel(_ name: String) -> String {
        guard let first = name.first else { return "?" }
        return String(first).uppercased()
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
