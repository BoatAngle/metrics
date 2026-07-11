import SwiftUI

// MARK: - Item kind

/// The metric or item type a menu bar item renders (Package 11 instance model).
///
/// This is the new, richer vocabulary for menu bar items. The legacy
/// `MenuBarWidgetKind` enum (which bundled metric + style into fixed cases like
/// `cpuGraph`) is kept *only* to migrate old saved settings forward — see
/// `WidgetInstance.migrate(from:)`. New raw values here are safe to add; the old
/// enum's raw values must never change.
enum WidgetItemKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case cpu, gpu, memory, disk, battery, temperature, network
    case combined      // #34 — 2–3 stacked mini metrics in one item
    case format        // #36 — custom format-string text
    case sensor        // #38 — any temperature sensor, custom label
    case fanRPM        // #38 — fan speed + active-mode glyph
    case topProcess    // #39 — top CPU process ticker

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .memory: return "Memory"
        case .disk: return "Disk"
        case .battery: return "Battery"
        case .temperature: return "Temperature"
        case .network: return "Network"
        case .combined: return "Combined"
        case .format: return "Custom Format"
        case .sensor: return "Sensor"
        case .fanRPM: return "Fan RPM"
        case .topProcess: return "Top Process"
        }
    }

    /// SF Symbol shown in the add menu and settings rows.
    var symbol: String {
        switch self {
        case .cpu: return "cpu"
        case .gpu: return "cpu.fill"
        case .memory: return "memorychip"
        case .disk: return "internaldrive"
        case .battery: return "battery.100percent"
        case .temperature: return "thermometer.medium"
        case .network: return "arrow.up.arrow.down"
        case .combined: return "square.stack"
        case .format: return "textformat"
        case .sensor: return "sensor"
        case .fanRPM: return "fanblades"
        case .topProcess: return "list.bullet.rectangle"
        }
    }

    /// True for kinds that reduce to a single 0…1 value and therefore support
    /// the full range of render styles (#35: text / line / meter / gauge / dot).
    var isScalar: Bool {
        switch self {
        case .cpu, .gpu, .memory, .disk, .battery, .temperature, .sensor, .fanRPM: return true
        case .network, .combined, .format, .topProcess: return false
        }
    }

    /// Scalar kinds a Combined item (#34) may stack.
    static var combinableScalars: [WidgetItemKind] {
        [.cpu, .gpu, .memory, .disk, .battery, .temperature]
    }

    /// The dashboard card an "open card" click action (#37) focuses.
    var card: CardKind? {
        switch self {
        case .cpu: return .cpu
        case .gpu: return .gpu
        case .memory: return .memory
        case .disk: return .disk
        case .battery: return .battery
        case .temperature, .sensor: return .sensors
        case .network: return .network
        case .fanRPM: return .fans
        case .topProcess: return .processes
        case .combined, .format: return nil
        }
    }

    /// Base accent used by graph/meter/gauge styles at normal load.
    var accent: Color {
        switch self {
        case .cpu: return .green
        case .gpu: return .orange
        case .memory: return .indigo
        case .disk: return .teal
        case .battery: return .green
        case .temperature: return .red
        case .network: return .blue
        case .sensor: return .pink
        case .fanRPM: return .cyan
        case .topProcess: return .green
        case .combined, .format: return .secondary
        }
    }

    /// One-char badge used by compact styles (meter/dot/combined rows).
    var badge: String {
        switch self {
        case .cpu: return "C"
        case .gpu: return "G"
        case .memory: return "M"
        case .disk: return "D"
        case .battery: return "B"
        case .temperature: return "T"
        case .network: return "N"
        case .sensor: return "S"
        case .fanRPM: return "F"
        case .topProcess: return "P"
        case .combined, .format: return "•"
        }
    }

    /// Default reactive-color thresholds (#33) in the metric's natural units —
    /// percent for load metrics, °C for temperatures. `nil` means the kind has
    /// no threshold coloring by default (memory is pressure-based; battery, fan,
    /// network carry no sensible default). `topProcess` is colored by its CPU %.
    var defaultThresholds: (warn: Double, crit: Double)? {
        switch self {
        case .cpu, .gpu, .topProcess: return (80, 90)
        case .disk: return (85, 95)
        case .temperature, .sensor: return (85, 95)
        case .memory, .battery, .fanRPM, .network, .combined, .format: return nil
        }
    }

    /// Render styles offered for this kind in settings. Scalars get the full
    /// set; specialised kinds render themselves and expose none.
    var availableStyles: [WidgetRenderStyle] {
        guard isScalar else { return [] }
        // Line graph only where a live history ring exists.
        return hasHistory
            ? WidgetRenderStyle.allCases
            : WidgetRenderStyle.allCases.filter { $0 != .lineGraph }
    }

    /// True when the engine keeps a 0…1 history ring for this metric, so the
    /// line-graph style has something to draw.
    var hasHistory: Bool {
        switch self {
        case .cpu, .gpu, .memory, .temperature: return true
        default: return false
        }
    }

    /// The default render style a freshly-added item of this kind uses.
    var defaultStyle: WidgetRenderStyle { .text }
}

