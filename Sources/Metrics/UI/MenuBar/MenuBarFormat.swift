import Foundation

// MARK: - Custom format tokens (#36)

/// The live values a custom-format template can interpolate. Kept as a plain
/// value type — decoupled from `MetricsEngine` — so the token renderer is pure
/// and testable from the headless `--dump` path.
struct MenuFormatValues {
    var cpuPercent: Double            // 0…100
    var gpuPercent: Double?           // nil → GPU unavailable
    var memPercent: Double            // 0…100
    var hotspotC: Double?             // °C, nil → no sensor
    var netDownBytesPerSec: Double
    var netUpBytesPerSec: Double
    var fanRPM: Double?               // max across fans, nil → no fan
    var batteryPercent: Double?       // nil → no battery
    var useFahrenheit: Bool
}

/// Renders a user format string (#36) by substituting `{token}` markers with
/// live values. Unknown tokens are left untouched so a typo is visible rather
/// than silently eaten.
enum MenuFormat {
    /// Documented tokens, surfaced inline in the Menu Bar settings tab.
    static let tokens: [(token: String, description: String)] = [
        ("{cpu}", "CPU load, e.g. 37%"),
        ("{gpu}", "GPU load, e.g. 12%"),
        ("{mem}", "Memory used, e.g. 58%"),
        ("{hot}", "Hottest sensor, number only (add ° yourself)"),
        ("{net.down}", "Download rate, e.g. 1.2 MB/s"),
        ("{net.up}", "Upload rate, e.g. 240 KB/s"),
        ("{fan.rpm}", "Fan speed, e.g. 2400"),
        ("{batt}", "Battery charge, e.g. 82%"),
    ]

    static let defaultTemplate = "{cpu}  {hot}°"

    static func render(_ template: String, _ v: MenuFormatValues) -> String {
        var out = template
        func sub(_ token: String, _ value: String) {
            if out.contains(token) { out = out.replacingOccurrences(of: token, with: value) }
        }
        sub("{cpu}", pct(v.cpuPercent))
        sub("{gpu}", v.gpuPercent.map(pct) ?? "n/a")
        sub("{mem}", pct(v.memPercent))
        sub("{hot}", v.hotspotC.map { degrees($0, fahrenheit: v.useFahrenheit) } ?? "–")
        sub("{net.down}", Fmt.rate(v.netDownBytesPerSec))
        sub("{net.up}", Fmt.rate(v.netUpBytesPerSec))
        sub("{fan.rpm}", v.fanRPM.map { String(Int($0.rounded())) } ?? "–")
        sub("{batt}", v.batteryPercent.map { String(format: "%.0f%%", $0) } ?? "n/a")
        return out
    }

    private static func pct(_ v: Double) -> String { String(format: "%.0f%%", v) }

    /// Degrees as a bare number (no unit symbol), converted for the °F setting —
    /// the template supplies its own ° so `{hot}°` reads naturally.
    private static func degrees(_ celsius: Double, fahrenheit: Bool) -> String {
        String(format: "%.0f", fahrenheit ? celsius * 9 / 5 + 32 : celsius)
    }
}

// MARK: - Live tooltips (#40)

