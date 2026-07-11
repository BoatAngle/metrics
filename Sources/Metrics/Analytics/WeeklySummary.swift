import Foundation

/// One local day's temperature rollup, a cell in the heatmap calendar
/// (feature #31). `peakC`/`avgC` are nil for days with no recorded data.
struct DayTemp: Identifiable, Sendable {
    var day: Date            // local midnight
    var peakC: Double?
    var avgC: Double?
    var id: Date { day }
    var hasData: Bool { peakC != nil }
}

/// Everything the "This Week" view needs beyond the raw history charts
/// (features #30/#31): the per-day temperature grid, per-day network usage,
/// headline totals, and the battery on-power split.
struct WeeklySummary: Sendable {
    var days: [DayTemp]               // contiguous, ascending, one per calendar day
    var networkPerDay: [DailyDataPoint]
    var totalDataBytes: UInt64
    var hottestDay: DayTemp?
    var hoursPlugged: Double
    var hoursOnBattery: Double
    var hasBattery: Bool

    static let empty = WeeklySummary(days: [], networkPerDay: [], totalDataBytes: 0,
                                     hottestDay: nil, hoursPlugged: 0, hoursOnBattery: 0,
                                     hasBattery: false)

    /// Builds the summary for the trailing `days` local days. `networkDaily`
    /// comes from the engine's authoritative NetworkDataStore counts (more exact
    /// than integrating the rate history).
    static func load(days: Int, networkDaily: [DailyDataPoint],
                     now: Date = Date(), calendar: Calendar = .current) async -> WeeklySummary {
        async let hotspotTask = HistoryStore.shared.localDailyRollups(
            metric: HistoryMetric.hotspot, days: days, endingAt: now)
        async let pluggedTask = HistoryStore.shared.localDailyRollups(
            metric: HistoryMetric.batteryPlugged, days: days, endingAt: now)
        let (hotspot, plugged) = await (hotspotTask, pluggedTask)

        // Index temperature rollups by local day.
        let today = calendar.startOfDay(for: now)
        var tempByDay: [Date: HistoryPoint] = [:]
        for p in hotspot { tempByDay[calendar.startOfDay(for: p.date)] = p }

        // Contiguous list of the last `days` days (oldest → newest).
        var cells: [DayTemp] = []
        for offset in stride(from: days - 1, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let p = tempByDay[day]
            cells.append(DayTemp(day: day, peakC: p?.max, avgC: p?.avg))
        }

        let hottest = cells.filter { $0.peakC != nil }.max { ($0.peakC ?? 0) < ($1.peakC ?? 0) }

        // Network per day from the authoritative daily counters.
        guard let windowStart = calendar.date(byAdding: .day, value: -(days - 1), to: today) else {
            return WeeklySummary(days: cells, networkPerDay: [], totalDataBytes: 0,
                                 hottestDay: hottest, hoursPlugged: 0, hoursOnBattery: 0,
                                 hasBattery: !plugged.isEmpty)
        }
        let net = networkDaily.filter { $0.day >= windowStart && $0.day <= today }
        let totalData = net.reduce(UInt64(0)) { $0 &+ $1.total }

        // Battery: integrate the plugged (0/1) daily means into hours. The
        // current day is scaled by hours elapsed rather than a full 24.
        var pluggedHours = 0.0, batteryHours = 0.0
        for p in plugged {
            let day = calendar.startOfDay(for: p.date)
            let hoursInDay = calendar.isDate(day, inSameDayAs: today)
                ? max(now.timeIntervalSince(today) / 3600, 0.01)
                : 24.0
            let fraction = min(max(p.avg, 0), 1)
            pluggedHours += fraction * hoursInDay
            batteryHours += (1 - fraction) * hoursInDay
        }

        return WeeklySummary(days: cells, networkPerDay: net, totalDataBytes: totalData,
                             hottestDay: hottest,
                             hoursPlugged: pluggedHours, hoursOnBattery: batteryHours,
                             hasBattery: !plugged.isEmpty)
    }
}
