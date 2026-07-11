import SwiftUI

struct NetworkDataCard: View {
    @Environment(MetricsEngine.self) private var engine
    @Environment(SettingsStore.self) private var settings

    private let gridColumns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        CardContainer(title: "Network Data", subtitle: "transferred") {
            LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 10) {
                cell("Today", engine.networkData.today)
                cell("Yesterday", engine.networkData.yesterday)
                cell("7 Days", engine.networkData.last7Days)
                cell("30 Days", engine.networkData.last30Days)
            }
            Divider()
            cycleSection
        }
    }

    private func cell(_ period: String, _ totals: DataTotals) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(period)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(Fmt.bytes(totals.total))
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
            Text("↓ \(Fmt.bytes(totals.down))   ↑ \(Fmt.bytes(totals.up))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Billing cycle (feature #28)

    private var cycleSection: some View {
        let cycle = BillingCycleUsage.compute(daily: engine.networkData.daily,
                                              startDay: settings.billingCycleStartDay)
        let capBytes = settings.monthlyDataCapGB.map { UInt64(max(0, $0) * 1_000_000_000) }
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("This cycle")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 8)
                Text("\(cycle.daysLeft) \(cycle.daysLeft == 1 ? "day" : "days") left")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            if let capBytes, capBytes > 0 {
                let fraction = min(Double(cycle.total) / Double(capBytes), 1)
                let overCap = cycle.total > capBytes
                Text("\(Fmt.bytes(cycle.total)) of \(Fmt.bytes(capBytes))")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(overCap ? .red : .primary)
                    .monospacedDigit()
                ProgressBar(fraction: fraction, color: barColor(fraction))
                Text("\(Int((Double(cycle.total) / Double(capBytes) * 100).rounded()))% of cap")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            } else {
                Text(Fmt.bytes(cycle.total))
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                Text("↓ \(Fmt.bytes(cycle.down))   ↑ \(Fmt.bytes(cycle.up))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
    }

    private func barColor(_ fraction: Double) -> Color {
        if fraction >= 1 { return .red }
        if fraction >= 0.8 { return .orange }
        return .accentColor
    }
}
