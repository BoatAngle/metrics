import AppKit
import CoreGraphics
import Observation

/// Focus / Gaming mode (Package 13, #44). A single global mode that, while
/// active:
///   • collapses every Metrics status item into one compact icon
///     (`StatusItemController` observes `active`),
///   • hides all desktop widgets (`DesktopWidgetController` observes `active`),
///   • slows sampling to 5 s (restarts the engine at a 5 s interval).
///
/// Exiting restores the previous status-item set, the desktop widgets, and the
/// user's real sampling interval exactly. An optional auto-trigger arms the mode
/// when a full-screen app appears or a chosen app comes frontmost; a mode that
/// was armed automatically is only auto-disarmed, never one the user toggled.
@Observable @MainActor
final class FocusModeController {
    static let shared = FocusModeController()

    /// Public read-only mode flag the status-item and widget controllers observe.
    private(set) var active = false

    /// True when the current activation came from the auto-trigger, so a manual
    /// activation isn't torn down the moment the trigger condition clears.
    @ObservationIgnored private var enteredByAuto = false
    @ObservationIgnored private var autoTimer: Timer?

    /// The sampling interval used while the mode is active.
    static let focusInterval: Double = 5.0

    private init() {}

    // MARK: Lifecycle

    /// Begins watching the auto-trigger conditions (a low-frequency poll) and
    /// keeps the poll in step with the settings that drive it.
    func start() {
        updateAutoTimer()
        observeChanges {
            _ = SettingsStore.shared.focusAutoEnabled
            _ = SettingsStore.shared.focusTrigger
            _ = SettingsStore.shared.focusTriggerBundleID
        } perform: { [weak self] in
            self?.updateAutoTimer()
        }
    }

    // MARK: Toggling

    func toggle() { active ? exit() : enter(auto: false) }

    /// Used by `metrics://focus/on|off` and the settings toggle.
    func setActive(_ on: Bool) { on ? enter(auto: false) : exit() }

    /// Enters the mode. `auto` records that the auto-trigger did it, so the poll
    /// may later disarm it; a manual enter is sticky.
    func enter(auto: Bool) {
        if active {
            // A manual enter over an auto-entered mode makes it sticky.
            if !auto { enteredByAuto = false }
            return
        }
        active = true
        enteredByAuto = auto
        MetricsEngine.shared.restart(interval: Self.focusInterval)
    }

    func exit() {
        guard active else { return }
        active = false
        enteredByAuto = false
        // Restore the user's real interval (the source of truth, unchanged by
        // Focus mode — this also picks up any edit made while it was active).
        MetricsEngine.shared.restart(interval: SettingsStore.shared.sampleInterval)
    }

    // MARK: Auto-trigger (#44)

    private func updateAutoTimer() {
        let enabled = SettingsStore.shared.focusAutoEnabled
        if enabled, autoTimer == nil {
            // A deliberately slow poll — 3 s is plenty for entering/leaving a
            // game or full-screen app and costs almost nothing.
            let t = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.evaluateAutoTrigger() }
            }
            autoTimer = t
            evaluateAutoTrigger() // don't wait a full period for the first check
        } else if !enabled, autoTimer != nil {
            autoTimer?.invalidate()
            autoTimer = nil
        }
    }

    private func evaluateAutoTrigger() {
        let settings = SettingsStore.shared
        guard settings.focusAutoEnabled else { return }
        let shouldFocus: Bool
        switch settings.focusTrigger {
        case .fullScreen:
            shouldFocus = Self.anyAppFullScreen()
        case .frontmostApp:
            shouldFocus = Self.chosenAppFrontmost(bundleID: settings.focusTriggerBundleID)
        }

        if shouldFocus && !active {
            enter(auto: true)
        } else if !shouldFocus && active && enteredByAuto {
            exit()
        }
    }

    // MARK: Detection heuristics

    /// True when some on-screen window at the normal window layer exactly covers
    /// a whole display — the tell-tale of a full-screen app or game. Compares
    /// window size to each display's point size (orientation-independent, so the
    /// CGWindow/NSScreen y-flip doesn't matter).
    static func anyAppFullScreen() -> Bool {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }

        let displaySizes = NSScreen.screens.map { $0.frame.size }
        guard !displaySizes.isEmpty else { return false }

        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { continue }
            for size in displaySizes {
                if abs(bounds.width - size.width) < 2 && abs(bounds.height - size.height) < 2 {
                    return true
                }
            }
        }
        return false
    }

    /// True when the frontmost app matches the chosen bundle id (#44).
    static func chosenAppFrontmost(bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
    }
}
