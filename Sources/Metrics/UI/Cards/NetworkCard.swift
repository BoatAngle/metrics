import SwiftUI

struct NetworkCard: View {
    @Environment(MetricsEngine.self) private var engine

    // Plain State (not @State): the macro form needs the SwiftUIMacros plugin,
    // which the Command Line Tools toolchain doesn't ship. SwiftUI picks up
    // stored DynamicProperty values by reflection, so this behaves the same.
    private var publicIP = State<String?>(initialValue: nil)
    private var fetchingIP = State(initialValue: false)
    private var fetchFailed = State(initialValue: false)

    var body: some View {
        let net = engine.network
        CardContainer(title: "Network Activity", subtitle: subtitle(net)) {
            trafficRow(icon: "arrow.down", label: "Download",
                       rate: net.downBytesPerSec,
                       history: engine.downHistory.ordered, color: .blue)
            trafficRow(icon: "arrow.up", label: "Upload",
                       rate: net.upBytesPerSec,
                       history: engine.upHistory.ordered, color: .orange)
            Divider()
            VStack(spacing: 5) {
                if let ssid = net.ssid {
                    StatRow(label: "SSID", value: ssid)
                }
                if let v4 = net.localIPv4 {
                    StatRow(label: "Local IP", value: v4)
                }
                if let v6 = net.localIPv6 {
                    StatRow(label: "Local IPv6", value: v6)
                }
                publicIPRow
            }
        }
    }

    private func subtitle(_ net: NetworkSnapshot) -> String {
        if let name = net.interfaceName {
            return "\(net.connection.rawValue) · \(name)"
        }
        return net.connection.rawValue
    }

    private func trafficRow(icon: String, label: String, rate: Double,
                            history: [Double], color: Color) -> some View {
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
            Sparkline(values: history, capacity: 120, color: color)
                .frame(height: 22)
        }
    }

    @ViewBuilder private var publicIPRow: some View {
        if let ip = publicIP.wrappedValue {
            StatRow(label: "Public IP", value: ip)
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
            let (data, _) = try await URLSession.shared.data(for: request)
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
    }
}
