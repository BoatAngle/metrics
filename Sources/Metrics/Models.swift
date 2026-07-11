import Foundation

// MARK: - CPU

/// A contiguous run of logical cores that share a performance level (an
/// Efficiency, Performance, or — on this M5 — "Super" cluster). `firstCoreIndex`
/// and `coreCount` index into `CPUSnapshot.perCore`.
struct CPUCluster: Identifiable {
    var name: String          // hw.perflevelN.name, e.g. "Performance" / "Efficiency"
    var shortName: String     // one-letter badge, e.g. "P" / "E"
    var firstCoreIndex: Int
    var coreCount: Int
    var id: String { name + "@\(firstCoreIndex)" }
    var range: Range<Int> { firstCoreIndex..<(firstCoreIndex + coreCount) }
}

struct CPUSnapshot {
    var totalUsage: Double = 0        // 0...1
    var userUsage: Double = 0         // 0...1
    var systemUsage: Double = 0       // 0...1
    var idleUsage: Double = 1         // 0...1
    var perCore: [Double] = []        // 0...1 per core
    /// E/P clusters covering `perCore` (empty when the split is unknown).
    var clusters: [CPUCluster] = []
    static let empty = CPUSnapshot()
}

// MARK: - GPU

struct GPUSnapshot {
    var available: Bool = false
    var name: String? = nil
    var deviceUtilization: Double? = nil     // 0...1
    var rendererUtilization: Double? = nil   // 0...1
    var tilerUtilization: Double? = nil      // 0...1
    var usageFraction: Double { deviceUtilization ?? rendererUtilization ?? 0 }
    static let empty = GPUSnapshot()
}

// MARK: - Memory

/// Kernel VM-pressure level (kern.memorystatus_vm_pressure_level): the same
/// signal DISPATCH_SOURCE_TYPE_MEMORYPRESSURE dispatches on.
enum MemoryPressureLevel: Int {
    case normal = 1
    case warning = 2
    case critical = 4

    /// Best-effort mapping for the raw sysctl value (unknown → normal).
    init(raw: Int32) {
        switch raw {
        case 4: self = .critical
        case 2: self = .warning
        default: self = .normal
        }
    }

    var label: String {
        switch self {
        case .normal: return "Normal"
        case .warning: return "Warning"
        case .critical: return "Critical"
        }
    }
}

struct MemorySnapshot {
    var totalBytes: UInt64 = 0
    var usedBytes: UInt64 = 0         // app + wired + compressed
    var appBytes: UInt64 = 0
    var wiredBytes: UInt64 = 0
    var compressedBytes: UInt64 = 0   // compressor pool size
    var cachedBytes: UInt64 = 0
    var swapUsedBytes: UInt64 = 0
    var swapTotalBytes: UInt64 = 0
    var pressurePercent: Double = 0   // 0...100
    var pressureLevel: MemoryPressureLevel = .normal
    var swapInBytesPerSec: Double = 0     // rate of pages faulted back in from swap
    var swapOutBytesPerSec: Double = 0    // rate of pages pushed out to swap
    var usedFraction: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0 }
    static let empty = MemorySnapshot()
}

// MARK: - Power & frequency

/// Effective (residency-weighted, active-only) clock of one CPU cluster,
/// derived from IOReport DVFS residencies × the hardware frequency table.
struct ClusterFrequency: Identifiable {
    var name: String          // matches a CPUCluster name, e.g. "Performance"
    var megahertz: Double     // 0 when the cluster is fully idle
    var activePercent: Double // share of the interval spent out of idle
    var id: String { name }
}

/// Where a PowerSnapshot's watts came from, surfaced so the card can be honest
/// about derived vs. measured values.
enum PowerSource: String {
    case none, ioreport, smc, hybrid
}

struct PowerSnapshot {
    var available: Bool = false
    var cpuWatts: Double = 0          // may be derived (total − GPU) under `smc`/`hybrid`
    var gpuWatts: Double = 0
    var aneWatts: Double? = nil       // Apple Neural Engine, when IOReport reports it
    var dramWatts: Double? = nil
    var totalWatts: Double = 0        // system/package total
    var adapterWatts: Double? = nil   // DC-in from the power adapter (SMC)
    var source: PowerSource = .none
    var cpuDerived: Bool = false      // true when cpuWatts = total − GPU rather than measured
    var clusterFreqs: [ClusterFrequency] = []
    static let empty = PowerSnapshot()
}

