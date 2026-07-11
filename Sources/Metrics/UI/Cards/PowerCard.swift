import SwiftUI

struct PowerCard: View {
    @Environment(MetricsEngine.self) private var engine
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        let p = engine.power
        // Like the GPU/battery cards, render nothing until real data arrives.
        if p.available {
            CardContainer(title: "Power", subtitle: Fmt.watts(p.totalWatts)) {
                VStack(spacing: 5) {
                    StatRow(label: cpuLabel(p), value: Fmt.watts(p.cpuWatts), dotColor: .orange)
                    StatRow(label: "GPU", value: Fmt.watts(p.gpuWatts), dotColor: .green)
                    if let ane = p.aneWatts {
                        StatRow(label: "ANE", value: Fmt.watts(ane), dotColor: .teal)
                    }
                    if let dram = p.dramWatts {
                        StatRow(label: "DRAM", value: Fmt.watts(dram), dotColor: .pink)
                    }
                    StatRow(label: "Total", value: Fmt.watts(p.totalWatts), dotColor: .blue)
                    if let adapter = p.adapterWatts, adapter > 0 {
                        StatRow(label: "Adapter (DC-in)", value: Fmt.watts(adapter), dotColor: .gray)
                    }
                }
                if !p.clusterFreqs.isEmpty {
                    Divider().opacity(0.4)
                    ForEach(p.clusterFreqs) { cluster in
                        StatRow(label: "\(cluster.name) clock", value: clockValue(cluster))
                    }
                }
                ChartWindowPicker(kind: .power)
                chart
            }
        }
    }

    /// The CPU rail is marked "(est.)" when it's derived from the SMC total
    /// because IOReport's CPU energy channels are gated on this machine.
    private func cpuLabel(_ p: PowerSnapshot) -> String {
        p.cpuDerived ? "CPU (est.)" : "CPU"
    }

    private func clockValue(_ cluster: ClusterFrequency) -> String {
        cluster.megahertz < 1 ? "Idle" : Fmt.frequency(cluster.megahertz)
    }

    @ViewBuilder private var chart: some View {
        if settings.chartWindow(for: .power) == .live {
            // Watts aren't 0…1, so the auto-scaling Sparkline fits better than the
            // fraction-based BarHistogram used elsewhere.
            Sparkline(values: engine.powerHistory.ordered, capacity: 120, color: .orange,
                      valueLabel: { Fmt.watts($0) }, sampleInterval: settings.sampleInterval)
                .frame(height: 36)
        } else {
            HistoryChartView(metric: HistoryMetric.powerTotal, window: settings.chartWindow(for: .power),
                             color: .orange, valueFormat: { Fmt.watts($0) })
                .frame(height: 56)
        }
    }
}
