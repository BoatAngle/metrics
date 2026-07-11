import Foundation

/// A parsed `metrics://` deep-link command. Parsing is pure (Foundation-only)
/// so it can be unit-reasoned about; the AppDelegate does the side effects.
enum MetricsURLCommand: Equatable {
    /// `metrics://dashboard` — bring the dashboard window forward.
    case dashboard
    /// `metrics://card/<cardKind>` — open the dashboard scrolled to a card.
    case card(CardKind)
    /// `metrics://fan/<mode>` — switch the fan mode.
    case fan(FanMode)
    /// `metrics://focus/<on|off|toggle>` — future in-app Focus mode (seam).
    case focus(FocusAction)
    /// `metrics://copy/<metric>` — copy a metric's current value to the clipboard.
    case copy(metric: String)

    enum FocusAction: String { case on, off, toggle }

    /// Parses a `metrics://…` URL, or returns nil for a foreign scheme or an
    /// unrecognized command/argument so the caller can log and ignore it.
    ///
    /// The command is normally the URL host (`metrics://fan/quiet`), but we also
    /// accept it as the first path segment for launchers that emit an authority-
    /// less form (`metrics:///fan/quiet`).
    static func parse(_ url: URL) -> MetricsURLCommand? {
        guard url.scheme?.lowercased() == "metrics" else { return nil }
        let host = url.host?.lowercased() ?? ""
        let segments = url.pathComponents.filter { $0 != "/" }

        let command: String
        let arg: String?
        if host.isEmpty {
            command = segments.first?.lowercased() ?? ""
            arg = segments.count > 1 ? segments[1] : nil
        } else {
            command = host
            arg = segments.first
        }

        switch command {
        case "dashboard":
            return .dashboard
        case "card":
            guard let arg, let kind = CardKind(rawValue: arg.lowercased()) else { return nil }
            return .card(kind)
        case "fan":
            guard let arg, let mode = FanMode(rawValue: arg.lowercased()) else { return nil }
            return .fan(mode)
        case "focus":
            guard let arg, let action = FocusAction(rawValue: arg.lowercased()) else { return nil }
            return .focus(action)
        case "copy":
            guard let arg else { return nil }
            return .copy(metric: arg.lowercased())
        default:
            return nil
        }
    }
}
