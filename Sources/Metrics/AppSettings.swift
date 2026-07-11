import AppKit
import Foundation
import Observation
import ServiceManagement

// MARK: - Appearance

enum AppearanceMode: String, Codable, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// nil means "follow the system". Applied to our popover and settings
    /// window only — menu bar items always match the menu bar itself.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

// MARK: - Kinds

enum CardKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case cpu, gpu, power, memory, disk, network
    case networkData = "network_data"
    case battery, sensors, fans, processes, bluetooth, device

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: return "Processor"
        case .gpu: return "Graphics"
        case .power: return "Power"
        case .memory: return "Memory"
        case .disk: return "Disk"
        case .network: return "Network Activity"
        case .networkData: return "Network Data"
        case .battery: return "Battery"
        case .sensors: return "Sensors"
        case .fans: return "Fan Control"
        case .processes: return "Processes"
        case .bluetooth: return "Bluetooth"
        case .device: return "Device"
        }
    }
}

enum MenuBarWidgetKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case cpuPercent, cpuGraph, gpu, gpuGraph, memory, memoryGraph, network, disk, battery, temperature

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpuPercent: return "CPU %"
        case .cpuGraph: return "CPU graph"
        case .gpu: return "GPU %"
        case .gpuGraph: return "GPU graph"
        case .memoryGraph: return "Memory graph"
        case .memory: return "Memory %"
        case .network: return "Network speeds"
        case .disk: return "Disk used"
        case .battery: return "Battery"
        case .temperature: return "Temperatures (CPU + GPU)"
        }
    }
}

// MARK: - Persistence model

private struct PersistedSettings: Codable {
    var enabledWidgets: [MenuBarWidgetKind] = [.cpuPercent, .network]
    var cardOrder: [CardKind] = CardKind.allCases
    var hiddenCards: [CardKind] = []
    var sampleInterval: Double = 1.0
    var useFahrenheit: Bool = false
    // Added after 1.0 — optional so old saved settings still decode.
    var appearance: AppearanceMode? = nil
    var fanMode: FanMode? = nil
    var desktopWidgets: [CardKind]? = nil
    /// CardKind.rawValue → ChartWindow.rawValue. Plain string keys keep the
    /// JSON a normal object (and avoid non-String dictionary-key encoding).
    var cardChartWindows: [String: String]? = nil
    /// Network billing cycle (feature #28): the day-of-month (1…31) the cycle
    /// resets on, and an optional data cap in GB (nil = no cap).
    var billingCycleStartDay: Int? = nil
    var monthlyDataCapGB: Double? = nil
    /// Processes card sort column (feature #13), stored as ProcessSortKey.rawValue.
    var processSortKey: String? = nil
    /// Alerts quiet hours (feature #22): a global mute window for non-bypass
    /// rules, plus best-effort suppression while macOS Focus/DND is on.
    var quietHoursEnabled: Bool? = nil
    var quietHoursStartMinutes: Int? = nil   // minutes since local midnight
    var quietHoursEndMinutes: Int? = nil
    var suppressDuringDND: Bool? = nil
    /// Menu bar overhaul (Package 11, features #33–#40). `widgetInstances`
    /// supersedes `enabledWidgets` when present; old settings that only have
    /// `enabledWidgets` are migrated forward losslessly on first load. Both are
    /// kept optional so every prior settings version still decodes, and
    /// `enabledWidgets` keeps being written as a legacy projection so a
    /// downgrade still finds something to show.
    var widgetInstances: [WidgetInstance]? = nil
    var menuBarReactiveColors: Bool? = nil
}

// MARK: - Store

@Observable @MainActor
final class SettingsStore {
    static let shared = SettingsStore()
    private static let key = "metrics.settings.v1"
    /// Bounds for the sampling interval; the settings slider spans the same range.
    static let sampleIntervalRange: ClosedRange<Double> = 0.5...5