// MARK: - Disk

struct VolumeInfo: Identifiable {
    var name: String
    var path: String
    var totalBytes: UInt64
    var availableBytes: UInt64
    var isRoot: Bool
    var isRemovable: Bool
    var id: String { path }
    var usedBytes: UInt64 { totalBytes > availableBytes ? totalBytes - availableBytes : 0 }
    var usedFraction: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0 }
}

struct DiskSnapshot {
    var volumes: [VolumeInfo] = []
    var root: VolumeInfo? { volumes.first(where: { $0.isRoot }) }
    var external: [VolumeInfo] { volumes.filter { !$0.isRoot } }
    static let empty = DiskSnapshot()
}

// MARK: - Disk I/O

/// Live throughput across all physical block-storage drivers, derived by
/// diffing the IOKit cumulative byte counters between ticks (like NetworkSampler).
struct DiskIOSnapshot {
    var readBytesPerSec: Double = 0
    var writeBytesPerSec: Double = 0
    var deltaReadBytes: UInt64 = 0    // bytes read since the previous sample
    var deltaWriteBytes: UInt64 = 0   // bytes written since the previous sample
    static let empty = DiskIOSnapshot()
}

// MARK: - Drive health (SMART / NVMe)

enum DriveHealthStatus {
    case ok       // green
    case warning  // amber
    case failing  // red
    case unknown  // no data
}

/// Per-drive SMART/NVMe health. All wear/endurance fields are optional so a
/// drive that only exposes some of them still renders what it has.
struct DriveHealth: Identifiable {
    var id: String                       // registry path — stable per drive
    var name: String
    var status: DriveHealthStatus
    var wearPercent: Double? = nil       // NVMe "Percentage Used" (may exceed 100)
    var availableSparePercent: Double? = nil
    var temperatureC: Double? = nil
    var dataUnitsWrittenBytes: UInt64? = nil   // total written (TBW)
    var powerOnHours: Int? = nil
    var isNVMe: Bool = true
}

struct DriveHealthSnapshot {
    var drives: [DriveHealth] = []
    static let empty = DriveHealthSnapshot()
}

// MARK: - Disk-growth forecast

/// Projection of when a volume runs out of free space, from its recorded
/// free-bytes history. Nothing is claimed until there are ≥3 days of data.
enum DiskForecast: Equatable {
    case collecting                  // fewer than 3 days recorded
    case steady                      // no meaningful downward trend
    case fillingUp(days: Double)     // free space trending toward zero

    /// Least-squares fit of free-bytes-per-day; only reports `fillingUp` when
    /// the trend is downward, fits reasonably well (guards against noise), and
    /// lands inside a useful horizon. `points` are the daily free-byte rollups
    /// from HistoryStore; `currentFreeBytes` is the live figure to project from.
    static func compute(points: [HistoryPoint], currentFreeBytes: Double) -> DiskForecast {
        guard points.count >= 3 else { return .collecting }
        let t0 = points[0].date.timeIntervalSince1970
        let xs = points.map { ($0.date.timeIntervalSince1970 - t0) / 86400 }  // days
        let ys = points.map(\.avg)                                            // free bytes
        let n = Double(xs.count)
        let meanX = xs.reduce(0, +) / n
        let meanY = ys.reduce(0, +) / n
        var sxx = 0.0, sxy = 0.0, syy = 0.0
        for i in xs.indices {
            let dx = xs[i] - meanX, dy = ys[i] - meanY
            sxx += dx * dx; sxy += dx * dy; syy += dy * dy
        }
        guard sxx > 0 else { return .steady }
        let slope = sxy / sxx                       // bytes/day (negative = filling up)
        let r2 = syy > 0 ? (sxy * sxy) / (sxx * syy) : 0
        guard slope < 0, r2 >= 0.6 else { return .steady }
        let days = currentFreeBytes / -slope
        guard days.isFinite, days > 0, days < 3650 else { return .steady }
        return .fillingUp(days: days)
    }
}

