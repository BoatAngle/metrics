import SwiftUI

struct BatteryCard: View {
    @Environment(MetricsEngine.self) private var engine
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        if engine.battery.hasBattery {
            card(engine.battery)
        } else {
            EmptyView()
        }
    }

    private func card(_ b: BatterySnapshot) -> some View {
        CardContainer(title: "Battery", subtitle: subtitle(b)) {
            HStack(alignment: .center, spacing: 14) {
                DonutGauge(fraction: b.percent / 100,
                           color: gaugeColor(b.percent),
                           centerTop: String(format: "%.0f%%", b.percent),
                           centerBottom: stateWord(b))
                VStack(spacing: 5) {
                    if let mins = b.timeRemainingMinutes, mins > 0 {
                        StatRow(label: "Time remaining", value: timeString(mins))
                    }
                    if let w = b.watts {
                        StatRow(label: "Power", value: String(format: "%+.1f W", w))
                    }
                    if let a = b.amperage {
                        StatRow(label: "Amperage", value: String(format: "%+.2f A", a))
                    }
                    if let v = b.voltage {
                        StatRow(label: "Voltage", value: String(format: "%.2f V", v))
                    }
                    if let adapter = b.adapterDescription, !adapter.isEmpty {
                        StatRow(label: "Adapter", value: adapter)
                    }
                }
            }
            if hasHealthInfo(b) {
                Divider()
                VStack(spacing: 5) {
                    if let hp = b.healthPercent {
                        StatRow(label: "Health", value: String(format: "%.0f%%", hp))
                        ProgressBar(fraction: hp / 100, color: healthColor(hp))
                    }
                    if let cycles = b.cycleCount {
                        StatRow(label: "Cycles", value: "\(cycles)")
                    }
                    if let maxC = b.maxCapacitymAh, let design = b.designCapacitymAh {
                        StatRow(label: "Capacity", value: "\(maxC) / \(design) mAh")
                    }
                    if let t = b.temperatureC {
                        StatRow(label: "Temperature",
                                value: Fmt.temp(t, fahrenheit: settings.useFahrenheit))
                    }
                }
            }
        }
    }

    private func stateWord(_ b: BatterySnapshot) -> String {
        if b.isCharging { return "Charging" }
        if b.isPluggedIn { return "Charged" }
        return "Discharging"
    }

    private func subtitle(_ b: BatterySnapshot) -> String {
        b.isPluggedIn ? stateWord(b) + " · Plugged in" : stateWord(b)
    }

    private func gaugeColor(_ percent: Double) -> Color {
        if percent < 15 { return .red }
        if percent < 40 { return .yellow }
        return .green
    }

    private func healthColor(_ percent: Double) -> Color {
        if percent < 60 { return .red }
        if percent < 80 { return .yellow }
        return .green
    }

    private func hasHealthInfo(_ b: BatterySnapshot) -> Bool {
        b.healthPercent != nil || b.cycleCount != nil || b.temperatureC != nil
            || (b.maxCapacitymAh != nil && b.designCapacitymAh != nil)
    }

    private func timeString(_ minutes: Int) -> String {
        let h = minutes / 60
        let m = minutes % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}