// MARK: - Render style (#35)

enum WidgetRenderStyle: String, Codable, CaseIterable, Identifiable, Hashable {
    case text, lineGraph, barMeter, gauge, dot

    var id: String { rawValue }

    var title: String {
        switch self {
        case .text: return "Text"
        case .lineGraph: return "Line graph"
        case .barMeter: return "Bar meter"
        case .gauge: return "Gauge"
        case .dot: return "Colored dot"
        }
    }
}

// MARK: - Click action (#37)

enum WidgetClickAction: String, Codable, CaseIterable, Identifiable, Hashable {
    case openDashboard      // toggle the popover — the historical default
    case openCard           // full dashboard window, scrolled + pulsed to the card
    case activityMonitor    // launch Activity Monitor
    case cycleFanMode       // advance the fan mode

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openDashboard: return "Open dashboard"
        case .openCard: return "Open dashboard at card"
        case .activityMonitor: return "Open Activity Monitor"
        case .cycleFanMode: return "Cycle fan mode"
        }
    }
}

// MARK: - Instance

/// One configured menu bar item. A value type persisted in
/// `SettingsStore.widgetInstances`; identity is a stable UUID string so
/// per-item settings and the menu bar's own ⌘-drag order survive edits.
///
/// Payload fields are optional and only meaningful for their owning kind, which
/// keeps the JSON small and lets future kinds add fields without disturbing the
/// existing ones.
struct WidgetInstance: Codable, Identifiable, Hashable {
    var id: String
    var kind: WidgetItemKind
    var style: WidgetRenderStyle
    /// Per-item reactive-color override (#33): nil follows the global toggle.
    var reactiveColor: Bool?
    /// Per-item threshold overrides (#33), metric units; nil uses kind defaults.
    var warnThreshold: Double?
    var critThreshold: Double?
    var clickAction: WidgetClickAction
    /// Combined item (#34): 2–3 scalar metrics stacked as mini rows.
    var combinedMetrics: [WidgetItemKind]?
    /// Custom-format item (#36): the token template.
    var formatString: String?
    /// Sensor item (#38): the chosen sensor's name and a short custom label.
    var sensorName: String?
    var sensorLabel: String?
    /// Fan RPM item (#38): a specific fan index, or nil for the max across fans.
    var fanIndex: Int?

    init(kind: WidgetItemKind,
         style: WidgetRenderStyle? = nil,
         clickAction: WidgetClickAction = .openDashboard,
         combinedMetrics: [WidgetItemKind]? = nil,
         formatString: String? = nil,
         sensorName: String? = nil,
         sensorLabel: String? = nil,
         fanIndex: Int? = nil,
         id: String = UUID().uuidString) {
        self.id = id
        self.kind = kind
        self.style = style ?? kind.defaultStyle
        self.clickAction = clickAction
        self.combinedMetrics = combinedMetrics
        self.formatString = formatString
        self.sensorName = sensorName
        self.sensorLabel = sensorLabel
        self.fanIndex = fanIndex
    }

