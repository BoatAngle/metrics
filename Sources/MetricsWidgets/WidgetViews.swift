import WidgetKit
import SwiftUI
import AppKit
import WidgetShared

// MARK: - Shared pieces

/// Honest-staleness footer: WidgetKit refreshes are budgeted by the system,
/// so every widget states when its data was captured.
private struct AsOfFooter: View {
    let date: Date

    var body: some View {
        Text("as of \(WFmt.time(date))")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }
}

/// Big monospaced number with a small caption label above it.
private struct BigStat: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
        }
    }
}

private extension View {
    /// Standard widget chrome shared by all Metrics widgets.
    func metricsContainer() -> some View {
        containerBackground(for: .widget) { Color(nsColor: .windowBackgroundColor) }
    }
}

// MARK: - System widget

struct SystemWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "metrics.system", provider: SnapshotProvider()) { entry in
            SystemWidgetView(entry: entry)
                .metricsContainer()
        }
        .configurationDisplayName("System")
        .description("CPU, GPU, and memory usage at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct SystemWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MetricsEntry

    private var s: WidgetSnapshot { entry.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 16) {
                BigStat(label: "CPU", value: WFmt.percent(s.cpuFraction))
                if let gpu = s.gpuFraction {
                    BigStat(label: "GPU", value: WFmt.percent(gpu))
                }
                BigStat(label: "MEM", value: WFmt.percent(s.memoryFraction))
            }
            if family == .systemMedium {
                if let temps = tempsLine {
                    Text(temps)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if !s.fanRPMs.isEmpty {
                    Text("Fans \(s.fanRPMs.map(WFmt.rpm).joined(separator: " · ")) RPM")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Text("Memory \(WFmt.bytes(s.memoryUsedBytes)) of \(WFmt.bytes(s.memoryTotalBytes))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
            AsOfFooter(date: s.capturedAt)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// "CPU 52°C · GPU 48°C" — nil when no temperature is known.
    private var tempsLine: String? {
        var parts: [String] = []
        if let t = s.cpuTempC { parts.append("CPU \(WFmt.temp(t))") }
        if let t = s.gpuTempC { parts.append("GPU \(WFmt.temp(t))") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Battery widget

struct BatteryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "metrics.battery", provider: SnapshotProvider()) { entry in
            BatteryWidgetView(entry: entry)
                .metricsContainer()
        }
        .configurationDisplayName("Battery")
        .description("Battery level and charging state.")
        .supportedFamilies([.systemSmall])
    }
}

struct BatteryWidgetView: View {
    let entry: MetricsEntry

    private var s: WidgetSnapshot { entry.snapshot }
    private var charging: Bool { s.batteryCharging == true }

    var body: some View {
        VStack(spacing: 4) {
            if let percent = s.batteryPercent {
                ring(for: percent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("No battery")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            AsOfFooter(date: s.capturedAt)
        }
    }

    private func ring(for percent: Double) -> some View {
        let fraction = min(max(percent / 100, 0), 1)
        return ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: 7)
            Circle()
                .trim(from: 0, to: max(fraction, 0.01))
                .stroke(ringColor(fraction: fraction), style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text(WFmt.percent(fraction))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                if charging {
                    Image(systemName: "bolt.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                }
            }
        }
        .padding(4)
    }

    private func ringColor(fraction: Double) -> Color {
        if charging { return .green }
        if fraction <= 0.2 { return .red }
        return .accentColor
    }
}

// MARK: - Network widget

struct NetworkWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "metrics.network", provider: SnapshotProvider()) { entry in
            NetworkWidgetView(entry: entry)
                .metricsContainer()
        }
        .configurationDisplayName("Network")
        .description("Data transferred today and last-known transfer rates.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct NetworkWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MetricsEntry

    private var s: WidgetSnapshot { entry.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if family == .systemMedium {
                HStack(alignment: .top, spacing: 16) {
                    column(symbol: "arrow.down", label: "Down",
                           rate: s.downBytesPerSec, today: s.dataTodayDownBytes)
                    column(symbol: "arrow.up", label: "Up",
                           rate: s.upBytesPerSec, today: s.dataTodayUpBytes)
                }
            } else {
                rateRow(symbol: "arrow.down", value: WFmt.rate(s.downBytesPerSec))
                rateRow(symbol: "arrow.up", value: WFmt.rate(s.upBytesPerSec))
                Text("Today \(WFmt.bytes(s.dataTodayDownBytes)) ↓ · \(WFmt.bytes(s.dataTodayUpBytes)) ↑")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
            AsOfFooter(date: s.capturedAt)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func rateRow(symbol: String, value: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
        }
    }

    private func column(symbol: String, label: String, rate: Double, today: UInt64) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.caption2)
                Text(label)
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
            Text(WFmt.rate(rate))
                .font(.title3.weight(.semibold))
                .monospacedDigit()
            Text("\(WFmt.bytes(today)) today")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}
