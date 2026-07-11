import Foundation

/// Turns live engine state into the compact readings the menu bar renderers,
/// tooltips and reactive coloring all share, so every surface agrees on the
/// same numbers. Main-actor: it reads `MetricsEngine`.
@MainActor
enum MenuBarReading {

    /// A single metric reduced to everything the render styles need.
    struct Scalar {
        var text: String                        // "37%" / "53°" / "2400"
        var fraction: Double                    // 0…1 for meter / gauge / dot
        var value: Double?                      // natural-unit value for thresholds
        var history: [Double]?                  // 0…1 history for the line graph
        var pressureLevel: MemoryPressureLevel? // memory only
    }

    // MARK: Scalar reading

    static func scalar(for kind: WidgetItemKind,
                       engine: MetricsEngine,
                       instance: WidgetInstance,
                       settings: SettingsStore) -> Scalar {
        let f = settings.useFahrenheit
        switch kind {
        case .cpu:
            let u = engine.cpu.totalUsage
            return Scalar(text: Fmt.percent(u), fraction: u, value: u * 100,
                          history: engine.cpuHistory.ordered)
        case .gpu:
            let g = engine.gpu
            let u = g.usageFraction
            return Scalar(text: g.available ? Fmt.percent(u) : "n/a",
                          fraction: u, value: g.available ? u * 100 : nil,
                          history: engine.gpuHistory.ordered)
        case .memory:
            let m = engine.memory
            return Scalar(text: Fmt.percent(m.usedFraction), fraction: m.usedFraction,
                          value: m.usedFraction * 100, history: engine.memoryHistory.ordered,
                          pressureLevel: m.pressureLevel)
        case .disk:
            guard let root = engine.disk.root else {
                return Scalar(text: "–", fraction: 0, value: nil, history: nil)
            }
            return Scalar(text: Fmt.percent(root.usedFraction), fraction: root.usedFraction,
                          value: root.usedFraction * 100, history: nil)
        case .battery:
            let b = engine.battery
            guard b.hasBattery else { return Scalar(text: "–", fraction: 0, value: nil, history: nil) }
            return Scalar(text: String(format: "%.0f%%", b.percent), fraction: b.percent / 100,
                          value: b.percent, history: nil)
        case .temperature:
            let t = engine.sensors.hotspotC ?? engine.sensors.cpuTempC
            return tempScalar(t, fahrenheit: f, history: engine.hotspotHistory.ordered)
        case .sensor:
            let c = instance.sensorName.flatMap { sensorCelsius(name: $0, sensors: engine.sensors) }
            return tempScalar(c, fahrenheit: f, history: nil)
        case .fanRPM:
            return fanScalar(engine: engine, instance: instance)
        case .network, .combined, .format, .topProcess:
            // Not rendered through the scalar path.
            return Scalar(text: "", fraction: 0, value: nil, history: nil)
        }
    }

    private static func tempScalar(_ celsius: Double?, fahrenheit: Bool, history: [Double]?) -> Scalar {
        guard let c = celsius else { return Scalar(text: "–", fraction: 0, value: nil, history: nil) }
        // Line-graph history is stored in °C; normalise to a 0…1 height.
        let normHistory = history?.map { min(max($0 / 100, 0), 1) }
        return Scalar(text: Fmt.tempShort(c, fahrenheit: fahrenheit),
                      fraction: min(max(c / 100, 0), 1), value: c, history: normHistory)
    }

    private static func fanScalar(engine: MetricsEngine, instance: WidgetInstance) -> Scalar {
        let fans = engine.sensors.fans
        guard !fans.isEmpty else { return Scalar(text: "–", fraction: 0, value: nil, history: nil) }
        let fan: FanInfo?
        if let idx = instance.fanIndex { fan = fans.first(where: { $0.id == idx }) }
        else { fan = fans.max(by: { $0.rpm < $1.rpm }) }
        guard let fan else { return Scalar(text: "–", fraction: 0, value: nil, history: nil) }
        let ceiling = fan.maxRPM ?? fans.compactMap(\.maxRPM).max() ?? 6000
        let fraction = ceiling > 0 ? min(max(fan.rpm / ceiling, 0), 1) : 0
        return Scalar(text: String(Int(fan.rpm.rounded())), fraction: fraction, value: fan.rpm, history: nil)
    }

