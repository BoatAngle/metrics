import SwiftUI

// MARK: - Window selection

/// The time window a live-graph card is showing. "Live" keeps the existing
/// real-time chart; the others swap in `HistoryChart` fed from `HistoryStore`.
enum ChartWindow: String, CaseIterable, Identifiable, Hashable {
    case live, hour, day, week

    var id: String { rawValue }

    var title: String {
        switch self {
        case .live: return "Live"
        case .hour: return "1h"
        case .day: return "24h"
        case .week: return "7d"
        }
    }

    /// Trailing span passed to `HistoryStore.series`; nil for the live chart.
    var seconds: TimeInterval? {
        switch self {
        case .live: return nil
        case .hour: return 3600
        case .day: return 86400
        case .week: return 7 * 86400
        }
    }

    /// How often the history view re-queries the store. Coarser windows move
    /// slowly, so they refresh far less often — keeps the popover snappy.
    var refreshInterval: TimeInterval {
        switch self {
        case .live: return 1
        case .hour: return 5
        case .day: return 20
        case .week: return 60
        }
    }
}

// MARK: - Window picker

/// Compact Live / 1h / 24h / 7d selector, persisted per card. A segmented
/// Picker (unlike a plain Button) survives the card's drag-to-reorder gesture.
struct ChartWindowPicker: View {
    @Environment(SettingsStore.self) private var settings
    let kind: CardKind

