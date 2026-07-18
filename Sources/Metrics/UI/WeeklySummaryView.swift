import SwiftUI

/// The "This Week" window (features #30/#31): headline totals, 7-day trend
/// charts, and a GitHub-style temperature calendar that expands to a month.
struct WeeklySummaryView: View {
    @Environment(MetricsEngine.self) private var engine
    @Environment(SettingsStore.self) private var settings

    enum Span: Int, CaseIterable, Identifiable {
        case week = 7, month = 30
        var id: Int { rawValue }
        var title: String { self == .week ? "7 days" : "30 days" }
    }

    // Plain State (not @State): the macro form needs the SwiftUIMacros plugin,
    // which the Command Line Tools toolchain doesn't ship.
    var span = State(initialValue: Span.week)
    var summary = State(initialValue: WeeklySummary.empty)

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 1)   // titlebar-bleed guard (see DashboardWindowView)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    headlineRow
                    chartsGrid
                    heatmapSection
                }
                .padding(20)
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor), ignoresSafeAreaEdges: [])
        .frame(minWidth: 640, minHeight: 560)
        .task(id: span.wrappedValue.rawValue) { await reload() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("This \(span.wrappedValue == .week ? "Week" : "Month")")
                    .font(.system(size: 17, weight: .semibold))
                Text("Local history · \(span.wrappedValue.title)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: span.projectedValue) {
                ForEach(Span.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 160)
            .labelsHidden()
        }
    }

    // MARK: - Headline numbers

    private var headlineRow: some View {
        HStack(spacing: 12) {
            headline("Hottest day", value: hottestValue, caption: hottestCaption, systemImage: "thermometer.high", tint: .red)
            headline("Data used", value: Fmt.bytes(summary.wrappedValue.totalDataBytes), caption: "↓ down + ↑ up", systemImage: "arrow.down.circle", tint: .teal)
            headline("Power source", value: powerSplitValue, caption: powerSplitCaption, systemImage: "bolt", tint: .green)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func headline(_ title: String, value: String, caption: String,
                          systemImage: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: systemImage).font(.system(size: 11)).foregroundStyle(tint)
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 20, weight: .semibold))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(caption)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
        )
    }

    private var hottestValue: String {
        guard let peak = summary.wrappedValue.hottestDay?.peakC else { return "—" }
        return Fmt.temp(peak, fahrenheit: settings.useFahrenheit)
    }
    private var hottestCaption: String {
        guard let day = summary.wrappedValue.hottestDay?.day else { return "no data yet" }
        return Self.dayLabel.string(from: day)
    }

    private var powerSplitValue: String {
        let s = summary.wrappedValue
        guard s.hasBattery else { return "AC only" }
        return "\(hoursText(s.hoursOnBattery)) on battery"
    }
    private var powerSplitCaption: String {
        let s = summary.wrappedValue
        guard s.hasBattery else { return "no battery" }
        return "\(hoursText(s.hoursPlugged)) plugged in"
    }

    // MARK: - Trend charts

    private var chartsGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Trends")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            let cols = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
            LazyVGrid(columns: cols, spacing: 12) {
                chartTile("CPU", tint: .accentColor) {
                    HistoryChartView(metric: HistoryMetric.cpu, window: .week, color: .accentColor,
                                     valueFormat: { Fmt.percentValue($0) }, yDomain: 0...100)
                }
                chartTile("Hotspot", tint: .red) {
                    HistoryChartView(metric: HistoryMetric.hotspot, window: .week, color: .red,
                                     valueFormat: { Fmt.temp($0, fahrenheit: settings.useFahrenheit) })
                }
                chartTile("Network per day", tint: .teal) {
                    DailyDataBarChart(points: summary.wrappedValue.networkPerDay)
                }
                chartTile("Battery", tint: .green) {
                    HistoryChartView(metric: HistoryMetric.batteryPercent, window: .week, color: .green,
                                     valueFormat: { Fmt.percentValue($0) }, yDomain: 0...100)
                }
            }
        }
    }

    private func chartTile<Content: View>(_ title: String, tint: Color,
                                          @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
                .frame(height: 92)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
        )
    }

    // MARK: - Heatmap calendar

    private var heatmapSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Temperature calendar")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                heatLegend
            }
            HeatmapGrid(days: summary.wrappedValue.days, useFahrenheit: settings.useFahrenheit)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
        )
    }

    private var heatLegend: some View {
        HStack(spacing: 6) {
            legendSwatch(.green, "<70°")
            legendSwatch(.orange, "70–90°")
            legendSwatch(.red, ">90°")
        }
    }

    private func legendSwatch(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
            Text(label).font(.system(size: 9.5)).foregroundStyle(.tertiary)
        }
    }

    // MARK: - Data / formatting

    private func reload() async {
        let daily = engine.networkData.daily
        summary.wrappedValue = await WeeklySummary.load(days: span.wrappedValue.rawValue,
                                                        networkDaily: daily)
    }

    private func hoursText(_ hours: Double) -> String {
        let total = Int((hours * 60).rounded())
        let h = total / 60, m = total % 60
        if h == 0 { return "\(m)m" }
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    private static let dayLabel: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE, MMM d"; return f
    }()
}

