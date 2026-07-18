import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A small shortcut-recorder field (feature #46): click to start capturing, then
/// press a modifier + key. Esc cancels; the ✕ clears. Lives in the Settings
/// Form, so a plain SwiftUI Button is fine here (no card drag gesture to fight).
struct HotkeyRecorder: View {
    var current: HotkeyCenter.Binding?
    var onChange: (HotkeyCenter.Binding?) -> Void

    // Plain State (not @State): the macro form needs the SwiftUIMacros plugin,
    // which the Command Line Tools toolchain doesn't ship.
    var recording = State(initialValue: false)
    var monitor = State<Any?>(initialValue: nil)

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggle) {
                Text(label)
                    .monospacedDigit()
                    .frame(minWidth: 116)
            }
            .help(recording.wrappedValue
                  ? "Press a shortcut, or Esc to cancel"
                  : "Click, then press a modifier + key")
            if current != nil && !recording.wrappedValue {
                Button(role: .destructive) { onChange(nil) } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .help("Clear shortcut")
            }
        }
        // A view rebuild or the settings window closing must not leave a live
        // key monitor swallowing every keystroke.
        .onDisappear(perform: stop)
    }

    private var label: String {
        if recording.wrappedValue { return "Press keys…" }
        return current?.displayString ?? "Record Shortcut"
    }

    private func toggle() {
        if recording.wrappedValue { stop() } else { start() }
    }

    private func start() {
        recording.wrappedValue = true
        monitor.wrappedValue = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            // Consume the event so the captured combo never leaks to the UI.
            handle(event)
            return nil
        }
    }

    private func stop() {
        recording.wrappedValue = false
        if let m = monitor.wrappedValue {
            NSEvent.removeMonitor(m)
            monitor.wrappedValue = nil
        }
    }

    private func handle(_ event: NSEvent) {
        // Esc cancels without touching the binding.
        if event.keyCode == UInt16(kVK_Escape) {
            stop()
            return
        }
        let mods = event.modifierFlags.intersection(HotkeyCenter.Binding.relevant)
        // Require at least one modifier so we don't hijack a bare key.
        guard !mods.isEmpty else { return }
        onChange(HotkeyCenter.Binding(keyCode: Int(event.keyCode),
                                      modifiers: Int(mods.rawValue)))
        stop()
    }
}
