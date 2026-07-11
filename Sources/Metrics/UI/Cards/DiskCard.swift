import SwiftUI

struct DiskCard: View {
    @Environment(MetricsEngine.self) private var engine

    var body: some View {
        let root = engine.disk.root
        CardContainer(title: "Disk", subtitle: root?.name) {
            HStack(alignment: .center, spacing: 14) {
                DonutGauge(fraction: root?.usedFraction ?? 0,
                           color: .teal,
                           centerTop: Fmt.percent(root?.usedFraction ?? 0),
                           centerBottom: root.map { Fmt.bytes($0.usedBytes) })
                VStack(spacing: 5) {
                    StatRow(label: "Used", value: Fmt.bytes(root?.usedBytes ?? 0))
                    StatRow(label: "Free", value: Fmt.bytes(root?.availableBytes ?? 0))
                    StatRow(label: "Total", value: Fmt.bytes(root?.totalBytes ?? 0))
                }
            }
            if !engine.disk.external.isEmpty {
                Divider()
                VStack(spacing: 8) {
                    ForEach(engine.disk.external) { vol in
                        volumeRow(vol)
                    }
                }
            }
        }
    }

    private func volumeRow(_ vol: VolumeInfo) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(vol.name)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                if vol.isRemovable {
                    Image(systemName: "eject.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 12)
                Text("\(Fmt.bytes(vol.usedBytes)) / \(Fmt.bytes(vol.totalBytes))")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            ProgressBar(fraction: vol.usedFraction, color: .teal)
        }
    }
}
