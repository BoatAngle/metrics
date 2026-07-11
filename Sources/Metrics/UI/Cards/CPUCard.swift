import SwiftUI

struct CPUCard: View {
    @Environment(MetricsEngine.self) private var engine
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        CardContainer(title: "Processor") {
            HStack(alignment: .center, spacing: 14) {
                DonutGauge(fraction: engine.cpu.totalUsage,
                           color: .green,
                           centerTop: Fmt.percent(engine.cpu.totalUsage),
                           centerBottom: "CPU")
                VStack(spacing: 5) {
                    StatRow(label: "User", value: Fmt.percent(engine.cpu.userUsage), dotColor: .blue)
                    StatRow(label: "System", value: Fmt.percent(engine.cpu.systemUsage), dotColor: .red)
                    StatRow(label: "Idle", value: Fmt.percent(engine.cpu.idleUsage), dotColor: .gray)
                }
            }
            ChartWindowPicker(kind: .cpu)
            chart
            if !engine.cpu.perCore.isEmpty {
                coreStrip
            }
        }
    }

    @ViewBuilder private var chart: some View {
        if settings.chartWindow(for: .cpu) == .live {
            BarHistogram(values: engine.cpuHistory.ordered, capacity: 120, color: .green,
                         valueLabel: { Fmt.percent($0) }, sampleInterval: settings.sampleInterval)
                .frame(height: 36)
        } else {
            HistoryChartView(metric: HistoryMetric.cpu, window: settings.chartWindow(for: .cpu),
                             color: .green, valueFormat: Fmt.percentValue, yDomain: 0...100)
                .frame(height: 56)
        }
    }

    private var coreStrip: some View {
        HStack(spacing: 2) {
            ForEach(Array(engine.cpu.perCore.enumerated()), id: \.offset) { _, load in
                coreBar(load)
            }
        }
    }

    private func coreBar(_ load: Double) -> some View {
        let clamped = min(max(load, 0), 1)
        return ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.primary.opacity(0.06))
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(coreColor(clamped))
                .frame(height: max(2, CGFloat(clamped) * 20))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 20)
    }

    private func coreColor(_ load: Double) -> Color {
        if load < 0.5 { return .green }
        if load < 0.8 { return .orange }
        return .red
    }
}
