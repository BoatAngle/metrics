import AppKit
import Observation
import SwiftUI

/// Observable pin flag for the dashboard popover (#45). One instance is created
/// per popover session and thrown away on close, so pinning never persists.
@Observable @MainActor
final class PopoverState {
    var pinned = false
}

/// Stable menu-bar slots. AppKit persists each autosaved status item's position
/// in UserDefaults as "NSStatusItem Preferred Position <name>" — the distance
/// in points from the RIGHT edge of the status area, so larger = further left —
/// plus a "NSStatusItem Visible <name>" flag. The position default is read when
/// the autosaveName is assigned, so a slot must be seeded BEFORE the item is
/// created for it to take effect. Seeding huge descending values (8000, 7998, …)
/// parks the whole group at the far left of the status area in settings order;
/// AppKit clamps them to real coordinates on first layout and owns the keys
/// from there, so a user's ⌘-drag fine-tune persists like any other autosave.
enum MenuBarPositions {
    /// Autosave name for a configured instance. The id is a persisted UUID, so
    /// the name — and thus the saved slot — is stable across launches.
    static func name(for instanceID: String) -> String { "metrics.\(instanceID)" }
    /// The Focus/Gaming-mode collapsed icon's fixed slot (#44).
    static let focusName = "metrics.focus"

    /// Seed for the item at `index` in settings order (index 0 = leftmost).
    /// Far wider than any real menu bar; descending keeps left→right order.
    static func seed(at index: Int) -> Double { 8000 - Double(index * 2) }

    private static func positionKey(_ name: String) -> String {
        "NSStatusItem Preferred Position \(name)"
    }
    private static func visibleKey(_ name: String) -> String {
        "NSStatusItem Visible \(name)"
    }

    /// The saved slot for a name, if a seed (or AppKit) has recorded one.
    static func savedPosition(_ name: String) -> Double? {
        UserDefaults.standard.object(forKey: positionKey(name)) as? Double
    }

    /// Seeds a far-left slot unless one is already saved — an existing value
    /// is the user's arrangement and must never be overwritten here.
    static func seedIfNeeded(_ name: String, index: Int) {
        guard UserDefaults.standard.object(forKey: positionKey(name)) == nil else { return }
        UserDefaults.standard.set(seed(at: index), forKey: positionKey(name))
    }

    /// Overwrites the slot unconditionally — the settings-reorder and "group
    /// items at the far left" path, which re-anchors the whole group.
    static func forceSeed(_ name: String, index: Int) {
        UserDefaults.standard.set(seed(at: index), forKey: positionKey(name))
    }

    /// Drops both autosave defaults for an instance deleted in settings.
    static func forget(_ name: String) {
        UserDefaults.standard.removeObject(forKey: positionKey(name))
        UserDefaults.standard.removeObject(forKey: visibleKey(name))
    }

    /// Removes a status item without losing its slot: AppKit deletes the
    /// preferred-position default when an autosaved item is removed, which
    /// would shuffle the bar on the next rebuild (Focus-mode collapse/restore).
    /// Snapshot the value, remove, write it back.
    @MainActor
    static func removePreservingSlot(_ item: NSStatusItem, name: String) {
        let key = positionKey(name)
        let saved = UserDefaults.standard.object(forKey: key)
        NSStatusBar.system.removeStatusItem(item)
        if let saved { UserDefaults.standard.set(saved, forKey: key) }
    }
}

