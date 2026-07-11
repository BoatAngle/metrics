import SwiftUI

struct GPUCard: View {
    @Environment(MetricsEngine.self) private var engine
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        if engine.gpu.available {
            CardContainer(title: "Graphics", subtitle: engine.gpu.name) {
                HStack(alignment: .center, spacing: 14) {
                    DonutGauge(fraction: engine.gpu.usageFraction,
                               color: .orange,
                               centerTop: Fmt.percent(engine.gpu.usageFraction),
                               centerBottom: "GPU")
                    VStack(alignment: .leading, spacing: 5) {
                        if let r = engine.gpu.rendererUtilization {
                            StatRow(label: "Renderer", value: Fmt.percent(r), dotColor: .orange)
                        }
                        if let t = engine.gpu.tilerUtilization {
                            StatRow(label: "Tiler", value: Fmt.percent(t), dotColor: .yellow)
                        }
                        if let temp = engine.sensors.gpuTempC {
                            StatRow(label: "Temperature",
                                    value: Fmt.temp(temp, fahrenheit: settings.useFahrenheit))
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                BarHistogram(values: engine.gpuHistory.ordered, capacity: 120, color: .orange)
                    .frame(height: 36)
            }
        }
    }
}
