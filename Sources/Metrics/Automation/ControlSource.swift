import Foundation

/// Outcome of a fan-mode change request over the control socket.
enum FanSetResult {
    /// The mode that actually took effect.
    case success(String)
    /// Human-readable reason it didn't (bad name, helper missing, …).
    case failure(String)
}

/// Abstracts "read the current metric values" for the control socket so the
/// wire protocol and transport can be exercised headlessly against a fake
/// source (see ControlSelfTest) without a running engine.
///
/// Methods are synchronous and callable from the server's background queue; the
/// live implementation hops to the main actor internally.
protocol ControlValueSource: AnyObject {
    /// Plain value for a metric key, or nil if the key is unknown.
    func value(for metric: String) -> String?
    /// Full machine-readable snapshot as a JSON-ready dictionary.
    func snapshotObject() -> [String: Any]
    /// Every known metric key (for `metricsctl`'s error/help text).
    func metricKeys() -> [String]
    /// Applies a fan mode. `.success` carries the mode that took effect;
    /// `.failure` a human-readable reason (bad mode name, helper missing, …).
    func setFan(mode: String) -> FanSetResult
}

/// Live source backed by the running MetricsEngine / FanControl. Its callers run
/// on the control server's background queue, so each read bounces onto the main
/// actor where the observable engine state lives.
final class LiveControlSource: ControlValueSource {
    func value(for metric: String) -> String? {
        onMain { MetricReadout.value(metric, engine: .shared, settings: .shared) }
    }

    func snapshotObject() -> [String: Any] {
        onMain { MetricReadout.snapshot(engine: .shared, settings: .shared) }
    }

    func metricKeys() -> [String] { MetricReadout.metricKeys }

    func setFan(mode: String) -> FanSetResult {
        onMain {
            guard let requested = FanMode(rawValue: mode.lowercased()) else {
                return .failure("unknown fan mode '\(mode)' (auto, quiet, balanced, performance, manual)")
            }
            FanControl.shared.mode = requested
            // A curve mode with no helper installed silently reverts to auto and
            // records the reason — surface that instead of a false success.
            if FanControl.shared.mode == requested {
                return .success(requested.rawValue)
            }
            return .failure(FanControl.shared.lastError ?? "fan mode '\(requested.rawValue)' is unavailable")
        }
    }

    /// Synchronously run `body` on the main actor. Safe because the control
    /// server never calls these from the main thread, and the app's main runloop
    /// keeps servicing the queue.
    private func onMain<T>(_ body: @MainActor () -> T) -> T {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { body() }
        }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { body() } }
    }
}
