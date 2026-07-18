import AppKit
import SwiftUI

struct NetworkCard: View {
    @Environment(MetricsEngine.self) private var engine
    @Environment(SettingsStore.self) private var settings

    // Plain State (not @State): the macro form needs the SwiftUIMacros plugin,
    // which the Command Line Tools toolchain doesn't ship. SwiftUI picks up
    // stored DynamicProperty values by reflection, so this behaves the same.
    var publicIP = State<String?>(initialValue: nil)
    var fetchingIP = State(initialValue: false)
    var fetchFailed = State(initialValue: false)
    var outagesExpanded = State(initialValue: false)

    var body: some View {
        let net = engine.network
        CardContainer(title: "Network Activity", subtitle: subtitle(net),
                      titleAccessory: AnyView(statusAccessory)) {
            ChartWindowPicker(kind: .network)
            trafficRow(icon: "arrow.down", label: "Download",
                       rate: net.downBytesPerSec, liveHistory: engine.downHistory.ordered,
                       metric: HistoryMetric.netDown, color: .blue)
            trafficRow(icon: "arrow.up", label: "Upload",
                       rate: net.upBytesPerSec, liveHistory: engine.upHistory.ordered,
                       metric: HistoryMetric.netUp, color: .orange)

            if !engine.topNetworkApps.isEmpty {
                Divider()
                topAppsSection
            }

            if let wifi = net.wifi {
                Divider()
                wifiSection(wifi)
            }

            Divider()
            VStack(spacing: 5) {
                // Identity values are click-to-copy (#49).
                if let v4 = net.localIPv4 {
                    CopyableStatRow(label: "Local IP", value: v4)
                }
                if let v6 = net.localIPv6 {
                    CopyableStatRow(label: "Local IPv6", value: v6)
                }
                publicIPRow
            }

            if !engine.connectivity.recentOutages.isEmpty || engine.connectivity.currentOutage != nil {
                Divider()
                outagesSection
            }
        }
        // The per-app nettop monitor is costly, so it runs only while this card
        // is actually on screen (energy fix). Balanced appear/disappear calls.
        .onAppear { engine.retainNetworkApps() }
        .onDisappear { engine.releaseNetworkApps() }
    }

    // MARK: - Header

    private var statusAccessory: some View {
        let online = engine.connectivity.online
        return HStack(spacing: 4) {
            Circle()
                .fill(online ? Color.green : Color.red)
                .frame(width: 7, height: 7)
            Text(online ? "Online" : "Offline")
                .font(.system(size: 11))
                .foregroundStyle(online ? Color.secondary : Color.red)
        }
    }

    private func subtitle(_ net: NetworkSnapshot) -> String {
        if let name = net.interfaceName {
            return "\(net.connection.rawValue) · \(name)"
        }
        return net.connection.rawValue
    }

    private func trafficRow(icon: String, label: String, rate: Double,
                            liveHistory: [Double], metric: String, color: Color) -> some View {
        let window = settings.chartWindow(for: .network)
        return HStack(spacing: 10) {
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

    // MARK: - Top apps (feature #3)

    private var topAppsSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Top apps")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.tertiary)
            ForEach(engine.topNetworkApps.prefix(4)) { app in
                HStack(spacing: 6) {
                    Text(app.name)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text("↓ \(Fmt.rate(app.downBytesPerSec))")
                        .foregroundStyle(.blue)
                    Text("↑ \(Fmt.rate(app.upBytesPerSec))")
                        .foregroundStyle(.orange)
                }
                .font(.system(size: 10.5, weight: .medium))
                .monospacedDigit()
            }
        }
    }

    // MARK: - Wi-Fi (feature #8)