/// Builds the rich multi-line tooltip shown on each status item, refreshed every
/// tick by `StatusItemController`. Reads live engine state, so it's main-actor.
@MainActor
enum MenuBarTooltip {
    static func text(for instance: WidgetInstance,
                     engine: MetricsEngine,
                     settings: SettingsStore) -> String {
        let f = settings.useFahrenheit
        switch instance.kind {
        case .cpu:
            var lines = ["CPU  \(Fmt.percent(engine.cpu.totalUsage))",
                         "User \(Fmt.percent(engine.cpu.userUsage)) · System \(Fmt.percent(engine.cpu.systemUsage))"]
            if let top = engine.processes.ranked(by: .cpu).first, top.cpuPercent > 0 {
                lines.append("Top: \(top.name) \(String(format: "%.0f%%", top.cpuPercent))")
            }
            return lines.joined(separator: "\n")

        case .gpu:
            guard engine.gpu.available else { return "GPU unavailable" }
            var lines = ["GPU  \(Fmt.percent(engine.gpu.usageFraction))"]
            if let name = engine.gpu.name { lines.append(name) }
            if let t = engine.sensors.gpuTempC { lines.append("Temp \(Fmt.temp(t, fahrenheit: f))") }
            return lines.joined(separator: "\n")

        case .memory:
            let m = engine.memory
            return ["Memory  \(Fmt.percent(m.usedFraction)) used",
                    "Used \(Fmt.bytes(m.usedBytes)) / \(Fmt.bytes(m.totalBytes))",
                    "Pressure \(m.pressureLevel.label)",
                    "Swap \(Fmt.bytes(m.swapUsedBytes))"].joined(separator: "\n")

        case .disk:
            guard let root = engine.disk.root else { return "Disk unavailable" }
            return ["\(root.name)  \(Fmt.percent(root.usedFraction)) used",
                    "\(Fmt.bytes(root.availableBytes)) free of \(Fmt.bytes(root.totalBytes))",
                    "Read \(Fmt.rate(engine.diskIO.readBytesPerSec)) · Write \(Fmt.rate(engine.diskIO.writeBytesPerSec))"]
                .joined(separator: "\n")

        case .battery:
            let b = engine.battery
            guard b.hasBattery else { return "No battery" }
            var lines = ["Battery  \(String(format: "%.0f%%", b.percent))"]
            lines.append(b.isCharging ? "Charging" : (b.isPluggedIn ? "Plugged in" : "On battery"))
            if let mins = b.timeRemainingMinutes, mins > 0 {
                lines.append("\(b.isCharging ? "To full" : "Remaining") \(mins / 60)h \(mins % 60)m")
            }
            if let h = b.healthPercent { lines.append("Health \(String(format: "%.0f%%", h))") }
            if let cy = b.cycleCount { lines.append("Cycles \(cy)") }
            return lines.joined(separator: "\n")

        case .temperature:
            let s = engine.sensors
            var lines: [String] = []
            let cpu = s.cpuTempC.map { Fmt.temp($0, fahrenheit: f) } ?? "–"
            let gpu = s.gpuTempC.map { Fmt.temp($0, fahrenheit: f) } ?? "–"
            lines.append("CPU \(cpu) · GPU \(gpu)")
            if let hot = s.hotspotC { lines.append("Hotspot \(Fmt.temp(hot, fahrenheit: f))") }
            return lines.isEmpty ? "No temperature sensors" : lines.joined(separator: "\n")

        case .network:
            let n = engine.network
            var lines = ["↓ \(Fmt.rate(n.downBytesPerSec))   ↑ \(Fmt.rate(n.upBytesPerSec))",
                         n.connection.rawValue]
            let today = engine.networkData.today
            lines.append("Today  ↓ \(Fmt.bytes(today.down)) · ↑ \(Fmt.bytes(today.up))")
            return lines.joined(separator: "\n")

        case .sensor:
            guard let name = instance.sensorName,
                  let value = MenuBarReading.sensorCelsius(name: name, sensors: engine.sensors) else {
                return "Sensor unavailable"
            }
            return "\(name)  \(Fmt.temp(value, fahrenheit: f))"

        case .fanRPM:
            let fans = engine.sensors.fans
            guard !fans.isEmpty else { return "No fans" }
            let list = fans.map { "\($0.name) \(Int($0.rpm.rounded())) rpm" }.joined(separator: " · ")
            return "Fans: \(list)\nMode: \(FanControl.shared.effectiveMode.title)"

        case .topProcess:
            let top = engine.processes.ranked(by: .cpu).prefix(3)
            guard !top.isEmpty else { return "No process data yet" }
            return (["Top CPU"] + top.map { "\($0.name)  \(String(format: "%.0f%%", $0.cpuPercent))" })
                .joined(separator: "\n")

        case .combined:
            let metrics = instance.combinedMetrics ?? []
            guard !metrics.isEmpty else { return "No metrics chosen" }
            return metrics.map { m in
                let r = MenuBarReading.scalar(for: m, engine: engine, instance: instance, settings: settings)
                return "\(m.title)  \(r.text)"
            }.joined(separator: "\n")

        case .format:
            let template = instance.formatString ?? MenuFormat.defaultTemplate
            return MenuFormat.render(template, MenuBarReading.formatValues(engine: engine, settings: settings))
        }
    }
}
