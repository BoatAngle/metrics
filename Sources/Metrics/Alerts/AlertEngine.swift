import Foundation
import Observation

/// Central alerts brain (features #15–#23). Evaluated from the metrics tick on
/// the main actor. Owns the persisted rules + config, per-rule runtime state
/// (sustain timers, hysteresis, cooldown re-arm), fan-mode escalation, the
/// data-budget monitor, quiet-hours/DND muting, and the firing history.
@Observable @MainActor
final class AlertEngine {
    static let shared = AlertEngine()

    /// A stable, well-known id for data-budget firings (feature #20) so they can
    /// be recorded in the history without a backing rule.
    static let dataBudgetRuleID = UUID(uuidString: "00000000-0000-0000-0000-0000000000DB")!

    private(set) var rules: [AlertRule] = []
    private(set) var config = AlertConfig()
    let history = AlertHistory()

    @ObservationIgnored private let store = AlertStore()
    @ObservationIgnored private let notifier = AlertNotifier.shared
    @ObservationIgnored private var runtime: [UUID: RuleRuntime] = [:]
    @ObservationIgnored private var escalation: Escalation?
    @ObservationIgnored private var loaded = false

    /// Per-rule transient evaluation state (never persisted).
    private struct RuleRuntime {
        var exceededSince: Date?
        var active = false          // in the fired state until hysteresis re-arms
        var peak = 0.0
        var lastFired: Date?
    }

    /// A fan-mode escalation in flight (feature #21).
    private struct Escalation {
        var ruleID: UUID
        var previousMode: FanMode
        var appliedMode: FanMode
        var restoreBelowC: Double
    }

    private init() {}

    // MARK: - Lifecycle

    func load() {
        let (r, c) = store.load()
        rules = r
        config = c
        runtime = Dictionary(uniqueKeysWithValues: rules.map { ($0.id, RuleRuntime(lastFired: $0.lastFired)) })
        loaded = true
        if rules.contains(where: { $0.enabled }) {
            notifier.requestAuthorizationIfNeeded()
        }
    }

    private func persist() {
        guard loaded else { return }
        store.save(rules: rules, config: config)
    }

    // MARK: - Rule CRUD

    func addRule(_ rule: AlertRule) {
        rules.append(rule)
        runtime[rule.id] = RuleRuntime(lastFired: rule.lastFired)
        if rule.enabled { notifier.requestAuthorizationIfNeeded() }
        persist()
    }

    func updateRule(_ rule: AlertRule) {
        guard let i = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[i] = rule
        // Editing invalidates the old sustain/active state.
        runtime[rule.id] = RuleRuntime(lastFired: rule.lastFired)
        if rule.enabled { notifier.requestAuthorizationIfNeeded() }
        persist()
    }

    func deleteRule(ruleID: UUID) {
        rules.removeAll { $0.id == ruleID }
        runtime[ruleID] = nil
        if escalation?.ruleID == ruleID { escalation = nil }
        persist()
    }

    func setEnabled(ruleID: UUID, enabled: Bool) {
        guard let i = rules.firstIndex(where: { $0.id == ruleID }) else { return }
        rules[i].enabled = enabled
        if enabled {
            runtime[ruleID] = RuleRuntime(lastFired: rules[i].lastFired)
            notifier.requestAuthorizationIfNeeded()
        }
        persist()
    }

    func setDataBudgetEnabled(_ enabled: Bool) {
        config.dataBudgetEnabled = enabled
        if enabled { notifier.requestAuthorizationIfNeeded() }
        persist()
    }

    // MARK: - Snooze (feature #22)

    func snooze(ruleID: UUID, seconds: TimeInterval) {
        guard let i = rules.firstIndex(where: { $0.id == ruleID }) else { return }
        rules[i].snoozedUntil = Date().addingTimeInterval(seconds)
        persist()
    }

