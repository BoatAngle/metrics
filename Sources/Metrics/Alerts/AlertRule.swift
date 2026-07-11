import Foundation

// MARK: - Comparator

/// Direction a threshold rule trips in.
enum AlertComparator: String, Codable, CaseIterable, Identifiable {
    case above, below

    var id: String { rawValue }
    var title: String { self == .above ? "rises above" : "drops below" }
    var symbol: String { self == .above ? ">" : "<" }

    /// Whether `value` satisfies this comparator against `threshold` (strict).
    func matches(_ value: Double, _ threshold: Double) -> Bool {
        self == .above ? value > threshold : value < threshold
    }
}

// MARK: - Metric

/// What a rule watches. Flat so it's Codable and picker-friendly; per-metric
/// context (which sensor, which volume) lives on `AlertRule`.
enum AlertMetric: String, Codable, CaseIterable, Identifiable {
    case cpuUsage
    case gpuUsage
    case hotspotTemp
    case tempSensor
    case memoryPressure
    case volumeFreePercent
    case volumeFreeGB
    case batteryPercent
    case batteryHealth
    case networkDown
    case networkUp
    case fanRPM
    case processCPU
    case processRSS
    case thermalState
    case weakCharger

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpuUsage: return "CPU usage"
        case .gpuUsage: return "GPU usage"
        case .hotspotTemp: return "Hotspot temperature"
        case .tempSensor: return "Temperature sensor"
        case .memoryPressure: return "Memory pressure"
        case .volumeFreePercent: return "Volume free space (%)"
        case .volumeFreeGB: return "Volume free space (GB)"
        case .batteryPercent: return "Battery charge (%)"
        case .batteryHealth: return "Battery health (%)"
        case .networkDown: return "Download speed"
        case .networkUp: return "Upload speed"
        case .fanRPM: return "Fan speed"
        case .processCPU: return "Any process CPU (%)"
        case .processRSS: return "Any process memory (GB)"
        case .thermalState: return "Thermal state"
        case .weakCharger: return "Charger delivery"
        }
    }

    /// Unit shown after a numeric threshold. Empty for level metrics.
    var unit: String {
        switch self {
        case .cpuUsage, .gpuUsage, .volumeFreePercent, .batteryPercent,
             .batteryHealth, .processCPU, .weakCharger:
            return "%"
        case .hotspotTemp, .tempSensor: return "°C"
        case .volumeFreeGB, .processRSS: return "GB"
        case .networkDown, .networkUp: return "Mbps"
        case .fanRPM: return "rpm"
        case .memoryPressure, .thermalState: return ""
        }
    }

    /// Level metrics compare with ">=" against a discrete level value and skip
    /// the percentage hysteresis; the editor shows a level picker for them.
    var isLevel: Bool { self == .memoryPressure || self == .thermalState }
    var isTemperature: Bool { self == .hotspotTemp || self == .tempSensor }
    var isProcess: Bool { self == .processCPU || self == .processRSS }
    var needsSensor: Bool { self == .tempSensor }
    var needsVolume: Bool { self == .volumeFreePercent || self == .volumeFreeGB }

    var defaultComparator: AlertComparator {
        switch self {
        case .volumeFreePercent, .volumeFreeGB, .batteryHealth, .weakCharger:
            return .below
        default:
            return .above
        }
    }

    var defaultThreshold: Double {
        switch self {
        case .cpuUsage: return 90
        case .gpuUsage: return 90
        case .hotspotTemp: return 95
        case .tempSensor: return 80
        case .memoryPressure: return Double(MemoryPressureLevel.critical.rawValue)
        case .volumeFreePercent: return 10
        case .volumeFreeGB: return 10
        case .batteryPercent: return 80
        case .batteryHealth: return 80
        case .networkDown: return 500
        case .networkUp: return 200
        case .fanRPM: return 5000
        case .processCPU: return 90
        case .processRSS: return 8
        case .thermalState: return Double(ThermalLevel.serious.rawValue)
        case .weakCharger: return 60
        }
    }

    /// Suggested rule name when creating one for this metric.
    var suggestedName: String {
        switch self {
        case .cpuUsage: return "High CPU usage"
        case .gpuUsage: return "High GPU usage"
        case .hotspotTemp: return "Hot chip"
        case .tempSensor: return "Sensor temperature"
        case .memoryPressure: return "Memory pressure"
        case .volumeFreePercent: return "Low disk space"
        case .volumeFreeGB: return "Low disk space"
        case .batteryPercent: return "Unplug reminder"
        case .batteryHealth: return "Battery health"
        case .networkDown: return "High download"
        case .networkUp: return "High upload"
        case .fanRPM: return "Fans spinning up"
        case .processCPU: return "Runaway process (CPU)"
        case .processRSS: return "Runaway process (memory)"
        case .thermalState: return "Thermal throttling"
        case .weakCharger: return "Slow charger"
        }
    }

    /// Formats a raw metric value into its human string.
    func format(_ value: Double, fahrenheit: Bool) -> String {
        switch self {
        case .hotspotTemp, .tempSensor:
            return Fmt.temp(value, fahrenheit: fahrenheit)
        case .memoryPressure:
            return MemoryPressureLevel(raw: Int32(value.rounded())).label
        case .thermalState:
            return ThermalLevel(rawValue: Int(value.rounded()))?.label ?? "Unknown"
        case .cpuUsage, .gpuUsage, .volumeFreePercent, .batteryPercent,
             .batteryHealth, .processCPU, .weakCharger:
            return "\(Int(value.rounded()))%"
        case .volumeFreeGB, .processRSS:
            return String(format: "%.1f GB", value)
        case .networkDown, .networkUp:
            return String(format: "%.0f Mbps", value)
        case .fanRPM:
            return "\(Int(value.rounded())) rpm"
        }
    }
}

