import SwiftUI

// MARK: - Collapse context (feature #48)

/// Threaded from `MetricCardView` down into `CardContainer` via the environment
/// so the shared container can render a clickable, collapsible title without
/// every card having to opt in individually. Absent (nil) → the container
/// behaves exactly as before (desktop widgets, previews, etc.).
struct CardCollapseContext {
    var collapsed: Bool
    /// One-line summary shown in place of the card body while collapsed.
    var summary: String
    /// Flips the collapsed state (already wrapped in the collapse animation).
    var toggle: () -> Void
}

private struct CardCollapseKey: EnvironmentKey {
    static let defaultValue: CardCollapseContext? = nil
}

extension EnvironmentValues {
    var cardCollapse: CardCollapseContext? {
        get { self[CardCollapseKey.self] }
        set { self[CardCollapseKey.self] = newValue }
    }
}

// MARK: - One-line summaries (feature #48)

/// Per-card single-line summaries for the collapsed state. Reads the same live
/// engine snapshots the full cards do, so a collapsed card still tracks reality.
enum CardSummary {
    @MainActor
    static func line(for kind: CardKind, engine: MetricsEngine, settings: SettingsStore) -> String {
        let f = settings.useFahrenheit
        switch kind {
        case .cpu:
            return Fmt.percent(engine.cpu.totalUsage)
        case .gpu:
            return engine.gpu.available ? Fmt.percent(engine.gpu.usageFraction) : "—"
        case .power:
            return engine.power.available ? Fmt.watts(engine.power.totalWatts) : "—"
        case .memory:
            let m = engine.memory
            return "\(Fmt.bytes(m.usedBytes)) · \(pressureWord(m.pressureLevel))"
        case .disk:
            guard let root = engine.disk.root else { return "—" }
            return "\(Fmt.percent(root.usedFraction)) used"
        case .network:
            let n = engine.network
            return "↓\(Fmt.rate(n.downBytesPerSec)) · ↑\(Fmt.rate(n.upBytesPerSec))"
        case .networkData:
            return "\(Fmt.bytes(engine.networkData.today.total)) today"
        case .battery:
            let b = engine.battery
            guard b.hasBattery else { return "—" }
            return "\(Int(b.percent.rounded()))% · \(batteryWord(b))"
        case .sensors:
            guard let hot = engine.sensors.hotspotC else { return "—" }
            return "hotspot \(Fmt.tempShort(hot, fahrenheit: f))"
        case .fans:
            let fans = engine.sensors.fans
            guard let peak = fans.map(\.rpm).max() else { return "—" }
            return "\(Int(peak.rounded()).formatted()) rpm · \(FanControl.shared.effectiveMode.title)"
        case .processes:
            let ranked = engine.processes.ranked(by: settings.processSortKey)
            guard let top = ranked.first else { return "—" }
            return "\(top.name) · \(processValue(top, key: settings.processSortKey, fahrenheit: f))"
        case .bluetooth:
            let count = engine.bluetooth.count
            return count == 1 ? "1 device" : "\(count) devices"
        case .device:
            let up = engine.device.uptimeSeconds
            return up > 0 ? "up " + Fmt.uptime(up) : (engine.device.modelName.isEmpty ? "—" : engine.device.modelName)
        }
    }

    /// Memory pressure worded the way the spec's summary shows it ("OK").
    private static func pressureWord(_ level: MemoryPressureLevel) -> String {
        switch level {
        case .normal: return "OK"
        case .warning: return "Warning"
        case .critical: return "Critical"
        }
    }

    private static func batteryWord(_ b: BatterySnapshot) -> String {
        if b.isCharging { return "charging" }
        if b.isPluggedIn { return "charged" }
        return "on battery"
    }

    private static func processValue(_ p: ProcessSample, key: ProcessSortKey, fahrenheit: Bool) -> String {
        switch key {
        case .cpu: return Fmt.percentValue(p.cpuPercent)
        case .memory: return Fmt.bytes(p.memoryBytes)
        case .disk: return Fmt.rate(p.diskBytesPerSec)
        case .energy: return Fmt.watts(p.energyWatts)
        case .gpu: return Fmt.percentValue(p.gpuPercent ?? 0)
        }
    }
}
