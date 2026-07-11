import AppKit
import SwiftUI

/// Settings → Alerts tab (features #15, #22, #23). A recent-firings log, the
/// rule list with enable toggles + last-fired, an editor sheet, quiet-hours,
/// the data-budget toggle, and notification status. Plain SwiftUI Buttons are
/// fine here — the dead-button caveat only applies to draggable dashboard cards.
struct AlertsSettingsTab: View {
    @Environment(MetricsEngine.self) private var engine
    @Environment(SettingsStore.self) private var settings

    // Plain State (not @State): the macro form needs the SwiftUIMacros plugin,
    // which the Command Line Tools toolchain doesn't ship.
    private var draftRule = State(initialValue: AlertRule.new())
    private var draftIsNew = State(initialValue: true)
    private var showingEditor = State(initialValue: false)

    private var alerts: AlertEngine { .shared }

    var body: some View {
        Form {
            recentSection
            rulesSection
            quietHoursSection
            dataBudgetSection
            notificationsSection
        }
        .formStyle(.grouped)
        .sheet(isPresented: showingEditor.projectedValue) {
            AlertRuleEditor(rule: draftRule.projectedValue,
                            isNew: draftIsNew.wrappedValue,
                            engine: engine,
                            useFahrenheit: settings.useFahrenheit,
                            onSave: { saved in
                                if draftIsNew.wrappedValue { alerts.addRule(saved) }
                                else { alerts.updateRule(saved) }
                                showingEditor.wrappedValue = false
                            },
                            onCancel: { showingEditor.wrappedValue = false })
        }
    }

    // MARK: - Recent alerts (#23)

