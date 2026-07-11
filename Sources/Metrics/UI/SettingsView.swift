import SwiftUI

/// Settings window content: seven tabs of standard Form controls.
struct SettingsView: View {
    @Environment(MetricsEngine.self) private var engine
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            menuBarTab
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

    // MARK: - Menu Bar

    private var menuBarTab: some View {
        Form {
            Section {
                ForEach(MenuBarWidgetKind.allCases) { kind in
                    Toggle(kind.title, isOn: widgetBinding(for: kind))
                        .disabled(settings.enabledWidgets.count == 1
                                  && settings.enabledWidgets.contains(kind))
                }
            } footer: {
                Text("⌘-drag items in the menu bar to rearrange them.")
            }
        }
        .formStyle(.grouped)
    }

    private func widgetBinding(for kind: MenuBarWidgetKind) -> Binding<Bool> {
        Binding(
            get: { settings.enabledWidgets.contains(kind) },
            set: { enabled in
                var membership = Set(settings.enabledWidgets)
                if enabled {
                    membership.insert(kind)
                } else {
                    guard membership.count > 1 else { return }
                    membership.remove(kind)
                }
                settings.enabledWidgets = MenuBarWidgetKind.allCases.filter { membership.contains($0) }
            }
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

    private var widgetsTab: some View {
        Form {
            Section {
                ForEach(CardKind.allCases.filter { $0 != .fans }) { kind in
                    Toggle(kind.title, isOn: desktopWidgetBinding(for: kind))
                }
            } footer: {
                Text("Widgets float on your desktop and update in real time. Cards for hardware this Mac doesn't have stay invisible.")
            }
            Section {
                Toggle("Arrange widgets", isOn: arrangeBinding)
                    .disabled(settings.desktopWidgets.isEmpty)
            } footer: {
                Text("The desktop layer ignores clicks, so widgets can't be dragged in place. While arranging, they float above your windows — drag them where you want, then turn this off to pin them back onto the desktop. Positions are remembered.")
            }
        }
        .formStyle(.grouped)
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

/// History-database section: size on disk, retention policy, delete-all.
private struct DataSettingsTab: View {
    // Plain State (not @State): the macro form needs the SwiftUIMacros plugin,
    // which the Command Line Tools toolchain doesn't ship. SwiftUI picks up
    // stored DynamicProperty values by reflection, so this behaves the same.
    private var dbSizeBytes = State(initialValue: UInt64?.none)
    private var confirmingDelete = State(initialValue: false)
    private var deleting = State(initialValue: false)

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
        .onAppear { refreshSize() }
        .confirmationDialog("Delete all recorded history?",
                            isPresented: confirmingDelete.projectedValue,
                            titleVisibility: .visible) {
            Button("Delete All History", role: .destructive) { deleteAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every recorded sample and summary will be removed. This cannot be undone.")
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
