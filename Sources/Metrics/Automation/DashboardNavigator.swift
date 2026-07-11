import Foundation
import Observation

/// Programmatic navigation requests for the dashboard window, driven by the
/// `metrics://card/<kind>` URL command. The window observes `scrollNonce` and
/// scrolls to `scrollTarget` whenever it bumps — a nonce (not just the target)
/// so scrolling to the same card twice still fires.
@Observable @MainActor
final class DashboardNavigator {
    static let shared = DashboardNavigator()

    private(set) var scrollTarget: CardKind? = nil
    private(set) var scrollNonce = 0

    /// The card to briefly pulse after a scroll (feature #37 deep-link
    /// highlight). A separate nonce so re-highlighting the same card re-fires.
    private(set) var highlightTarget: CardKind? = nil
    private(set) var highlightNonce = 0

    private init() {}

    /// Scrolls the requested card to the top and pulses it, so a menu bar item's
    /// "open dashboard at card" click (and the metrics://card/<kind> URL) land
    /// the eye on the right place.
    func requestScroll(to kind: CardKind) {
        scrollTarget = kind
        scrollNonce &+= 1
        highlightTarget = kind
        highlightNonce &+= 1
    }
}
