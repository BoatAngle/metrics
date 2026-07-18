import AppKit
import Darwin
import SwiftUI

struct ProcessesCard: View {
    @Environment(MetricsEngine.self) private var engine
    @Environment(SettingsStore.self) private var settings

    // Plain State (not @State): the macro form needs the SwiftUIMacros plugin,
    // which the Command Line Tools toolchain doesn't ship. SwiftUI picks up
    // stored DynamicProperty values by reflection, so this behaves the same.
    var hoveredPID = State(initialValue: Int32?.none)
    var confirmKillPID = State(initialValue: Int32?.none)
    var iconCache = State(initialValue: ProcessIconCache())

    private static let rowCount = 6

    /// Sort columns offered right now — GPU only when the hardware maps it.
    private var availableKeys: [ProcessSortKey] {
        var keys: [ProcessSortKey] = [.cpu, .memory, .disk, .energy]
        if engine.processes.gpuAvailable { keys.append(.gpu) }
        return keys
    }

    /// The persisted sort key, clamped to what's currently available.
    private var activeKey: ProcessSortKey {
        availableKeys.contains(settings.processSortKey) ? settings.processSortKey : .cpu
    }

    var body: some View {
        CardContainer(title: "Processes") {
            sortPicker

            let rows = Array(engine.processes.ranked(by: activeKey).prefix(Self.rowCount))
            if rows.isEmpty {
                Text("No data yet")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                VStack(spacing: 5) {
                    ForEach(rows) { proc in
                        row(proc)
                    }
                }
            }
        }
    }

    // MARK: - Sort picker

    private var sortPicker: some View {
        Picker("", selection: Binding(
            get: { activeKey },
            set: { settings.processSortKey = $0 })) {
            ForEach(availableKeys) { key in
                Text(key.title).tag(key)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.small)
        .labelsHidden()
    }

    // MARK: - Row

    private func row(_ proc: ProcessSample) -> some View {
        let hovered = hoveredPID.wrappedValue == proc.pid
        return HStack(spacing: 6) {
            Image(nsImage: iconCache.wrappedValue.icon(for: proc))
                .resizable()
                .frame(width: 15, height: 15)
            Text(proc.name)
                .font(.system(size: 11.5))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if hovered {
                actionButtons(proc)
            }
            Text(valueText(proc))
                .font(.system(size: 11.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(hovered ? .secondary : .primary)
        }
        .frame(height: 17)
        .contentShape(Rectangle())
        .background(ProcessRowClickCatcher(pid: proc.pid, name: proc.name))
        .onHover { inside in
            if inside {
                hoveredPID.wrappedValue = proc.pid
            } else if hoveredPID.wrappedValue == proc.pid {
                hoveredPID.wrappedValue = nil
                confirmKillPID.wrappedValue = nil
            }
        }
    }

    @ViewBuilder private func actionButtons(_ proc: ProcessSample) -> some View {
        // Quit (terminate / SIGTERM).
        ProcessActionButton(symbol: "power", tint: .secondaryLabelColor,
                            tooltip: "Quit \(proc.name)") {
            ProcessControl.quit(proc.pid)
        }
        .frame(width: 16, height: 15)

        // Force Kill (SIGKILL) with a one-shot confirm state instead of a modal.
        if confirmKillPID.wrappedValue == proc.pid {
            ProcessActionButton(title: "Sure?", tint: .systemRed,
                                tooltip: "Force kill \(proc.name)") {
                ProcessControl.forceKill(proc.pid)
                confirmKillPID.wrappedValue = nil
            }
            .frame(width: 38, height: 15)
        } else {
            ProcessActionButton(symbol: "xmark.octagon.fill", tint: .secondaryLabelColor,
                                tooltip: "Force Kill \(proc.name)") {
                armKillConfirm(for: proc.pid)
            }
            .frame(width: 16, height: 15)
        }
    }

    /// Turns the Force-Kill button into a red "Sure?" for 3s; a second click
    /// within that window sends SIGKILL, otherwise it reverts on its own.
    private func armKillConfirm(for pid: Int32) {
        confirmKillPID.wrappedValue = pid
        let box = confirmKillPID
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if box.wrappedValue == pid { box.wrappedValue = nil }
        }
    }

    private func valueText(_ proc: ProcessSample) -> String {
        switch activeKey {
        case .cpu: return String(format: "%.1f%%", proc.cpuPercent)
        case .memory: return Fmt.bytes(proc.memoryBytes)
        case .disk: return Fmt.rate(proc.diskBytesPerSec)
        case .energy: return Fmt.watts(proc.energyWatts)
        case .gpu: return String(format: "%.0f%%", proc.gpuPercent ?? 0)
        }
    }
}

// MARK: - Process control

/// Terminate / force-kill helpers. `quit` prefers a graceful AppKit terminate
/// for real apps and falls back to SIGTERM for non-app processes; `forceKill`
/// always sends SIGKILL.
enum ProcessControl {
    static func quit(_ pid: Int32) {
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.terminate()
        } else {
            _ = kill(pid, SIGTERM)
        }
    }

    static func forceKill(_ pid: Int32) {
        _ = kill(pid, SIGKILL)
    }
}

// MARK: - Icon cache

/// Caches process icons by pid so repeated renders don't re-hit AppKit. Prefers
/// the running application's icon, then the executable file's icon, then a
/// generic glyph.
@MainActor final class ProcessIconCache {
    private var cache: [Int32: NSImage] = [:]

