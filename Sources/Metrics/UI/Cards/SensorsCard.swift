import SwiftUI

struct SensorsCard: View {
    @Environment(MetricsEngine.self) private var engine
    @Environment(SettingsStore.self) private var settings

    private let gridColumns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        if engine.sensors.available {
            card(engine.sensors)
        } else {
            EmptyView()
        }
    }

    private func card(_ s: SensorsSnapshot) -> some View {
        CardContainer(title: "Sensors") {
            if s.cpuTempC != nil || s.gpuTempC != nil {
                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    if let cpu = s.cpuTempC { tempBlock(cpu, label: "CPU") }
                    if let gpu = s.gpuTempC { tempBlock(gpu, label: "GPU") }
                }
            }
            if !s.extraTemps.isEmpty {
                LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 5) {
                    ForEach(s.extraTemps) { t in
                        StatRow(label: t.name,
                                value: Fmt.temp(t.celsius, fahrenheit: settings.useFahrenheit))
                    }
                }
            }
            if !s.fans.isEmpty {
                VStack(spacing: 5) {
                    ForEach(s.fans) { fan in
                        fanRow(fan)
                    }
                }
            }
        }
    }

    private func tempBlock(_ celsius: Double, label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(Fmt.temp(celsius, fahrenheit: settings.useFahrenheit))
                .font(.system(size: 18, weight: .semibold))
                .monospacedDigit()
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private func fanRow(_ fan: FanInfo) -> some View {
        HStack(spacing: 8) {
            Text(fan.name)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 12)
            if let minRPM = fan.minRPM, let maxRPM = fan.maxRPM, maxRPM > minRPM {
                ProgressBar(fraction: (fan.rpm - minRPM) / (maxRPM - minRPM))
                    .frame(width: 70)
            }
            Text("\(Int(fan.rpm).formatted()) rpm")
                .font(.system(size: 11.5, weight: .medium))
                .monospacedDigit()
        }
    }
}