    // MARK: Reactive level (#33)

    /// The reactive severity band for a whole item, honoring its per-item
    /// override or the global toggle.
    static func level(for instance: WidgetInstance,
                      engine: MetricsEngine,
                      settings: SettingsStore) -> LoadLevel {
        let enabled = instance.reactiveColor ?? settings.menuBarReactiveColors
        guard enabled else { return .normal }

        switch instance.kind {
        case .memory:
            return level(fromPressure: engine.memory.pressureLevel)
        case .topProcess:
            let cpu = engine.processes.ranked(by: .cpu).first?.cpuPercent ?? 0
            let (w, c) = instance.thresholds ?? (80, 90)
            return LoadLevel.evaluate(value: cpu, warn: w, crit: c)
        case .network, .combined, .format:
            return .normal
        default:
            let reading = scalar(for: instance.kind, engine: engine, instance: instance, settings: settings)
            guard let value = reading.value, let (w, c) = instance.thresholds else { return .normal }
            return LoadLevel.evaluate(value: value, warn: w, crit: c)
        }
    }

    /// Per-metric level for a Combined item's rows: each row is colored by its
    /// own metric's default thresholds (no per-row overrides).
    static func level(forRow kind: WidgetItemKind,
                      engine: MetricsEngine,
                      instance: WidgetInstance,
                      settings: SettingsStore) -> LoadLevel {
        let enabled = instance.reactiveColor ?? settings.menuBarReactiveColors
        guard enabled else { return .normal }
        if kind == .memory { return level(fromPressure: engine.memory.pressureLevel) }
        let reading = scalar(for: kind, engine: engine, instance: instance, settings: settings)
        guard let value = reading.value, let (w, c) = kind.defaultThresholds else { return .normal }
        return LoadLevel.evaluate(value: value, warn: w, crit: c)
    }

    private static func level(fromPressure level: MemoryPressureLevel) -> LoadLevel {
        switch level {
        case .critical: return .crit
        case .warning: return .warn
        case .normal: return .normal
        }
    }

    // MARK: Sensors (#38)

    /// The °C value of a named sensor, or nil when it isn't currently reported.
    static func sensorCelsius(name: String, sensors: SensorsSnapshot) -> Double? {
        switch name {
        case "CPU": return sensors.cpuTempC
        case "GPU": return sensors.gpuTempC
        case "Hotspot": return sensors.hotspotC
        default: return sensors.extraTemps.first(where: { $0.name == name })?.celsius
        }
    }

    /// Selectable sensor names for the sensor-item picker, in a friendly order.
    static func availableSensorNames(_ sensors: SensorsSnapshot) -> [String] {
        var names: [String] = []
        if sensors.cpuTempC != nil { names.append("CPU") }
        if sensors.gpuTempC != nil { names.append("GPU") }
        if sensors.hotspotC != nil { names.append("Hotspot") }
        for t in sensors.extraTemps where !names.contains(t.name) { names.append(t.name) }
        return names
    }

    // MARK: Custom format (#36)

    static func formatValues(engine: MetricsEngine, settings: SettingsStore) -> MenuFormatValues {
        MenuFormatValues(
            cpuPercent: engine.cpu.totalUsage * 100,
            gpuPercent: engine.gpu.available ? engine.gpu.usageFraction * 100 : nil,
            memPercent: engine.memory.usedFraction * 100,
            hotspotC: engine.sensors.hotspotC ?? engine.sensors.cpuTempC,
            netDownBytesPerSec: engine.network.downBytesPerSec,
            netUpBytesPerSec: engine.network.upBytesPerSec,
            fanRPM: engine.sensors.fans.map(\.rpm).max(),
            batteryPercent: engine.battery.hasBattery ? engine.battery.percent : nil,
            useFahrenheit: settings.useFahrenheit)
    }
}
