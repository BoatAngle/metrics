import SwiftUI

struct SensorsCard: View {
    @Environment(MetricsEngine.self) private var engine
    @Environment(SettingsStore.self) private var settings

    enum RecordScope: String, CaseIterable, Identifiable {
        case today, allTime
        var id: String { rawValue }
        var title: String { self == .today ? "Today" : "All-time" }
    }

    // Plain State (not @State): the macro form needs the SwiftUIMacros plugin,
    // which the Command Line Tools toolchain doesn't ship.
    var recordsExpanded = State(initialValue: false)
    var recordScope = State(initialValue: RecordScope.allTime)
    var confirmingReset = State(initialValue: false)

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
            if s.cpuTempC != nil || s.gpuTempC != nil {
                Divider()
                ChartWindowPicker(kind: .sensors)
                tempChart
            }
            Divider()
            recordsSection
        }
    }

    // MARK: - Records (feature #26)

    private var recordsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardDisclosureHeader(title: "Records", expanded: recordsExpanded.wrappedValue) {
                recordsExpanded.wrappedValue.toggle()
            }
            if recordsExpanded.wrappedValue {
                Picker("", selection: recordScope.projectedValue) {
                    ForEach(RecordScope.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .controlSize(.mini)
                .labelsHidden()

                let store = RecordsStore.shared
                let set = recordScope.wrappedValue == .today ? store.today : store.allTime
                VStack(spacing: 6) {
                    recordRow("Hottest sensor", set.hottestSensor) {
                        Fmt.temp($0, fahrenheit: settings.useFahrenheit)
                    }
                    recordRow("Peak fan speed", set.peakFanRPM) { "\(Int($0.rounded())) rpm" }
                    recordRow("Peak network", set.peakNetworkBurst) { Fmt.rate($0) }
                    recordRow("Lowest free memory", set.lowestFreeMemory) { Fmt.bytes(UInt64(max(0, $0))) }
                    recordRow("Peak power draw", set.peakPowerWatts) { Fmt.watts($0) }
                }
                resetRow
            }
        }
    }

    private func recordRow(_ title: String, _ entry: RecordsStore.Entry?,
                           format: (Double) -> String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if let entry {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(format(entry.value))
                        .font(.system(size: 11.5, weight: .medium))
                        .monospacedDigit()
                    Text("\(entry.label) · \(Fmt.ago(Date().timeIntervalSince(entry.date)))")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text("—")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var resetRow: some View {
        HStack {
            Spacer()
            if recordScope.wrappedValue == .today {
                CardPushButton(title: "Reset today") {
                    RecordsStore.shared.resetToday()
                }
            } else if confirmingReset.wrappedValue {
                CardPushButton(title: "Confirm reset", prominent: true) {
                    RecordsStore.shared.resetAllTime()
                    confirmingReset.wrappedValue = false
                }
            } else {
                CardPushButton(title: "Reset all-time") {
                    confirmingReset.wrappedValue = true
                    let box = confirmingReset
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { box.wrappedValue = false }
                }
            }
        }
    }

    /// Trend of the hottest CPU/GPU sensor — live buffer, or a history series.
    @ViewBuilder private var tempChart: some View {
        if settings.chartWindow(for: .sensors) == .live {
            Sparkline(values: engine.hotspotHistory.ordered, capacity: 120, color: .red,
                      autoBaseline: true,
                      valueLabel: { Fmt.temp($0, fahrenheit: settings.useFahrenheit) },
                      sampleInterval: settings.sampleInterval)
                .frame(height: 28)
        } else {
            HistoryChartView(metric: HistoryMetric.hotspot,
                             window: settings.chartWindow(for: .sensors), color: .red,
                             valueFormat: { Fmt.temp($0, fahrenheit: settings.useFahrenheit) })
                .frame(height: 56)
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