// MARK: - Network

enum ConnectionType: String {
    case wifi = "Wi-Fi"
    case ethernet = "Ethernet"
    case other = "Network"
    case none = "Offline"
}

/// Live Wi-Fi link details (feature #8). All CoreWLAN types are reduced to
/// plain values here so Models stays Foundation-only. `ssidHidden` is true
/// when we're associated to a network but macOS withholds the SSID (no
/// Location permission), which is the common case on modern macOS.
struct WiFiInfo {
    var ssid: String? = nil
    var ssidHidden: Bool = false
    var bssid: String? = nil
    var band: String? = nil            // "2.4 GHz" / "5 GHz" / "6 GHz"
    var channel: Int? = nil
    var channelWidth: String? = nil    // "80 MHz"
    var rssi: Int? = nil               // dBm (signal)
    var noise: Int? = nil              // dBm
    var snr: Int? = nil                // dB (rssi − noise)
    var txRateMbps: Double? = nil      // PHY transmit rate
}

struct NetworkSnapshot {
    var downBytesPerSec: Double = 0
    var upBytesPerSec: Double = 0
    var deltaDownBytes: UInt64 = 0    // bytes received since the previous sample
    var deltaUpBytes: UInt64 = 0      // bytes sent since the previous sample
    var connection: ConnectionType = .none
    var interfaceName: String? = nil
    var ssid: String? = nil           // often nil on modern macOS without location permission
    var localIPv4: String? = nil
    var localIPv6: String? = nil
    var wifi: WiFiInfo? = nil         // present only on a Wi-Fi link
    static let empty = NetworkSnapshot()
}

/// Per-process network throughput (feature #3), aggregated by app name across
/// its helper PIDs. Rates are averaged over the ~5 s nettop sampling window.
struct AppNetworkUsage: Identifiable {
    var name: String
    var downBytesPerSec: Double
    var upBytesPerSec: Double
    var id: String { name }
    var combinedBytesPerSec: Double { downBytesPerSec + upBytesPerSec }
}

struct DataTotals {
    var down: UInt64 = 0
    var up: UInt64 = 0
    var total: UInt64 { down &+ up }
}

/// One day's transferred totals, dated at that day's local midnight. Used to
/// roll the persisted daily history into billing-cycle windows (feature #28).
struct DailyDataPoint: Identifiable {
    var day: Date
    var down: UInt64
    var up: UInt64
    var total: UInt64 { down &+ up }
    var id: Date { day }
}

struct NetworkDataSnapshot {
    var today = DataTotals()
    var yesterday = DataTotals()
    var last7Days = DataTotals()
    var last30Days = DataTotals()
    /// Recent per-day totals (ascending), for arbitrary-window rollups like
    /// the billing cycle. Bounded by the store's ~60-day retention.
    var daily: [DailyDataPoint] = []
    static let empty = NetworkDataSnapshot()
}

/// Transferred totals for the current billing cycle (feature #28), computed on
/// the fly from `NetworkDataSnapshot.daily` so nothing is double-counted.
struct BillingCycleUsage {
    var start: Date
    var nextStart: Date
    var down: UInt64
    var up: UInt64
    var daysLeft: Int
    var total: UInt64 { down &+ up }

    /// Sums the daily history that falls inside the cycle containing `now`.
    /// `startDay` (1…31) is clamped to each month's length, so a "31st" start
    /// lands on the last day of a short month.
    static func compute(daily: [DailyDataPoint], startDay: Int,
                        now: Date = Date(), calendar: Calendar = .current) -> BillingCycleUsage {
        let day = min(max(startDay, 1), 31)
        let today = calendar.startOfDay(for: now)
        let start = cycleStart(onOrBefore: today, day: day, calendar: calendar)
        let next = cycleStart(after: start, day: day, calendar: calendar)
        var down: UInt64 = 0, up: UInt64 = 0
        for point in daily where point.day >= start && point.day < next {
            down &+= point.down
            up &+= point.up
        }
        let daysLeft = max(0, calendar.dateComponents([.day], from: today, to: next).day ?? 0)
        return BillingCycleUsage(start: start, nextStart: next, down: down, up: up, daysLeft: daysLeft)
    }

