import AppKit
import SwiftUI

struct BatteryCard: View {
    @Environment(MetricsEngine.self) private var engine
    @Environment(SettingsStore.self) private var settings

    // Plain State (not @State): the macro form needs the SwiftUIMacros plugin,
    // which the Command Line Tools toolchain doesn't ship. SwiftUI picks up
    // stored DynamicProperty values by reflection, so this behaves the same.
    private var healthExpanded = State(initialValue: false)
    /// Daily health-% series (months scale), loaded off-main while the Health
    /// history section is open.
    private var healthPoints = State(initialValue: [HistoryPoint]())

    private var charge: BatteryChargeControl { .shared }

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
            if charge.supported {
                Divider()
                chargeLimitSection
            }
            if b.healthPercent != nil {
                Divider()
                healthHistorySection
            }
        }
    }

    // MARK: - Charge limit (feature #11)

    private var chargeLimitSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Limit charging to 80%")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                // AppKit control: a SwiftUI Toggle's tap can be swallowed by the
                // card's .onDrag reorder gesture; NSSwitch receives it directly.
                AppKitSwitch(isOn: charge.limitEnabled,
                             enabled: charge.canControl && !charge.busy) { on in
                    charge.setLimit(on)
                }
                .frame(width: 38, height: 20)
            }
            if !charge.canControl {
                Text("Install or update the helper in Settings → Fans to change the charge limit.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if charge.limitEnabled {
                if charge.chargingToFull {
                    Text("Charging to 100% once — the 80% limit resumes at full charge or when unplugged.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    // AppKit button: a SwiftUI Button here is dead inside a card.
                    CardTextButton(title: "Charge to 100% once", enabled: !charge.busy) {
                        charge.chargeToFullOnce()
                    }
                    .frame(height: 22)
                }
            }
            if let error = charge.lastError {
                Text(error)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Health history (feature #27)

    private var healthHistorySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureButton(title: "Health history", expanded: healthExpanded.wrappedValue) {
                healthExpanded.wrappedValue.toggle()
            }
            .frame(height: 16)
            if healthExpanded.wrappedValue {
                healthHistoryBody
            }
        }
        .task(id: healthExpanded.wrappedValue) { [healthExpanded, healthPoints] in
            guard healthExpanded.wrappedValue else { return }
            while !Task.isCancelled {
                let series = await HistoryStore.shared.series(
                    metric: HistoryMetric.batteryHealth, window: 180 * 86400)
                await MainActor.run { healthPoints.wrappedValue = series }
                try? await Task.sleep(nanoseconds: 300 * 1_000_000_000)  // 5 min
            }
        }
    }

    @ViewBuilder private var healthHistoryBody: some View {
        let points = healthPoints.wrappedValue
        let projection = BatteryHealthProjection.compute(points: points)
        if case .collecting = projection {
            Text("Collecting data — check back in a couple weeks.")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            HistoryChart(points: points,
                         window: 180 * 86400,
                         color: .green,
                         valueFormat: { Fmt.percentValue($0) })
                .frame(height: 90)
            if case .reaches80(let date) = projection {
                Label("Projected to reach 80% around \(Self.monthYear(date))",
                      systemImage: "chart.line.downtrend.xyaxis")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private static func monthYear(_ date: Date) -> String {
        monthYearFormatter.string(from: date)
    }

    private static let monthYearFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMMM yyyy"; return f
    }()

    // MARK: - Helpers

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

// MARK: - AppKit controls (survive the card's drag-to-reorder gesture)

/// An AppKit `NSSwitch` used instead of a SwiftUI `Toggle`: the dashboard
/// cards carry an `.onDrag` reorder gesture that can swallow SwiftUI control
/// taps, but the native switch receives clicks directly.
private struct AppKitSwitch: NSViewRepresentable {
    var isOn: Bool
    var enabled: Bool
    var onChange: (Bool) -> Void

    func makeNSView(context: Context) -> NSSwitch {
        let sw = NSSwitch()
        sw.controlSize = .small
        sw.target = context.coordinator
        sw.action = #selector(Coordinator.changed(_:))
        return sw
    }

    func updateNSView(_ nsView: NSSwitch, context: Context) {
        context.coordinator.onChange = onChange
        nsView.state = isOn ? .on : .off
        nsView.isEnabled = enabled
    }

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    final class Coordinator: NSObject {
        var onChange: (Bool) -> Void
        init(onChange: @escaping (Bool) -> Void) { self.onChange = onChange }
        @objc func changed(_ sender: NSSwitch) { onChange(sender.state == .on) }
    }
}

/// A small bordered AppKit push button for use inside a card (a SwiftUI
/// `Button` there is dead — the `.onDrag` reorder gesture eats its taps).
private struct CardTextButton: NSViewRepresentable {
    var title: String
    var enabled: Bool
    var action: () -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: title, target: context.coordinator,
                              action: #selector(Coordinator.fire))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.action = action
        nsView.title = title
        nsView.isEnabled = enabled
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func fire() { action() }
    }
}

/// A borderless AppKit disclosure header (chevron + label) that toggles a
/// section open. Uses NSButton for the same drag-gesture reason as above.
private struct DisclosureButton: NSViewRepresentable {
    var title: String
    var expanded: Bool
    var action: () -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.bezelStyle = .inline
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.alignment = .left
        button.contentTintColor = .secondaryLabelColor
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        button.target = context.coordinator
        button.action = #selector(Coordinator.fire)
        button.setContentHuggingPriority(.required, for: .horizontal)
        apply(to: button)
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.action = action
        apply(to: nsView)
    }

    private func apply(to button: NSButton) {
        let symbol = expanded ? "chevron.down" : "chevron.right"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.attributedTitle = NSAttributedString(
            string: "  " + title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor
            ])
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func fire() { action() }
    }
}