    /// Configured menu bar items (Package 11). Authoritative source of truth for
    /// what the status bar shows; supersedes the legacy `enabledWidgets` list.
    var widgetInstances: [WidgetInstance] { didSet { save() } }
    /// Global reactive-color toggle (#33). Per-item overrides live on the
    /// instance's `reactiveColor`.
    var menuBarReactiveColors: Bool { didSet { save() } }
    var cardOrder: [CardKind] { didSet { save() } }
    var hiddenCards: Set<CardKind> { didSet { save() } }
    var sampleInterval: Double { didSet { save() } }
    var useFahrenheit: Bool { didSet { save() } }
    var appearance: AppearanceMode { didSet { save() } }
    /// Owned by FanControl; persisted here so the chosen mode survives relaunch.
    var fanMode: FanMode { didSet { save() } }
    /// Cards floating on the desktop as real-time widgets.
    var desktopWidgets: Set<CardKind> { didSet { save() } }
    /// Selected history window per live-graph card (CardKind → ChartWindow).
    var cardChartWindows: [CardKind: ChartWindow] { didSet { save() } }
    /// Day of the month (1…31) the data billing cycle resets on.
    var billingCycleStartDay: Int { didSet { save() } }
    /// Optional monthly data cap in GB (nil = no cap).
    var monthlyDataCapGB: Double? { didSet { save() } }
    /// Which column the Processes card ranks by (feature #13).
    var processSortKey: ProcessSortKey { didSet { save() } }
    /// Alerts quiet hours (feature #22).
    var quietHoursEnabled: Bool { didSet { save() } }
    var quietHoursStartMinutes: Int { didSet { save() } }
    var quietHoursEndMinutes: Int { didSet { save() } }
    var suppressDuringDND: Bool { didSet { save() } }

    /// Dashboard cards in display order with hidden ones filtered out.
    var visibleCards: [CardKind] {
        cardOrder.filter { !hiddenCards.contains($0) }
    }

    /// The chart window a card is showing (defaults to Live).
    func chartWindow(for kind: CardKind) -> ChartWindow {
        cardChartWindows[kind] ?? .live
    }

    func setChartWindow(_ window: ChartWindow, for kind: CardKind) {
        cardChartWindows[kind] = window
    }

    // MARK: Menu bar items (Package 11)

    /// Appends a new item of the given kind, seeded with sensible defaults.
    func addWidget(_ kind: WidgetItemKind) {
        var inst = WidgetInstance(kind: kind, style: kind.defaultStyle)
        switch kind {
        case .combined: inst.combinedMetrics = [.cpu, .memory]
        case .format: inst.formatString = MenuFormat.defaultTemplate
        default: break
        }
        widgetInstances.append(inst)
    }

    /// Removes an item, never leaving the list empty (which would strand the app).
    func removeWidget(id: String) {
        widgetInstances.removeAll { $0.id == id }
        if widgetInstances.isEmpty { widgetInstances = WidgetInstance.defaults }
    }

    /// Shifts an item earlier/later in the list (and thus left/right in the bar).
    func moveWidget(id: String, by offset: Int) {
        guard let idx = widgetInstances.firstIndex(where: { $0.id == id }) else { return }
        let target = idx + offset
        guard widgetInstances.indices.contains(target) else { return }
        var arr = widgetInstances
        arr.swapAt(idx, target)
        widgetInstances = arr
    }

    /// Replaces an item in place (reassigning the whole array so observers fire).
    func updateWidget(_ instance: WidgetInstance) {
        guard let idx = widgetInstances.firstIndex(where: { $0.id == instance.id }) else { return }
        var arr = widgetInstances
        arr[idx] = instance
        widgetInstances = arr
    }

    private var loaded = false

