import AppKit
import SwiftUI

struct DiskCard: View {
    @Environment(MetricsEngine.self) private var engine
    @Environment(SettingsStore.self) private var settings

    // Plain State (not @State): the macro form needs the SwiftUIMacros plugin,
    // which the Command Line Tools toolchain doesn't ship. SwiftUI picks up
    // stored DynamicProperty values by reflection, so this behaves the same.
    var ejecting = State(initialValue: Set<String>())
    var ejectError = State(initialValue: [String: String]())
    /// Per-volume free-space forecasts, keyed by volume path. Loaded off-main
    /// from HistoryStore and refreshed slowly (free space moves over days).
    var forecasts = State(initialValue: [String: DiskForecast]())

    var body: some View {
        let root = engine.disk.root
        CardContainer(title: "Disk", subtitle: root?.name) {
            HStack(alignment: .center, spacing: 14) {
                DonutGauge(fraction: root?.usedFraction ?? 0,
                           color: .teal,
                           centerTop: Fmt.percent(root?.usedFraction ?? 0),
                           centerBottom: root.map { Fmt.bytes($0.usedBytes) })
                VStack(spacing: 5) {
                    StatRow(label: "Used", value: Fmt.bytes(root?.usedBytes ?? 0))
                    StatRow(label: "Free", value: Fmt.bytes(root?.availableBytes ?? 0))
                    StatRow(label: "Total", value: Fmt.bytes(root?.totalBytes ?? 0))
                }
            }
            forecastLine(for: root)

            Divider()
            ioSection

            if !engine.driveHealth.drives.isEmpty {
                Divider()
                driveHealthSection
            }

            if !engine.disk.external.isEmpty {
                Divider()
                VStack(spacing: 8) {
                    ForEach(engine.disk.external) { vol in
                        VStack(alignment: .leading, spacing: 3) {
                            volumeRow(vol)
                            forecastLine(for: vol)
                        }
                    }
                }
            }
        }
        .task(id: forecastTaskID) { await loadForecasts() }
    }

    // MARK: - Disk I/O

    private var ioSection: some View {
        let window = settings.chartWindow(for: .disk)
        return VStack(spacing: 6) {
            ChartWindowPicker(kind: .disk)
            ioRow(icon: "arrow.down", label: "Read",
                  rate: engine.diskIO.readBytesPerSec, liveHistory: engine.diskReadHistory.ordered,
                  metric: HistoryMetric.diskRead, color: .teal, window: window)
            ioRow(icon: "arrow.up", label: "Write",
                  rate: engine.diskIO.writeBytesPerSec, liveHistory: engine.diskWriteHistory.ordered,
                  metric: HistoryMetric.diskWrite, color: .orange, window: window)
        }
    }