/// ProcessInfo.ThermalState mirrored as an ordered, labelled level so the
/// editor and messages can name it without importing Foundation enums into UI.
enum ThermalLevel: Int, CaseIterable, Identifiable {
    case nominal = 0, fair = 1, serious = 2, critical = 3
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        }
    }
}

// MARK: - Action

/// A side effect a rule performs when it fires. Every rule notifies; extra
/// actions (currently just fan-mode escalation, feature #21) live in `actions`.
enum AlertAction: Codable, Hashable {
    case notify
    case setFanMode(FanMode)
}

// MARK: - Rule

/// A persisted alert rule (features #15–#21). Runtime evaluation state
/// (sustain timers, hysteresis, escalation) lives in `AlertEngine`, not here.
struct AlertRule: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var metric: AlertMetric
    var comparator: AlertComparator
    var threshold: Double
    var sustainSeconds: Double
    var cooldownSeconds: Double
    var enabled: Bool
    var quietHoursBypass: Bool = false
    var actions: [AlertAction] = [.notify]

    /// Named temperature sensor (`.tempSensor`). nil → not applicable.
    var sensorName: String? = nil
    /// Target volume path (`.volumeFreePercent`/`.volumeFreeGB`). nil → boot volume.
    var volumePath: String? = nil
    /// Battery "unplug now" rules only fire while charging.
    var chargingOnly: Bool = false
    /// °C below the trip threshold at which a fan escalation restores the prior
    /// mode (feature #21). nil → default 8 °C margin.
    var fanRestoreMarginC: Double? = nil

    /// Suppressed until this instant (feature #22 snooze). nil → active.
    var snoozedUntil: Date? = nil
    /// Last time this rule fired, persisted so "last fired" survives relaunch
    /// and doubles as the cooldown reference after a cold start.
    var lastFired: Date? = nil

    /// The fan mode this rule escalates to, if any (feature #21).
    var escalationFanMode: FanMode? {
        for action in actions {
            if case .setFanMode(let mode) = action { return mode }
        }
        return nil
    }

    var isSnoozed: Bool { (snoozedUntil.map { $0 > Date() }) ?? false }
}

// MARK: - Editor factories

extension AlertRule {
    /// A fresh enabled rule seeded from a metric's defaults.
    static func new(metric: AlertMetric = .cpuUsage) -> AlertRule {
        AlertRule(name: metric.suggestedName, metric: metric,
                  comparator: metric.defaultComparator, threshold: metric.defaultThreshold,
                  sustainSeconds: 30, cooldownSeconds: 300, enabled: true)
    }

    /// Returns a copy re-seeded for a newly chosen metric: comparator/threshold
    /// reset to the metric's defaults and any now-irrelevant context cleared.
    func reconfigured(for metric: AlertMetric) -> AlertRule {
        var r = self
        // Track the suggested name only while the user hasn't customized it.
        if r.name == self.metric.suggestedName { r.name = metric.suggestedName }
        r.metric = metric
        r.comparator = metric.defaultComparator
        r.threshold = metric.defaultThreshold
        if !metric.needsSensor { r.sensorName = nil }
        if !metric.needsVolume { r.volumePath = nil }
        if metric != .batteryPercent { r.chargingOnly = false }
        if !metric.isTemperature { r.actions = [.notify] }   // fan escalation is temp-only
        return r
    }
}

extension AlertMetric {
    /// Discrete level choices for the editor (level metrics only).
    var levelOptions: [(value: Double, label: String)] {
        switch self {
        case .memoryPressure:
            return [(Double(MemoryPressureLevel.warning.rawValue), "Warning"),
                    (Double(MemoryPressureLevel.critical.rawValue), "Critical")]
        case .thermalState:
            return [(Double(ThermalLevel.fair.rawValue), "Fair"),
                    (Double(ThermalLevel.serious.rawValue), "Serious"),
                    (Double(ThermalLevel.critical.rawValue), "Critical")]
        default:
            return []
        }
    }
}