/// Creates one NSStatusItem per configured menu bar item (fixed widths, so the
/// menu bar never shifts as values update), dispatches per-item click actions
/// (#37), refreshes live tooltips each tick (#40), keeps every item in a
/// stable, far-left autosaved slot (`MenuBarPositions`), and owns the dashboard
/// popover.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let engine: MetricsEngine
    private let settings: SettingsStore
    private let openDashboardAction: () -> Void
    private let openSettingsAction: () -> Void

    /// One live status item. Its content is a bitmap re-rendered once per sample
    /// tick (see `image(for:)`), NOT a live NSHostingView: a hosted SwiftUI view
    /// inside a status item re-runs a full layout pass every display frame on
    /// current macOS, burning a CPU core at idle. Drawing to `button.image`
    /// costs a few milliseconds a second instead.
    private struct Item {
        var instance: WidgetInstance
        let statusItem: NSStatusItem
    }
    private var items: [String: Item] = [:]
    /// The lone compact item shown while Focus/Gaming mode collapses the bar (#44).
    private var focusItem: NSStatusItem?
    private var popover: NSPopover?
    private weak var popoverAnchor: NSStatusBarButton?
    private var clickMonitor: Any?
    /// Pin state for the currently-open popover (#45); reset on every close.
    private var popoverState = PopoverState()

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
        observeReseedRequests()
        observeFocusMode()
        observeEngineForTooltips()
    }

    // MARK: Items

    private func rebuildItems(reseed: Bool = false) {
        // Focus/Gaming mode (#44): collapse everything into one compact item.
        // Removal keeps each item's saved slot so positions restore intact.
        if FocusModeController.shared.active {
            for (id, entry) in items {
                MenuBarPositions.removePreservingSlot(entry.statusItem,
                                                      name: MenuBarPositions.name(for: id))
                items[id] = nil
            }
            if focusItem == nil { focusItem = makeFocusItem() }
            return
        }
        if let existing = focusItem {
            MenuBarPositions.removePreservingSlot(existing, name: MenuBarPositions.focusName)
            focusItem = nil
        }

        var wanted = settings.widgetInstances
        if wanted.isEmpty { wanted = WidgetInstance.defaults } // never leave the app unreachable

        let wantedIDs = Set(wanted.map(\.id))
        // Drop items that vanished, along with their saved slots.
        for (id, entry) in items where !wantedIDs.contains(id) {
            NSStatusBar.system.removeStatusItem(entry.statusItem)
            MenuBarPositions.forget(MenuBarPositions.name(for: id))
            items[id] = nil
        }
        // Re-anchor: tear down the surviving items and force-seed every slot in
        // the new settings order, so the on-screen order follows settings again.
        // (⌘-drag tweaks are deliberately reset — that's the point of the ask.)
        if reseed {
            for (id, entry) in items {
                NSStatusBar.system.removeStatusItem(entry.statusItem)
                items[id] = nil
            }
            for (index, inst) in wanted.enumerated() {
                MenuBarPositions.forceSeed(MenuBarPositions.name(for: inst.id), index: index)
            }
        }
        // Update changed items in place; create missing ones in settings order
        // (deterministic), seeding each new slot before creation — AppKit reads
        // the position default when the autosaveName is assigned, never after.
        for (index, inst) in wanted.enumerated() {
            if let existing = items[inst.id] {
                if existing.instance != inst { apply(inst, to: existing) }
            } else {
                MenuBarPositions.seedIfNeeded(MenuBarPositions.name(for: inst.id), index: index)
                items[inst.id] = makeItem(for: inst)
            }
        }
        refreshItems()
    }

    private func makeItem(for instance: WidgetInstance) -> Item {
        let statusItem = NSStatusBar.system.statusItem(withLength: MenuBarLayout.width(for: instance))
        // Tidy up the pre-slot-seeding autosave keys ("metrics.widget.<id>")
        // from earlier builds; harmless no-op once they're gone.
        MenuBarPositions.forget("metrics.widget.\(instance.id)")
        statusItem.autosaveName = MenuBarPositions.name(for: instance.id)
        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.image = image(for: instance, appearance: button.effectiveAppearance)
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        return Item(instance: instance, statusItem: statusItem)
    }

    /// Renders a menu bar item's SwiftUI view to a bitmap for `button.image`.
    /// Re-rendered each tick so values stay live without a permanently-hosted
    /// (and permanently-relayout-looping) NSHostingView. Rendered in the menu
    /// bar's own appearance so `.primary`/`.secondary` resolve to legible
    /// colors; the colored graphs/reactive tints ride along as-is.
    private func image(for instance: WidgetInstance, appearance: NSAppearance) -> NSImage? {
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let content = MenuBarItemView(instance: instance)
            .environment(engine)
            .environment(settings)
            .environment(\.colorScheme, isDark ? .dark : .light)
            .frame(height: NSStatusBar.system.thickness)
        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = false   // preserve rendered colors (graphs, warn/crit tints)
        return image
    }

    /// The single compact item shown in Focus/Gaming mode. Clicking it (or
    /// right-clicking for the menu) exits the mode and restores every item (#44).
    private func makeFocusItem() -> NSStatusItem {
        // Same far-left anchoring as the real items: seed the fixed slot before
        // creation so the collapsed icon lands (and stays) where the group lives.
        MenuBarPositions.seedIfNeeded(MenuBarPositions.focusName, index: 0)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = MenuBarPositions.focusName
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "moon.zzz.fill",
                                   accessibilityDescription: "Focus mode")
            button.image?.isTemplate = true
            button.toolTip = "Focus mode is on — click to restore Metrics"
            button.target = self
            button.action = #selector(handleFocusClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        return item
    }

    @objc private func handleFocusClick(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu(from: sender)
        } else {
            FocusModeController.shared.toggle()
        }
    }

    /// Applies a changed configuration to a live item: new width and redrawn
    /// content, keeping the same NSStatusItem (and its menu bar slot).
    private func apply(_ instance: WidgetInstance, to entry: Item) {
        entry.statusItem.length = MenuBarLayout.width(for: instance)
        if let button = entry.statusItem.button {
            button.image = image(for: instance, appearance: button.effectiveAppearance)
        }
        items[instance.id]?.instance = instance
    }

    /// The instance a status bar button belongs to, matched by identity.
    private func instance(for button: NSStatusBarButton) -> WidgetInstance? {
        items.values.first(where: { $0.statusItem.button === button })?.instance
    }

    // MARK: Settings observation

    private func observeSettings() {
        observeChanges { [weak self] in
            _ = self?.settings.widgetInstances
        } perform: { [weak self] in
            self?.rebuildItems()
        }
    }

    /// Re-anchors the whole group at the far left whenever settings asks for it
    /// (the reorder arrows in the Menu Bar tab, or its explicit button).
    private func observeReseedRequests() {
        observeChanges { [weak self] in
            _ = self?.settings.menuBarReseedNonce
        } perform: { [weak self] in
            self?.rebuildItems(reseed: true)
        }
    }

    /// Rebuilds the item set whenever Focus/Gaming mode toggles (#44).
    private func observeFocusMode() {
        observeChanges {
            _ = FocusModeController.shared.active
        } perform: { [weak self] in
            self?.rebuildItems()
        }
    }

    // MARK: Live content (#40 tooltips + per-tick redraw)

    /// Redraws every item's image and tooltip each time the engine publishes
    /// new samples. This once-per-tick redraw replaces a live NSHostingView,
    /// which would relayout every display frame (the idle-CPU fix).
    private func observeEngineForTooltips() {
        observeChanges { [weak self] in
            guard let self else { return }
            // Touch the snapshots the items read so this re-fires each tick.
            _ = self.engine.cpu
            _ = self.engine.gpu
            _ = self.engine.memory
            _ = self.engine.disk
            _ = self.engine.diskIO
            _ = self.engine.battery
            _ = self.engine.sensors
            _ = self.engine.network
            _ = self.engine.networkData
            _ = self.engine.processes
        } perform: { [weak self] in
            self?.refreshItems()
        }
    }

    /// Redraws each item's bitmap from the latest samples and refreshes its
    /// tooltip. Cheap: a handful of small ImageRenderer passes per second.
    private func refreshItems() {
        for (_, entry) in items {
            guard let button = entry.statusItem.button else { continue }
            button.image = image(for: entry.instance, appearance: button.effectiveAppearance)
            button.toolTip = MenuBarTooltip.text(for: entry.instance,
                                                 engine: engine, settings: settings)
        }
    }

    // MARK: Clicks

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu(from: sender)
        } else {
            performLeftClick(instance(for: sender), from: sender)
        }
    }

    /// Dispatches the item's configured left-click action (#37). A missing
    /// instance (shouldn't happen) falls back to the historical popover toggle.
    private func performLeftClick(_ instance: WidgetInstance?, from button: NSStatusBarButton) {
        switch instance?.clickAction ?? .openDashboard {
        case .openDashboard:
            togglePopover(from: button)
        case .openCard:
            openCard(for: instance, from: button)
        case .activityMonitor:
            openActivityMonitor()
        case .cycleFanMode:
            FanControl.shared.mode = FanControl.shared.mode.next
        }
    }

    /// Opens the dashboard window and scrolls/pulses to the item's card. Items
    /// without a natural card (Combined, Custom Format) just open the popover.
    private func openCard(for instance: WidgetInstance?, from button: NSStatusBarButton) {
        guard let kind = instance?.kind.card else {
            togglePopover(from: button)
            return
        }
        if settings.hiddenCards.contains(kind) { settings.hiddenCards.remove(kind) }
        openDashboardAction()
        // Defer so the freshly shown window observes the nonce change.
        DispatchQueue.main.async { DashboardNavigator.shared.requestScroll(to: kind) }
    }

    private func openActivityMonitor() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
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
        // Focus/Gaming mode toggle (#44).
        let focusItem = NSMenuItem(title: "Focus / Gaming Mode",
                                   action: #selector(toggleFocusMode),
                                   keyEquivalent: "")
        focusItem.target = self
        focusItem.state = FocusModeController.shared.active ? .on : .off
        menu.addItem(focusItem)
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

    @objc private func toggleFocusMode() {
        FocusModeController.shared.toggle()
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
        // Fresh pin state each time — pinning never carries across opens (#45).
        popoverState = PopoverState()
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
                quit: { NSApp.terminate(nil) },
                popoverState: popoverState,
                onTogglePin: { [weak self] in self?.togglePin() }
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
        installClickMonitor()
    }

    /// Watches for clicks outside our app to close a transient popover. Pinning
    /// suspends this (and switches the popover to .applicationDefined) so the
    /// popover stays open across outside clicks (#45).
    private func installClickMonitor() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.closePopover() }
        }
    }

    private func removeClickMonitor() {
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
    }

    /// Flips the popover between pinned and transient (#45).
    private func togglePin() {
        popoverState.pinned.toggle()
        if popoverState.pinned {
            popover?.behavior = .applicationDefined  // AppKit won't auto-close it
            removeClickMonitor()                     // and neither will our click-away
        } else {
            popover?.behavior = .transient
            installClickMonitor()
        }
    }

    /// Toggles the popover from the global hotkey (#46), anchored to the
    /// leftmost menu-bar item.
    func toggleFromHotkey() {
        guard let button = anchorButton() else {
            openDashboardAction()
            return
        }
        togglePopover(from: button)
    }

    /// The button of the leftmost configured item (falls back to any item).
    private func anchorButton() -> NSStatusBarButton? {
        if let firstID = settings.widgetInstances.first?.id,
           let button = items[firstID]?.statusItem.button {
            return button
        }
        return items.values.first?.statusItem.button
    }

    private func closePopover() {
        popover?.performClose(nil)
        popoverCleanup()
    }

    private func popoverCleanup() {
        removeClickMonitor()
        popover = nil
        popoverAnchor = nil
        // Pin state never survives a close (#45).
        popoverState.pinned = false
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
