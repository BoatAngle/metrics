import AppKit
import Observation
import SwiftUI

/// Borderless window pinned to the desktop layer. Never becomes key or main
/// so widgets can't steal focus (borderless windows refuse key by default —
/// the override makes it explicit), yet background-drag still moves them.
private final class DesktopWidgetWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// While arranging, snaps the dragged origin to the 8-pt grid, screen edges
    /// and other widgets' edges (#43). nil = free movement / pinned.
    var snap: ((NSPoint, NSSize) -> NSPoint)?

    override func setFrameOrigin(_ point: NSPoint) {
        if let snap { super.setFrameOrigin(snap(point, frame.size)) }
        else { super.setFrameOrigin(point) }
    }

    /// Programmatic moves (size re-sync, profile restore) that must bypass the
    /// magnetic snapping so we don't fight our own layout math.
    func setOriginBypassingSnap(_ point: NSPoint) { super.setFrameOrigin(point) }
}

/// A borderless panel that can become key so its SwiftUI "Done" button fires.
private final class PillPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Floats one real-time metric card per enabled kind directly on the desktop
/// — above the wallpaper, below the desktop icons (GeekTool/Übersicht style)
/// — and keeps the set of windows in sync with SettingsStore.desktopWidgets.
///
/// Package 13 adds per-widget size/opacity/frameless/theme (#41/#42), magnetic
/// snapping + a floating "Done arranging" pill + named layout profiles with
/// display auto-switching (#43), and honors Focus/Gaming mode by hiding all
/// widgets while it is active (#44).
@Observable @MainActor
final class DesktopWidgetController {
    static let shared = DesktopWidgetController()

    @ObservationIgnored private var windows: [CardKind: DesktopWidgetWindow] = [:]
    @ObservationIgnored private var hostingViews: [CardKind: NSHostingView<AnyView>] = [:]
    /// A plain NSView between the window and the hosting view. Its layer carries
    /// the scale transform (#41) — SwiftUI never touches this layer, so the
    /// transform can't be reset out from under us on a content update.
    @ObservationIgnored private var scaleViews: [CardKind: NSView] = [:]
    /// Last config applied to each live window, so a settings change only
    /// rebuilds what actually changed.
    @ObservationIgnored private var appliedConfigs: [CardKind: DesktopWidgetConfig] = [:]
    @ObservationIgnored private var sizeTimer: Timer?
    @ObservationIgnored private var pillWindow: PillPanel?
    /// The display signature last auto-applied, so an unrelated screen change
    /// doesn't re-trigger the same profile.
    @ObservationIgnored private var lastAppliedSignature: String?

    /// The desktop layer is click-through, so widgets can't be dragged in
    /// place. While arranging, they float above other windows (with a shadow
    /// as the cue) and become draggable; turning it off pins them back down.
    var arranging = false {
        didSet {
            guard arranging != oldValue else { return }
            applyLevel()
            applySnapping()
            if arranging { showArrangePill() } else { hideArrangePill() }
        }
    }

    private var currentLevel: NSWindow.Level {
        arranging
            ? .floating
            : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
    }

    private func applyLevel() {
        for window in windows.values {
            window.level = currentLevel
            window.hasShadow = arranging
            if arranging { window.orderFrontRegardless() }
        }
    }

    private init() {}

    func start() {
        syncWindows()
        observeSettings()
        observeDisplayChanges()
    }

    // MARK: - Settings observation

    private func observeSettings() {
        // Which widgets exist (and whether Focus mode has hidden them all).
        observeChanges {
            _ = SettingsStore.shared.desktopWidgets
            _ = FocusModeController.shared.active
        } perform: { [weak self] in
            self?.syncWindows()
        }
        // Per-widget appearance (size/opacity/frameless/theme).
        observeChanges {
            _ = SettingsStore.shared.desktopWidgetConfigs
        } perform: { [weak self] in
            self?.applyConfigsToExisting()
        }
    }

