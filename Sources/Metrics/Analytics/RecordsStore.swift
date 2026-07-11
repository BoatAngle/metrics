import Foundation
import Observation
import WidgetShared

/// Persisted "personal bests" — the most extreme readings this Mac has hit
/// (feature #26). Two scopes: `today` (auto-resets at local midnight) and
/// `allTime`. Updated cheaply on every engine tick; only a genuinely new
/// record touches disk, and writes happen off the main actor.
@Observable @MainActor
final class RecordsStore {
    static let shared = RecordsStore()

    /// One record: the extreme value, a human label (which sensor / fan /
    /// direction), and when it happened.
    struct Entry: Codable, Equatable, Sendable {
        var value: Double
        var label: String
        var date: Date
    }

    /// The five tracked superlatives. `lowestFreeMemory` is a minimum; the rest
    /// are maxima.
    struct RecordSet: Codable, Equatable, Sendable {
        var hottestSensor: Entry?
        var peakFanRPM: Entry?
        var peakNetworkBurst: Entry?    // combined ↓+↑, B/s
        var lowestFreeMemory: Entry?    // free bytes
        var peakPowerWatts: Entry?
    }

    private(set) var today = RecordSet()
    private(set) var allTime = RecordSet()
    /// Local midnight of the day `today` currently covers.
    private var todayStart: Date

    private nonisolated static let fileURL =
        WidgetSnapshotStore.appSupportDirectory.appendingPathComponent("records.json")
    private nonisolated static let ioQueue = DispatchQueue(label: "metrics.records.io", qos: .utility)

    private struct Persisted: Codable {
        var today: RecordSet
        var allTime: RecordSet
        var todayStart: Date
    }

    private init() {
        let midnight = Calendar.current.startOfDay(for: Date())
        todayStart = midnight
        if let data = try? Data(contentsOf: Self.fileURL),
           let p = try? JSONDecoder().decode(Persisted.self, from: data) {
            allTime = p.allTime
            // Keep today's records only if they belong to the current day.
            if Calendar.current.isDate(p.todayStart, inSameDayAs: midnight) {
                today = p.today
                todayStart = p.todayStart
            }
        }
    }

    // MARK: - Recording

    /// Folds the current snapshots into both scopes. Called from the engine's
    /// main-actor apply pass. Persists only when something actually changed.
    func record(sensors: SensorsSnapshot, fans: [FanInfo], network: NetworkSnapshot,
                memory: MemorySnapshot, power: PowerSnapshot, now: Date = Date()) {
        rollDayIfNeeded(now: now)
        var changed = false

        // Hottest sensor — scan the named CPU/GPU peaks plus every extra probe.
        var hottest: (name: String, c: Double)? = nil
        func consider(_ name: String, _ c: Double?) {
            guard let c, c > 0, c < 120 else { return }
            if hottest == nil || c > hottest!.c { hottest = (name, c) }
        }
        consider("CPU", sensors.cpuTempMaxC ?? sensors.cpuTempC)
        consider("GPU", sensors.gpuTempMaxC ?? sensors.gpuTempC)
        for t in sensors.extraTemps { consider(t.name, t.celsius) }
        if let h = hottest {
            changed = raiseMax(\.hottestSensor, value: h.c, label: h.name, now: now) || changed
        }

        // Peak fan RPM.
        if let fastest = fans.max(by: { $0.rpm < $1.rpm }), fastest.rpm > 0 {
            changed = raiseMax(\.peakFanRPM, value: fastest.rpm, label: fastest.name, now: now) || changed
        }

        // Peak network burst (combined throughput).
        let burst = network.downBytesPerSec + network.upBytesPerSec
        if burst > 0 {
            let label = network.downBytesPerSec >= network.upBytesPerSec ? "mostly ↓" : "mostly ↑"
            changed = raiseMax(\.peakNetworkBurst, value: burst, label: label, now: now) || changed
        }

        // Lowest free memory.
        if memory.totalBytes > 0 {
            let free = Double(memory.totalBytes) - Double(memory.usedBytes)
            changed = lowerMin(\.lowestFreeMemory, value: max(0, free),
                               label: Fmt.percentValue(memory.usedFraction * 100) + " used", now: now) || changed
        }

        // Peak power draw.
        if power.available, power.totalWatts > 0 {
            changed = raiseMax(\.peakPowerWatts, value: power.totalWatts, label: power.source.rawValue, now: now) || changed
        }

        if changed { save() }
    }

    // MARK: - Reset

    func resetToday() {
        today = RecordSet()
        todayStart = Calendar.current.startOfDay(for: Date())
        save()
    }

    func resetAllTime() {
        allTime = RecordSet()
        save()
    }

    // MARK: - Internals

    /// Clears `today` when the local day advances past what it covers.
    private func rollDayIfNeeded(now: Date) {
        let midnight = Calendar.current.startOfDay(for: now)
        if !Calendar.current.isDate(todayStart, inSameDayAs: midnight) {
            today = RecordSet()
            todayStart = midnight
        }
    }

    /// Raises both scopes' record if `value` beats them; returns whether either moved.
    private func raiseMax(_ key: WritableKeyPath<RecordSet, Entry?>,
                          value: Double, label: String, now: Date) -> Bool {
        var moved = false
        if today[keyPath: key].map({ value > $0.value }) ?? true {
            today[keyPath: key] = Entry(value: value, label: label, date: now); moved = true
        }
        if allTime[keyPath: key].map({ value > $0.value }) ?? true {
            allTime[keyPath: key] = Entry(value: value, label: label, date: now); moved = true
        }
        return moved
    }

    /// Lowers both scopes' record if `value` is below them (for minima).
    private func lowerMin(_ key: WritableKeyPath<RecordSet, Entry?>,
                          value: Double, label: String, now: Date) -> Bool {
        var moved = false
        if today[keyPath: key].map({ value < $0.value }) ?? true {
            today[keyPath: key] = Entry(value: value, label: label, date: now); moved = true
        }
        if allTime[keyPath: key].map({ value < $0.value }) ?? true {
            allTime[keyPath: key] = Entry(value: value, label: label, date: now); moved = true
        }
        return moved
    }

    private func save() {
        let snapshot = Persisted(today: today, allTime: allTime, todayStart: todayStart)
        Self.ioQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(
                at: WidgetSnapshotStore.appSupportDirectory, withIntermediateDirectories: true)
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }
}