    @ViewBuilder private var recentSection: some View {
        let recent = Array(alerts.history.entries.prefix(12))
        Section {
            if recent.isEmpty {
                Text("No alerts yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(recent) { entry in
                    historyRow(entry)
                }
                if alerts.history.entries.count > recent.count {
                    Text("Showing the \(recent.count) most recent of \(alerts.history.entries.count).")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        } header: {
            Text("Recent alerts")
        }
    }

    private func historyRow(_ entry: AlertHistoryEntry) -> some View {
        // Snooze/disable only make sense while the backing rule still exists.
        let rule = alerts.rules.first { $0.id == entry.ruleID }
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.ruleName)
                    .font(.system(size: 12, weight: .medium))
                Text("\(Fmt.date(entry.date))  ·  peak \(entry.peakText)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let rule {
                Menu {
                    Button("Snooze 30 min") { alerts.snooze(ruleID: rule.id, seconds: 30 * 60) }
                    Button("Snooze until tomorrow") { alerts.snoozeUntilTomorrow(ruleID: rule.id) }
                    if rule.isSnoozed {
                        Button("Clear snooze") { alerts.clearSnooze(ruleID: rule.id) }
                    }
                    Divider()
                    Button("Disable rule", role: .destructive) {
                        alerts.setEnabled(ruleID: rule.id, enabled: false)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .padding(.vertical, 1)
    }

    // MARK: - Rules (#15)

    private var rulesSection: some View {
        Section {
            if alerts.rules.isEmpty {
                Text("No rules yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(alerts.rules) { rule in
                    ruleRow(rule)
                }
            }
            Button {
                draftRule.wrappedValue = AlertRule.new()
                draftIsNew.wrappedValue = true
                showingEditor.wrappedValue = true
            } label: {
                Label("Add Rule…", systemImage: "plus")
            }
        } header: {
            Text("Rules")
        } footer: {
            Text("Rules are evaluated every sampling tick with a sustain delay, ~5% hysteresis, and a cooldown so nothing spams. Starter rules ship disabled.")
        }
    }

    private func ruleRow(_ rule: AlertRule) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: enabledBinding(rule))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
            VStack(alignment: .leading, spacing: 1) {
                Text(rule.name)
                    .font(.system(size: 12, weight: .medium))
                Text(subtitle(for: rule))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                draftRule.wrappedValue = rule
                draftIsNew.wrappedValue = false
                showingEditor.wrappedValue = true
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            Button(role: .destructive) {
                alerts.deleteRule(ruleID: rule.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 1)
    }

    private func subtitle(for rule: AlertRule) -> String {
        var parts: [String] = [conditionText(rule)]
        if let last = alerts.history.lastFired(ruleID: rule.id) ?? rule.lastFired {
            parts.append("last \(Fmt.ago(Date().timeIntervalSince(last)))")
        } else {
            parts.append("never fired")
        }
        if rule.isSnoozed, let until = rule.snoozedUntil {
            parts.append("snoozed to \(Fmt.date(until))")
        }
        return parts.joined(separator: "  ·  ")
    }

    private func conditionText(_ rule: AlertRule) -> String {
        let value = rule.metric.format(rule.threshold, fahrenheit: settings.useFahrenheit)
        if rule.metric.isLevel {
            return "\(rule.metric.title) ≥ \(value)"
        }
        return "\(rule.metric.title) \(rule.comparator.symbol) \(value)"
    }

    private func enabledBinding(_ rule: AlertRule) -> Binding<Bool> {
        Binding(
            get: { alerts.rules.first { $0.id == rule.id }?.enabled ?? false },
            set: { alerts.setEnabled(ruleID: rule.id, enabled: $0) }
        )
    }

    // MARK: - Quiet hours (#22)

    private var quietHoursSection: some View {
        Section {
            Toggle("Quiet hours", isOn: quietEnabledBinding)
            if settings.quietHoursEnabled {
                DatePicker("From", selection: quietStartBinding, displayedComponents: .hourAndMinute)
                DatePicker("Until", selection: quietEndBinding, displayedComponents: .hourAndMinute)
            }
            Toggle("Mute while Focus / Do Not Disturb is on", isOn: dndBinding)
        } header: {
            Text("Quiet hours")
        } footer: {
            Text("During quiet hours, only rules marked “bypass quiet hours” notify. Focus/DND state is read best-effort and may be unavailable on this macOS.")
        }
    }

    private var quietEnabledBinding: Binding<Bool> {
        Binding(get: { settings.quietHoursEnabled }, set: { settings.quietHoursEnabled = $0 })
    }
    private var dndBinding: Binding<Bool> {
        Binding(get: { settings.suppressDuringDND }, set: { settings.suppressDuringDND = $0 })
    }
    private var quietStartBinding: Binding<Date> {
        minutesDateBinding(get: { settings.quietHoursStartMinutes },
                           set: { settings.quietHoursStartMinutes = $0 })
    }
    private var quietEndBinding: Binding<Date> {
        minutesDateBinding(get: { settings.quietHoursEndMinutes },
                           set: { settings.quietHoursEndMinutes = $0 })
    }

    /// Bridges a minutes-since-midnight Int to a Date for DatePicker.
    private func minutesDateBinding(get: @escaping () -> Int, set: @escaping (Int) -> Void) -> Binding<Date> {
        Binding(
            get: {
                let cal = Calendar.current
                let m = get()
                return cal.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                set((c.hour ?? 0) * 60 + (c.minute ?? 0))
            }
        )
    }

    // MARK: - Data budget (#20)

    private var dataBudgetSection: some View {
        Section {
            Toggle("Alert at 50 / 80 / 100% of the monthly data cap", isOn: dataBudgetBinding)
                .disabled(settings.monthlyDataCapGB == nil)
        } header: {
            Text("Data budget")
        } footer: {
            if settings.monthlyDataCapGB == nil {
                Text("Set a monthly data cap in the Network tab to enable budget alerts.")
            } else {
                Text("Fires once per cycle at each threshold, using the cap and billing cycle from the Network tab.")
            }
        }
    }

    private var dataBudgetBinding: Binding<Bool> {
        Binding(get: { alerts.config.dataBudgetEnabled },
                set: { alerts.setDataBudgetEnabled($0) })
    }

    // MARK: - Notifications status

    private var notificationsSection: some View {
        Section {
            if !AlertNotifier.shared.isAvailable {
                Label("Notifications need the built Metrics.app bundle.", systemImage: "bell.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label(AlertNotifier.shared.authorized
                        ? "Notifications are enabled."
                        : "Enable notifications for Metrics in System Settings to receive alerts.",
                      systemImage: AlertNotifier.shared.authorized ? "bell.badge" : "bell")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Open Notification Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        } header: {
            Text("Notifications")
        }
    }
}

// MARK: - Rule editor sheet (#15/#16/#19/#21)

/// Add/edit sheet for a single rule. Drives a bound draft owned by the parent
/// tab, so no State lives in the custom-init path.
struct AlertRuleEditor: View {
    @Binding var rule: AlertRule
    let isNew: Bool
    let engine: MetricsEngine
    let useFahrenheit: Bool
    let onSave: (AlertRule) -> Void
    let onCancel: () -> Void

    private var sensorNames: [String] { AlertEngine.availableSensorNames(engine: engine) }

    var body: some View {
        VStack(spacing: 0) {
            Text(isNew ? "New Alert Rule" : "Edit Alert Rule")
                .font(.system(size: 13, weight: .semibold))
                .padding(.top, 14)
            Form {
                Section {
                    TextField("Name", text: $rule.name)
                    Picker("Metric", selection: metricBinding) {
                        ForEach(AlertMetric.allCases) { metric in
                            Text(metric.title).tag(metric)
                        }
                    }
                    contextControls
                    conditionControls
                }
                Section {
                    sustainControl
                    cooldownControl
                    Toggle("Bypass quiet hours", isOn: $rule.quietHoursBypass)
                } header: {
                    Text("Timing")
                }
                if rule.metric.isTemperature {
                    fanEscalationSection
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("Cancel", role: .cancel) { onCancel() }
                Spacer()
                Button(isNew ? "Add Rule" : "Save") { onSave(rule) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(rule.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
        .frame(width: 460, height: 520)
    }

    // MARK: Metric + context

    private var metricBinding: Binding<AlertMetric> {
        Binding(
            get: { rule.metric },
            set: { newMetric in
                var r = rule.reconfigured(for: newMetric)
                // Seed a sensor so a temp-sensor rule isn't a silent no-op.
                if newMetric.needsSensor, r.sensorName == nil { r.sensorName = sensorNames.first }
                rule = r
            }
        )
    }

    @ViewBuilder private var contextControls: some View {
        if rule.metric.needsSensor {
            if sensorNames.isEmpty {
                Text("No temperature sensors detected on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Sensor", selection: sensorBinding) {
                    ForEach(sensorNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
            }
        }
        if rule.metric.needsVolume {
            Picker("Volume", selection: volumeBinding) {
                Text("Boot volume").tag(String?.none)
                ForEach(engine.disk.volumes.filter { !$0.isRoot }) { vol in
                    Text(vol.name).tag(Optional(vol.path))
                }
            }
        }
        if rule.metric == .batteryPercent {
            Toggle("Only while charging", isOn: $rule.chargingOnly)
        }
    }

    private var sensorBinding: Binding<String> {
        Binding(
            get: { rule.sensorName ?? sensorNames.first ?? "" },
            set: { rule.sensorName = $0 }
        )
    }

    private var volumeBinding: Binding<String?> {
        Binding(get: { rule.volumePath }, set: { rule.volumePath = $0 })
    }

    // MARK: Condition

    @ViewBuilder private var conditionControls: some View {
        if rule.metric.isLevel {
            Picker("At level", selection: levelBinding) {
                ForEach(rule.metric.levelOptions, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
        } else {
            Picker("When it", selection: $rule.comparator) {
                ForEach(AlertComparator.allCases) { c in
                    Text(c.title).tag(c)
                }
            }
            LabeledContent("Threshold") {
                HStack(spacing: 6) {
                    TextField("", value: thresholdBinding, format: .number)
                        .labelsHidden()
                        .frame(width: 90)
                        .multilineTextAlignment(.trailing)
                    Text(displayUnit)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var displayUnit: String {
        rule.metric.isTemperature ? (useFahrenheit ? "°F" : "°C") : rule.metric.unit
    }

    private var levelBinding: Binding<Double> {
        Binding(get: { rule.threshold }, set: { rule.threshold = $0 })
    }

    /// Threshold in the user's display unit (converts °C↔°F for temp metrics).
    private var thresholdBinding: Binding<Double> {
        Binding(
            get: {
                let c = rule.threshold
                return (rule.metric.isTemperature && useFahrenheit) ? c * 9 / 5 + 32 : c
            },
            set: { shown in
                rule.threshold = (rule.metric.isTemperature && useFahrenheit) ? (shown - 32) * 5 / 9 : shown
            }
        )
    }

    // MARK: Timing

    private var sustainControl: some View {
        LabeledContent("Sustain for") {
            HStack(spacing: 6) {
                TextField("", value: $rule.sustainSeconds, format: .number)
                    .labelsHidden()
                    .frame(width: 70)
                    .multilineTextAlignment(.trailing)
                Text("seconds").foregroundStyle(.secondary)
            }
        }
    }

    private var cooldownControl: some View {
        LabeledContent("Cooldown") {
            HStack(spacing: 6) {
                TextField("", value: cooldownMinutesBinding, format: .number)
                    .labelsHidden()
                    .frame(width: 70)
                    .multilineTextAlignment(.trailing)
                Text("minutes").foregroundStyle(.secondary)
            }
        }
    }

    private var cooldownMinutesBinding: Binding<Double> {
        Binding(
            get: { rule.cooldownSeconds / 60 },
            set: { rule.cooldownSeconds = max(0, $0) * 60 }
        )
    }

    // MARK: Fan escalation (#21)

    private var fanEscalationSection: some View {
        Section {
            Picker("Set fan mode", selection: fanModeBinding) {
                Text("Don't change fans").tag(FanMode?.none)
                ForEach([FanMode.quiet, .balanced, .performance]) { mode in
                    Text(mode.title).tag(Optional(mode))
                }
            }
            if rule.escalationFanMode != nil {
                LabeledContent("Restore below") {
                    HStack(spacing: 6) {
                        TextField("", value: restoreMarginBinding, format: .number)
                            .labelsHidden()
                            .frame(width: 70)
                            .multilineTextAlignment(.trailing)
                        Text("° below").foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Action")
        } footer: {
            Text("When this rule fires, switch the fans to the chosen mode, then restore the previous mode once the hotspot falls the set amount below the threshold. Changing fan mode yourself cancels the restore.")
        }
    }

    private var fanModeBinding: Binding<FanMode?> {
        Binding(
            get: { rule.escalationFanMode },
            set: { mode in
                if let mode { rule.actions = [.notify, .setFanMode(mode)] }
                else { rule.actions = [.notify] }
            }
        )
    }

    private var restoreMarginBinding: Binding<Double> {
        Binding(
            get: { rule.fanRestoreMarginC ?? 8 },
            set: { rule.fanRestoreMarginC = max(0, $0) }
        )
    }
}
