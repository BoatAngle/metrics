import AppKit
import SwiftUI

/// Hosting view that never intercepts clicks — the status bar button
/// underneath handles them.
private final class PassthroughHostingView: NSHostingView<AnyView> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Creates one NSStatusItem per enabled menu bar widget (fixed widths, so the
/// menu bar never shifts as values update) and owns the dashboard popover.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let engine: MetricsEngine
    private let settings: SettingsStore
    private let openDashboardAction: () -> Void
    private let openSettingsAction: () -> Void

    private var items: [MenuBarWidgetKind: NSStatusItem] = [:]
    private var popover: NSPopover?
    private weak var popoverAnchor: NSStatusBarButton?
    private var clickMonitor: Any?

    init(engine: MetricsEngine,
         settings: SettingsStore,
         openDashboard: @escaping () -> Void,
         openSettings: @escaping () -> Void) {
        self.engine = engine
        self.settings = settings
        self.openDashboardAction = openDashboard
        self.openSettingsAction = openSettings
        super.init()
        rebuildItems()
        observeSettings()
    }

    // MARK: Items

    private func rebuildItems() {
        var wanted = settings.enabledWidgets
        if wanted.isEmpty { wanted = [.cpuPercent] } // never leave the app unreachable

        for (kind, item) in items where !wanted.contains(kind) {
            NSStatusBar.system.removeStatusItem(item)
            items[kind] = nil
        }
        // New items appear leftmost, so create in reverse for stable order.
        for kind in wanted.reversed() where items[kind] == nil {
            items[kind] = makeItem(kind: kind)
        }
    }

    private func makeItem(kind: MenuBarWidgetKind) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: kind.fixedWidth)
        item.autosaveName = "metrics.widget.\(kind.rawValue)"

        let root = AnyView(
            MenuBarItemView(kind: kind)
                .environment(engine)
                .environment(settings)
        )
        let hosting = PassthroughHostingView(rootView: root)
        hosting.translatesAutoresizingMaskIntoConstraints = false

        if let button = item.button {
            button.addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                hosting.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            ])
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        return item
    }

    // MARK: Settings observation

    private func observeSettings() {
        observeChanges { [weak self] in
            _ = self?.settings.enabledWidgets
        } perform: { [weak self] in
            self?.rebuildItems()
        }
    }

    // MARK: Clicks

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu(from: sender)
        } else {
            togglePopover(from: sender)
        }
    }

    private func showContextMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()
        let dashboardItem = NSMenuItem(title: "Open Dashboard", action: #selector(openDashboardFromMenu), keyEquivalent: "d")
        dashboardItem.target = self
        menu.addItem(dashboardItem)
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        if !settings.desktopWidgets.isEmpty {
            let arrangeItem = NSMenuItem(title: "Arrange Desktop Widgets",
                                         action: #selector(toggleArrangeWidgets),
                                         keyEquivalent: "")
            arrangeItem.target = self
            arrangeItem.state = DesktopWidgetController.shared.arranging ? .on : .off
            menu.addItem(arrangeItem)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Metrics", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func openSettingsFromMenu() {
        openSettingsAction()
    }

    @objc private func openDashboardFromMenu() {
        openDashboardAction()
    }

    @objc private func toggleArrangeWidgets() {
        DesktopWidgetController.shared.arranging.toggle()
    }

    // MARK: Popover

    private func togglePopover(from button: NSStatusBarButton) {
        if let p = popover, p.isShown {
            let sameAnchor = (popoverAnchor === button)
            closePopover()
            if sameAnchor { return } // plain toggle; otherwise fall through and reopen anchored here
        }
        showPopover(from: button)
    }

    private func showPopover(from button: NSStatusBarButton) {
        let p = NSPopover()
        p.behavior = .transient
        p.delegate = self
        p.appearance = settings.appearance.nsAppearance
        let root = AnyView(
            DashboardView(
                openDashboard: { [weak self] in
                    self?.closePopover()
                    self?.openDashboardAction()
                },
                openSettings: { [weak self] in
                    self?.closePopover()
                    self?.openSettingsAction()
                },
                quit: { NSApp.terminate(nil) }
            )
            .environment(engine)
            .environment(settings)
        )
        p.contentViewController = NSHostingController(rootView: root)
        NSApp.activate(ignoringOtherApps: true)
        p.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        p.contentViewController?.view.window?.makeKey()
        popover = p
        popoverAnchor = button

        // .transient alone is unreliable for LSUIElement apps (no key window
        // to resign) — close explicitly on any click outside our app.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.closePopover() }
        }
    }

    private func closePopover() {
        popover?.performClose(nil)
        popoverCleanup()
    }

    private func popoverCleanup() {
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
        popover = nil
        popoverAnchor = nil
    }

    // Covers closes we didn't initiate (Esc, transient behavior firing, etc.).
    nonisolated func popoverDidClose(_ notification: Notification) {
        Task { @MainActor in
            // Only clean up for the popover we're tracking — a stale
            // notification from an already-replaced popover must not tear
            // down the current one's state.
            guard (notification.object as? NSPopover) === self.popover else { return }
            self.popoverCleanup()
        }
    }
}
