import Foundation
import Darwin

/// Per-core CPU usage from Mach processor load-info tick deltas.
final class CPUSampler {

    /// Previous sample's per-core ticks: [user, system, idle, nice].
    private var previousTicks: [[UInt32]] = []

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
        snapshot.totalUsage = min(max(perCore.reduce(0, +) / Double(coreCount), 0), 1)
        if totalTicks > 0 {
            snapshot.userUsage = Double(userTicks) / Double(totalTicks)
            snapshot.systemUsage = Double(systemTicks) / Double(totalTicks)
            snapshot.idleUsage = Double(idleTicks) / Double(totalTicks)
        }
        return snapshot
    }
}
