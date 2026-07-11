import Foundation
import IOKit
import SMCCore

/// SoC power and per-cluster effective frequency.
///
/// Power — primary source is the private IOReport "Energy Model" group (the same
/// channels `powermetrics` reads): "GPU Energy" is reliable and needs no
/// privileges, but on this M5/macOS build the CPU energy channels read zero
/// (gated), so CPU and total watts fall back to the SMC power rails (`PSTR`
/// system total, `PDTR` DC-in). Where IOReport *does* report CPU energy it's
/// used directly. Watts come from ΔEnergy ÷ Δtime.
///
/// Frequency — IOReport "CPU Complex Performance States" gives per-DVFS-state
/// residencies per cluster; multiplied by the hardware frequency table
/// (`voltage-statesN-sram` under the `pmgr` IORegistry node) and normalised over
/// non-idle time, that yields each cluster's effective active clock.
final class PowerSampler {
    private let bridge = IOReportBridge.shared
    private let energySub: IOReportSubscription?
    private let cpuStatsSub: IOReportSubscription?
    private let smc = SMCConnection()

    /// CPU DVFS frequency tables (MHz), keyed by entry count so a complex with N
    /// active P-states maps to the table with N rows.
    private let dvfsByStateCount: [Int: [Double]]
    /// Performance-level names, highest performance first (perflevel0 first).
    private let perfLevelNames: [String]

    private var previousTime: DispatchTime?

    init() {
        energySub = bridge?.makeSubscription(group: "Energy Model")
        cpuStatsSub = bridge?.makeSubscription(group: "CPU Stats",
                                               subgroup: "CPU Complex Performance States")
        dvfsByStateCount = Self.readDVFSTables()
        perfLevelNames = Self.readPerfLevelNames()
    }

    func sample() -> PowerSnapshot {
        let now = DispatchTime.now()
        let elapsed: Double
        if let previousTime {
            elapsed = Double(now.uptimeNanoseconds &- previousTime.uptimeNanoseconds) / 1_000_000_000
        } else {
            elapsed = 0
        }
        previousTime = now

        var snapshot = PowerSnapshot()

        // --- Power rails ---
        var ioCPU: Double? = nil, ioGPU: Double? = nil, ioANE: Double? = nil, ioDRAM: Double? = nil
        if elapsed > 0, let delta = energySub?.nextDelta(), let bridge {
            var cpuJ = 0.0, gpuJ = 0.0, aneJ = 0.0, dramJ = 0.0
            var haveCPU = false, haveGPU = false, haveANE = false, haveDRAM = false
            bridge.forEachChannel(in: delta) { channel in
                guard bridge.format(channel) == IOReportBridge.formatSimple else { return }
                let name = bridge.channelName(channel)
                let joules = Self.joules(bridge.simpleValue(channel), unit: bridge.unitLabel(channel))
                switch name {
                case "CPU Energy": cpuJ += joules; haveCPU = true
                case "GPU Energy": gpuJ += joules; haveGPU = true
                case "ANE Energy": aneJ += joules; haveANE = true
                case "DRAM Energy": dramJ += joules; haveDRAM = true
                default: break
                }
            }
            if haveCPU { ioCPU = cpuJ / elapsed }
            if haveGPU { ioGPU = gpuJ / elapsed }
            if haveANE { ioANE = aneJ / elapsed }
            if haveDRAM { ioDRAM = dramJ / elapsed }
        } else {
            _ = energySub?.nextDelta() // prime the baseline on the first tick
        }

        // SMC total/adapter rails (watts, type "flt ").
        let pstr = smc?.readKey("PSTR")?.doubleValue          // system total
        let pdtr = smc?.readKey("PDTR")?.doubleValue          // DC-in / adapter
        snapshot.adapterWatts = pdtr.map { max(0, $0) }

        snapshot.gpuWatts = max(0, ioGPU ?? 0)
        if let ane = ioANE, ane > 0 { snapshot.aneWatts = ane }
        if let dram = ioDRAM, dram > 0 { snapshot.dramWatts = dram }

        if let cpu = ioCPU, cpu > 0.01 {
            // IOReport reports real CPU energy — use it directly.
            snapshot.cpuWatts = cpu
            snapshot.totalWatts = pstr ?? (cpu + snapshot.gpuWatts + (snapshot.aneWatts ?? 0) + (snapshot.dramWatts ?? 0))
            snapshot.source = .ioreport
        } else if let total = pstr, total > 0 {
            // CPU energy is gated: derive it as total − everything measured.
            snapshot.totalWatts = total
            let others = snapshot.gpuWatts + (snapshot.aneWatts ?? 0) + (snapshot.dramWatts ?? 0)
            snapshot.cpuWatts = max(0, total - others)
            snapshot.cpuDerived = true
            snapshot.source = (ioGPU != nil) ? .hybrid : .smc
        } else if snapshot.gpuWatts > 0 {
            // Only GPU available (no SMC total).
            snapshot.totalWatts = snapshot.gpuWatts + (snapshot.aneWatts ?? 0) + (snapshot.dramWatts ?? 0)
            snapshot.source = .ioreport
        }

        // --- Cluster frequencies ---
        snapshot.clusterFreqs = sampleClusterFrequencies()

        snapshot.available = snapshot.totalWatts > 0 || snapshot.cpuWatts > 0
            || snapshot.gpuWatts > 0 || !snapshot.clusterFreqs.isEmpty
        return snapshot
    }