    func snoozeUntilTomorrow(ruleID: UUID) {
        guard let i = rules.firstIndex(where: { $0.id == ruleID }) else { return }
        rules[i].snoozedUntil = Self.tomorrowMorning()
        persist()
    }

    func clearSnooze(ruleID: UUID) {
        guard let i = rules.firstIndex(where: { $0.id == ruleID }) else { return }
        rules[i].snoozedUntil = nil
        persist()
    }

    /// Local 8 a.m. tomorrow — a reasonable "until tomorrow" wake time.
    private static func tomorrowMorning() -> Date {
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: Date()) ?? Date().addingTimeInterval(86400)
        return cal.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }

    /// Whether a fan escalation is currently active (for the Alerts tab).
    var escalationActive: Bool { escalation != nil }

    // MARK: - Evaluation

    /// Called every metrics tick. Cheap: a handful of comparisons per rule.
    func evaluate(from engine: MetricsEngine) {
        guard loaded else { return }
        let now = Date()
        let muted = computeMuted(now: now)
        for rule in rules where rule.enabled {
            evaluateRule(rule, engine: engine, now: now, muted: muted)
        }
        evaluateFanRestore(engine: engine)
        evaluateDataBudget(engine: engine, now: now, muted: muted)
    }

    private func evaluateRule(_ rule: AlertRule, engine: MetricsEngine, now: Date, muted: Bool) {
        var rt = runtime[rule.id] ?? RuleRuntime()
        defer { runtime[rule.id] = rt }

        guard let (value, offender) = reading(for: rule, engine: engine) else {
            // Metric unavailable this tick — drop any pending sustain so we don't
            // fire on stale state, and let an active episode lapse.
            rt.exceededSince = nil
            rt.active = false
            return
        }

        // Already fired: wait for the value to recover past the hysteresis band
        // before re-arming, so a value hovering at the threshold can't re-fire.
        if rt.active {
            if recovered(value, rule: rule) {
                rt.active = false
                rt.exceededSince = nil
            } else {
                rt.peak = extremum(rt.peak, value, comparator: rule.comparator)
                return
            }
        }

        guard exceeds(value, rule: rule) else {
            rt.exceededSince = nil
            return
        }

        if rt.exceededSince == nil {
            rt.exceededSince = now
            rt.peak = value
        } else {
            rt.peak = extremum(rt.peak, value, comparator: rule.comparator)
        }

        // Sustain gate.
        guard now.timeIntervalSince(rt.exceededSince ?? now) >= rule.sustainSeconds else { return }
        // Cooldown gate (re-arm): don't fire again inside the cooldown window.
        if let last = rt.lastFired, now.timeIntervalSince(last) < rule.cooldownSeconds { return }

        // Suppression (snooze / quiet hours / DND). Notify-only rules defer so
        // they still fire once unmuted; rules with a side effect (fan mode) act
        // now but stay silent.
        let suppressed = isSuppressed(rule, now: now, muted: muted)
        if suppressed && rule.escalationFanMode == nil { return }

        fire(rule, peak: rt.peak, value: value, offender: offender,
             engine: engine, now: now, suppressNotification: suppressed)
        rt.active = true
        rt.lastFired = now
    }

    private func fire(_ rule: AlertRule, peak: Double, value: Double, offender: ProcessSample?,
                      engine: MetricsEngine, now: Date, suppressNotification: Bool) {
        // Persist the fire time on the rule so "last fired" survives relaunch.
        if let i = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[i].lastFired = now
        }
        let fahrenheit = SettingsStore.shared.useFahrenheit

        // Side-effect actions run regardless of notification suppression.
        for action in rule.actions {
            if case .setFanMode(let mode) = action {
                applyFanEscalation(rule: rule, mode: mode)
            }
        }

        history.record(AlertHistoryEntry(date: now, ruleID: rule.id, ruleName: rule.name,
                                         metric: rule.metric, peakValue: peak,
                                         peakText: rule.metric.format(peak, fahrenheit: fahrenheit)))
        persist()

        guard !suppressNotification else { return }

        let (title, body) = message(rule: rule, peak: peak, offender: offender, fahrenheit: fahrenheit)
        var note = AlertNotification(ruleID: rule.id, title: title, body: body)
        if rule.metric.isProcess { note.pid = offender?.pid }
        if rule.metric.needsVolume { note.volumePath = volume(for: rule, engine: engine)?.path }
        notifier.post(note)
    }

    // MARK: - Fan escalation (feature #21)

    private func applyFanEscalation(rule: AlertRule, mode: FanMode) {
        let fans = FanControl.shared
        guard fans.canControlFans, escalation == nil else { return }
        let previous = fans.mode
        guard previous != mode else { return }
        let margin = rule.fanRestoreMarginC ?? 8
        fans.mode = mode
        escalation = Escalation(ruleID: rule.id, previousMode: previous,
                                appliedMode: mode, restoreBelowC: rule.threshold - margin)
    }

    private func evaluateFanRestore(engine: MetricsEngine) {
        guard let esc = escalation else { return }
        let fans = FanControl.shared
        // The user changed fan mode while escalated — respect it, cancel restore.
        if fans.mode != esc.appliedMode {
            escalation = nil
            return
        }
        guard let hotspot = engine.sensors.hotspotC else { return }
        if hotspot < esc.restoreBelowC {
            fans.mode = esc.previousMode
            escalation = nil
        }
    }

    // MARK: - Data budget (feature #20)

    private func evaluateDataBudget(engine: MetricsEngine, now: Date, muted: Bool) {
        guard config.dataBudgetEnabled,
              let capGB = SettingsStore.shared.monthlyDataCapGB, capGB > 0 else { return }
        let capBytes = capGB * 1_000_000_000   // decimal GB, matching Fmt.bytes
        let cycle = BillingCycleUsage.compute(daily: engine.networkData.daily,
                                              startDay: SettingsStore.shared.billingCycleStartDay,
                                              now: now)
        let usedPercent = Double(cycle.total) / capBytes * 100
        let cycleKey = Self.cycleKeyFormatter.string(from: cycle.start)

        var changed = false
        for level in [50, 80, 100] where usedPercent >= Double(level) {
            let marker = "\(cycleKey)|\(level)"
            guard !config.firedBudgetMarkers.contains(marker) else { continue }
            config.firedBudgetMarkers.append(marker)
            changed = true

            let usedText = Fmt.bytes(cycle.total)
            history.record(AlertHistoryEntry(date: now, ruleID: Self.dataBudgetRuleID,
                                             ruleName: "Data budget",
                                             metric: nil, peakValue: usedPercent,
                                             peakText: "\(level)% of \(capGB.formatted()) GB"))
            if !muted {
                let body = level >= 100
                    ? "You've used your full \(capGB.formatted()) GB budget this cycle (\(usedText))."
                    : "You've used \(level)% of your \(capGB.formatted()) GB budget this cycle (\(usedText))."
                notifier.post(AlertNotification(ruleID: Self.dataBudgetRuleID,
                                                title: "Data budget \(level)%", body: body))
            }
        }
        if changed {
            // Keep the marker list bounded (a couple of cycles' worth).
            if config.firedBudgetMarkers.count > 24 {
                config.firedBudgetMarkers.removeFirst(config.firedBudgetMarkers.count - 24)
            }
            persist()
        }
    }

    private static let cycleKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    // MARK: - Muting / suppression (feature #22)

    @ObservationIgnored private var dndCache: (value: Bool, at: Date)?

    private func computeMuted(now: Date) -> Bool {
        if quietHoursActive(now: now) { return true }
        if SettingsStore.shared.suppressDuringDND, dndActive(now: now) { return true }
        return false
    }

    /// Best-effort Focus/DND read, cached ~15 s so we don't hit the assertions
    /// file on every tick. Unknown (`nil`) is treated as "not muted".
    private func dndActive(now: Date) -> Bool {
        if let cache = dndCache, now.timeIntervalSince(cache.at) < 15 { return cache.value }
        let value = FocusState.isActive() == true
        dndCache = (value, now)
        return value
    }

    private func quietHoursActive(now: Date) -> Bool {
        let s = SettingsStore.shared
        guard s.quietHoursEnabled else { return false }
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute], from: now)
        let minutes = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        let start = s.quietHoursStartMinutes, end = s.quietHoursEndMinutes
        if start == end { return false }
        if start < end { return minutes >= start && minutes < end }
        // Overnight window (e.g. 22:00 → 07:00).
        return minutes >= start || minutes < end
    }

    private func isSuppressed(_ rule: AlertRule, now: Date, muted: Bool) -> Bool {
        if let s = rule.snoozedUntil, s > now { return true }
        if muted && !rule.quietHoursBypass { return true }
        return false
    }

    // MARK: - Metric readings

    /// Current value for a rule plus, for process metrics, the offending process
    /// (so the notification can name it and offer Force Quit). nil → the metric
    /// is unavailable this tick and the rule is skipped.
    private func reading(for rule: AlertRule, engine: MetricsEngine) -> (value: Double, offender: ProcessSample?)? {
        switch rule.metric {
        case .cpuUsage:
            return (engine.cpu.totalUsage * 100, nil)
        case .gpuUsage:
            guard engine.gpu.available else { return nil }
            return (engine.gpu.usageFraction * 100, nil)
        case .hotspotTemp:
            guard let t = engine.sensors.hotspotC else { return nil }
            return (t, nil)
        case .tempSensor:
            guard let name = rule.sensorName,
                  let t = Self.sensorTemp(named: name, engine: engine) else { return nil }
            return (t, nil)
        case .memoryPressure:
            return (Double(engine.memory.pressureLevel.rawValue), nil)
        case .volumeFreePercent:
            guard let vol = volume(for: rule, engine: engine) else { return nil }
            return ((1 - vol.usedFraction) * 100, nil)
        case .volumeFreeGB:
            guard let vol = volume(for: rule, engine: engine) else { return nil }
            return (Double(vol.availableBytes) / 1_000_000_000, nil)
        case .batteryPercent:
            guard engine.battery.hasBattery else { return nil }
            // An "unplug now" rule only makes sense while charging.
            if rule.chargingOnly && !engine.battery.isCharging { return nil }
            return (engine.battery.percent, nil)
        case .batteryHealth:
            guard let h = engine.battery.healthPercent else { return nil }
            return (h, nil)
        case .networkDown:
            return (engine.network.downBytesPerSec * 8 / 1_000_000, nil)
        case .networkUp:
            return (engine.network.upBytesPerSec * 8 / 1_000_000, nil)
        case .fanRPM:
            guard let rpm = engine.sensors.fans.map(\.rpm).max() else { return nil }
            return (rpm, nil)
        case .processCPU:
            guard let p = engine.processes.ranked(by: .cpu).first else { return nil }
            return (p.cpuPercent, p)
        case .processRSS:
            guard let p = engine.processes.ranked(by: .memory).first else { return nil }
            return (Double(p.memoryBytes) / 1_000_000_000, p)
        case .thermalState:
            return (Double(Self.thermalRaw()), nil)
        case .weakCharger:
            guard let percent = chargerDeliveryPercent(engine: engine) else { return nil }
            return (percent, nil)
        }
    }

    /// Charger delivery as a percentage of the adapter's rated wattage while
    /// charging (feature #19). nil when not charging or the rating is unknown.
    private func chargerDeliveryPercent(engine: MetricsEngine) -> Double? {
        let b = engine.battery
        guard b.hasBattery, b.isPluggedIn, b.isCharging else { return nil }
        guard let rated = Self.ratedAdapterWatts(b.adapterDescription), rated > 0 else { return nil }
        let delivered = engine.power.adapterWatts ?? b.watts ?? 0
        guard delivered > 0 else { return nil }
        return min(200, delivered / rated * 100)
    }

    /// The volume a rule targets (nil path → boot volume).
    private func volume(for rule: AlertRule, engine: MetricsEngine) -> VolumeInfo? {
        if let path = rule.volumePath {
            return engine.disk.volumes.first { $0.path == path } ?? engine.disk.root
        }
        return engine.disk.root
    }

    // MARK: - Comparison helpers

    private func exceeds(_ value: Double, rule: AlertRule) -> Bool {
        rule.metric.isLevel ? value >= rule.threshold
                            : rule.comparator.matches(value, rule.threshold)
    }

    /// Has the value recovered enough (past a 5% hysteresis band) to re-arm?
    private func recovered(_ value: Double, rule: AlertRule) -> Bool {
        if rule.metric.isLevel { return value < rule.threshold }
        let delta = abs(rule.threshold) * 0.05
        switch rule.comparator {
        case .above: return value <= rule.threshold - delta
        case .below: return value >= rule.threshold + delta
        }
    }

    private func extremum(_ a: Double, _ b: Double, comparator: AlertComparator) -> Double {
        comparator == .above ? max(a, b) : min(a, b)
    }

    // MARK: - Message building

    private func message(rule: AlertRule, peak: Double, offender: ProcessSample?, fahrenheit: Bool) -> (title: String, body: String) {
        let peakText = rule.metric.format(peak, fahrenheit: fahrenheit)
        switch rule.metric {
        case .processCPU, .processRSS:
            let name = offender?.name ?? "A process"
            let pidText = offender.map { " (pid \($0.pid))" } ?? ""
            return (rule.name, "\(name) is using \(peakText)\(pidText).")
        case .memoryPressure:
            return (rule.name, "Memory pressure is now \(peakText).")
        case .thermalState:
            return (rule.name, "Thermal state is now \(peakText).")
        case .weakCharger:
            return (rule.name, "The charger is delivering about \(peakText) of its rated power — a slow charger or cable?")
        default:
            let thresholdText = rule.metric.format(rule.threshold, fahrenheit: fahrenheit)
            let dir = rule.comparator == .above ? "above" : "below"
            return (rule.name, "\(rule.metric.title) hit \(peakText) — \(dir) the \(thresholdText) threshold.")
        }
    }

    // MARK: - Static helpers

    /// Sensor names selectable in the editor (CPU / GPU averages plus every
    /// named extra temperature).
    static func availableSensorNames(engine: MetricsEngine) -> [String] {
        availableSensorNames(engineSensors: engine.sensors)
    }

    static func availableSensorNames(engineSensors sensors: SensorsSnapshot) -> [String] {
        var names: [String] = []
        if sensors.cpuTempC != nil { names.append("CPU") }
        if sensors.gpuTempC != nil { names.append("GPU") }
        names.append(contentsOf: sensors.extraTemps.map(\.name))
        return names
    }

    static func sensorTemp(named name: String, engine: MetricsEngine) -> Double? {
        if name == "CPU" { return engine.sensors.cpuTempMaxC ?? engine.sensors.cpuTempC }
        if name == "GPU" { return engine.sensors.gpuTempMaxC ?? engine.sensors.gpuTempC }
        return engine.sensors.extraTemps.first { $0.name == name }?.celsius
    }

    private static func thermalRaw() -> Int {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return 0
        case .fair: return 1
        case .serious: return 2
        case .critical: return 3
        @unknown default: return 0
        }
    }

    /// Parses a wattage rating out of an adapter description like
    /// "96W USB-C Power Adapter" → 96.
    static func ratedAdapterWatts(_ description: String?) -> Double? {
        guard let description else { return nil }
        var digits = ""
        for ch in description {
            if ch.isNumber {
                digits.append(ch)
            } else if (ch == "W" || ch == "w"), let value = Double(digits) {
                return value
            } else {
                digits.removeAll()
            }
        }
        return nil
    }
}
