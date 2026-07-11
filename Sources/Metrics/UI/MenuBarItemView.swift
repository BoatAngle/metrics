import SwiftUI

/// The compact content rendered inside a status bar item, driven by a
/// `WidgetInstance` (Package 11). Clicks reach the NSStatusBarButton because the
/// PassthroughHostingView wrapping this view blocks hit testing for the subtree;
/// per-item click actions are dispatched by `StatusItemController`.
struct MenuBarItemView: View {
    @Environment(MetricsEngine.self) private var engine
    @Environment(SettingsStore.self) private var settings
    let instance: WidgetInstance

    var body: some View {
        content
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .fixedSize()
            .frame(width: MenuBarLayout.width(for: instance))
    }

    /// Reactive severity for the whole item (nil tint at normal load).
    private var level: LoadLevel {
        MenuBarReading.level(for: instance, engine: engine, settings: settings)
    }

    /// Graph/meter/gauge color: warn/crit tint overrides the kind accent.
    private var accentColor: Color { level.tint ?? instance.kind.accent }
    /// Text color: warn/crit tint overrides the label color.
    private var textColor: Color { level.tint ?? .primary }
    /// Status-dot color: green normal, amber warn, red crit.
    private var dotColor: Color {
        switch level {
        case .normal: return .green
        case .warn: return .orange
        case .crit: return .red
        }
    }

    @ViewBuilder private var content: some View {
        switch instance.kind {
        case .network: networkView
        case .combined: combinedView
        case .format: formatView
        case .topProcess: topProcessView
        case .fanRPM: fanView
        case .sensor: sensorView
        case .temperature: temperatureView
        default: scalarView   // cpu / gpu / memory / disk / battery
        }
    }

    // MARK: Scalar kinds

    private var reading: MenuBarReading.Scalar {
        MenuBarReading.scalar(for: instance.kind, engine: engine, instance: instance, settings: settings)
    }

    @ViewBuilder private var scalarView: some View {
        styled(reading: reading) {
            HStack(spacing: 3) {
                icon
                Text(reading.text)
            }
            .foregroundStyle(textColor)
        }
    }

    /// Applies the chosen render style to a scalar reading, falling back to the
    /// text builder for the `.text` style.
    @ViewBuilder private func styled(reading r: MenuBarReading.Scalar,
                                     @ViewBuilder text: () -> some View) -> some View {
        switch instance.style {
        case .text:
            text()
        case .lineGraph:
            if let history = r.history, history.count > 1 {
                MiniLineGraph(values: history, color: accentColor).frame(width: 46, height: 15)
            } else {
                MeterBar(fraction: r.fraction, color: accentColor)
            }
        case .barMeter:
            MeterBar(fraction: r.fraction, color: accentColor)
        case .gauge:
            MiniGauge(fraction: r.fraction, color: accentColor)
        case .dot:
            ColorDot(color: dotColor)
        }
    }

    @ViewBuilder private var icon: some View {
        switch instance.kind {
        case .cpu: Image(systemName: "cpu").font(.system(size: 11))
        case .gpu: Text("GPU").font(.system(size: 9, weight: .semibold))
        case .memory: Image(systemName: "memorychip").font(.system(size: 11))
        case .disk: Image(systemName: "internaldrive").font(.system(size: 11))
        case .battery: Image(systemName: batterySymbol).font(.system(size: 11))
        default: EmptyView()
        }
    }

    // MARK: Temperature (keeps the CPU+GPU stack for the text style)

    @ViewBuilder private var temperatureView: some View {
        if instance.style == .text {
            if engine.sensors.gpuTempC != nil {
                VStack(alignment: .leading, spacing: -1) {
                    Text("C " + shortTemp(engine.sensors.cpuTempC))
                    Text("G " + shortTemp(engine.sensors.gpuTempC))
                }
                .font(.system(size: 9, weight: .medium).monospacedDigit())
                .foregroundStyle(textColor)
            } else {
                HStack(spacing: 2) {
                    Image(systemName: "thermometer.medium").font(.system(size: 11))
                    Text(engine.sensors.cpuTempC.map { Fmt.temp($0, fahrenheit: settings.useFahrenheit) } ?? "–")
                }
                .foregroundStyle(textColor)
            }
        } else {
            styled(reading: reading) { EmptyView() }
        }
    }

    // MARK: Sensor (#38)

    @ViewBuilder private var sensorView: some View {
        let r = reading
        if instance.style == .text {
            HStack(spacing: 3) {
                Text(sensorLabel).font(.system(size: 9, weight: .semibold))
                Text(r.text)
            }
            .foregroundStyle(textColor)
        } else {
            styled(reading: r) { EmptyView() }
        }
    }

    /// The 3-char badge for a sensor item: the custom label, else the first
    /// three letters of the sensor name.
    private var sensorLabel: String {
        if let l = instance.sensorLabel, !l.isEmpty { return String(l.prefix(3)) }
        return String((instance.sensorName ?? "T").prefix(3)).uppercased()
    }

    // MARK: Fan RPM (#38)

    @ViewBuilder private var fanView: some View {
        let r = reading
        if instance.style == .text {
            HStack(spacing: 3) {
                Image(systemName: FanControl.shared.effectiveMode.glyph).font(.system(size: 10))
                Text(r.text)
            }
            .foregroundStyle(textColor)
        } else {
            styled(reading: r) { EmptyView() }
        }
    }

    // MARK: Top process (#39)

    @ViewBuilder private var topProcessView: some View {
        Group {
            if let top = engine.processes.ranked(by: .cpu).first {
                Text("\(top.name.prefix(10)) \(String(format: "%.0f%%", top.cpuPercent))")
                    .foregroundStyle(textColor)
            } else {
                Text("—").foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .minimumScaleFactor(0.7)
        .frame(width: MenuBarLayout.width(for: instance) - 4)
    }

    // MARK: Combined (#34)

    @ViewBuilder private var combinedView: some View {
        let metrics = Array((instance.combinedMetrics ?? []).prefix(3))
        VStack(alignment: .leading, spacing: 1) {
            ForEach(metrics, id: \.self) { m in
                let r = MenuBarReading.scalar(for: m, engine: engine, instance: instance, settings: settings)
                let rowLevel = MenuBarReading.level(forRow: m, engine: engine, instance: instance, settings: settings)
                let rowColor = rowLevel.tint ?? m.accent
                HStack(spacing: 3) {
                    Text(m.badge).font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
                    HMeter(fraction: r.fraction, color: rowColor)
                    Text(r.text).font(.system(size: 8, weight: .medium).monospacedDigit())
                        .foregroundStyle(rowLevel.tint ?? .primary)
                }
            }
        }
    }

    // MARK: Custom format (#36)

    @ViewBuilder private var formatView: some View {
        let template = instance.formatString ?? MenuFormat.defaultTemplate
        Text(MenuFormat.render(template, MenuBarReading.formatValues(engine: engine, settings: settings)))
            .lineLimit(1)
            .truncationMode(.tail)
            .minimumScaleFactor(0.7)
            .foregroundStyle(.primary)
            .frame(width: MenuBarLayout.width(for: instance) - 4)
    }

    // MARK: Network (unchanged two-row rates)

    @ViewBuilder private var networkView: some View {
        VStack(alignment: .trailing, spacing: -1) {
            Text("↓ " + Fmt.rate(engine.network.downBytesPerSec))
            Text("↑ " + Fmt.rate(engine.network.upBytesPerSec))
        }
        .font(.system(size: 9, weight: .medium).monospacedDigit())
    }

    // MARK: Helpers

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