    // MARK: - Frequencies

    /// One accumulator per cluster type (grouped by DVFS table = active-state
    /// count), summing residency-weighted MHz across the complexes that share it.
    private struct FreqGroup { var num = 0.0; var den = 0.0; var idle = 0.0; var maxMHz = 0.0 }

    private func sampleClusterFrequencies() -> [ClusterFrequency] {
        // `nextDelta` primes itself on its first call (storing the baseline and
        // returning nil), so no separate priming step is needed here.
        guard let bridge, let delta = cpuStatsSub?.nextDelta() else { return [] }
        var groups: [Int: FreqGroup] = [:]  // keyed by active-state count
        bridge.forEachChannel(in: delta) { channel in
            guard bridge.format(channel) == IOReportBridge.formatState,
                  Self.isComplexChannel(bridge.channelName(channel)) else { return }
            let count = bridge.stateCount(channel)
            // Split states into idle (IDLE/DOWN/OFF) and active DVFS points; the
            // k-th active state maps to row k of the same-sized frequency table.
            var activeResidencies: [Double] = []
            var idleResidency = 0.0
            for i in 0..<count {
                let residency = Double(bridge.stateResidency(channel, i))
                if Self.isIdleState(bridge.stateName(channel, i)) {
                    idleResidency += residency
                } else {
                    activeResidencies.append(residency)
                }
            }
            guard let table = self.dvfsByStateCount[activeResidencies.count] else { return }
            var num = 0.0, den = 0.0
            for (k, residency) in activeResidencies.enumerated() where k < table.count {
                num += residency * table[k]
                den += residency
            }
            var group = groups[activeResidencies.count] ?? FreqGroup()
            group.num += num
            group.den += den
            group.idle += idleResidency
            group.maxMHz = table.max() ?? group.maxMHz
            groups[activeResidencies.count] = group
        }
        guard !groups.isEmpty else { return [] }

        // Highest-clocked cluster first; label from the perflevels (perflevel0 is
        // the highest-performance level) when the counts line up.
        let ordered = groups.values.sorted { $0.maxMHz > $1.maxMHz }
        return ordered.enumerated().map { index, group in
            let total = group.den + group.idle
            let name: String
            if perfLevelNames.count == ordered.count, index < perfLevelNames.count {
                name = perfLevelNames[index]
            } else {
                name = "Cluster \(index + 1)"
            }
            return ClusterFrequency(name: name,
                                    megahertz: group.den > 0 ? group.num / group.den : 0,
                                    activePercent: total > 0 ? group.den / total * 100 : 0)
        }
    }

