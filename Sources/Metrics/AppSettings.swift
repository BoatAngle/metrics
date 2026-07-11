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
    case cpu, gpu, memory, disk, network
    case networkData = "network_data"
    case battery, sensors, fans, processes, bluetooth, device

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: return "Processor"
        case .gpu: return "Graphics"
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
}

// MARK: - Store

@Observable @MainActor
final class SettingsStore {
    static let shared = SettingsStore()
    private static let key = "metrics.settings.v1"
    /// Bounds for the sampling interval; the settings slider spans the same range.
    static let sampleIntervalRange: ClosedRange<Double> = 0.5...5

    var enabledWidgets: [MenuBarWidgetKind] { didSet { save() } }
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

        enabledWidgets = p.enabledWidgets
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
        loaded = true
    }

    private func save() {
        guard loaded else { return }
        let p = PersistedSettings(enabledWidgets: enabledWidgets,
                                  cardOrder: cardOrder,
                                  hiddenCards: Array(hiddenCards),
                                  sampleInterval: sampleInterval,
                                  useFahrenheit: useFahrenheit,
                                  appearance: appearance,
                                  fanMode: fanMode,
                                  desktopWidgets: Array(desktopWidgets),
                                  cardChartWindows: cardChartWindows.reduce(into: [:]) { result, pair in
                                      result[pair.key.rawValue] = pair.value.rawValue
                                  })
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