    private init() {
        var p = PersistedSettings()
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(PersistedSettings.self, from: data) {
            p = decoded
        }
        // Heal card order: keep saved order, append any kinds added in later versions.
        var order = p.cardOrder
        for kind in CardKind.allCases where !order.contains(kind) { order.append(kind) }

        // Menu bar items (Package 11): prefer the new instance list; otherwise
        // migrate the legacy `enabledWidgets` forward. Fall back to defaults if
        // both come up empty so the app is never left unreachable.
        var instances: [WidgetInstance]
        if let saved = p.widgetInstances, !saved.isEmpty {
            instances = saved
        } else {
            instances = WidgetInstance.migrate(from: p.enabledWidgets)
        }
        if instances.isEmpty { instances = WidgetInstance.defaults }
        widgetInstances = instances
        menuBarReactiveColors = p.menuBarReactiveColors ?? true
        cardOrder = order
        hiddenCards = Set(p.hiddenCards)
        sampleInterval = min(max(p.sampleInterval, Self.sampleIntervalRange.lowerBound),
                             Self.sampleIntervalRange.upperBound)
        useFahrenheit = p.useFahrenheit
        appearance = p.appearance ?? .system
        fanMode = p.fanMode ?? .auto
        desktopWidgets = Set(p.desktopWidgets ?? [])
        cardChartWindows = (p.cardChartWindows ?? [:]).reduce(into: [:]) { result, pair in
            if let kind = CardKind(rawValue: pair.key),
               let window = ChartWindow(rawValue: pair.value) {
                result[kind] = window
            }
        }
        billingCycleStartDay = min(max(p.billingCycleStartDay ?? 1, 1), 31)
        monthlyDataCapGB = p.monthlyDataCapGB.map { max(0, $0) }
        processSortKey = p.processSortKey.flatMap { ProcessSortKey(rawValue: $0) } ?? .cpu
        quietHoursEnabled = p.quietHoursEnabled ?? false
        quietHoursStartMinutes = min(max(p.quietHoursStartMinutes ?? (22 * 60), 0), 24 * 60 - 1)
        quietHoursEndMinutes = min(max(p.quietHoursEndMinutes ?? (7 * 60), 0), 24 * 60 - 1)
        suppressDuringDND = p.suppressDuringDND ?? true
        loaded = true
    }

    private func save() {
        guard loaded else { return }
        // Keep the legacy list in sync as a best-effort projection, so an older
        // build reading only `enabledWidgets` after a downgrade still shows
        // something reasonable. Empty (all-new kinds) falls back to CPU%.
        var legacy = widgetInstances.compactMap { $0.legacyKind }
        if legacy.isEmpty { legacy = [.cpuPercent] }
        let p = PersistedSettings(enabledWidgets: legacy,
                                  cardOrder: cardOrder,
                                  hiddenCards: Array(hiddenCards),
                                  sampleInterval: sampleInterval,
                                  useFahrenheit: useFahrenheit,
                                  appearance: appearance,
                                  fanMode: fanMode,
                                  desktopWidgets: Array(desktopWidgets),
                                  cardChartWindows: cardChartWindows.reduce(into: [:]) { result, pair in
                                      result[pair.key.rawValue] = pair.value.rawValue
                                  },
                                  billingCycleStartDay: billingCycleStartDay,
                                  monthlyDataCapGB: monthlyDataCapGB,
                                  processSortKey: processSortKey.rawValue,
                                  quietHoursEnabled: quietHoursEnabled,
                                  quietHoursStartMinutes: quietHoursStartMinutes,
                                  quietHoursEndMinutes: quietHoursEndMinutes,
                                  suppressDuringDND: suppressDuringDND,
                                  widgetInstances: widgetInstances,
                                  menuBarReactiveColors: menuBarReactiveColors)
        if let data = try? JSONEncoder().encode(p) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    // MARK: Launch at login

    /// Backed by SMAppService, not persisted by us. Works best when the app
    /// bundle lives in /Applications (ad-hoc signed is fine for personal use).
    var launchAtLogin: Bool {
        get {
            access(keyPath: \.launchAtLoginError) // participate in observation for error updates
            return SMAppService.mainApp.status == .enabled
        }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
                launchAtLoginError = nil
            } catch {
                launchAtLoginError = error.localizedDescription
            }
        }
    }
    private(set) var launchAtLoginError: String? = nil
}
