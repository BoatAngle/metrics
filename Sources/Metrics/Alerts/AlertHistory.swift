import Foundation
import Observation
import WidgetShared

/// One recorded firing (feature #23). Carries the rule identity plus the peak
/// value so the history survives the rule being edited or deleted.
struct AlertHistoryEntry: Codable, Identifiable {
    var id: UUID = UUID()
    var date: Date
    var ruleID: UUID
    var ruleName: String
    /// nil for non-rule firings such as the data-budget monitor (feature #20).
    var metric: AlertMetric? = nil
    var peakValue: Double
    /// Pre-formatted peak (e.g. "97%", "96 °C") so old entries render even if
    /// the formatting logic later changes.
    var peakText: String
}

/// A persisted ring of the last 100 firings, stored as JSON in Application
/// Support (feature #23). Reads/writes are cheap and happen on the main actor
/// alongside the rest of the alert engine.
@Observable @MainActor
final class AlertHistory {
    static let maxEntries = 100

    private(set) var entries: [AlertHistoryEntry] = []   // newest first
    @ObservationIgnored private let fileURL: URL

    init() {
        let dir = WidgetSnapshotStore.appSupportDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("alert-history.json")
        load()
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? decoder.decode([AlertHistoryEntry].self, from: data) else { return }
        entries = decoded.sorted { $0.date > $1.date }
    }

    func record(_ entry: AlertHistoryEntry) {
        entries.insert(entry, at: 0)
        if entries.count > Self.maxEntries {
            entries.removeLast(entries.count - Self.maxEntries)
        }
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    /// Most recent firing for a rule, for the "last fired" line in the tab.
    func lastFired(ruleID: UUID) -> Date? {
        entries.first { $0.ruleID == ruleID }?.date
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
