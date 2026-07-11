import AppKit
import Observation
import SwiftUI

/// Borderless window pinned to the desktop layer. Never becomes key or main
/// so widgets can't steal focus (borderless windows refuse key by default —
/// the override makes it explicit), yet background-drag still moves them.
private final class DesktopWidgetWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Floats one real-time metric card per enabled kind directly on the desktop
/// — above the wallpaper, below the desktop icons (GeekTool/Übersicht style)
/// — and keeps the set of windows in sync with SettingsStore.desktopWidgets.
@Observable @MainActor
final class DesktopWidgetController {
    static let shared = DesktopWidgetController()

    @ObservationIgnored private var windows: [CardKind: DesktopWidgetWindow] = [:]
    @ObservationIgnored private var hostingViews: [CardKind: NSHostingView<AnyView>] = [:]
    @ObservationIgnored private var sizeTimer: Timer?

    /// The desktop layer is click-through, so widgets can't be dragged in
    /// place. While arranging, they float above other windows (with a shadow
    /// as the cue) and become draggable; turning it off pins them back down.
    var arranging = false {
        didSet { applyLevel() }
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
    }

    // MARK: - Settings observation

    private func observeSettings() {
        observeChanges {
            _ = SettingsStore.shared.desktopWidgets
        } perform: { [weak self] in
            self?.syncWindows()
        }
    }

    // MARK: - Window lifecycle

    private func syncWindows() {
        let wanted = SettingsStore.shared.desktopWidgets

        for (kind, window) in windows where !wanted.contains(kind) {
            window.close()
            windows[kind] = nil
            hostingViews[kind] = nil
        }
        // allCases order keeps first-ever stagger placement deterministic.
        for kind in CardKind.allCases where wanted.contains(kind) && windows[kind] == nil {
            makeWindow(kind: kind)
        }
        updateSizeTimer()
    }

    private func makeWindow(kind: CardKind) {
        let root = AnyView(
            MetricCardView(kind: kind)
                .frame(width: 300)
                .padding(2)
                .environment(MetricsEngine.shared)
                .environment(SettingsStore.shared)
        )
        let hosting = NSHostingView(rootView: root)

        let window = DesktopWidgetWindow(contentRect: .zero,
                                         styleMask: [.borderless],
                                         backing: .buffered,
                                         defer: false)
        window.isReleasedWhenClosed = false // ARC owns it via our dictionary
        // Just above the wallpaper, just below the desktop icons — or
        // floating while the user is arranging.
        window.level = currentLevel
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = arranging
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.contentView = hosting
        window.setContentSize(hosting.fittingSize)

        let autosaveName = "metrics.widget.\(kind.rawValue)"
        if !window.setFrameUsingName(autosaveName) {
            placeInitially(window, kind: kind)
        }
        // Adopt the autosave name after restoring so future drags persist.
        window.setFrameAutosaveName(autosaveName)
        // A restored frame may carry a stale size; re-fit the content.
        window.setContentSize(hosting.fittingSize)

        window.orderFrontRegardless()
        windows[kind] = window
        hostingViews[kind] = hosting
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
        for (kind, window) in windows {
            guard let hosting = hostingViews[kind] else { continue }
            let fitted = hosting.fittingSize
            let current = window.frame.size // borderless: frame == content
            guard abs(fitted.height - current.height) > 0.5
                    || abs(fitted.width - current.width) > 0.5 else { continue }
            // Anchor the top edge so a height change doesn't walk the widget
            // up or down the screen.
            let topY = window.frame.maxY
            window.setContentSize(fitted)
            var origin = window.frame.origin
            origin.y = topY - window.frame.height
            window.setFrameOrigin(origin)
        }
    }
}
