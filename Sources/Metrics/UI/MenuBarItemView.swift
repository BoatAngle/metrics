import SwiftUI

extension MenuBarWidgetKind {
    /// Stable status item width. Sizing items to their live content makes the
    /// whole menu bar shift every second as values change digits.
    var fixedWidth: CGFloat {
        switch self {
        case .cpuPercent: return 54
        case .cpuGraph: return 54
        case .gpu: return 60
        case .gpuGraph: return 54
        case .memory: return 54
        case .memoryGraph: return 54
        case .network: return 68
        case .disk: return 54
        case .battery: return 58
        case .temperature: return 54
        }
    }
}

/// The compact content rendered inside a status bar item. Clicks reach the
/// NSStatusBarButton because the PassthroughHostingView wrapping this view
/// blocks hit testing for the whole subtree.
struct MenuBarItemView: View {
    @Environment(MetricsEngine.self) private var engine
    @Environment(SettingsStore.self) private var settings
    let kind: MenuBarWidgetKind

    var body: some View {
        content
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .fixedSize()
            .frame(width: kind.fixedWidth)
    }

    @ViewBuilder private var content: some View {
        switch kind {
        case .cpuPercent:
            HStack(spacing: 3) {
                Image(systemName: "cpu").font(.system(size: 11))
                Text(Fmt.percent(engine.cpu.totalUsage))
            }
        case .cpuGraph:
            BarHistogram(values: engine.cpuHistory.ordered, capacity: 30, color: .green)
                .frame(width: 46, height: 15)
        case .gpu:
            HStack(spacing: 3) {
                Text("GPU").font(.system(size: 9, weight: .semibold))
                Text(Fmt.percent(engine.gpu.usageFraction))
            }
        case .gpuGraph:
            BarHistogram(values: engine.gpuHistory.ordered, capacity: 30, color: .orange)
                .frame(width: 46, height: 15)
        case .memoryGraph:
            BarHistogram(values: engine.memoryHistory.ordered, capacity: 30, color: .indigo)
                .frame(width: 46, height: 15)
        case .memory:
            HStack(spacing: 3) {
                Image(systemName: "memorychip").font(.system(size: 11))
                Text(Fmt.percent(engine.memory.usedFraction))
            }
        case .network:
            VStack(alignment: .trailing, spacing: -1) {
                Text("↓ " + Fmt.rate(engine.network.downBytesPerSec))
                Text("↑ " + Fmt.rate(engine.network.upBytesPerSec))
            }
            .font(.system(size: 9, weight: .medium).monospacedDigit())
        case .disk:
            HStack(spacing: 3) {
                Image(systemName: "internaldrive").font(.system(size: 11))
                Text(Fmt.percent(engine.disk.root?.usedFraction ?? 0))
            }
        case .battery:
            HStack(spacing: 3) {
                Image(systemName: batterySymbol).font(.system(size: 11))
                Text(String(format: "%.0f%%", engine.battery.percent))
            }
        case .temperature:
            // One combined item: CPU and GPU stack into the same slot
            // instead of claiming two spots in the menu bar.
            if engine.sensors.gpuTempC != nil {
                VStack(alignment: .leading, spacing: -1) {
                    Text("C " + shortTemp(engine.sensors.cpuTempC))
                    Text("G " + shortTemp(engine.sensors.gpuTempC))
                }
                .font(.system(size: 9, weight: .medium).monospacedDigit())
            } else {
                HStack(spacing: 2) {
                    Image(systemName: "thermometer.medium").font(.system(size: 11))
                    if let t = engine.sensors.cpuTempC {
                        Text(Fmt.temp(t, fahrenheit: settings.useFahrenheit))
                    } else {
                        Text("–")
                    }
                }
            }
        }
    }

    /// Degrees-only ("53°"), unit implied by the settings toggle.
    private func shortTemp(_ celsius: Double?) -> String {
        guard let celsius else { return "–" }
        return Fmt.tempShort(celsius, fahrenheit: settings.useFahrenheit)
    }

    private var batterySymbol: String {
        let b = engine.battery
        guard b.hasBattery else { return "battery.0percent" }
        if b.isCharging { return "battery.100percent.bolt" }
        switch b.percent {
        case ..<15: return "battery.25percent"
        case ..<40: return "battery.50percent"
        case ..<70: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}
