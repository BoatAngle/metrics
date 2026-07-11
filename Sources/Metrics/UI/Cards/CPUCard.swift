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
                coreSection
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

    /// Grouped per-core strip: one labelled panel per E/P cluster when the split
    /// is known (and tiles every core), otherwise a single flat strip.
    @ViewBuilder private var coreSection: some View {
        let cores = engine.cpu.perCore
        let clusters = engine.cpu.clusters
        if !clusters.isEmpty,
           clusters.allSatisfy({ $0.range.upperBound <= cores.count }),
           clusters.reduce(0, { $0 + $1.coreCount }) == cores.count {
            HStack(alignment: .top, spacing: 12) {
                ForEach(clusters) { cluster in
                    clusterPanel(cluster, cores: cores)
                }
            }
        } else {
            plainStrip(cores)
        }
    }

    private func clusterPanel(_ cluster: CPUCluster, cores: [Double]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 2) {
                ForEach(cluster.range, id: \.self) { index in
                    coreBar(cores[index],
                            tooltip: "\(cluster.shortName)\(index - cluster.firstCoreIndex): \(Fmt.percent(cores[index]))")
                }
            }
            Text(cluster.name)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func plainStrip(_ cores: [Double]) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(cores.enumerated()), id: \.offset) { index, load in
                coreBar(load, tooltip: "Core \(index): \(Fmt.percent(load))")
            }
        }
    }

    private func coreBar(_ load: Double, tooltip: String) -> some View {
        let clamped = min(max(load, 0), 1)
        return ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.primary.opacity(0.06))
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(coreColor(clamped))
                .frame(height: max(2, CGFloat(clamped) * 20))
                // Ease each core bar between samples (#50), keyed to the value.
                .animation(.easeOut(duration: 0.25), value: clamped)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 20)
        .help(tooltip)
    }

    private func coreColor(_ load: Double) -> Color {
        if load < 0.5 { return .green }
        if load < 0.8 { return .orange }
        return .red
    }
}
