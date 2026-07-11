import Foundation

/// Aggregate activity over a session window — since boot or since the last
/// wake (feature #25). Built entirely from HistoryStore, so it survives across
/// launches and reflects the whole session, not just what this process saw.
struct SessionStats: Sendable {
    var avgCPU: Double?      // %
    var peakCPU: Double?     // %
    var avgGPU: Double?      // %
    var peakGPU: Double?     // %
    var avgHotspot: Double?  // °C
    var peakHotspot: Double? // °C
    var netDownBytes: Double?
    var netUpBytes: Double?
    /// Start of the window this covers, for labelling.
    var start: Date

    var hasData: Bool {
        avgCPU != nil || peakHotspot != nil || netDownBytes != nil || avgGPU != nil
    }

    static let empty = SessionStats(start: Date())

    /// Loads every aggregate for `[start, end]` concurrently off the main actor.
    static func load(since start: Date, until end: Date = Date()) async -> SessionStats {
        async let cpu = HistoryStore.shared.aggregate(metric: HistoryMetric.cpu, since: start, until: end)
        async let gpu = HistoryStore.shared.aggregate(metric: HistoryMetric.gpu, since: start, until: end)
        async let hot = HistoryStore.shared.aggregate(metric: HistoryMetric.hotspot, since: start, until: end)
        async let down = HistoryStore.shared.aggregate(metric: HistoryMetric.netDown, since: start, until: end)
        async let up = HistoryStore.shared.aggregate(metric: HistoryMetric.netUp, since: start, until: end)

        let (c, g, h, d, u) = await (cpu, gpu, hot, down, up)
        var stats = SessionStats(start: start)
        stats.avgCPU = c?.avg;      stats.peakCPU = c?.max
        stats.avgGPU = g?.avg;      stats.peakGPU = g?.max
        stats.avgHotspot = h?.avg;  stats.peakHotspot = h?.max
        stats.netDownBytes = d?.total
        stats.netUpBytes = u?.total
        return stats
    }
}
