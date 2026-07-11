import SwiftUI

// MARK: - Scale (#41)

/// Per-widget size preset. Realised as a scaled window plus a matching layer
/// transform on the card (see `DesktopWidgetController`), so the card lays out
/// once at its natural size and the whole thing is scaled crisply.
enum WidgetScale: String, Codable, CaseIterable, Identifiable, Hashable {
    case small, medium, large

    var id: String { rawValue }

    var title: String {
        switch self {
        case .small: return "S"
        case .medium: return "M"
        case .large: return "L"
        }
    }

    var factor: CGFloat {
        switch self {
        case .small: return 0.85
        case .medium: return 1.0
        case .large: return 1.2
        }
    }
}

// MARK: - Theme (#42)

/// Per-widget theme, independent of the app's light/dark appearance. Threaded
/// into the card views through the `desktopWidgetStyle` environment so the
/// shared building blocks (CardContainer, StatRow, DonutGauge, ProgressBar)
/// restyle themselves.
enum WidgetTheme: String, Codable, CaseIterable, Identifiable, Hashable {
    case system, glass, solid, minimal, terminal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .glass: return "Glass"
        case .solid: return "Solid"
        case .minimal: return "Minimal"
        case .terminal: return "Terminal"
        }
    }

    /// Minimal floats the values with no card chrome (frameless by definition).
    var impliesFrameless: Bool { self == .minimal }
}

// MARK: - Per-widget config (#41 + #42)

/// Everything the user can tune about one desktop widget. Persisted per
/// `CardKind` in `SettingsStore.desktopWidgetConfigs`.
struct DesktopWidgetConfig: Codable, Hashable {
    var scale: WidgetScale = .medium
    /// Background opacity, 0…1 (0 = fully see-through card, 1 = opaque).
    var backgroundOpacity: Double = 1.0
    /// Drop all card chrome and float the values directly on the wallpaper.
    var frameless: Bool = false
    var theme: WidgetTheme = .system

    static let `default` = DesktopWidgetConfig()

    /// The resolved, environment-injected style the card views read. Folds the
    /// Minimal theme's implicit framelessness and clamps the opacity.
    var style: DesktopWidgetStyle {
        DesktopWidgetStyle(theme: theme,
                           backgroundOpacity: min(max(backgroundOpacity, 0), 1),
                           frameless: frameless || theme.impliesFrameless)
    }
}

// MARK: - Resolved style (environment value, #42)

/// The style a card honors while it is being rendered inside a desktop widget.
/// Absent (nil) in the dashboard/popover and previews, where cards keep their
/// standard chrome.
struct DesktopWidgetStyle: Hashable {
    var theme: WidgetTheme
    var backgroundOpacity: Double
    var frameless: Bool

    /// Terminal renders green monospaced text; others keep their normal colors.
    var monospaced: Bool { theme == .terminal }

    /// A foreground tint applied over the card's normal text colors (Terminal
    /// only). nil leaves each element's own color untouched.
    var textTint: Color? {
        theme == .terminal ? Color(red: 0.30, green: 1.0, blue: 0.45) : nil
    }

    /// The card's rounded-rect fill for this theme, already faded by
    /// `backgroundOpacity`. nil means "draw no fill" (frameless / minimal).
    var backgroundColor: Color? {
        guard !frameless else { return nil }
        switch theme {
        case .system, .solid:
            return Color(nsColor: .controlBackgroundColor).opacity(backgroundOpacity)
        case .terminal:
            return Color.black.opacity(backgroundOpacity)
        case .glass:
            // Glass draws a material instead of a flat fill (handled in
            // CardContainer); this flat color is unused.
            return nil
        case .minimal:
            return nil
        }
    }

    /// True when the card should back itself with `ultraThinMaterial` (Glass).
    var usesMaterial: Bool { theme == .glass && !frameless }

    /// Whether to stroke the card's border. Frameless/minimal drop it; Terminal
    /// keeps a faint green edge; the rest keep the standard separator.
    var drawsBorder: Bool { !frameless }