    // MARK: - Static setup helpers

    private static func joules(_ value: Int64, unit: String) -> Double {
        switch unit {
        case "mJ": return Double(value) / 1_000
        case "uJ", "µJ": return Double(value) / 1_000_000
        case "nJ": return Double(value) / 1_000_000_000
        default: return Double(value)  // assume joules
        }
    }

    /// Complex residency channels: a letter, "CPM", then optional cluster index
    /// (ECPM, PCPM, MCPM0…). Excludes per-core "…CPU…" and "…_IDLE" channels.
    private static func isComplexChannel(_ name: String) -> Bool {
        let chars = Array(name)
        guard chars.count >= 4, chars[0].isLetter,
              chars[1] == "C", chars[2] == "P", chars[3] == "M" else { return false }
        return chars.dropFirst(4).allSatisfy { $0.isNumber }
    }

    private static func isIdleState(_ name: String) -> Bool {
        let upper = name.uppercased()
        return upper.contains("IDLE") || upper.contains("DOWN") || upper.contains("OFF")
    }

    private static func readPerfLevelNames() -> [String] {
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("hw.nperflevels", &count, &size, nil, 0) == 0, count > 0 else { return [] }
        return (0..<Int(count)).map { index in
            var nameSize = 0
            let key = "hw.perflevel\(index).name"
            guard sysctlbyname(key, nil, &nameSize, nil, 0) == 0, nameSize > 0 else { return "Level \(index)" }
            var buffer = [CChar](repeating: 0, count: nameSize)
            guard sysctlbyname(key, &buffer, &nameSize, nil, 0) == 0 else { return "Level \(index)" }
            return String(cString: buffer)
        }
    }

    /// CPU DVFS tables from the `pmgr` IORegistry node. On this silicon each CPU
    /// cluster's frequencies live in a `voltage-statesN-sram` blob as 8-byte
    /// (freq_kHz, voltage) pairs. Non-CPU (GPU/ANE) blobs store frequency in Hz,
    /// so interpreting the first word as kHz yields absurd values that the sane
    /// range filter rejects. Keyed by row count to match a complex's state count.
    private static func readDVFSTables() -> [Int: [Double]] {
        guard let pmgr = findPMGR() else { return [:] }
        defer { IOObjectRelease(pmgr) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(pmgr, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return [:] }

        var tables: [Int: [Double]] = [:]
        for (key, value) in dict where key.hasPrefix("voltage-states") && key.hasSuffix("-sram") {
            guard let data = value as? Data else { continue }
            let entries = data.count / 8
            guard entries >= 2 else { continue }
            var mhz: [Double] = []
            mhz.reserveCapacity(entries)
            data.withUnsafeBytes { raw in
                let words = raw.bindMemory(to: UInt32.self)
                for i in 0..<entries {
                    mhz.append(Double(UInt32(littleEndian: words[i * 2])) / 1_000.0)  // kHz → MHz
                }
            }
            // Keep only plausible CPU tables: monotonic non-decreasing, top clock
            // in a realistic range. Same-sized CPU tables are identical, so last
            // write wins harmlessly.
            let isMonotonic = zip(mhz, mhz.dropFirst()).allSatisfy { $0 <= $1 }
            if isMonotonic, let top = mhz.last, top >= 600, top <= 7_000 {
                tables[entries] = mhz
            }
        }
        return tables
    }

    private static func findPMGR() -> io_registry_entry_t? {
        let matching = IOServiceMatching("AppleARMIODevice")
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            var nameBuffer = [CChar](repeating: 0, count: 128)
            if IORegistryEntryGetName(entry, &nameBuffer) == KERN_SUCCESS,
               String(cString: nameBuffer) == "pmgr" {
                return entry
            }
            IOObjectRelease(entry)
        }
        return nil
    }
}
