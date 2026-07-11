import SwiftUI

struct NetworkDataCard: View {
    @Environment(MetricsEngine.self) private var engine

    private let gridColumns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        CardContainer(title: "Network Data", subtitle: "transferred") {
            LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 10) {
                cell("Today", engine.networkData.today)
                cell("Yesterday", engine.networkData.yesterday)
                cell("7 Days", engine.networkData.last7Days)
                cell("30 Days", engine.networkData.last30Days)
            }
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
}