    var borderColor: Color {
        theme == .terminal
            ? Color(red: 0.30, green: 1.0, blue: 0.45).opacity(0.35)
            : Color(nsColor: .separatorColor).opacity(0.6)
    }

    /// A subtle shadow that keeps frameless text legible on a busy wallpaper.
    var needsLegibilityShadow: Bool { frameless }
}

private struct DesktopWidgetStyleKey: EnvironmentKey {
    static let defaultValue: DesktopWidgetStyle? = nil
}

extension EnvironmentValues {
    /// Non-nil only while a card renders inside a desktop widget window.
    var desktopWidgetStyle: DesktopWidgetStyle? {
        get { self[DesktopWidgetStyleKey.self] }
        set { self[DesktopWidgetStyleKey.self] = newValue }
    }
}

// MARK: - Layout profiles (#43)

/// One widget's saved geometry, stored relative to the display it lived on so a
/// later display rearrangement doesn't strand it off-screen.
struct WidgetFrame: Codable, Hashable {
    /// Origin relative to the owning display's frame origin (points).
    var relX: Double
    var relY: Double
    var width: Double
    var height: Double
    /// CGDirectDisplayID the frame was captured on (nil → main display).
    var displayID: UInt32?
}

/// A named snapshot of every desktop widget's on/off state, per-widget config
/// and position (#43). Optionally auto-restored when its display signature
/// reappears.
struct LayoutProfile: Codable, Hashable, Identifiable {
    var id: String = UUID().uuidString
    var name: String
    /// The NSScreen-set signature captured when this profile was saved; used to
    /// auto-switch when the same monitor arrangement returns.
    var displaySignature: String?
    /// Auto-restore this profile the moment its display signature appears.
    var autoSwitch: Bool = false
    /// Enabled widget kinds (raw values).
    var enabled: [String]
    /// Per-kind widget configuration (raw-value keyed, like `cardChartWindows`).
    var configs: [String: DesktopWidgetConfig]
    /// Per-kind saved geometry (raw-value keyed).
    var frames: [String: WidgetFrame]
}

// MARK: - Snapping math (#43)

/// Pure, testable magnetic-snap helper used by `DesktopWidgetController` while
/// arranging: snaps one axis of a widget's origin to the nearest guide line or
/// grid line within a threshold.
enum WidgetSnap {
    /// Snaps `value` — the near-edge origin of a widget with the given `extent`
    /// on this axis. Screen/widget edge guides take priority (aligning either
    /// the near or the far edge to a guide within `threshold`); if none match,
    /// the value quantizes to the nearest grid line. Guides win over the grid so
    /// widget-to-widget alignment isn't drowned out by the ever-present grid.
    static func snap(value: CGFloat, extent: CGFloat, lines: [CGFloat],
                     threshold: CGFloat = 8, grid: CGFloat = 8) -> CGFloat {
        var bestMag = threshold + 1
        var target = value
        func consider(_ candidate: CGFloat, _ mag: CGFloat) {
            if mag <= threshold && mag < bestMag { bestMag = mag; target = candidate }
        }
        let near = value, far = value + extent
        for line in lines {
            consider(line, abs(near - line))         // align the near edge
            consider(line - extent, abs(far - line)) // align the far edge
        }
        if bestMag <= threshold { return target }    // a guide edge won
        let g = (value / grid).rounded() * grid      // otherwise quantize to grid
        return abs(value - g) <= threshold ? g : value
    }
}

// MARK: - Focus / Gaming mode (#44)

/// What condition auto-arms Focus mode when auto-trigger is enabled.
enum FocusTrigger: String, Codable, CaseIterable, Identifiable, Hashable {
    case fullScreen      // any app occupies a whole display
    case frontmostApp    // a user-chosen app is frontmost

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fullScreen: return "Any app is full-screen"
        case .frontmostApp: return "A chosen app is frontmost"
        }
    }
}
