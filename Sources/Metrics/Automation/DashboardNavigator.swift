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

    private init() {}

    func requestScroll(to kind: CardKind) {
        scrollTarget = kind
        scrollNonce &+= 1
    }
}