    var body: some View {
        Picker("Window", selection: binding) {
            ForEach(ChartWindow.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .controlSize(.mini)
        .labelsHidden()
    }

    private var binding: Binding<ChartWindow> {
        Binding(get: { settings.chartWindow(for: kind) },
                set: { settings.setChartWindow($0, for: kind) })
    }
}

// MARK: - History-backed chart

/// Loads a `HistoryStore` series off-main for a metric + window and renders it
/// with `HistoryChart`, refreshing on a cadence matched to the window. The
/// `.task(id:)` is keyed on metric+window, so hover redraws never re-query and
/// changing window cancels the old loop cleanly.
struct HistoryChartView: View {
    let metric: String
    let window: ChartWindow
    var color: Color = .accentColor
    var valueFormat: (Double) -> String
    var yDomain: ClosedRange<Double>? = nil

    // Plain State (not @State): the macro form needs the SwiftUIMacros plugin,
    // which the Command Line Tools toolchain doesn't ship.
    var points = State(initialValue: [HistoryPoint]())

    var body: some View {
        HistoryChart(points: points.wrappedValue,
                     window: window.seconds ?? 3600,
                     color: color,
                     valueFormat: valueFormat,
                     yDomain: yDomain)
            .task(id: "\(metric)|\(window.rawValue)") { [metric, window, points] in
                let seconds = window.seconds ?? 3600
                let refresh = window.refreshInterval
                while !Task.isCancelled {
                    let series = await HistoryStore.shared.series(metric: metric, window: seconds)
                    await MainActor.run { points.wrappedValue = series }
                    try? await Task.sleep(nanoseconds: UInt64(refresh * 1_000_000_000))
                }
            }
    }
}

/// Canvas rendering of an aggregated history series: a min/max band, the
/// average line on top, time labels along the bottom, value labels at the
/// edges, and a value/time crosshair tooltip on hover. Purely presentational —
/// it draws whatever `points` it's given.
struct HistoryChart: View {
    var points: [HistoryPoint]
    var window: TimeInterval
    var endDate: Date = Date()
    var color: Color = .accentColor
    var valueFormat: (Double) -> String
    /// Fixed y-range (e.g. 0...100 for percentages); nil auto-fits the data.
    var yDomain: ClosedRange<Double>? = nil

    // Plain State (not @State): the macro form needs the SwiftUIMacros plugin,
    // which the Command Line Tools toolchain doesn't ship.
    var hover = State<CGPoint?>(initialValue: nil)

    private static let axisHeight: CGFloat = 12

    var body: some View {
        Canvas { ctx, size in
            guard !points.isEmpty else {
                let text = ctx.resolve(Text("Collecting…")
                    .font(.system(size: 10)).foregroundStyle(.secondary))
                ctx.draw(text, at: CGPoint(x: size.width / 2, y: size.height / 2))
                return
            }

            let plot = CGRect(x: 0, y: 0, width: size.width,
                              height: max(1, size.height - Self.axisHeight))
            let tEnd = endDate.timeIntervalSince1970
            let tStart = tEnd - window
            let win = max(window, 1)

            // Y range: explicit domain, or the data extremes padded 8%.
            let lo: Double, hi: Double
            if let yDomain {
                lo = yDomain.lowerBound; hi = yDomain.upperBound
            } else {
                let rawLo = points.map(\.min).min() ?? 0
                let rawHi = points.map(\.max).max() ?? 1
                let pad = (rawHi - rawLo) * 0.08
                lo = rawLo - pad; hi = rawHi + pad
            }
            let span = max(hi - lo, 0.000_001)
            func xFor(_ d: Date) -> CGFloat {
                let f = (d.timeIntervalSince1970 - tStart) / win
                return plot.minX + CGFloat(min(max(f, 0), 1)) * plot.width
            }
            func yFor(_ v: Double) -> CGFloat {
                plot.maxY - CGFloat((v - lo) / span) * plot.height
            }

            // Min/max band.
            var band = Path()
            for (i, p) in points.enumerated() {
                let pt = CGPoint(x: xFor(p.date), y: yFor(p.max))
                if i == 0 { band.move(to: pt) } else { band.addLine(to: pt) }
            }
            for p in points.reversed() {
                band.addLine(to: CGPoint(x: xFor(p.date), y: yFor(p.min)))
            }
            band.closeSubpath()
            ctx.fill(band, with: .color(color.opacity(0.15)))

            // Average line.
            var line = Path()
            for (i, p) in points.enumerated() {
                let pt = CGPoint(x: xFor(p.date), y: yFor(p.avg))
                if i == 0 { line.move(to: pt) } else { line.addLine(to: pt) }
            }
            ctx.stroke(line, with: .color(color), lineWidth: 1.5)

            // Value labels at the y extremes.
            let hiText = ctx.resolve(Text(valueFormat(hi))
                .font(.system(size: 9)).foregroundStyle(.tertiary))
            ctx.draw(hiText, at: CGPoint(x: 1, y: plot.minY + 1), anchor: .topLeading)
            let loText = ctx.resolve(Text(valueFormat(lo))
                .font(.system(size: 9)).foregroundStyle(.tertiary))
            ctx.draw(loText, at: CGPoint(x: 1, y: plot.maxY - 1), anchor: .bottomLeading)

            // Time labels along the bottom.
            let axisY = plot.maxY + 1
            for frac in [0.0, 0.5, 1.0] {
                let d = Date(timeIntervalSince1970: tStart + win * frac)
                let text = ctx.resolve(Text(timeLabel(d))
                    .font(.system(size: 9)).foregroundStyle(.secondary))
                let anchor: UnitPoint = frac == 0 ? .topLeading : frac == 1 ? .topTrailing : .top
                ctx.draw(text, at: CGPoint(x: plot.minX + CGFloat(frac) * plot.width, y: axisY),
                         anchor: anchor)
            }

            // Hover crosshair on the nearest point (by x).
            if let h = hover.wrappedValue {
                var best = points[0]; var bestDx = CGFloat.greatestFiniteMagnitude
                for p in points {
                    let dx = abs(xFor(p.date) - h.x)
                    if dx < bestDx { bestDx = dx; best = p }
                }
                drawChartCrosshair(in: &ctx, size: size, x: xFor(best.date), dotY: yFor(best.avg),
                                   value: valueFormat(best.avg), caption: timeLabel(best.date),
                                   color: color)
            }
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            if case .active(let p) = phase { hover.wrappedValue = p } else { hover.wrappedValue = nil }
        }
    }

    private func timeLabel(_ d: Date) -> String {
        if window <= 26 * 3600 { return Self.hourMinute.string(from: d) }
        if window <= 8 * 86400 { return Self.dayHour.string(from: d) }
        return Self.monthDay.string(from: d)
    }

    private static let hourMinute: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
    private static let dayHour: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE HH:mm"; return f
    }()
    private static let monthDay: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d"; return f
    }()
}
