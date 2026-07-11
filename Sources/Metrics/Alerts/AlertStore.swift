import Foundation
import WidgetShared

/// Non-rule alert configuration persisted alongside the rules: the data-budget
/// monitor toggle (feature #20) and which budget crossings already fired this
/// cycle (so 50/80/100% each fire once per cycle).
struct AlertConfig: Codable {
    var dataBudgetEnabled: Bool = false
    /// "<cycleStartISO>|<level>" markers already notified, e.g. "2026-07-01…|80".
    var firedBudgetMarkers: [String] = []
}

/// Disk-backed persistence for alert rules + config (feature #15's "JSON file
/// in Application Support, not the UserDefaults settings blob"). All access is
/// on the main actor; the engine owns the in-memory copies.
@MainActor
final class AlertStore {
    private let fileURL: URL

    private struct Persisted: Codable {
        var rules: [AlertRule]
        var config: AlertConfig
        /// Set once so re-seeding never resurrects starters the user deleted.
        var seeded: Bool
    }

    init() {
        let dir = WidgetSnapshotStore.appSupportDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("alerts.json")
    }

    func load() -> (rules: [AlertRule], config: AlertConfig) {
        let decoder = Self.decoder()
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? decoder.decode(Persisted.self, from: data) else {
            // First launch: seed the disabled starter rules and persist them so
            // the "seeded" flag sticks.
            let seeds = Self.starterRules()
            save(rules: seeds, config: AlertConfig(), seeded: true)
            return (seeds, AlertConfig())
        }
        return (decoded.rules, decoded.config)
    }

    func save(rules: [AlertRule], config: AlertConfig, seeded: Bool = true) {
        let encoder = Self.encoder()
        let payload = Persisted(rules: rules, config: config, seeded: seeded)
        guard let data = try? encoder.encode(payload) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Starter rules (feature #15/#17/#18)

    /// Sensible defaults, all shipped DISABLED. Covers the three required
    /// starters plus built-in thermal alerts (#17) and a disk-critical level
    /// (#18) so the common alerts are one toggle away.
    static func starterRules() -> [AlertRule] {
        [
            AlertRule(name: "Chip running hot",
                      metric: .hotspotTemp, comparator: .above, threshold: 95,
                      sustainSeconds: 15, cooldownSeconds: 300, enabled: false),
            AlertRule(name: "Boot volume almost full",
                      metric: .volumeFreePercent, comparator: .below, threshold: 10,
                      sustainSeconds: 0, cooldownSeconds: 6 * 3600, enabled: false),
            AlertRule(name: "Memory pressure critical",
                      metric: .memoryPressure, comparator: .above,
                      threshold: Double(MemoryPressureLevel.critical.rawValue),
                      sustainSeconds: 5, cooldownSeconds: 600, enabled: false),
            // Built-in thermal alerts (#17).
            AlertRule(name: "Thermal state serious",
                      metric: .thermalState, comparator: .above,
                      threshold: Double(ThermalLevel.serious.rawValue),
                      sustainSeconds: 5, cooldownSeconds: 600, enabled: false),
            // Disk critical crossing (#18).
            AlertRule(name: "Boot volume critically full",
                      metric: .volumeFreePercent, comparator: .below, threshold: 5,
                      sustainSeconds: 0, cooldownSeconds: 6 * 3600, enabled: false),
        ]
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