    func icon(for proc: ProcessSample) -> NSImage {
        if let cached = cache[proc.pid] { return cached }
        let image = Self.lookup(pid: proc.pid)
        cache[proc.pid] = image
        return image
    }

    private static func lookup(pid: Int32) -> NSImage {
        if let app = NSRunningApplication(processIdentifier: pid), let icon = app.icon {
            return icon
        }
        if let path = executablePath(pid) {
            return NSWorkspace.shared.icon(forFile: path)
        }
        return NSImage(systemSymbolName: "gearshape.2", accessibilityDescription: nil)
            ?? NSImage()
    }

    private static func executablePath(_ pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        let p = String(cString: buf)
        return p.isEmpty ? nil : p
    }
}

// MARK: - AppKit action button

/// A borderless AppKit button for the per-row Quit / Force-Kill controls. Used
/// instead of a SwiftUI `Button` because the dashboard cards carry an `.onDrag`
/// reorder gesture that swallows SwiftUI button taps; an NSButton receives the
/// click directly. Renders either an SF Symbol or a short text title.
private struct ProcessActionButton: NSViewRepresentable {
    var symbol: String? = nil
    var title: String? = nil
    var tint: NSColor
    var tooltip: String
    var action: () -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.bezelStyle = .inline
        button.setButtonType(.momentaryChange)
        button.target = context.coordinator
        button.action = #selector(Coordinator.fire)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        configure(button)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        configure(button)
    }

    private func configure(_ button: NSButton) {
        button.toolTip = tooltip
        if let title {
            button.image = nil
            button.imagePosition = .noImage
            button.attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: tint,
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            ])
        } else if let symbol {
            button.title = ""
            button.imagePosition = .imageOnly
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title ?? symbol)
            button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
            button.contentTintColor = tint
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func fire() { action() }
    }
}

// MARK: - Row click catcher (opens the inspector popover)

/// A transparent AppKit overlay that turns a whole process row into a click
/// target which opens the inspector `NSPopover` anchored to itself. A plain
/// SwiftUI tap gesture here would be swallowed by the card's drag-to-reorder
/// gesture, so the click is handled at the AppKit layer instead.
private struct ProcessRowClickCatcher: NSViewRepresentable {
    var pid: Int32
    var name: String

    func makeNSView(context: Context) -> ClickView { ClickView() }

    func updateNSView(_ nsView: ClickView, context: Context) {
        nsView.pid = pid
        nsView.procName = name
    }

    final class ClickView: NSView {
        var pid: Int32 = 0
        var procName: String = ""
        private var downPoint: NSPoint = .zero
        private var popover: NSPopover?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            downPoint = event.locationInWindow
        }

        override func mouseUp(with event: NSEvent) {
            // Treat only a click-in-place (not a drag) as an inspector open.
            let up = event.locationInWindow
            let moved = hypot(up.x - downPoint.x, up.y - downPoint.y)
            guard moved < 4 else { return }
            showInspector()
        }

        private func showInspector() {
            if let existing = popover, existing.isShown {
                existing.close()
                popover = nil
                return
            }
            let host = NSHostingController(rootView: ProcessInspectorView(pid: pid, name: procName))
            host.sizingOptions = [.preferredContentSize]
            let pop = NSPopover()
            pop.behavior = .transient
            pop.contentViewController = host
            pop.show(relativeTo: bounds, of: self, preferredEdge: .maxX)
            popover = pop
        }
    }
}
