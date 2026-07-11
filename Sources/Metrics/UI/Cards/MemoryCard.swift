import SwiftUI

struct MemoryCard: View {
    @Environment(MetricsEngine.self) private var engine
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        let m = engine.memory
        CardContainer(title: "Memory",
                      subtitle: "\(Fmt.bytes(m.usedBytes)) / \(Fmt.bytes(m.totalBytes))",
                      titleAccessory: AnyView(pressureBadge(m.pressureLevel))) {
            HStack(alignment: .center, spacing: 14) {
                DonutGauge(fraction: m.usedFraction,
                           color: .purple,
                           centerTop: Fmt.percent(m.usedFraction),
                           centerBottom: Fmt.bytes(m.usedBytes))
                VStack(spacing: 5) {
                    StatRow(label: "App", value: Fmt.bytes(m.appBytes), dotColor: .purple)
                    StatRow(label: "Wired", value: Fmt.bytes(m.wiredBytes), dotColor: .indigo)
                    StatRow(label: "Compressed", value: Fmt.bytes(m.compressedBytes), dotColor: .pink)
                    StatRow(label: "Cached", value: Fmt.bytes(m.cachedBytes), dotColor: .gray)
                }
            }
            StatRow(label: "Swap Used",
                    value: "\(Fmt.bytes(m.swapUsedBytes)) / \(Fmt.bytes(m.swapTotalBytes))")
            StatRow(label: "Swap activity", value: swapActivity(m))
            HStack(spacing: 8) {
                Text("Pressure")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                ProgressBar(fraction: m.pressurePercent / 100,
                            color: levelColor(m.pressureLevel))
                Text(String(format: "%.0f%%", m.pressurePercent))
                    .font(.system(size: 11.5, weight: .medium))
                    .monospacedDigit()
            }
            ChartWindowPicker(kind: .memory)
            chart
        }
    }

    /// Colour-coded pressure dot + level word shown beside the card's value.
    private func pressureBadge(_ level: MemoryPressureLevel) -> some View {
        HStack(spacing: 4) {
            Circle().fill(levelColor(level)).frame(width: 7, height: 7)
            Text(level.label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func swapActivity(_ m: MemorySnapshot) -> String {
        if m.swapInBytesPerSec < 1 && m.swapOutBytesPerSec < 1 { return "Idle" }
        return "in \(Fmt.rate(m.swapInBytesPerSec))  ·  out \(Fmt.rate(m.swapOutBytesPerSec))"
    }

    @ViewBuilder private var chart: some View {
        if settings.chartWindow(for: .memory) == .live {
            BarHistogram(values: engine.memoryHistory.ordered, capacity: 120, color: .indigo,
                         valueLabel: { Fmt.percent($0) }, sampleInterval: settings.sampleInterval)
                .frame(height: 24)
        } else {
            HistoryChartView(metric: HistoryMetric.memoryUsed, window: settings.chartWindow(for: .memory),
                             color: .indigo, valueFormat: { Fmt.bytes(UInt64(max(0, $0))) })
                .frame(height: 56)
        }
    }

    private func levelColor(_ level: MemoryPressureLevel) -> Color {
        switch level {
        case .normal: return .green
        case .warning: return .yellow
        case .critical: return .red
        }
    }
}
