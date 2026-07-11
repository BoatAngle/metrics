import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings window content: seven tabs of standard Form controls.
struct SettingsView: View {
    @Environment(MetricsEngine.self) private var engine
    @Environment(SettingsStore.self) private var settings

    // Plain State (not @State): the macro form needs the SwiftUIMacros plugin,
    // which the Command Line Tools toolchain doesn't ship.
    /// The name being typed for a new layout profile (#43).
    private var newProfileName = State(initialValue: "")

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            MenuBarSettingsTab()
                .environment(engine)
                .environment(settings)
                .tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }
            dashboardTab
                .tabItem { Label("Dashboard", systemImage: "rectangle.grid.1x2") }
            FansSettingsTab()
                .tabItem { Label("Fans", systemImage: "fanblades") }
            AlertsSettingsTab()
                .tabItem { Label("Alerts", systemImage: "bell.badge") }
            widgetsTab
                .tabItem { Label("Widgets", systemImage: "square.on.square.dashed") }
            networkTab
                .tabItem { Label("Network", systemImage: "network") }
            DataSettingsTab()
                .tabItem { Label("Data", systemImage: "cylinder.split.1x2") }
            aboutTab
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 470, height: 500)
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: launchAtLoginBinding)
                if let error = settings.launchAtLoginError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Section {
                LabeledContent {
                    Slider(value: sampleIntervalBinding,
                           in: SettingsStore.sampleIntervalRange,
                           step: 0.5,
                           onEditingChanged: { editing in
                               if !editing {
                                   engine.restart(interval: settings.sampleInterval)
                               }
                           })
                } label: {
                    Text("Sampling interval")
                    Text(intervalLabel)
                }
                Picker("Temperature unit", selection: fahrenheitBinding) {
                    Text("°C").tag(false)
                    Text("°F").tag(true)
                }
            }
            Section {
                Picker("Appearance", selection: appearanceBinding) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
            } footer: {
                Text("Applies to the dashboard and this window. Menu bar items always match the menu bar.")
            }
            Section {
                LabeledContent("Toggle dashboard") {
                    HotkeyRecorder(current: settings.dashboardHotkey) { settings.dashboardHotkey = $0 }
                }
                LabeledContent("Focus mode") {
                    HotkeyRecorder(current: settings.focusHotkey) { settings.focusHotkey = $0 }
                }
            } header: {
                Text("Global shortcuts")
            } footer: {
                Text("System-wide hotkeys, active from any app. “Toggle dashboard” shows or hides the menu-bar popover; “Focus mode” toggles Focus / Gaming mode (Widgets tab). Default: none.")
            }
        }
        .formStyle(.grouped)
    }

    private var appearanceBinding: Binding<AppearanceMode> {
        Binding(
            get: { settings.appearance },
            set: { settings.appearance = $0 }
        )
    }

    private var intervalLabel: String {
        let v = settings.sampleInterval
        return v == v.rounded()
            ? "every \(Int(v)) s"
            : String(format: "every %.1f s", v)
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { settings.launchAtLogin },
            set: { settings.launchAtLogin = $0 }
        )
    }

    private var sampleIntervalBinding: Binding<Double> {
        Binding(
            get: { settings.sampleInterval },
            set: { settings.sampleInterval = $0 }
        )
    }

    private var fahrenheitBinding: Binding<Bool> {
        Binding(
            get: { settings.useFahrenheit },
            set: { settings.useFahrenheit = $0 }
        )
    }

    // MARK: - Dashboard

    private var dashboardTab: some View {
        List {
            ForEach(Array(settings.cardOrder.enumerated()), id: \.element) { index, kind in
                HStack(spacing: 10) {
                    Toggle(kind.title, isOn: cardVisibleBinding(for: kind))
                    Spacer()
                    Button {
                        moveCard(at: index, by: -1)
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(.borderless)
                    .disabled(index == 0)
                    Button {
                        moveCard(at: index, by: 1)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.borderless)
                    .disabled(index == settings.cardOrder.count - 1)
                }
                .padding(.vertical, 2)
            }
            .onMove { source, destination in
                var order = settings.cardOrder
                order.move(fromOffsets: source, toOffset: destination)
                settings.cardOrder = order
            }
        }
    }

    private func cardVisibleBinding(for kind: CardKind) -> Binding<Bool> {
        Binding(
            get: { !settings.hiddenCards.contains(kind) },
            set: { visible in
                var hidden = settings.hiddenCards
                if visible { hidden.remove(kind) } else { hidden.insert(kind) }
                settings.hiddenCards = hidden
            }
        )
    }

    private func moveCard(at index: Int, by offset: Int) {
        var order = settings.cardOrder
        let target = index + offset
        guard order.indices.contains(index), order.indices.contains(target) else { return }
        order.swapAt(index, target)
        settings.cardOrder = order
    }

    // MARK: - Widgets

    private var enabledWidgetKinds: [CardKind] {
        CardKind.allCases.filter { $0 != .fans && settings.desktopWidgets.contains($0) }
    }

    private var widgetsTab: some View {
        Form {
            Section {
                ForEach(CardKind.allCases.filter { $0 != .fans }) { kind in
                    Toggle(kind.title, isOn: desktopWidgetBinding(for: kind))
                }
            } footer: {
                Text("Widgets float on your desktop and update in real time. Cards for hardware this Mac doesn't have stay invisible.")
            }

            if !enabledWidgetKinds.isEmpty {
                Section {
                    ForEach(enabledWidgetKinds) { kind in
                        DisclosureGroup(kind.title) { widgetAppearanceControls(for: kind) }
                    }
                } header: {
                    Text("Widget appearance")
                } footer: {
                    Text("Size, background opacity, a frameless look, and a per-widget theme — independent of the app's light/dark appearance.")
                }
            }

            Section {
                Toggle("Arrange widgets", isOn: arrangeBinding)
                    .disabled(settings.desktopWidgets.isEmpty)
            } footer: {
                Text("The desktop layer ignores clicks, so widgets can't be dragged in place. While arranging, they float above your windows and snap to an 8-pt grid and to each other's edges — drag them where you want, then use the floating “Done” pill (or turn this off) to pin them back onto the desktop.")
            }

            layoutProfilesSection
            focusModeSection
        }
        .formStyle(.grouped)
    }

    // MARK: Widget appearance (#41/#42)

    @ViewBuilder private func widgetAppearanceControls(for kind: CardKind) -> some View {
        Picker("Size", selection: configBinding(for: kind, \.scale)) {
            ForEach(WidgetScale.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)

        LabeledContent {
            Slider(value: configBinding(for: kind, \.backgroundOpacity), in: 0...1)
        } label: {
            Text("Background")
            Text("\(Int((settings.desktopConfig(for: kind).backgroundOpacity * 100).rounded()))%")
        }

        Toggle("Frameless", isOn: configBinding(for: kind, \.frameless))

        Picker("Theme", selection: configBinding(for: kind, \.theme)) {
            ForEach(WidgetTheme.allCases) { Text($0.title).tag($0) }
        }
    }

    /// Generic read/write binding into one field of a widget's config.
    private func configBinding<T>(for kind: CardKind,
                                  _ keyPath: WritableKeyPath<DesktopWidgetConfig, T>) -> Binding<T> {
        Binding(
            get: { settings.desktopConfig(for: kind)[keyPath: keyPath] },
            set: { newValue in
                var cfg = settings.desktopConfig(for: kind)
                cfg[keyPath: keyPath] = newValue
                settings.setDesktopConfig(cfg, for: kind)
            }
        )
    }

    // MARK: Layout profiles (#43)

    private var layoutProfilesSection: some View {
        Section {
            ForEach(settings.layoutProfiles) { profile in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(profile.name).fontWeight(.medium)
                        Spacer()
                        Button("Restore") { DesktopWidgetController.shared.applyProfile(profile) }
                            .controlSize(.small)
                        Button(role: .destructive) {
                            settings.removeLayoutProfile(id: profile.id)
                        } label: { Image(systemName: "trash") }
                            .controlSize(.small)
                    }
                    Toggle("Auto-switch when this display setup returns",
                           isOn: autoSwitchBinding(for: profile))
                        .font(.system(size: 11))
                        .controlSize(.small)
                }
                .padding(.vertical, 2)
            }
            HStack {
                TextField("New layout name", text: newProfileName.projectedValue)
                Button("Save current layout") { saveCurrentLayout() }
                    .disabled(settings.desktopWidgets.isEmpty)
            }
        } header: {
            Text("Layout profiles")
        } footer: {
            Text("Save every widget's position and settings as a named layout (e.g. “Desk”, “Laptop”). A profile remembers the monitor arrangement it was saved under; enable auto-switch to restore it automatically when that arrangement returns.")
        }
    }

    private func autoSwitchBinding(for profile: LayoutProfile) -> Binding<Bool> {
        Binding(
            get: { profile.autoSwitch },
            set: { on in
                var p = profile
                p.autoSwitch = on
                settings.updateLayoutProfile(p)
            }
        )
    }

    private func saveCurrentLayout() {
        let trimmed = newProfileName.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "Layout \(settings.layoutProfiles.count + 1)" : trimmed
        let profile = DesktopWidgetController.shared.captureProfile(named: name, autoSwitch: false)
        settings.addLayoutProfile(profile)
        newProfileName.wrappedValue = ""
    }

    // MARK: Focus / Gaming mode (#44)

    private var focusModeSection: some View {
        Section {
            Toggle("Focus / Gaming mode", isOn: focusActiveBinding)
            Toggle("Auto-enable on a system condition", isOn: focusAutoEnabledBinding)
            if settings.focusAutoEnabled {
                Picker("When", selection: focusTriggerBinding) {
                    ForEach(FocusTrigger.allCases) { Text($0.title).tag($0) }
                }
                if settings.focusTrigger == .frontmostApp {
                    Picker("App", selection: focusAppBinding) {
                        Text("Choose an app…").tag("")
                        ForEach(runningAppChoices, id: \.bundleID) { choice in
                            Text(choice.name).tag(choice.bundleID)
                        }
                    }
                }
            }
        } header: {
            Text("Focus / Gaming mode")
        } footer: {
            Text("Collapses every Metrics menu-bar item into one icon, hides all desktop widgets, and slows sampling to 5 s. Turn it off (click the icon, use the shortcut in General, or this switch) to restore everything exactly. Auto-enable arms it when a full-screen app appears or your chosen app comes to the front.")
        }
    }

    private var focusActiveBinding: Binding<Bool> {
        Binding(
            get: { FocusModeController.shared.active },
            set: { FocusModeController.shared.setActive($0) }
        )
    }

    private var focusAutoEnabledBinding: Binding<Bool> {
        Binding(get: { settings.focusAutoEnabled }, set: { settings.focusAutoEnabled = $0 })
    }

    private var focusTriggerBinding: Binding<FocusTrigger> {
        Binding(get: { settings.focusTrigger }, set: { settings.focusTrigger = $0 })
    }

    private var focusAppBinding: Binding<String> {
        Binding(
            get: { settings.focusTriggerBundleID ?? "" },
            set: { settings.focusTriggerBundleID = $0.isEmpty ? nil : $0 }
        )
    }

    /// Running regular apps offered by the frontmost-app trigger picker, plus
    /// the stored choice even if it isn't currently running.
    private var runningAppChoices: [(name: String, bundleID: String)] {
        var seen = Set<String>()
        var result: [(name: String, bundleID: String)] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let id = app.bundleIdentifier, let name = app.localizedName,
                  !seen.contains(id) else { continue }
            seen.insert(id)
            result.append((name, id))
        }
        if let stored = settings.focusTriggerBundleID, !stored.isEmpty, !seen.contains(stored) {
            result.append((stored, stored))
        }
        return result.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    private var arrangeBinding: Binding<Bool> {
        Binding(
            get: { DesktopWidgetController.shared.arranging },
            set: { DesktopWidgetController.shared.arranging = $0 }
        )
    }

    private func desktopWidgetBinding(for kind: CardKind) -> Binding<Bool> {
        Binding(
            get: { settings.desktopWidgets.contains(kind) },
            set: { enabled in
                var widgets = settings.desktopWidgets
                if enabled { widgets.insert(kind) } else { widgets.remove(kind) }
                settings.desktopWidgets = widgets
                // A freshly added widget floats immediately so it can be
                // dragged into place; flip Arrange off to pin it down.
                if enabled {
                    DesktopWidgetController.shared.arranging = true
                }
            }
        )
    }

    // MARK: - Network

    private var networkTab: some View {
        Form {
            Section {
                Stepper(value: billingDayBinding, in: 1...31) {
                    LabeledContent("Billing cycle starts", value: ordinalDay(settings.billingCycleStartDay))
                }
            } header: {
                Text("Billing cycle")
            } footer: {
                Text("The Network Data card's “This cycle” total resets on this day each month. A day past the month's length lands on its last day.")
            }
            Section {
                Toggle("Set a monthly data cap", isOn: capEnabledBinding)
                if settings.monthlyDataCapGB != nil {
                    LabeledContent("Cap") {
                        HStack(spacing: 6) {
                            TextField("", value: capValueBinding, format: .number)
                                .labelsHidden()
                                .frame(width: 90)
                                .multilineTextAlignment(.trailing)
                            Text("GB")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                Text("With a cap set, the card shows how much of it this cycle has used and how many days remain.")
            }
        }
        .formStyle(.grouped)
    }

    private var billingDayBinding: Binding<Int> {
        Binding(
            get: { settings.billingCycleStartDay },
            set: { settings.billingCycleStartDay = min(max($0, 1), 31) }
        )
    }

    private var capEnabledBinding: Binding<Bool> {
        Binding(
            get: { settings.monthlyDataCapGB != nil },
            set: { settings.monthlyDataCapGB = $0 ? (settings.monthlyDataCapGB ?? 1000) : nil }
        )
    }

    private var capValueBinding: Binding<Double> {
        Binding(
            get: { settings.monthlyDataCapGB ?? 1000 },
            set: { settings.monthlyDataCapGB = max(0, $0) }
        )
    }

    private func ordinalDay(_ day: Int) -> String {
        let suffix: String
        switch (day % 10, day % 100) {
        case (1, 11), (2, 12), (3, 13): suffix = "th"
        case (1, _): suffix = "st"
        case (2, _): suffix = "nd"
        case (3, _): suffix = "rd"
        default: suffix = "th"
        }
        return "\(day)\(suffix)"
    }

    // MARK: - About

    private var aboutTab: some View {
        VStack(spacing: 12) {
            Image(systemName: "gauge")
                .font(.system(size: 52))
                .foregroundStyle(Color.accentColor)
            Text("Metrics 1.0.0")
                .font(.system(size: 15, weight: .semibold))
            Text("Personal build — every feature free, nothing phones home.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("~/Desktop/metrics")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Data

/// History-database section: size, export (feature #32), diagnostics
/// (feature #10), retention policy, delete-all.
private struct DataSettingsTab: View {
    @Environment(MetricsEngine.self) private var engine
    @Environment(SettingsStore.self) private var settings

    // Plain State (not @State): the macro form needs the SwiftUIMacros plugin,
    // which the Command Line Tools toolchain doesn't ship. SwiftUI picks up
    // stored DynamicProperty values by reflection, so this behaves the same.
    private var dbSizeBytes = State(initialValue: UInt64?.none)
    private var confirmingDelete = State(initialValue: false)
    private var deleting = State(initialValue: false)

    private var availableMetrics = State(initialValue: [String]())
    private var selectedMetrics = State(initialValue: Set<String>())
    private var exportRange = State(initialValue: HistoryExport.Range.week)
    private var exportFormat = State(initialValue: HistoryExport.Format.csv)
    private var exporting = State(initialValue: false)
    private var exportMessage = State(initialValue: String?.none)
    private var showingDiagnostics = State(initialValue: false)

    var body: some View {
        Form {
            Section {
                LabeledContent("Size on disk",
                               value: dbSizeBytes.wrappedValue.map { Fmt.bytes($0) } ?? "—")
                LabeledContent("Location") {
                    Text("~/Library/Application Support/Metrics/history.sqlite")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } header: {
                Text("History database")
            } footer: {
                Text("Metrics records CPU, GPU, memory, temperature, fan, network, disk and battery history locally — nothing leaves this Mac. Raw samples are kept for 2 hours, per-minute summaries for 7 days, per-hour summaries for 90 days, and daily summaries forever.")
            }

            exportSection

            Section {
                Button("Run Diagnostics…") { showingDiagnostics.wrappedValue = true }
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Checks fans, sensors, battery, disk SMART status, recent abnormal shutdowns and the fan helper, with a plain-language verdict for each.")
            }

            Section {
                Button("Delete All History…", role: .destructive) {
                    confirmingDelete.wrappedValue = true
                }
                .disabled(deleting.wrappedValue)
            } footer: {
                Text("Removes every recorded sample and summary. Recording starts over immediately.")
            }
        }
        .formStyle(.grouped)
        .onAppear { refreshSize(); loadMetrics() }
        .sheet(isPresented: showingDiagnostics.projectedValue) {
            DiagnosticsView { showingDiagnostics.wrappedValue = false }
                .environment(engine)
                .environment(settings)
        }
        .confirmationDialog("Delete all recorded history?",
                            isPresented: confirmingDelete.projectedValue,
                            titleVisibility: .visible) {
            Button("Delete All History", role: .destructive) { deleteAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every recorded sample and summary will be removed. This cannot be undone.")
        }
    }

    // MARK: - Export (feature #32)

    private var exportSection: some View {
        Section {
            if availableMetrics.wrappedValue.isEmpty {
                Text("No history recorded yet.")
                    .foregroundStyle(.secondary)
            } else {
                DisclosureGroup("Series (\(selectedMetrics.wrappedValue.count) of \(availableMetrics.wrappedValue.count))") {
                    HStack {
                        Button("Select all") {
                            selectedMetrics.wrappedValue = Set(availableMetrics.wrappedValue)
                        }
                        Button("None") { selectedMetrics.wrappedValue = [] }
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    ForEach(availableMetrics.wrappedValue, id: \.self) { metric in
                        Toggle(HistoryExport.label(for: metric), isOn: metricBinding(metric))
                    }
                }
                Picker("Date range", selection: exportRange.projectedValue) {
                    ForEach(HistoryExport.Range.allCases) { Text($0.title).tag($0) }
                }
                Picker("Format", selection: exportFormat.projectedValue) {
                    ForEach(HistoryExport.Format.allCases) { Text($0.title).tag($0) }
                }
                HStack {
                    Button("Export Selected…") { export(everything: false) }
                        .disabled(selectedMetrics.wrappedValue.isEmpty || exporting.wrappedValue)
                    Button("Export Everything…") { export(everything: true) }
                        .disabled(exporting.wrappedValue)
                }
                if let msg = exportMessage.wrappedValue {
                    Text(msg).font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Export")
        } footer: {
            Text("Writes the chosen series to a CSV or JSON file. “Export Everything” saves every recorded series over the full retention window in one file.")
        }
    }

    private func metricBinding(_ metric: String) -> Binding<Bool> {
        Binding(
            get: { selectedMetrics.wrappedValue.contains(metric) },
            set: { on in
                if on { selectedMetrics.wrappedValue.insert(metric) }
                else { selectedMetrics.wrappedValue.remove(metric) }
            }
        )
    }

    private func loadMetrics() {
        Task { @MainActor in
            let metrics = await HistoryStore.shared.distinctMetrics()
            availableMetrics.wrappedValue = metrics
            if selectedMetrics.wrappedValue.isEmpty {
                selectedMetrics.wrappedValue = Set(metrics)   // default: all
            }
        }
    }

    private func export(everything: Bool) {
        let format = exportFormat.wrappedValue
        let range: HistoryExport.Range = everything ? .all : exportRange.wrappedValue
        let metrics = everything ? availableMetrics.wrappedValue : Array(selectedMetrics.wrappedValue)
        guard !metrics.isEmpty else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "metrics-\(everything ? "all" : "export").\(format.fileExtension)"
        panel.allowedContentTypes = [format == .csv ? .commaSeparatedText : .json]
        panel.canCreateDirectories = true
        // The user drives the panel and picks the destination — a first-party save.
        guard panel.runModal() == .OK, let url = panel.url else { return }

        exporting.wrappedValue = true
        exportMessage.wrappedValue = "Exporting…"
        Task { @MainActor in
            let content = await HistoryExport.build(metrics: metrics, range: range, format: format)
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
                exportMessage.wrappedValue = "Saved \(url.lastPathComponent)."
            } catch {
                exportMessage.wrappedValue = "Export failed: \(error.localizedDescription)"
            }
            exporting.wrappedValue = false
        }
    }

    private func refreshSize() {
        Task { @MainActor in
            dbSizeBytes.wrappedValue = await HistoryStore.shared.databaseSizeBytes()
        }
    }

    private func deleteAll() {
        deleting.wrappedValue = true
        Task { @MainActor in
            await HistoryStore.shared.deleteAllHistory()
            dbSizeBytes.wrappedValue = await HistoryStore.shared.databaseSizeBytes()
            availableMetrics.wrappedValue = []
            selectedMetrics.wrappedValue = []
            deleting.wrappedValue = false
        }
    }
}

// MARK: - Fans

private struct FansSettingsTab: View {
    @Environment(MetricsEngine.self) private var engine
    @Environment(SettingsStore.self) private var settings

    // Plain State (not @State): the macro form needs the SwiftUIMacros plugin,
    // which the Command Line Tools toolchain doesn't ship. SwiftUI picks up
    // stored DynamicProperty values by reflection, so this behaves the same.
    private var sliderRPM = State(initialValue: [Int: Double]())

    private var fans: FanControl { .shared }

    var body: some View {
        Form {
            if engine.sensors.fans.isEmpty {
                Section {
                    Text("No controllable fans detected.")
                        .foregroundStyle(.secondary)
                }
            } else {
                helperSection
                modeSection
                ForEach(engine.sensors.fans) { fan in
                    fanSection(fan)
                }
                Section {
                } footer: {
                    Text("Manual control is restored to automatic when Metrics quits. Speeds are clamped to the fan's safe range.")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            fans.refreshHelperStatus()
            fans.detectConflicts()
        }
    }

    private var helperSection: some View {
        Section {
            if fans.helperInstalled && !fans.helperNeedsUpdate {
                Label("Privileged helper installed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
            } else if fans.helperNeedsUpdate {
                Text("A newer fan helper is available. Reinstall to apply the update (admin password required).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Update Helper…") {
                    Task { await fans.installHelper() }
                }
                .disabled(fans.busy)
            } else {
                Text("Changing fan speeds needs a one-time privileged helper (admin password required).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Install Helper…") {
                    Task { await fans.installHelper() }
                }
                .disabled(fans.busy)
            }
            if let conflict = fans.conflictingController {
                Label("\(conflict) is also controlling the fans — quit it to avoid conflicts.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let error = fans.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: Mode

    private var modeSection: some View {
        Section {
            Picker("Fan mode", selection: fans.modeBinding) {
                ForEach(FanMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!fans.canControlFans)
            Text(fans.effectiveMode.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
            if fans.effectiveMode.isCurve {
                curveStatusRow
            }
            // The chart stays visible in every mode — the dashed marker
            // tracks the live hotspot so you can see where each curve
            // would put the fans before committing to one.
            FanCurveChart(selected: fans.effectiveMode,
                          drivingTempC: fans.drivingTempC ?? engine.sensors.hotspotC,
                          useFahrenheit: settings.useFahrenheit)
                .frame(maxWidth: .infinity)
                .frame(height: 110)
        }
    }

    private var curveStatusRow: some View {
        Group {
            if let text = fanCurveStatusText(engine: engine, fans: fans,
                                             useFahrenheit: settings.useFahrenheit) {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                Text("Waiting for first reading…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Per-fan sections

    private func fanSection(_ fan: FanInfo) -> some View {
        Section(fan.name) {
            LabeledContent("Current speed", value: "\(Int(fan.rpm).formatted()) rpm")
            switch fans.effectiveMode {
            case .manual:
                LabeledContent {
                    Slider(value: fanSliderBinding(for: fan, store: sliderRPM.projectedValue),
                           in: fan.controlRange,
                           onEditingChanged: { editing in
                               guard !editing else { return }
                               let rpm = fan.clampedSliderValue(sliderRPM.wrappedValue[fan.id])
                               Task { await fans.setManual(fan: fan.id, rpm: rpm) }
                           })
                    .disabled(!fans.canControlFans)
                } label: {
                    Text("Target")
                    Text("\(Int(fan.clampedSliderValue(sliderRPM.wrappedValue[fan.id])).formatted()) rpm")
                }
            case .quiet, .balanced, .performance:
                LabeledContent("Curve target", value: curveTargetText(for: fan))
            case .auto:
                EmptyView()
            }
        }
    }

    private func curveTargetText(for fan: FanInfo) -> String {
        guard let rpm = fans.currentTargets[fan.id] else { return "—" }
        return "\(Int(rpm.rounded()).formatted()) rpm"
    }
}

// MARK: - Menu Bar (Package 11)

/// Tri-state per-item reactive-color choice (#33): follow the global toggle, or
/// force it on/off for this item.
private enum ReactiveChoice: String, CaseIterable, Identifiable {
    case global, on, off
    var id: String { rawValue }
    var title: String {
        switch self {
        case .global: return "Follow global"
        case .on: return "On"
        case .off: return "Off"
        }
    }
}

/// Full menu bar item editor: the global reactive toggle plus one configurable
/// section per item (kind-specific fields, render style, thresholds, click
/// action) with add / remove / reorder.
private struct MenuBarSettingsTab: View {
    @Environment(MetricsEngine.self) private var engine
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        Form {
            Section {
                Toggle("Load-reactive colors", isOn: reactiveGlobalBinding)
            } footer: {
                Text("Tints items amber, then red, as CPU, memory pressure, temperature or disk cross their thresholds. Each item can override this below.")
            }

            Section {
                addMenu
            } footer: {
                Text("⌘-drag items in the menu bar to rearrange them, or use the arrows on each item.")
            }

            ForEach(Array(settings.widgetInstances.enumerated()), id: \.element.id) { index, inst in
                itemSection(inst, index: index)
            }
        }
        .formStyle(.grouped)
    }

    private var reactiveGlobalBinding: Binding<Bool> {
        Binding(get: { settings.menuBarReactiveColors },
                set: { settings.menuBarReactiveColors = $0 })
    }

    private var addMenu: some View {
        Menu {
            ForEach(WidgetItemKind.allCases) { kind in
                Button { settings.addWidget(kind) } label: { Label(kind.title, systemImage: kind.symbol) }
            }
        } label: {
            Label("Add Item", systemImage: "plus.circle")
        }
    }

    // MARK: One item

    @ViewBuilder private func itemSection(_ inst: WidgetInstance, index: Int) -> some View {
        Section {
            // Kind-specific configuration first.
            kindConfig(inst)

            if !inst.kind.availableStyles.isEmpty {
                Picker("Style", selection: styleBinding(inst)) {
                    ForEach(inst.kind.availableStyles) { Text($0.title).tag($0) }
                }
            }

            if showsColoring(inst.kind) {
                Picker("Reactive color", selection: reactiveChoiceBinding(inst)) {
                    ForEach(ReactiveChoice.allCases) { Text($0.title).tag($0) }
                }
                if inst.kind == .memory {
                    Text("Colored by memory pressure (amber at Warning, red at Critical).")
                        .font(.caption).foregroundStyle(.secondary)
                } else if inst.kind == .combined {
                    Text("Each metric is colored by its own thresholds.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    thresholdRows(inst)
                }
            }

            Picker("On left-click", selection: clickBinding(inst)) {
                ForEach(WidgetClickAction.allCases) { Text($0.title).tag($0) }
            }
        } header: {
            HStack(spacing: 8) {
                Image(systemName: inst.kind.symbol)
                VStack(alignment: .leading, spacing: 1) {
                    Text(inst.kind.title).font(.system(size: 12, weight: .semibold))
                    Text(inst.summary).font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
                Spacer()
                Button { settings.moveWidget(id: inst.id, by: -1) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless).disabled(index == 0)
                Button { settings.moveWidget(id: inst.id, by: 1) } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless).disabled(index == settings.widgetInstances.count - 1)
                Button(role: .destructive) { settings.removeWidget(id: inst.id) } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
            .textCase(nil)
        }
    }

    /// Kinds that participate in reactive coloring (#33) and so show the toggle.
    private func showsColoring(_ kind: WidgetItemKind) -> Bool {
        kind.defaultThresholds != nil || kind == .memory || kind == .combined
    }

    // MARK: Kind-specific config

    @ViewBuilder private func kindConfig(_ inst: WidgetInstance) -> some View {
        switch inst.kind {
        case .combined:
            LabeledContent("Metrics (2–3)") {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(WidgetItemKind.combinableScalars) { metric in
                        Toggle(metric.title, isOn: combinedBinding(inst, metric))
                            .toggleStyle(.checkbox)
                            .disabled(combinedDisabled(inst, metric))
                    }
                }
            }
        case .format:
            TextField("Template", text: formatBinding(inst))
            DisclosureGroup("Tokens") {
                ForEach(MenuFormat.tokens, id: \.token) { entry in
                    LabeledContent {
                        Text(entry.description).font(.caption).foregroundStyle(.secondary)
                    } label: {
                        Text(entry.token).font(.system(size: 11, design: .monospaced))
                    }
                }
            }
        case .sensor:
            Picker("Sensor", selection: sensorNameBinding(inst)) {
                ForEach(sensorChoices(inst), id: \.self) { Text($0).tag($0) }
            }
            TextField("Label (3 chars)", text: sensorLabelBinding(inst))
                .onAppear { seedSensorIfNeeded(inst) }
        case .fanRPM:
            Picker("Fan", selection: fanBinding(inst)) {
                Text("Max").tag(Int?.none)
                ForEach(engine.sensors.fans) { fan in
                    Text(fan.name).tag(Int?.some(fan.id))
                }
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder private func thresholdRows(_ inst: WidgetInstance) -> some View {
        let isTemp = (inst.kind == .temperature || inst.kind == .sensor)
        let unit = isTemp ? "°C" : "%"
        let range: ClosedRange<Double> = isTemp ? 0...120 : 0...100
        Stepper(value: warnBinding(inst), in: range, step: isTemp ? 1 : 5) {
            LabeledContent("Warn", value: "\(Int(currentThresholds(inst).warn)) \(unit)")
        }
        Stepper(value: critBinding(inst), in: range, step: isTemp ? 1 : 5) {
            LabeledContent("Critical", value: "\(Int(currentThresholds(inst).crit)) \(unit)")
        }
    }

    // MARK: Lookups & bindings

    /// The live copy of an instance from the store (the ForEach element can lag
    /// a mutation by a frame).
    private func current(_ inst: WidgetInstance) -> WidgetInstance {
        settings.widgetInstances.first(where: { $0.id == inst.id }) ?? inst
    }

    private func currentThresholds(_ inst: WidgetInstance) -> (warn: Double, crit: Double) {
        current(inst).thresholds ?? inst.kind.defaultThresholds ?? (0, 0)
    }

    private func styleBinding(_ inst: WidgetInstance) -> Binding<WidgetRenderStyle> {
        Binding(get: { current(inst).style },
                set: { var c = current(inst); c.style = $0; settings.updateWidget(c) })
    }

    private func clickBinding(_ inst: WidgetInstance) -> Binding<WidgetClickAction> {
        Binding(get: { current(inst).clickAction },
                set: { var c = current(inst); c.clickAction = $0; settings.updateWidget(c) })
    }

    private func reactiveChoiceBinding(_ inst: WidgetInstance) -> Binding<ReactiveChoice> {
        Binding(get: {
            switch current(inst).reactiveColor {
            case .none: return .global
            case .some(true): return .on
            case .some(false): return .off
            }
        }, set: {
            var c = current(inst)
            switch $0 {
            case .global: c.reactiveColor = nil
            case .on: c.reactiveColor = true
            case .off: c.reactiveColor = false
            }
            settings.updateWidget(c)
        })
    }

    private func warnBinding(_ inst: WidgetInstance) -> Binding<Double> {
        Binding(get: { currentThresholds(inst).warn },
                set: { var c = current(inst); c.warnThreshold = $0; settings.updateWidget(c) })
    }

    private func critBinding(_ inst: WidgetInstance) -> Binding<Double> {
        Binding(get: { currentThresholds(inst).crit },
                set: { var c = current(inst); c.critThreshold = $0; settings.updateWidget(c) })
    }

    private func combinedBinding(_ inst: WidgetInstance, _ metric: WidgetItemKind) -> Binding<Bool> {
        Binding(get: { (current(inst).combinedMetrics ?? []).contains(metric) },
                set: { on in
                    var c = current(inst)
                    var list = c.combinedMetrics ?? []
                    if on {
                        if list.count < 3, !list.contains(metric) { list.append(metric) }
                    } else {
                        if list.count > 2 { list.removeAll { $0 == metric } }
                    }
                    c.combinedMetrics = list
                    settings.updateWidget(c)
                })
    }

    /// A metric checkbox is disabled when unchecking would drop below 2, or
    /// checking would exceed 3 — keeping a Combined item in its 2–3 range.
    private func combinedDisabled(_ inst: WidgetInstance, _ metric: WidgetItemKind) -> Bool {
        let list = current(inst).combinedMetrics ?? []
        if list.contains(metric) { return list.count <= 2 }
        return list.count >= 3
    }

    private func formatBinding(_ inst: WidgetInstance) -> Binding<String> {
        Binding(get: { current(inst).formatString ?? "" },
                set: { var c = current(inst); c.formatString = $0; settings.updateWidget(c) })
    }

    private func sensorChoices(_ inst: WidgetInstance) -> [String] {
        var names = MenuBarReading.availableSensorNames(engine.sensors)
        if let saved = current(inst).sensorName, !names.contains(saved) { names.append(saved) }
        return names
    }

    private func sensorNameBinding(_ inst: WidgetInstance) -> Binding<String> {
        Binding(get: { current(inst).sensorName ?? sensorChoices(inst).first ?? "" },
                set: { var c = current(inst); c.sensorName = $0
                    if (c.sensorLabel ?? "").isEmpty { c.sensorLabel = String($0.prefix(3)) }
                    settings.updateWidget(c) })
    }

    private func sensorLabelBinding(_ inst: WidgetInstance) -> Binding<String> {
        Binding(get: { current(inst).sensorLabel ?? "" },
                set: { var c = current(inst); c.sensorLabel = String($0.prefix(3)); settings.updateWidget(c) })
    }

    private func seedSensorIfNeeded(_ inst: WidgetInstance) {
        let c = current(inst)
        guard c.sensorName == nil, let first = MenuBarReading.availableSensorNames(engine.sensors).first else { return }
        var updated = c
        updated.sensorName = first
        if (updated.sensorLabel ?? "").isEmpty { updated.sensorLabel = String(first.prefix(3)) }
        settings.updateWidget(updated)
    }

    private func fanBinding(_ inst: WidgetInstance) -> Binding<Int?> {
        Binding(get: { current(inst).fanIndex },
                set: { var c = current(inst); c.fanIndex = $0; settings.updateWidget(c) })
    }
}