    /// The clamped cycle-start on or before `date`.
    private static func cycleStart(onOrBefore date: Date, day: Int, calendar: Calendar) -> Date {
        let c = calendar.dateComponents([.year, .month], from: date)
        let thisMonth = clamped(year: c.year ?? 2000, month: c.month ?? 1, day: day, calendar: calendar)
        if thisMonth <= date { return thisMonth }
        let prev = calendar.date(byAdding: .month, value: -1, to: thisMonth) ?? thisMonth
        let pc = calendar.dateComponents([.year, .month], from: prev)
        return clamped(year: pc.year ?? 2000, month: pc.month ?? 1, day: day, calendar: calendar)
    }

    /// The clamped cycle-start one month after `start`.
    private static func cycleStart(after start: Date, day: Int, calendar: Calendar) -> Date {
        let next = calendar.date(byAdding: .month, value: 1, to: start) ?? start
        let c = calendar.dateComponents([.year, .month], from: next)
        return clamped(year: c.year ?? 2000, month: c.month ?? 1, day: day, calendar: calendar)
    }

    /// Local midnight of `day`, clamped into the given month's valid range.
    private static func clamped(year: Int, month: Int, day: Int, calendar: Calendar) -> Date {
        var c = DateComponents(); c.year = year; c.month = month; c.day = 1
        let firstOfMonth = calendar.date(from: c) ?? Date()
        let length = calendar.range(of: .day, in: .month, for: firstOfMonth)?.count ?? 28
        c.day = min(day, length)
        return calendar.startOfDay(for: calendar.date(from: c) ?? firstOfMonth)
    }
}

// MARK: - Connectivity / outages

/// One internet-outage interval (feature #9). `end` is nil while ongoing.
struct OutageRecord: Codable, Identifiable {
    var start: Date
    var end: Date? = nil
    var id: Date { start }
    var durationSeconds: TimeInterval? { end.map { $0.timeIntervalSince(start) } }
}

/// Live connectivity state plus the recent outage log. `online` combines an
/// interface being up (NWPathMonitor) with an active reachability probe.
struct ConnectivitySnapshot {
    var online: Bool = true
    var interfaceUp: Bool = true       // a usable interface exists
    var probeReachable: Bool = true    // the active TCP probe last succeeded
    var currentOutage: OutageRecord? = nil
    var recentOutages: [OutageRecord] = []   // newest first
    static let empty = ConnectivitySnapshot()
}

// MARK: - Battery

struct BatterySnapshot {
    var hasBattery: Bool = false
    var percent: Double = 0                  // 0...100
    var isCharging: Bool = false
    var isPluggedIn: Bool = false
    var timeRemainingMinutes: Int? = nil     // to empty or to full, per state
    var watts: Double? = nil                 // signed: + while charging, − while discharging
    var amperage: Double? = nil              // A, signed
    var voltage: Double? = nil               // V
    var cycleCount: Int? = nil
    var designCapacitymAh: Int? = nil
    var maxCapacitymAh: Int? = nil
    var healthPercent: Double? = nil         // 0...100 (rawMax / design)
    var temperatureC: Double? = nil
    var adapterDescription: String? = nil    // e.g. "96W USB-C Power Adapter"
    static let empty = BatterySnapshot()
}

// MARK: - Battery health projection

/// Projection of when battery max-capacity health decays to 80% (the common
/// "service" threshold), from the recorded daily health-% history (feature
/// #27). Deliberately conservative: nothing is claimed until there are ≥14
/// daily points with a real downward trend that fits well.
enum BatteryHealthProjection: Equatable {
    case collecting                  // fewer than 2 points — nothing to chart yet
    case noProjection                // enough to chart, but no reliable forecast
    case reaches80(date: Date)       // linear fit crosses 80% on this date

    /// Minimum daily points before a projection is even attempted.
    static let minPointsForProjection = 14