    private func ioRow(icon: String, label: String, rate: Double, liveHistory: [Double],
                       metric: String, color: Color, window: ChartWindow) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 3) {
                    Image(systemName: icon)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(color)
                    Text(label)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Text(Fmt.rate(rate))
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
            }
            .frame(width: 92, alignment: .leading)
            if window == .live {
                Sparkline(values: liveHistory, capacity: 120, color: color,
                          valueLabel: { Fmt.rate($0) }, sampleInterval: settings.sampleInterval)
                    .frame(height: 22)
            } else {
                HistoryChartView(metric: metric, window: window, color: color,
                                 valueFormat: { Fmt.rate($0) })
                    .frame(height: 48)
            }
        }
    }

    // MARK: - Drive health

    private var driveHealthSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Drive Health")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.tertiary)
            ForEach(engine.driveHealth.drives) { drive in
                driveHealthRow(drive)
            }
        }
    }

    private func driveHealthRow(_ drive: DriveHealth) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle().fill(drive.status.color).frame(width: 7, height: 7)
                Text(drive.name)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(drive.status.label)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(drive.status.color)
            }
            HStack(alignment: .top, spacing: 16) {
                if let wear = drive.wearPercent {
                    healthMetric("Wear", "\(Int(wear.rounded()))%")
                }
                if let written = drive.dataUnitsWrittenBytes {
                    healthMetric("Written", Fmt.bytes(written))
                }
                if let temp = drive.temperatureC {
                    healthMetric("Temp", Fmt.temp(temp, fahrenheit: settings.useFahrenheit))
                }
                if let spare = drive.availableSparePercent {
                    healthMetric("Spare", "\(Int(spare.rounded()))%")
                }
            }
        }
    }

    private func healthMetric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 11.5, weight: .medium))
                .monospacedDigit()
        }
    }

    // MARK: - Growth forecast

    /// Reloads whenever the set of volumes changes; the loop inside refreshes
    /// on a slow cadence since free-space trends move over days.
    private var forecastTaskID: String {
        engine.disk.volumes.map(\.path).sorted().joined(separator: "|")
    }

    private func loadForecasts() async {
        while !Task.isCancelled {
            // Read live volumes (main actor) each pass so the projection uses
            // current free space, not a value captured when the task started.
            let volumes = engine.disk.volumes
            var result: [String: DiskForecast] = [:]
            for vol in volumes {
                let points = await HistoryStore.shared.series(
                    metric: HistoryMetric.diskFree(vol.path), window: 30 * 86400)
                result[vol.path] = DiskForecast.compute(
                    points: points, currentFreeBytes: Double(vol.availableBytes))
            }
            forecasts.wrappedValue = result
            try? await Task.sleep(nanoseconds: 300 * 1_000_000_000)  // 5 min
        }
    }

    @ViewBuilder private func forecastLine(for vol: VolumeInfo?) -> some View {
        if let vol, let forecast = forecasts.wrappedValue[vol.path] {
            switch forecast {
            case .fillingUp(let days):
                Text("Full in ~\(Self.forecastHorizon(days)) at current rate")
                    .font(.system(size: 10))
                    .foregroundStyle(days < 30 ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .collecting:
                Text("Forecast: collecting data…")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            case .steady:
                EmptyView()
            }
        }
    }

    private static func forecastHorizon(_ days: Double) -> String {
        let d = Int(days.rounded())
        if d < 1 { return "under a day" }
        if d == 1 { return "1 day" }
        if d < 60 { return "\(d) days" }
        if d < 730 { return "\(d / 30) months" }
        return "\(d / 365) years"
    }

    // MARK: - External volume rows

    private func volumeRow(_ vol: VolumeInfo) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(vol.name)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                if vol.isRemovable {
                    if ejecting.wrappedValue.contains(vol.id) {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.6)
                            .frame(width: 16, height: 14)
                    } else {
                        // AppKit button: a SwiftUI Button here is swallowed by
                        // the card's drag-to-reorder gesture; NSButton isn't.
                        EjectButton(tooltip: "Eject \(vol.name)") { eject(vol) }
                            .frame(width: 16, height: 14)
                    }
                }
                Spacer(minLength: 12)
                Text("\(Fmt.bytes(vol.usedBytes)) / \(Fmt.bytes(vol.totalBytes))")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            ProgressBar(fraction: vol.usedFraction, color: .teal)
            if let error = ejectError.wrappedValue[vol.id] {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func eject(_ vol: VolumeInfo) {
        guard !ejecting.wrappedValue.contains(vol.id) else { return }
        ejecting.wrappedValue.insert(vol.id)
        ejectError.wrappedValue[vol.id] = nil
        let url = URL(fileURLWithPath: vol.path)
        Task {
            let result = await Self.performEject(at: url, name: vol.name)
            ejecting.wrappedValue.remove(vol.id)
            if let message = result {
                ejectError.wrappedValue[vol.id] = message
            }
        }
    }

    /// Unmounts and ejects off the main actor (it can block briefly).
    /// Returns nil on success, or a short user-facing message on failure.
    private nonisolated static func performEject(at url: URL, name: String) async -> String? {
        await Task.detached {
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
                return nil
            } catch {
                let reason = (error as NSError).localizedRecoverySuggestion
                    ?? error.localizedDescription
                return reason.isEmpty
                    ? "Couldn't eject \(name) — a program may still be using it."
                    : reason
            }
        }.value
    }
}

private extension DriveHealthStatus {
    var color: Color {
        switch self {
        case .ok: return .green
        case .warning: return .orange
        case .failing: return .red
        case .unknown: return .gray
        }
    }

    var label: String {
        switch self {
        case .ok: return "OK"
        case .warning: return "Warn"
        case .failing: return "Fail"
        case .unknown: return "—"
        }
    }
}

/// A borderless AppKit eject button. Used instead of a SwiftUI `Button`
/// because the dashboard cards carry an `.onDrag` reorder gesture that
/// swallows SwiftUI button taps; an NSButton receives the click directly.
private struct EjectButton: NSViewRepresentable {
    var tooltip: String
    var action: () -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.bezelStyle = .inline
        button.imagePosition = .imageOnly
        button.image = NSImage(systemSymbolName: "eject.fill", accessibilityDescription: "Eject")
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tooltip
        button.target = context.coordinator
        button.action = #selector(Coordinator.fire)
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.action = action
        nsView.toolTip = tooltip
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func fire() { action() }
    }
}