    private func observeDisplayChanges() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleScreenChange() }
        }
    }

    // MARK: - Window lifecycle

    private func syncWindows() {
        // Focus/Gaming mode hides every widget without disturbing the saved set.
        let wanted = FocusModeController.shared.active ? [] : SettingsStore.shared.desktopWidgets

        for (kind, window) in windows where !wanted.contains(kind) {
            window.close()
            windows[kind] = nil
            hostingViews[kind] = nil
            scaleViews[kind] = nil
            appliedConfigs[kind] = nil
        }
        // allCases order keeps first-ever stagger placement deterministic.
        for kind in CardKind.allCases where wanted.contains(kind) && windows[kind] == nil {
            makeWindow(kind: kind)
        }
        applyConfigsToExisting()
        applySnapping()
        updateSizeTimer()
    }

    private func makeWindow(kind: CardKind) {
        let config = SettingsStore.shared.desktopConfig(for: kind)
        let hosting = NSHostingView(rootView: rootView(kind: kind, config: config))
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.wantsLayer = true

        // scaleView carries the scale transform; hosting fills it; container
        // fills the window. Only scaleView's layer is transformed.
        let scaleView = NSView()
        scaleView.wantsLayer = true
        scaleView.addSubview(hosting)

        let container = NSView()
        container.wantsLayer = true
        container.addSubview(scaleView)

        let window = DesktopWidgetWindow(contentRect: .zero,
                                         styleMask: [.borderless],
                                         backing: .buffered,
                                         defer: false)
        window.isReleasedWhenClosed = false // ARC owns it via our dictionary
        window.level = currentLevel
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = arranging
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.contentView = container

        windows[kind] = window
        hostingViews[kind] = hosting
        scaleViews[kind] = scaleView
        appliedConfigs[kind] = config

        // Size to the (scaled) content, then restore the saved frame or place it.
        layoutWidget(kind: kind, anchorTop: false)
        let autosaveName = "metrics.widget.\(kind.rawValue)"
        if !window.setFrameUsingName(autosaveName) {
            placeInitially(window, kind: kind)
        }
        window.setFrameAutosaveName(autosaveName)
        // A restored frame may carry a stale size; re-fit while pinning the top.
        layoutWidget(kind: kind, anchorTop: true)
        window.orderFrontRegardless()
    }

    /// The SwiftUI card, constrained to the widget width and carrying the theme
    /// style (#42). Scale (#41) is applied by `layoutWidget`'s bounds/frame
    /// mismatch, not here.
    private func rootView(kind: CardKind, config: DesktopWidgetConfig) -> AnyView {
        AnyView(
            MetricCardView(kind: kind)
                .frame(width: 300)
                .padding(2)
                .environment(\.desktopWidgetStyle, config.style)
                .environment(MetricsEngine.shared)
                .environment(SettingsStore.shared)
        )
    }

    /// First-ever placement: staggered down the right edge of the main screen.
    private func placeInitially(_ window: NSWindow, kind: CardKind) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let index = CGFloat(CardKind.allCases.firstIndex(of: kind) ?? 0)
        let size = window.frame.size
        let x = visible.maxX - size.width - 24
        let y = visible.maxY - 24 - size.height - index * 40
        window.setFrameOrigin(NSPoint(x: x, y: max(visible.minY, y)))
    }

    // MARK: - Per-widget size + scale (#41)

    /// Sizes the window to the card's natural fitting size times the scale
    /// factor. The card lays out once at its natural size inside `scaleView`'s
    /// *bounds*, while `scaleView`'s *frame* is the scaled footprint — AppKit's
    /// native bounds/frame mismatch scales the content crisply, with no layer
    /// transform to be reset out from under us. `anchorTop` keeps the top edge
    /// fixed when the size changes in place.
    private func layoutWidget(kind: CardKind, anchorTop: Bool) {
        guard let window = windows[kind], let hosting = hostingViews[kind],
              let scaleView = scaleViews[kind] else { return }
        let factor = SettingsStore.shared.desktopConfig(for: kind).scale.factor
        let natural = hosting.fittingSize
        guard natural.width > 1, natural.height > 1 else { return }

        let scaled = NSSize(width: (natural.width * factor).rounded(),
                            height: (natural.height * factor).rounded())
        // Frame first (footprint) — that resets bounds.size — then bounds
        // (natural coordinate space) so the mismatch scales the content.
        scaleView.frame = NSRect(origin: .zero, size: scaled)
        scaleView.bounds = NSRect(origin: .zero, size: natural)
        hosting.frame = NSRect(origin: .zero, size: natural)

        let current = window.frame.size
        if abs(scaled.width - current.width) < 0.5 && abs(scaled.height - current.height) < 0.5 {
            return // window already the right size; scaleView is fresh
        }
        let topY = window.frame.maxY
        let savedSnap = window.snap
        window.snap = nil
        window.setContentSize(scaled)
        if anchorTop {
            var origin = window.frame.origin
            origin.y = topY - window.frame.height
            window.setOriginBypassingSnap(origin)
        }
        window.snap = savedSnap
    }

    // MARK: - Per-widget config apply (#41/#42)

    /// Rebuilds the root view + relayouts any window whose config changed.
    private func applyConfigsToExisting() {
        for kind in windows.keys {
            let config = SettingsStore.shared.desktopConfig(for: kind)
            guard appliedConfigs[kind] != config else { continue }
            appliedConfigs[kind] = config
            hostingViews[kind]?.rootView = rootView(kind: kind, config: config)
            layoutWidget(kind: kind, anchorTop: true)
        }
    }

    // MARK: - Snapping (#43)

    private func applySnapping() {
        for (kind, window) in windows {
            window.snap = arranging ? { [weak self] point, size in
                self?.snappedOrigin(for: kind, proposed: point, size: size) ?? point
            } : nil
        }
    }

    /// Magnetic origin: snaps each edge to the nearest screen edge, other
    /// widget edge, or 8-pt grid line within 8 pt.
    private func snappedOrigin(for kind: CardKind, proposed: NSPoint, size: NSSize) -> NSPoint {
        let rect = NSRect(origin: proposed, size: size)
        let screen = NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main
        var vLines: [CGFloat] = []
        var hLines: [CGFloat] = []
        if let vf = screen?.visibleFrame {
            vLines += [vf.minX, vf.maxX]
            hLines += [vf.minY, vf.maxY]
        }
        for (other, w) in windows where other != kind {
            let f = w.frame
            vLines += [f.minX, f.maxX]
            hLines += [f.minY, f.maxY]
        }
        return NSPoint(x: WidgetSnap.snap(value: proposed.x, extent: size.width, lines: vLines),
                       y: WidgetSnap.snap(value: proposed.y, extent: size.height, lines: hLines))
    }

    // MARK: - "Done arranging" pill (#43)

    private func showArrangePill() {
        let panel: PillPanel
        if let existing = pillWindow {
            panel = existing
        } else {
            let hosting = NSHostingView(rootView: AnyView(
                ArrangePillView(onDone: { [weak self] in self?.arranging = false })))
            let p = PillPanel(contentRect: .zero,
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
            p.isFloatingPanel = true
            p.level = .floating
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.hidesOnDeactivate = false
            p.isMovableByWindowBackground = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            p.contentView = hosting
            p.setContentSize(hosting.fittingSize)
            pillWindow = p
            panel = p
        }
        if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.minY + 42))
        }
        panel.orderFrontRegardless()
    }

    private func hideArrangePill() { pillWindow?.orderOut(nil) }

    // MARK: - Layout profiles (#43)

    /// Captures the current widgets (on/off, configs, positions) as a profile
    /// tagged with the current display signature.
    func captureProfile(named name: String, autoSwitch: Bool) -> LayoutProfile {
        let settings = SettingsStore.shared
        let enabled = CardKind.allCases.filter { settings.desktopWidgets.contains($0) }
        var configs: [String: DesktopWidgetConfig] = [:]
        var frames: [String: WidgetFrame] = [:]
        for kind in enabled {
            configs[kind.rawValue] = settings.desktopConfig(for: kind)
            if let window = windows[kind] {
                let screen = window.screen ?? NSScreen.main
                let base = screen?.frame.origin ?? .zero
                frames[kind.rawValue] = WidgetFrame(relX: Double(window.frame.minX - base.x),
                                                    relY: Double(window.frame.minY - base.y),
                                                    width: Double(window.frame.width),
                                                    height: Double(window.frame.height),
                                                    displayID: displayID(of: screen))
            }
        }
        return LayoutProfile(name: name,
                             displaySignature: currentSignature(),
                             autoSwitch: autoSwitch,
                             enabled: enabled.map(\.rawValue),
                             configs: configs,
                             frames: frames)
    }

    /// Restores a profile: applies its configs and enabled set, rebuilds the
    /// windows, then positions each on its remembered display.
    func applyProfile(_ profile: LayoutProfile) {
        let settings = SettingsStore.shared
        var configs: [CardKind: DesktopWidgetConfig] = [:]
        for (raw, cfg) in profile.configs {
            if let kind = CardKind(rawValue: raw) { configs[kind] = cfg }
        }
        settings.desktopWidgetConfigs = configs
        settings.desktopWidgets = Set(profile.enabled.compactMap { CardKind(rawValue: $0) })
        // Build/tear down windows now rather than waiting for the async observer.
        syncWindows()
        positionWindows(from: profile)
        lastAppliedSignature = profile.displaySignature
    }

    private func positionWindows(from profile: LayoutProfile) {
        for (raw, frame) in profile.frames {
            guard let kind = CardKind(rawValue: raw), let window = windows[kind] else { continue }
            let screen = screenMatching(displayID: frame.displayID) ?? NSScreen.main
            let base = screen?.frame.origin ?? .zero
            var origin = NSPoint(x: base.x + frame.relX, y: base.y + frame.relY)
            if let vf = screen?.visibleFrame {
                // Keep at least a 40-pt sliver on-screen after a rearrangement.
                origin.x = min(max(origin.x, vf.minX - CGFloat(frame.width) + 40), vf.maxX - 40)
                origin.y = min(max(origin.y, vf.minY - CGFloat(frame.height) + 40), vf.maxY - 40)
            }
            window.setOriginBypassingSnap(origin)
        }
    }

    // MARK: - Displays (#43)

    /// A stable signature of the current monitor arrangement (id + point size),
    /// used to auto-match a layout profile.
    func currentSignature() -> String {
        NSScreen.screens.map { s in
            "\(displayID(of: s) ?? 0):\(Int(s.frame.width))x\(Int(s.frame.height))"
        }.sorted().joined(separator: ",")
    }

    private func displayID(of screen: NSScreen?) -> UInt32? {
        guard let screen else { return nil }
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value
    }

    private func screenMatching(displayID id: UInt32?) -> NSScreen? {
        guard let id else { return nil }
        return NSScreen.screens.first { displayID(of: $0) == id }
    }

    private func handleScreenChange() {
        clampWindowsOnScreen()
        let signature = currentSignature()
        guard signature != lastAppliedSignature else { return }
        if let profile = SettingsStore.shared.layoutProfiles.first(
            where: { $0.autoSwitch && $0.displaySignature == signature }) {
            applyProfile(profile)
        } else {
            lastAppliedSignature = signature
        }
    }

    /// Nudges any widget that ended up fully off-screen (a display was
    /// unplugged) back onto the main display.
    private func clampWindowsOnScreen() {
        let screens = NSScreen.screens
        for window in windows.values {
            let onScreen = screens.contains { $0.frame.intersects(window.frame) }
            guard !onScreen, let main = NSScreen.main else { continue }
            let vf = main.visibleFrame
            let size = window.frame.size
            window.setOriginBypassingSnap(NSPoint(x: vf.maxX - size.width - 24,
                                                  y: vf.maxY - size.height - 24))
        }
    }

    // MARK: - Size re-sync

    /// Cards grow/shrink rarely (a sensor appears, a process list lengthens),
    /// so a slow timer — running only while widgets exist — keeps each window
    /// snug around its card without per-frame layout work.
    private func updateSizeTimer() {
        if windows.isEmpty {
            sizeTimer?.invalidate()
            sizeTimer = nil
        } else if sizeTimer == nil {
            sizeTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.resyncSizes() }
            }
        }
    }

    private func resyncSizes() {
        for kind in windows.keys {
            layoutWidget(kind: kind, anchorTop: true)
        }
    }
}

// MARK: - Arrange pill view (#43)

/// The floating pill shown while arranging: a hint plus a Done button that
/// pins the widgets back onto the desktop in place.
private struct ArrangePillView: View {
    var onDone: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.grid.2x2")
                .foregroundStyle(.secondary)
            Text("Arranging widgets — drag to position; they snap to a grid and to each other")
                .font(.system(size: 11.5, weight: .medium))
                .fixedSize()
            Button("Done", action: onDone)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor).opacity(0.5)))
        .padding(6) // room for the window shadow
    }
}