    private func wifiSection(_ wifi: WiFiInfo) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Wi-Fi")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.tertiary)
            // The SSID is click-to-copy when we actually have it (#49);
            // otherwise it's an explanatory placeholder, not worth copying.
            if let ssid = wifi.ssid {
                CopyableStatRow(label: "SSID", value: ssid)
            } else {
                StatRow(label: "SSID", value: ssidText(wifi))
            }
            if let bssid = wifi.bssid {
                StatRow(label: "BSSID", value: bssid)
            }
            if let channel = channelText(wifi) {
                StatRow(label: "Channel", value: channel)
            }
            if let rssi = wifi.rssi {
                StatRow(label: "Signal", value: "\(rssi) dBm")
            }
            if let noise = wifi.noise {
                StatRow(label: "Noise", value: "\(noise) dBm")
            }
            if let snr = wifi.snr {
                StatRow(label: "SNR", value: "\(snr) dB")
            }
            if let rate = wifi.txRateMbps {
                StatRow(label: "PHY rate", value: rateText(rate))
            }
            if wifi.rssi != nil, engine.rssiHistory.ordered.count > 1 {
                Sparkline(values: engine.rssiHistory.ordered, capacity: 120, color: .green,
                          autoBaseline: true, valueLabel: { "\(Int($0)) dBm" },
                          sampleInterval: settings.sampleInterval)
                    .frame(height: 22)
                    .padding(.top, 1)
            }
        }
    }

    private func ssidText(_ wifi: WiFiInfo) -> String {
        if let ssid = wifi.ssid { return ssid }
        return wifi.ssidHidden ? "Hidden (Location permission)" : "—"
    }

    private func channelText(_ wifi: WiFiInfo) -> String? {
        var parts: [String] = []
        if let ch = wifi.channel { parts.append("\(ch)") }
        if let band = wifi.band { parts.append(band) }
        if let width = wifi.channelWidth { parts.append(width) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func rateText(_ mbps: Double) -> String {
        mbps >= 1000
            ? String(format: "%.2f Gbps", mbps / 1000)
            : String(format: "%.0f Mbps", mbps)
    }

    // MARK: - Recent outages (feature #9)

    private var outagesSection: some View {
        let connectivity = engine.connectivity
        let count = connectivity.recentOutages.count
        return VStack(alignment: .leading, spacing: 5) {
            DisclosureHeaderButton(expanded: outagesExpanded.wrappedValue,
                                   title: "Recent outages (\(count))") {
                outagesExpanded.wrappedValue.toggle()
            }
            .frame(height: 16)
            if let current = connectivity.currentOutage {
                HStack(spacing: 6) {
                    Circle().fill(Color.red).frame(width: 6, height: 6)
                    Text("Ongoing since \(Fmt.date(current.start))")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.red)
                }
            }
            if outagesExpanded.wrappedValue {
                if connectivity.recentOutages.isEmpty {
                    Text("No outages recorded.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(connectivity.recentOutages.prefix(10)) { outage in
                        HStack(spacing: 6) {
                            Text(Fmt.date(outage.start))
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Text(outage.durationSeconds.map { Fmt.duration($0) } ?? "—")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Public IP

    @ViewBuilder private var publicIPRow: some View {
        if let ip = publicIP.wrappedValue {
            CopyableStatRow(label: "Public IP", value: ip)
        } else {
            HStack(spacing: 6) {
                Text("Public IP")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Button(fetchingIP.wrappedValue ? "Fetching…"
                       : fetchFailed.wrappedValue ? "Retry" : "Fetch public IP",
                       action: fetchPublicIP)
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                    .disabled(fetchingIP.wrappedValue)
            }
        }
    }

    private func fetchPublicIP() {
        guard !fetchingIP.wrappedValue else { return }
        fetchingIP.wrappedValue = true
        Task { @MainActor in
            let ip = await Self.loadPublicIP()
            publicIP.wrappedValue = ip
            fetchFailed.wrappedValue = (ip == nil)
            fetchingIP.wrappedValue = false
        }
    }

    /// nil on failure or an empty response, so the row keeps offering the button.
    private static func loadPublicIP() async -> String? {
        guard let url = URL(string: "https://api64.ipify.org") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        do {
            // Ephemeral session (no cache/cookies), same hygiene as UpdateChecker.
            let session = URLSession(configuration: .ephemeral)
            defer { session.finishTasksAndInvalidate() }
            let (data, _) = try await session.data(for: request)
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
    }
}

/// A borderless AppKit disclosure header (chevron + title). Used instead of a
/// SwiftUI `DisclosureGroup`/`Button` because the dashboard cards carry an
/// `.onDrag` reorder gesture that swallows SwiftUI button taps; an NSButton
/// receives the click directly (same reason as DiskCard's EjectButton).
private struct DisclosureHeaderButton: NSViewRepresentable {
    var expanded: Bool
    var title: String
    var action: () -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.bezelStyle = .inline
        button.imagePosition = .imageLeading
        button.font = .systemFont(ofSize: 10.5, weight: .semibold)
        button.contentTintColor = .tertiaryLabelColor
        button.target = context.coordinator
        button.action = #selector(Coordinator.fire)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.alignment = .left
        configure(button)
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.action = action
        configure(nsView)
    }

    private func configure(_ button: NSButton) {
        let symbol = expanded ? "chevron.down" : "chevron.right"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold)
        button.title = " " + title
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func fire() { action() }
    }
}
