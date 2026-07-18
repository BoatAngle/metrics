import SwiftUI

struct DeviceCard: View {
    @Environment(MetricsEngine.self) private var engine
    @Environment(SettingsStore.self) private var settings

    enum Scope: String, CaseIterable, Identifiable {
        case boot, wake
        var id: String { rawValue }
        var title: String { self == .boot ? "Since boot" : "Since wake" }
    }

    // Plain State (not @State): the macro form needs the SwiftUIMacros plugin,
    // which the Command Line Tools toolchain doesn't ship. SwiftUI picks up
    // stored DynamicProperty values by reflection, so this behaves the same.
    var scope = State(initialValue: Scope.boot)
    var bootStats = State(initialValue: SessionStats?.none)
    var wakeStats = State(initialValue: SessionStats?.none)
    var showingDiagnostics = State(initialValue: false)

    var body: some View {
        CardContainer(title: "Device") {
            VStack(spacing: 5) {
                ForEach(rows, id: \.label) { row in
                    if row.copyable {
                        // Identity values are click-to-copy (#49).
                        CopyableStatRow(label: row.label, value: row.value)
                    } else {
                        StatRow(label: row.label, value: row.value)
                    }
                }
            }
            Divider()
            sessionSection
            Divider()
            CardPushButton(title: "Run Diagnostics", systemImage: "stethoscope") {
                showingDiagnostics.wrappedValue = true
            }
        }
        .task { await loadStats() }
        .sheet(isPresented: showingDiagnostics.projectedValue) {
            DiagnosticsView { showingDiagnostics.wrappedValue = false }
                .environment(engine)
                .environment(settings)
        }
    }

    // MARK: - Session stats (feature #25)

    private var sessionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: scope.projectedValue) {
                ForEach(Scope.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .controlSize(.mini)
            .labelsHidden()

            let stats = scope.wrappedValue == .boot ? bootStats.wrappedValue : wakeStats.wrappedValue
            if let stats, stats.hasData {
                VStack(spacing: 4) {
                    ForEach(sessionRows(stats), id: \.0) { row in
                        StatRow(label: row.0, value: row.1)
                    }
                }
            } else {
                Text("Collecting session data…")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func sessionRows(_ s: SessionStats) -> [(String, String)] {
        var out: [(String, String)] = []
        if let avg = s.avgCPU, let peak = s.peakCPU {
            out.append(("CPU", "avg \(Fmt.percentValue(avg)) · peak \(Fmt.percentValue(peak))"))
        }
        if let avg = s.avgGPU, let peak = s.peakGPU, peak > 0 {
            out.append(("GPU", "avg \(Fmt.percentValue(avg)) · peak \(Fmt.percentValue(peak))"))
        }
        if let avg = s.avgHotspot, let peak = s.peakHotspot {
            out.append(("Hotspot", "avg \(Fmt.temp(avg, fahrenheit: settings.useFahrenheit)) · peak \(Fmt.temp(peak, fahrenheit: settings.useFahrenheit))"))
        }
        if let down = s.netDownBytes, let up = s.netUpBytes {
            let downStr = Fmt.bytes(UInt64(max(0, down)))
            let upStr = Fmt.bytes(UInt64(max(0, up)))
            out.append(("Network", "↓ \(downStr) · ↑ \(upStr)"))
        }
        return out
    }

    private func loadStats() async {
        while !Task.isCancelled {
            if let boot = engine.device.bootDate {
                bootStats.wrappedValue = await SessionStats.load(since: boot)
            }
            wakeStats.wrappedValue = await SessionStats.load(since: engine.lastWakeDate)
            try? await Task.sleep(nanoseconds: 15 * 1_000_000_000)
        }
    }

    // MARK: - Device rows

    private var rows: [(label: String, value: String, copyable: Bool)] {
        let d = engine.device
        var out: [(label: String, value: String, copyable: Bool)] = []
        if !d.modelName.isEmpty { out.append(("Model", d.modelName, false)) }
        if !d.chipName.isEmpty { out.append(("Chip", d.chipName, false)) }
        if !d.osVersionString.isEmpty {
            let os = d.buildVersion.isEmpty
                ? d.osVersionString
                : "\(d.osVersionString) (\(d.buildVersion))"
            out.append(("macOS", os, true))
        }
        if !d.hostname.isEmpty { out.append(("Hostname", d.hostname, true)) }
        if d.uptimeSeconds > 0 { out.append(("Uptime", Fmt.uptime(d.uptimeSeconds), false)) }
        if let boot = d.bootDate { out.append(("Booted", Fmt.date(boot), false)) }
        return out
    }
}
