import AppKit
import SwiftUI

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static func main() {
        if CommandLine.arguments.contains("--dump") {
            DumpRunner.run()
            return
        }
        // Headless harness for the control socket + metricsctl CLI (Package 9).
        // Never touches the GUI; exits when done.
        if CommandLine.arguments.contains("--control-selftest") {
            ControlSelfTest.run()
            return
        }
        // Single instance: if another copy of Metrics (same bundle id, e.g. a
        // second launch or a build in a different folder) is already running,
        // focus it and exit instead of adding a second menu bar item.
        if let bundleID = Bundle.main.bundleIdentifier {
            let mine = NSRunningApplication.current.processIdentifier
            let existing = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleID)
                .first { $0.processIdentifier != mine }
            if let existing {
                existing.activate()
                return
            }
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Accessory even when run as a bare executable during development
        // (the bundled app also sets LSUIElement).
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private var statusController: StatusItemController?
    private var settingsWindow: NSWindow?
    private var dashboardWindow: NSWindow?
    private var weeklyWindow: NSWindow?

    /// Install the `metrics://` GetURL Apple Event handler early, before the
    /// initial open-URL event that a launch-by-URL delivers. FourCC literals
    /// ('GURL'/'GURL'/'----') keep us free of Carbon constant imports, matching
    /// the launch-kind check below.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(0x4755524C),   // 'GURL' kInternetEventClass
            andEventID: AEEventID(0x4755524C))         // 'GURL' kAEGetURL
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = SettingsStore.shared
        let engine = MetricsEngine.shared
        engine.start(interval: settings.sampleInterval)
        engine.startMonitors()
        statusController = StatusItemController(
            engine: engine,
            settings: settings,
            openDashboard: { [weak self] in self?.showDashboard() },
            openSettings: { [weak self] in self?.showSettings() }
        )
        buildMainMenu()
        observeAppearance()
        // Global hotkeys (feature #46): register the persisted bindings and
        // keep them in step as the user re-records them in Settings.
        registerHotkeys()
        observeHotkeys()
        // Alerts (features #15–#23): wire the notification delegate/categories,
        // then load the persisted rules so evaluation can begin on the next tick.
        AlertNotifier.shared.configure()
        AlertEngine.shared.load()
        FanControl.shared.engagePersistedModeAtLaunch()
        DesktopWidgetController.shared.start()
        // Control socket for the metricsctl CLI (Package 9). Best-effort: the
        // app runs fine without it.
        MetricsControlServer.shared.start(source: LiveControlSource())
        // Launching by hand (Finder, Spotlight, `open`) shows the dashboard;
        // a login-item launch stays quietly in the menu bar, and a
        // launch-by-URL lets the URL command decide whether to open a window.
        if !Self.launchedAsLoginItem && !Self.launchedViaURL {
            showDashboard()
        }
    }

    /// Double-clicking the app in Finder/Spotlight while it's already
    /// running lands here — surface the dashboard window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showDashboard()
        return true
    }

    /// Keeps open windows in step with the appearance setting.
    /// (The popover picks its appearance up fresh on every show.)
    private func observeAppearance() {
        observeChanges {
            _ = SettingsStore.shared.appearance
        } perform: { [weak self] in
            guard let self else { return }
            let appearance = SettingsStore.shared.appearance.nsAppearance
            self.settingsWindow?.appearance = appearance
            self.dashboardWindow?.appearance = appearance
            self.weeklyWindow?.appearance = appearance
        }
    }

    // MARK: - Global hotkeys (feature #46)

    /// Registers both optional hotkeys. The toggle-dashboard key flips the
    /// menu-bar popover; the focus-mode key is a registration seam only — it
    /// fires a callback P13 will hook, but ships no Focus mode yet.
    private func registerHotkeys() {
        let settings = SettingsStore.shared
        HotkeyCenter.shared.setBinding(settings.dashboardHotkey, for: .toggleDashboard) { [weak self] in
            self?.statusController?.toggleFromHotkey()
        }
        HotkeyCenter.shared.setBinding(settings.focusHotkey, for: .focusMode) {
            NSLog("Metrics: Focus-mode hotkey pressed — in-app Focus mode not implemented yet (P13).")
        }
    }

    /// Re-registers whenever the user records or clears a shortcut in Settings.
    private func observeHotkeys() {
        observeChanges {
            _ = SettingsStore.shared.dashboardHotkey
            _ = SettingsStore.shared.focusHotkey
        } perform: { [weak self] in
            self?.registerHotkeys()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Never leave fans forced after we're gone.
        FanControl.shared.restoreAllAutoOnQuit()
        MetricsControlServer.shared.stop()
        MetricsEngine.shared.stopMonitors()
        MetricsEngine.shared.stop()
    }

    // MARK: - URL scheme (metrics://)

    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor,
                                         withReplyEvent: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: AEKeyword(0x2D2D2D2D))?.stringValue, // '----' keyDirectObject
              let url = URL(string: string) else { return }
        handleURL(url)
    }

    /// Executes a parsed `metrics://` command. Unknown commands are logged and
    /// ignored — never a crash from a stray URL.
    private func handleURL(_ url: URL) {
        guard let command = MetricsURLCommand.parse(url) else {
            NSLog("Metrics: ignoring unrecognized URL %@", url.absoluteString)
            return
        }
        switch command {
        case .dashboard:
            showDashboard()

        case .card(let kind):
            // The card has to be visible to scroll to it; unhide if needed.
            if SettingsStore.shared.hiddenCards.contains(kind) {
                SettingsStore.shared.hiddenCards.remove(kind)
            }
            showDashboard()
            // Defer so the freshly shown window observes the nonce change.
            DispatchQueue.main.async { DashboardNavigator.shared.requestScroll(to: kind) }

        case .fan(let mode):
            FanControl.shared.mode = mode

        case .focus(let action):
            // Clean seam for a future in-app Focus mode (package P13). No such
            // mode exists yet, so log and no-op rather than pretend.
            NSLog("Metrics: focus/%@ requested — in-app Focus mode not implemented yet; ignoring.",
                  action.rawValue)

        case .copy(let metric):
            guard let value = MetricReadout.value(metric, engine: .shared, settings: SettingsStore.shared) else {
                NSLog("Metrics: copy/%@ — unknown metric; clipboard left unchanged.", metric)
                return
            }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(value, forType: .string)
        }
    }

    // MARK: - Dashboard window

    func showDashboard() {
        if dashboardWindow == nil {
            let root = DashboardWindowView(
                openSettings: { [weak self] in self?.showSettings() },
                openWeekly: { [weak self] in self?.showWeeklySummary() })
                .environment(MetricsEngine.shared)
                .environment(SettingsStore.shared)
                .environment(DashboardNavigator.shared)
            let hosting = NSHostingController(rootView: AnyView(root))
            // macOS Tahoe bug (FB21850950): scrolled content can paint into
            // the titlebar zone. The mitigation is twofold: a
            // contentViewController-mode window (SwiftUI manages the titlebar
            // integration) plus the 1-pt top spacer in DashboardWindowView
            // that keeps the scroll view off the content view's top edge.
            let window = NSWindow(contentViewController: hosting)
            window.title = "Metrics"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 940, height: 700))
            window.contentMinSize = NSSize(width: 720, height: 480)
            window.isReleasedWhenClosed = false
            window.center()
            // v4: earlier autosave names may hold badly-sized frames.
            window.setFrameAutosaveName("MetricsDashboard.v4")
            window.delegate = self
            dashboardWindow = window
        }
        dashboardWindow?.appearance = SettingsStore.shared.appearance.nsAppearance
        // Behave like a normal app (Dock icon, ⌘-tab) while the dashboard
        // is open; windowWillClose drops back to menu-bar-only.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        dashboardWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === dashboardWindow else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: - This Week window (features #30/#31)

    func showWeeklySummary() {
        if weeklyWindow == nil {
            let root = WeeklySummaryView()
                .environment(MetricsEngine.shared)
                .environment(SettingsStore.shared)
            let hosting = NSHostingController(rootView: AnyView(root))
            let window = NSWindow(contentViewController: hosting)
            window.title = "This Week"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 760, height: 680))
            window.contentMinSize = NSSize(width: 640, height: 560)
            window.isReleasedWhenClosed = false
            window.center()
            window.setFrameAutosaveName("MetricsThisWeek.v1")
            weeklyWindow = window
        }
        weeklyWindow?.appearance = SettingsStore.shared.appearance.nsAppearance
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        weeklyWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Settings window

    func showSettings() {
        if settingsWindow == nil {
            let root = SettingsView()
                .environment(MetricsEngine.shared)
                .environment(SettingsStore.shared)
            let hosting = NSHostingController(rootView: AnyView(root))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Metrics Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.appearance = SettingsStore.shared.appearance.nsAppearance
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func openSettingsFromMenu() {
        showSettings()
    }

    // MARK: - Main menu

    /// Minimal main menu so ⌘W/⌘M/⌘Q and Settings work while the app is in
    /// regular (Dock) mode with the dashboard open.
    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Metrics",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Metrics",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }

    // MARK: - Launch kind

    /// True when the running instance was started by logind/SMAppService
    /// rather than by the user. FourCC literals keep us independent of the
    /// Carbon constant imports: 'oapp', 'prdt', 'lgit'.
    private static var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == AEEventID(0x6F617070)
            && event.paramDescriptor(forKeyword: AEKeyword(0x70726474))?.enumCodeValue == OSType(0x6C676974)
    }

    /// True when this instance was launched to open a `metrics://` URL ('GURL').
    /// The URL handler then decides whether to surface a window, so we skip the
    /// unconditional dashboard show at launch.
    private static var launchedViaURL: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == AEEventID(0x4755524C) // 'GURL'
    }
}
