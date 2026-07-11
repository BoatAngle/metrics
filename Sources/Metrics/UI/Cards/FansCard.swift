import SwiftUI

struct FansCard: View {
    @Environment(MetricsEngine.self) private var engine
    @Environment(SettingsStore.self) private var settings

    // Plain State (not @State): the macro form needs the SwiftUIMacros plugin,
    // which the Command Line Tools toolchain doesn't ship. SwiftUI picks up
    // stored DynamicProperty values by reflection, so this behaves the same.
    private var sliderRPM = State(initialValue: [Int: Double]())

    private var fans: FanControl { .shared }

    var body: some View {
        if engine.sensors.fans.isEmpty {
            EmptyView()
        } else {
            card
        }
    }

    private var card: some View {
        CardContainer(title: "Fan Control", subtitle: subtitle) {
            modePicker
            if !fans.canControlFans {
                Text("Install the fan helper in Settings → Fans to control fan speed.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if fans.effectiveMode.isCurve {
                curveStatus
                FanCurveChart(selected: fans.effectiveMode,
                              drivingTempC: fans.drivingTempC ?? engine.sensors.hotspotC,
                              useFahrenheit: settings.useFahrenheit)
                    .frame(maxWidth: .infinity)
                    .frame(height: 72)
            }
            VStack(spacing: 6) {
                ForEach(engine.sensors.fans) { fan in
                    fanRow(fan)
                }
            }
            if let conflict = fans.conflictingController {
                Label("\(conflict) is also controlling the fans — quit it to avoid conflicts.",
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
            if let error = fans.lastError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
        }
        .onAppear {
            fans.refreshHelperStatus()
            fans.detectConflicts()
        }
    }

    // MARK: Mode

    private var subtitle: String? {
        fans.effectiveMode == .auto ? nil : fans.effectiveMode.title
    }

    private var modePicker: some View {
        Picker("Fan mode", selection: fans.modeBinding) {
            ForEach(FanMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.small)
        .labelsHidden()
        .disabled(!fans.canControlFans)
    }

    // MARK: Curve status

    private var curveStatus: some View {
        Group {
            if let text = fanCurveStatusText(engine: engine, fans: fans,
                                             useFahrenheit: settings.useFahrenheit) {
                Text(text)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                Text("Waiting for first reading…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Per-fan rows

    @ViewBuilder
    private func fanRow(_ fan: FanInfo) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(fan.name)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 12)
                Text("\(Int(fan.rpm).formatted()) rpm")
                    .font(.system(size: 11.5, weight: .medium))
                    .monospacedDigit()
                if fans.effectiveMode.isCurve, let target = fans.currentTargets[fan.id] {
                    Text("→ \(Int(target.rounded()).formatted()) rpm")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
            if fans.effectiveMode == .manual {
                Slider(value: fanSliderBinding(for: fan, store: sliderRPM.projectedValue),
                       in: fan.controlRange,
                       onEditingChanged: { editing in
                           guard !editing else { return }
                           let rpm = fan.clampedSliderValue(sliderRPM.wrappedValue[fan.id])
                           Task { await fans.setManual(fan: fan.id, rpm: rpm) }
                       })
                .controlSize(.mini)
                .disabled(!fans.canControlFans)
            }
        }
    }
}