    /// Least-squares fit of health-% per day. Reports `.reaches80` only when the
    /// trend is downward, fits reasonably well (guards against noise), health is
    /// still above 80, and the crossing lands in a sensible future horizon.
    /// `points` are the daily health rollups from HistoryStore.
    static func compute(points: [HistoryPoint], now: Date = Date()) -> BatteryHealthProjection {
        guard points.count >= 2 else { return .collecting }
        guard points.count >= minPointsForProjection else { return .noProjection }

        let t0 = points[0].date.timeIntervalSince1970
        let xs = points.map { ($0.date.timeIntervalSince1970 - t0) / 86400 }  // days
        let ys = points.map(\.avg)                                            // health %
        let n = Double(xs.count)
        let meanX = xs.reduce(0, +) / n
        let meanY = ys.reduce(0, +) / n
        var sxx = 0.0, sxy = 0.0, syy = 0.0
        for i in xs.indices {
            let dx = xs[i] - meanX, dy = ys[i] - meanY
            sxx += dx * dx; sxy += dx * dy; syy += dy * dy
        }
        guard sxx > 0 else { return .noProjection }
        let slope = sxy / sxx                       // %/day (negative = declining)
        let intercept = meanY - slope * meanX
        let r2 = syy > 0 ? (sxy * sxy) / (sxx * syy) : 0
        guard slope < 0, r2 >= 0.5 else { return .noProjection }

        // Current health from the fit; only forecast while still above 80.
        let currentDays = xs.last ?? 0
        let currentHealth = intercept + slope * currentDays
        guard currentHealth > 80 else { return .noProjection }

        // Solve intercept + slope·x = 80 for x, back into a calendar date.
        let daysTo80 = (80 - intercept) / slope
        let date80 = Date(timeIntervalSince1970: t0 + daysTo80 * 86400)
        guard date80 > now, date80.timeIntervalSince(now) < 30 * 365 * 86400 else {
            return .noProjection
        }
        return .reaches80(date: date80)
    }
}

// MARK: - Sensors (SMC)

struct FanInfo: Identifiable {
    var id: Int
    var name: String
    var rpm: Double
    var minRPM: Double? = nil
    var maxRPM: Double? = nil
}

struct NamedTemp: Identifiable {
    var name: String
    var celsius: Double
    var id: String { name }
}

struct SensorsSnapshot {
    var available: Bool = false
    var cpuTempC: Double? = nil          // average across core sensors
    var gpuTempC: Double? = nil
    var cpuTempMaxC: Double? = nil       // hottest single sensor — what fan
    var gpuTempMaxC: Double? = nil       // curves react to, like Apple does
    /// Hottest CPU/GPU reading available; falls back to the averages.
    var hotspotC: Double? {
        let candidates = [cpuTempMaxC ?? cpuTempC, gpuTempMaxC ?? gpuTempC].compactMap { $0 }
        return candidates.max()
    }
    var extraTemps: [NamedTemp] = []
    var fans: [FanInfo] = []
    static let empty = SensorsSnapshot()
}

// MARK: - Processes

struct ProcessSample: Identifiable {
    var pid: Int32
    var name: String
    var cpuPercent: Double
    var memoryBytes: UInt64
    var id: Int32 { pid }
}

struct ProcessesSnapshot {
    var topCPU: [ProcessSample] = []
    var topMemory: [ProcessSample] = []
    static let empty = ProcessesSnapshot()
}

// MARK: - Bluetooth

struct BluetoothDeviceSample: Identifiable {
    var id: String                   // address or name
    var name: String
    var batteryPercent: Int? = nil
    var kind: String? = nil          // "Keyboard", "Mouse", "Headphones", …
}

// MARK: - Device

struct DeviceSnapshot {
    var osVersionString: String = ""
    var buildVersion: String = ""
    var modelName: String = ""       // e.g. "MacBook Pro" / hw.model
    var chipName: String = ""        // e.g. "Apple M3 Pro"
    var hostname: String = ""
    var bootDate: Date? = nil
    var uptimeSeconds: TimeInterval = 0
    static let empty = DeviceSnapshot()
}
