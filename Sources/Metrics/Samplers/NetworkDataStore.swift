import Foundation
import WidgetShared

/// Persists daily network transfer totals to
/// ~/Library/Application Support/Metrics/network-data.json.
final class NetworkDataStore {
    private struct DayEntry: Codable {
        var day: String
        var down: UInt64
        var up: UInt64
    }

    private let lock = NSLock()
    private var totals: [String: (down: UInt64, up: UInt64)] = [:]
    private let fileURL: URL
    private let dayFormatter: DateFormatter

    init() {
        let dir = WidgetSnapshotStore.appSupportDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("network-data.json")

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        dayFormatter = formatter

        if let data = try? Data(contentsOf: fileURL),
           let entries = try? JSONDecoder().decode([DayEntry].self, from: data) {
            for entry in entries {
                totals[entry.day] = (entry.down, entry.up)
            }
        }
    }

    func accumulate(down: UInt64, up: UInt64) {
        guard down > 0 || up > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        let key = dayFormatter.string(from: Date())
        var entry = totals[key] ?? (0, 0)
        entry.down &+= down
        entry.up &+= up
        totals[key] = entry
    }

    func snapshot() -> NetworkDataSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        let calendar = Calendar.current
        let todayKey = dayFormatter.string(from: now)
        var snap = NetworkDataSnapshot()
        if let t = totals[todayKey] {
            snap.today = DataTotals(down: t.down, up: t.up)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           let t = totals[dayFormatter.string(from: yesterday)] {
            snap.yesterday = DataTotals(down: t.down, up: t.up)
        }
        snap.last7Days = sumLocked(daysBack: 7, endingAt: now, todayKey: todayKey, calendar: calendar)
        snap.last30Days = sumLocked(daysBack: 30, endingAt: now, todayKey: todayKey, calendar: calendar)
        return snap
    }

    func flush() {
        lock.lock()
        defer { lock.unlock() }
        if let cutoffDate = Calendar.current.date(byAdding: .day, value: -60, to: Date()) {
            let cutoff = dayFormatter.string(from: cutoffDate)
            totals = totals.filter { $0.key >= cutoff }
        }
        let entries = totals
            .map { DayEntry(day: $0.key, down: $0.value.down, up: $0.value.up) }
            .sorted { $0.day < $1.day }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // Caller must hold `lock`. "yyyy-MM-dd" keys sort lexicographically in
    // date order, so string comparison bounds the window.
    private func sumLocked(daysBack: Int, endingAt now: Date, todayKey: String, calendar: Calendar) -> DataTotals {
        guard let start = calendar.date(byAdding: .day, value: -(daysBack - 1), to: now) else {
            return DataTotals()
        }
        let startKey = dayFormatter.string(from: start)
        var result = DataTotals()
        for (key, value) in totals where key >= startKey && key <= todayKey {
            result.down &+= value.down
            result.up &+= value.up
        }
        return result
    }
}
