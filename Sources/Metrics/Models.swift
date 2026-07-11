import Foundation

// MARK: - CPU

struct CPUSnapshot {
    var totalUsage: Double = 0        // 0...1
    var userUsage: Double = 0         // 0...1
    var systemUsage: Double = 0       // 0...1
    var idleUsage: Double = 1         // 0...1
    var perCore: [Double] = []        // 0...1 per core
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

struct MemorySnapshot {
    var totalBytes: UInt64 = 0
    var usedBytes: UInt64 = 0         // app + wired + compressed
    var appBytes: UInt64 = 0
    var wiredBytes: UInt64 = 0
    var compressedBytes: UInt64 = 0
    var cachedBytes: UInt64 = 0
    var swapUsedBytes: UInt64 = 0
    var swapTotalBytes: UInt64 = 0
    var pressurePercent: Double = 0   // 0...100
    var usedFraction: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0 }
    static let empty = MemorySnapshot()
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

// MARK: - Network

enum ConnectionType: String {
    case wifi = "Wi-Fi"
    case ethernet = "Ethernet"
    case other = "Network"
    case none = "Offline"
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
    static let empty = NetworkSnapshot()
}

struct DataTotals {
    var down: UInt64 = 0
    var up: UInt64 = 0
    var total: UInt64 { down &+ up }
}

struct NetworkDataSnapshot {
    var today = DataTotals()
    var yesterday = DataTotals()
    var last7Days = DataTotals()
    var last30Days = DataTotals()
    static let empty = NetworkDataSnapshot()
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
