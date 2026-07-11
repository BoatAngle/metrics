import Foundation

/// Canonical "what's the current value of metric X" lookup, shared by the
/// `metrics://copy/<metric>` URL command and the `metricsctl` control socket so
/// both speak the same metric vocabulary. Reads live engine state, so it stays
/// on the main actor.
enum MetricReadout {
    /// Every queryable metric key, with a human title for help/error text.
    /// The order here is the order `metricsctl` lists them in.
    static let metrics: [(key: String, title: String)] = [
        ("cpu", "CPU usage"),
        ("gpu", "GPU usage"),
        ("memory", "Memory used"),
        ("swap", "Swap used"),
        ("power", "Total power draw"),
        ("cpu-temp", "CPU temperature"),
        ("gpu-temp", "GPU temperature"),
        ("hotspot", "Hottest CPU/GPU sensor"),
        ("battery", "Battery charge"),
        ("net-down", "Network download rate"),
        ("net-up", "Network upload rate"),
        ("disk", "Boot volume used"),
        ("ip", "Local IP address"),
        ("fan", "Fan mode"),
    ]

    static var metricKeys: [String] { metrics.map(\.key) }

    /// Plain, human-readable current value for `key`, formatted the way the
    /// cards show it. Returns nil only when the key isn't a known metric;
    /// known-but-unavailable metrics (e.g. GPU % on hardware without it) return
    /// a short "n/a".
    @MainActor
    static func value(_ key: String, engine: MetricsEngine, settings: SettingsStore) -> String? {
        let f = settings.useFahrenheit
        switch key.lowercased() {
        case "cpu": return Fmt.percent(engine.cpu.totalUsage)
        case "gpu": return engine.gpu.available ? Fmt.percent(engine.gpu.usageFraction) : "n/a"
        case "memory": return Fmt.percent(engine.memory.usedFraction)
        case "swap": return Fmt.bytes(engine.memory.swapUsedBytes)
        case "power": return engine.power.available ? Fmt.watts(engine.power.totalWatts) : "n/a"
        case "cpu-temp": return engine.sensors.cpuTempC.map { Fmt.temp($0, fahrenheit: f) } ?? "n/a"
        case "gpu-temp": return engine.sensors.gpuTempC.map { Fmt.temp($0, fahrenheit: f) } ?? "n/a"
        case "hotspot": return engine.sensors.hotspotC.map { Fmt.temp($0, fahrenheit: f) } ?? "n/a"
        case "battery": return engine.battery.hasBattery ? String(format: "%.0f%%", engine.battery.percent) : "n/a"
        case "net-down": return Fmt.rate(engine.network.downBytesPerSec)
        case "net-up": return Fmt.rate(engine.network.upBytesPerSec)
        case "disk": return engine.disk.root.map { Fmt.percent($0.usedFraction) } ?? "n/a"
        case "ip": return engine.network.localIPv4 ?? engine.network.localIPv6 ?? "n/a"
        case "fan": return FanControl.shared.effectiveMode.rawValue
        default: return nil
        }
    }

    /// A full machine-readable snapshot of every subsystem, as a JSON-ready
    /// dictionary. Temperatures are Celsius (`*_c`), percentages are 0…100
    /// numbers rounded to one decimal. Optional fields are omitted when absent
    /// rather than encoded as null.
    @MainActor
    static func snapshot(engine: MetricsEngine, settings: SettingsStore) -> [String: Any] {
        var out: [String: Any] = [:]
        out["timestamp"] = ISO8601DateFormatter().string(from: Date())

        let c = engine.cpu
        out["cpu"] = [
            "usage_percent": r1(c.totalUsage * 100),
            "user_percent": r1(c.userUsage * 100),
            "system_percent": r1(c.systemUsage * 100),
        ]

        var gpu: [String: Any] = ["available": engine.gpu.available]
        if engine.gpu.available { gpu["usage_percent"] = r1(engine.gpu.usageFraction * 100) }
        out["gpu"] = gpu

        let m = engine.memory
        out["memory"] = [
            "used_bytes": m.usedBytes,
            "total_bytes": m.totalBytes,
            "used_percent": r1(m.usedFraction * 100),
            "pressure": m.pressureLevel.label,
            "swap_used_bytes": m.swapUsedBytes,
        ]

        let p = engine.power
        var power: [String: Any] = ["available": p.available]
        if p.available {
            power["total_watts"] = r1(p.totalWatts)
            power["cpu_watts"] = r1(p.cpuWatts)
            power["gpu_watts"] = r1(p.gpuWatts)
        }
        out["power"] = power

        if let root = engine.disk.root {
            out["disk"] = [
                "root_used_bytes": root.usedBytes,
                "root_total_bytes": root.totalBytes,
                "root_used_percent": r1(root.usedFraction * 100),
            ]
        }

        let n = engine.network
        var net: [String: Any] = [
            "down_bytes_per_sec": r1(n.downBytesPerSec),
            "up_bytes_per_sec": r1(n.upBytesPerSec),
            "connection": n.connection.rawValue,
        ]
        if let ip4 = n.localIPv4 { net["local_ipv4"] = ip4 }
        if let ip6 = n.localIPv6 { net["local_ipv6"] = ip6 }
        out["network"] = net

        let b = engine.battery
        var bat: [String: Any] = ["has_battery": b.hasBattery]
        if b.hasBattery {
            bat["percent"] = r1(b.percent)
            bat["charging"] = b.isCharging
            bat["plugged_in"] = b.isPluggedIn
            if let h = b.healthPercent { bat["health_percent"] = r1(h) }
            if let cy = b.cycleCount { bat["cycle_count"] = cy }
        }
        out["battery"] = bat

        let s = engine.sensors
        var sensors: [String: Any] = ["available": s.available]
        if let cpuT = s.cpuTempC { sensors["cpu_temp_c"] = r1(cpuT) }
        if let gpuT = s.gpuTempC { sensors["gpu_temp_c"] = r1(gpuT) }
        if let hot = s.hotspotC { sensors["hotspot_c"] = r1(hot) }
        if !s.fans.isEmpty {
            sensors["fans"] = s.fans.map { ["name": $0.name, "rpm": Int($0.rpm.rounded())] }
        }
        out["sensors"] = sensors

        out["fan_mode"] = FanControl.shared.effectiveMode.rawValue

        let d = engine.device
        out["device"] = [
            "model": d.modelName,
            "chip": d.chipName,
            "os": d.osVersionString,
            "uptime_seconds": Int(d.uptimeSeconds),
        ]
        return out
    }

    private static func r1(_ x: Double) -> Double { (x * 10).rounded() / 10 }
}
