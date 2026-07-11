import SwiftUI

struct DeviceCard: View {
    @Environment(MetricsEngine.self) private var engine

    var body: some View {
        CardContainer(title: "Device") {
            VStack(spacing: 5) {
                ForEach(rows, id: \.0) { row in
                    StatRow(label: row.0, value: row.1)
                }
            }
        }
    }

    private var rows: [(String, String)] {
        let d = engine.device
        var out: [(String, String)] = []
        if !d.modelName.isEmpty { out.append(("Model", d.modelName)) }
        if !d.chipName.isEmpty { out.append(("Chip", d.chipName)) }
        if !d.osVersionString.isEmpty {
            let os = d.buildVersion.isEmpty
                ? d.osVersionString
                : "\(d.osVersionString) (\(d.buildVersion))"
            out.append(("macOS", os))
        }
        if !d.hostname.isEmpty { out.append(("Hostname", d.hostname)) }
        if d.uptimeSeconds > 0 { out.append(("Uptime", Fmt.uptime(d.uptimeSeconds))) }
        if let boot = d.bootDate { out.append(("Booted", Fmt.date(boot))) }
        return out
    }
}
