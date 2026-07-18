import SwiftUI

/// Content of the process-inspector popover (feature #14). Self-contained: it
/// lives inside an NSHostingController in an NSPopover, outside the app's
/// SwiftUI environment, so it takes only the pid/name and loads the rest lazily
/// off the main actor when it appears.
struct ProcessInspectorView: View {
    let pid: Int32
    let name: String

    // Plain State (not @State): the macro form needs the SwiftUIMacros plugin,
    // which the Command Line Tools toolchain doesn't ship.
    var details = State(initialValue: ProcessDetails?.none)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let d = details.wrappedValue {
                Divider()
                facts(d)
                if !d.sockets.isEmpty {
                    Divider()
                    socketsSection(d.sockets)
                }
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
        .task(id: pid) {
            let loaded = await Self.load(pid: pid, name: name)
            details.wrappedValue = loaded
        }
    }

    private nonisolated static func load(pid: Int32, name: String) async -> ProcessDetails {
        await Task.detached(priority: .userInitiated) {
            ProcessInspector.load(pid: pid, name: name)
        }.value
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Text("PID \(pid)")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    // MARK: - Facts

    @ViewBuilder private func facts(_ d: ProcessDetails) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            factRow("Path", d.executablePath ?? "unavailable", mono: true)
            factRow("Arguments", argumentsText(d.arguments), mono: true)
            factRow("Parent", parentText(d))
            if let t = d.threadCount { factRow("Threads", "\(t)") }
            if let rss = d.residentBytes { factRow("Memory (RSS)", Fmt.bytes(rss)) }
            if let files = d.openFileCount { factRow("Open files", "\(files)") }
        }
    }

    private func argumentsText(_ args: [String]?) -> String {
        guard let args else { return "unavailable" }
        return args.isEmpty ? "(none)" : args.joined(separator: " ")
    }

    private func parentText(_ d: ProcessDetails) -> String {
        guard let ppid = d.parentPID else { return "unavailable" }
        if let n = d.parentName { return "\(n) (\(ppid))" }
        return "PID \(ppid)"
    }

    private func factRow(_ label: String, _ value: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 11, design: mono ? .monospaced : .default))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Sockets

    private func socketsSection(_ sockets: [SocketConn]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Connections")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.tertiary)
            ForEach(sockets) { s in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(s.proto)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, alignment: .leading)
                    Text(connectionText(s))
                        .font(.system(size: 10.5, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if let state = s.state {
                        Text(state == "LISTEN" ? "LISTEN" : "EST")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(state == "LISTEN" ? .green : .blue)
                    }
                }
            }
        }
    }

    private func connectionText(_ s: SocketConn) -> String {
        if let remote = s.remote { return "\(s.local) → \(remote)" }
        return s.local
    }
}