// MARK: - Daily data bar chart

/// Simple per-day network-usage bars with hover tooltips (feature #30). Bars
/// scale to the busiest day; each carries a `.help` with the exact figure.
private struct DailyDataBarChart: View {
    var points: [DailyDataPoint]

    var body: some View {
        if points.isEmpty {
            Text("Collecting…")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let maxTotal = Double(points.map(\.total).max() ?? 1)
            GeometryReader { geo in
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(points) { p in
                        let frac = maxTotal > 0 ? Double(p.total) / maxTotal : 0
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.teal.opacity(0.9))
                            .frame(height: max(2, CGFloat(frac) * (geo.size.height - 2)))
                            .frame(maxWidth: .infinity)
                            .help("\(Self.dayLabel.string(from: p.day)): \(Fmt.bytes(p.total)) (↓\(Fmt.bytes(p.down)) ↑\(Fmt.bytes(p.up)))")
                    }
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
    }

    private static let dayLabel: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE, MMM d"; return f
    }()
}

// MARK: - Heatmap grid

/// GitHub-style calendar: one cell per day, colored by peak hotspot, laid out
/// in week columns. Hover shows the date with that day's peak/avg (feature #31).
private struct HeatmapGrid: View {
    var days: [DayTemp]
    var useFahrenheit: Bool

    var body: some View {
        let columns = Self.weekColumns(days)
        HStack(alignment: .top, spacing: 3) {
            ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                VStack(spacing: 3) {
                    ForEach(0..<7, id: \.self) { row in
                        cell(column[row])
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private func cell(_ day: DayTemp?) -> some View {
        if let day, let peak = day.peakC {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Self.color(peak))
                .frame(width: 13, height: 13)
                .help(tooltip(day, peak: peak))
        } else if let day {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.4))
                .frame(width: 13, height: 13)
                .help("\(Self.dayLabel.string(from: day.day)): no data")
        } else {
            Color.clear.frame(width: 13, height: 13)
        }
    }

    private func tooltip(_ day: DayTemp, peak: Double) -> String {
        var s = "\(Self.dayLabel.string(from: day.day)): peak \(Fmt.temp(peak, fahrenheit: useFahrenheit))"
        if let avg = day.avgC { s += ", avg \(Fmt.temp(avg, fahrenheit: useFahrenheit))" }
        return s
    }

    /// Green < 70 ≤ amber < 90 ≤ red.
    private static func color(_ peakC: Double) -> Color {
        if peakC < 70 { return .green }
        if peakC < 90 { return .orange }
        return .red
    }

    /// Buckets the (ascending) days into week columns aligned to the local
    /// week start, padding leading/trailing slots with nil.
    private static func weekColumns(_ days: [DayTemp]) -> [[DayTemp?]] {
        let cal = Calendar.current
        var columns: [[DayTemp?]] = []
        var current: [DayTemp?] = Array(repeating: nil, count: 7)
        var started = false
        for day in days {
            let weekday = cal.component(.weekday, from: day.day)  // 1…7
            let row = (weekday - cal.firstWeekday + 7) % 7
            if row == 0 && started {
                columns.append(current)
                current = Array(repeating: nil, count: 7)
            }
            current[row] = day
            started = true
        }
        if started { columns.append(current) }
        return columns
    }

    private static let dayLabel: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE, MMM d"; return f
    }()
}
