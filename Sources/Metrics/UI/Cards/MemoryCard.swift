import SwiftUI

struct MemoryCard: View {
    @Environment(MetricsEngine.self) private var engine

    var body: some View {
        let m = engine.memory
        CardContainer(title: "Memory",
                      subtitle: "\(Fmt.bytes(m.usedBytes)) / \(Fmt.bytes(m.totalBytes))") {
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
            StatRow(label: "Swap",
                    value: "\(Fmt.bytes(m.swapUsedBytes)) / \(Fmt.bytes(m.swapTotalBytes))")
            HStack(spacing: 8) {
                Text("Pressure")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                ProgressBar(fraction: m.pressurePercent / 100,
                            color: pressureColor(m.pressurePercent))
                Text(String(format: "%.0f%%", m.pressurePercent))
                    .font(.system(size: 11.5, weight: .medium))
                    .monospacedDigit()
            }
            BarHistogram(values: engine.memoryHistory.ordered, capacity: 120, color: .indigo)
                .frame(height: 24)
        }
    }

    private func pressureColor(_ percent: Double) -> Color {
        if percent < 50 { return .green }
        if percent < 80 { return .yellow }
        return .red
    }
}
