import AppKit
import SwiftUI

struct DiskCard: View {
    @Environment(MetricsEngine.self) private var engine

    // Plain State (not @State): the macro form needs the SwiftUIMacros plugin,
    // which the Command Line Tools toolchain doesn't ship. SwiftUI picks up
    // stored DynamicProperty values by reflection, so this behaves the same.
    private var ejecting = State(initialValue: Set<String>())
    private var ejectError = State(initialValue: [String: String]())

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
            if !engine.disk.external.isEmpty {
                Divider()
                VStack(spacing: 8) {
                    ForEach(engine.disk.external) { vol in
                        volumeRow(vol)
                    }
                }
            }
        }
    }

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