    /// Effective (warn, crit) thresholds: per-item overrides win, else the
    /// kind's defaults. nil when the kind has no numeric threshold coloring.
    var thresholds: (warn: Double, crit: Double)? {
        guard let base = kind.defaultThresholds else {
            // A kind with no defaults can still be colored if the user typed
            // both thresholds in explicitly.
            if let w = warnThreshold, let c = critThreshold { return (w, c) }
            return nil
        }
        return (warnThreshold ?? base.warn, critThreshold ?? base.crit)
    }

    /// A one-line human summary of the item's configuration, for settings rows.
    var summary: String {
        switch kind {
        case .combined:
            let names = (combinedMetrics ?? []).map(\.title)
            return names.isEmpty ? "No metrics chosen" : names.joined(separator: " · ")
        case .format:
            let f = (formatString ?? "").trimmingCharacters(in: .whitespaces)
            return f.isEmpty ? "Empty template" : f
        case .sensor:
            return sensorName ?? "No sensor chosen"
        case .fanRPM:
            return fanIndex == nil ? "Max fan" : "Fan \((fanIndex ?? 0) + 1)"
        default:
            return style.title
        }
    }
}

// MARK: - Defaults & migration

extension WidgetInstance {
    /// Fallback set used when nothing is saved and there is nothing to migrate.
    static var defaults: [WidgetInstance] {
        [WidgetInstance(kind: .cpu, style: .text),
         WidgetInstance(kind: .network, style: .text)]
    }

    /// Lossless forward migration of a legacy `enabledWidgets` list into the
    /// instance model. Called once, on first load of a build that predates
    /// `widgetInstances`. Order is preserved.
    static func migrate(from legacy: [MenuBarWidgetKind]) -> [WidgetInstance] {
        legacy.map { legacyKind in
            switch legacyKind {
            case .cpuPercent:  return WidgetInstance(kind: .cpu, style: .text)
            case .cpuGraph:    return WidgetInstance(kind: .cpu, style: .lineGraph)
            case .gpu:         return WidgetInstance(kind: .gpu, style: .text)
            case .gpuGraph:    return WidgetInstance(kind: .gpu, style: .lineGraph)
            case .memory:      return WidgetInstance(kind: .memory, style: .text)
            case .memoryGraph: return WidgetInstance(kind: .memory, style: .lineGraph)
            case .network:     return WidgetInstance(kind: .network, style: .text)
            case .disk:        return WidgetInstance(kind: .disk, style: .text)
            case .battery:     return WidgetInstance(kind: .battery, style: .text)
            case .temperature: return WidgetInstance(kind: .temperature, style: .text)
            }
        }
    }

    /// Best-effort projection back to a legacy `MenuBarWidgetKind`, so an older
    /// build that reads only `enabledWidgets` after a downgrade still shows
    /// something reasonable. New kinds have no legacy equivalent → nil.
    var legacyKind: MenuBarWidgetKind? {
        switch kind {
        case .cpu:         return style == .lineGraph ? .cpuGraph : .cpuPercent
        case .gpu:         return style == .lineGraph ? .gpuGraph : .gpu
        case .memory:      return style == .lineGraph ? .memoryGraph : .memory
        case .network:     return .network
        case .disk:        return .disk
        case .battery:     return .battery
        case .temperature: return .temperature
        case .sensor:      return .temperature
        case .combined, .format, .fanRPM, .topProcess: return nil
        }
    }
}

// MARK: - Reactive load level (#33)

/// The severity band a reactive item is currently in. Drives the amber/red tint
/// applied to text and graph colors.
enum LoadLevel {
    case normal, warn, crit

    /// Overlay tint for warn/crit, nil at normal (use the item's own color).
    var tint: Color? {
        switch self {
        case .normal: return nil
        case .warn: return .orange
        case .crit: return .red
        }
    }

    /// Classify a value against ascending warn/crit thresholds.
    static func evaluate(value: Double, warn: Double, crit: Double) -> LoadLevel {
        if value >= crit { return .crit }
        if value >= warn { return .warn }
        return .normal
    }
}
