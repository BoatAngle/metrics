import SwiftUI

struct BluetoothCard: View {
    @Environment(MetricsEngine.self) private var engine

    var body: some View {
        if engine.bluetooth.isEmpty {
            EmptyView()
        } else {
            CardContainer(title: "Bluetooth") {
                VStack(spacing: 7) {
                    ForEach(engine.bluetooth) { device in
                        deviceRow(device)
                    }
                }
            }
        }
    }

    private func deviceRow(_ device: BluetoothDeviceSample) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name)
                    .font(.system(size: 11.5))
                    .lineLimit(1)
                if let kind = device.kind, !kind.isEmpty {
                    Text(kind)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 12)
            if let percent = device.batteryPercent {
                ProgressBar(fraction: Double(percent) / 100, color: batteryColor(percent))
                    .frame(width: 48)
                Text("\(percent)%")
                    .font(.system(size: 11.5, weight: .medium))
                    .monospacedDigit()
            } else {
                Text("—")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func batteryColor(_ percent: Int) -> Color {
        if percent > 50 { return .green }
        if percent > 20 { return .yellow }
        return .red
    }
}
