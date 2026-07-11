import AppKit
import Carbon.HIToolbox

/// System-wide hotkeys via Carbon `RegisterEventHotKey` (feature #46). This is
/// the only reliable way to catch a key combo while another app is frontmost
/// for an unsandboxed accessory app — no Accessibility permission required.
///
/// Two named slots are exposed: `.toggleDashboard` (wired here to flip the
/// menu-bar popover) and `.focusMode` (a registration seam only — Package 13
/// hooks the action; we register the key and fire the callback but ship no
/// Focus mode yet).
@MainActor
final class HotkeyCenter {
    static let shared = HotkeyCenter()

    /// A recorded shortcut. `keyCode` is a virtual key code (identical between
    /// `NSEvent.keyCode` and Carbon), `modifiers` is an `NSEvent.ModifierFlags`
    /// rawValue so the recorder and Carbon layer speak the same units.
    struct Binding: Equatable {
        var keyCode: Int
        var modifiers: Int   // NSEvent.ModifierFlags rawValue

        var flags: NSEvent.ModifierFlags {
            NSEvent.ModifierFlags(rawValue: UInt(modifiers)).intersection(Self.relevant)
        }

        /// The modifier subset we record and register on (device-independent).
        static let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
    }

    /// Stable identifiers for the registered hotkeys (also the Carbon hotkey id).
    enum Slot: UInt32 {
        case toggleDashboard = 1
        case focusMode = 2
    }

    private var actions: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    /// FourCC 'MTRC' — our owning signature so we only react to our own keys.
    private let signature: OSType = 0x4D54_5243

    private init() {}

    /// Registers (or re-registers) the shortcut for a slot. The action is kept
    /// even when `binding` is nil, so a later binding change reuses it. A nil
    /// binding just tears down the key (the default "none" state).
    func setBinding(_ binding: Binding?, for slot: Slot, action: @escaping () -> Void) {
        actions[slot.rawValue] = action
        installHandlerIfNeeded()

        if let existing = refs[slot.rawValue] {
            UnregisterEventHotKey(existing)
            refs[slot.rawValue] = nil
        }
        guard let binding, binding.keyCode >= 0 else { return }

        let hotKeyID = EventHotKeyID(signature: signature, id: slot.rawValue)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(binding.keyCode),
                                         carbonModifiers(binding.flags),
                                         hotKeyID,
                                         GetApplicationEventTarget(),
                                         0,
                                         &ref)
        if status == noErr, let ref {
            refs[slot.rawValue] = ref
        } else {
            NSLog("Metrics: hotkey registration for slot %u failed (status %d) — the combo may be taken by another app.",
                  slot.rawValue, Int(status))
        }
    }

    /// Installs the single app-wide keyboard handler the first time it's needed.
    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        // Non-capturing so it converts to a C function pointer: it reaches the
        // shared instance through the global and hops to the main actor.
        let callback: EventHandlerUPP = { _, eventRef, _ in
            guard let eventRef else { return OSStatus(eventNotHandledErr) }
            var hkID = EventHotKeyID()
            let err = GetEventParameter(eventRef,
                                        EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID),
                                        nil,
                                        MemoryLayout<EventHotKeyID>.size,
                                        nil,
                                        &hkID)
            guard err == noErr else { return err }
            let id = hkID.id
            DispatchQueue.main.async { HotkeyCenter.shared.fire(id) }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec, nil, &handler)
    }

    fileprivate func fire(_ id: UInt32) {
        actions[id]?()
    }

    /// NSEvent modifier flags → Carbon modifier mask.
    private func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        if flags.contains(.option)  { mask |= UInt32(optionKey) }
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        if flags.contains(.shift)   { mask |= UInt32(shiftKey) }
        return mask
    }
}

// MARK: - Display

extension HotkeyCenter.Binding {
    /// A menu-style rendering of the shortcut, e.g. "⌥⌘M".
    var displayString: String {
        var out = ""
        let f = flags
        if f.contains(.control) { out += "⌃" }
        if f.contains(.option)  { out += "⌥" }
        if f.contains(.shift)   { out += "⇧" }
        if f.contains(.command) { out += "⌘" }
        out += HotkeyKeyNames.name(for: keyCode)
        return out
    }
}

/// Virtual-key-code → readable label for the standard US layout. Covers the
/// keys a shortcut realistically uses; anything else falls back to "#<code>".
enum HotkeyKeyNames {
    static func name(for keyCode: Int) -> String {
        if let named = special[keyCode] { return named }
        if let ansi = ansi[keyCode] { return ansi }
        return "#\(keyCode)"
    }

    private static let ansi: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
        kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
        kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
        kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
        kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=",
        kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        kVK_ANSI_Backslash: "\\", kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'",
        kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/",
        kVK_ANSI_Grave: "`",
    ]

    private static let special: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋",
        kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12",
    ]
}
