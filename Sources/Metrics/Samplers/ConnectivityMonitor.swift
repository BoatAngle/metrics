import Foundation
import Network
import WidgetShared

/// Internet-outage monitor (feature #9). Combines two signals:
///   • NWPathMonitor — whether a usable network interface exists at all.
///   • an active TCP probe to 1.1.1.1:443 every 15 s — whether the internet is
///     actually reachable (catches "connected to Wi-Fi, no internet").
///
/// A down transition opens an outage; recovery closes it with a duration. The
/// log (newest ~100) is persisted to Application Support so it survives relaunch.
/// All state is confined to a single serial queue.
final class ConnectivityMonitor {
    private static let probeInterval: TimeInterval = 15
    private static let probeTimeout: TimeInterval = 3
    private static let maxOutages = 100

    private let queue = DispatchQueue(label: "metrics.connectivity", qos: .utility)
    private let monitor = NWPathMonitor()
    private var probeTimer: DispatchSourceTimer?
    private var stopped = false

    private var interfaceUp = true
    private var probeReachable = true
    private var online = true
    private var currentOutage: OutageRecord?
    private var outages: [OutageRecord] = []   // newest first
    private var handler: ((ConnectivitySnapshot) -> Void)?

    private let logURL = WidgetSnapshotStore.appSupportDirectory
        .appendingPathComponent("outages.json")

    func start(handler: @escaping (ConnectivitySnapshot) -> Void) {
        queue.async { [self] in
            self.handler = handler
            stopped = false
            loadLog()
            monitor.pathUpdateHandler = { [weak self] path in
                guard let self else { return }
                self.queue.async {
                    self.interfaceUp = (path.status == .satisfied)
                    self.evaluate()
                }
            }
            monitor.start(queue: queue)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 0.5, repeating: Self.probeInterval)
            timer.setEventHandler { [weak self] in self?.runProbe() }
            probeTimer = timer
            timer.resume()
            publish()
        }
    }

    func stop() {
        queue.sync { [self] in
            stopped = true
            probeTimer?.cancel()
            probeTimer = nil
            monitor.cancel()
        }
    }

    // MARK: - Probe (queue-confined)

    private func runProbe() {
        guard !stopped else { return }
        Self.probe(timeout: Self.probeTimeout, on: queue) { [weak self] reachable in
            guard let self, !self.stopped else { return }
            self.probeReachable = reachable
            self.evaluate()
        }
    }

    /// One TCP-connect probe to 1.1.1.1:443. Calls back on `queue` with whether
    /// the handshake completed before the timeout.
    private static func probe(timeout: TimeInterval, on queue: DispatchQueue,
                              completion: @escaping (Bool) -> Void) {
        let conn = NWConnection(host: "1.1.1.1", port: 443, using: .tcp)
        var finished = false
        func finish(_ reachable: Bool) {
            queue.async {
                guard !finished else { return }
                finished = true
                conn.cancel()
                completion(reachable)
            }
        }
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready: finish(true)
            case .failed, .cancelled: finish(false)
            default: break   // .waiting means no route right now; the timeout resolves it
            }
        }
        conn.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { finish(false) }
    }

    // MARK: - State transitions (queue-confined)

    private func evaluate() {
        let nowOnline = interfaceUp && probeReachable
        if nowOnline != online {
            online = nowOnline
            if nowOnline {
                closeOutage()
            } else {
                openOutage()
            }
        }
        publish()
    }

    private func openOutage() {
        guard currentOutage == nil else { return }
        currentOutage = OutageRecord(start: Date())
    }

    private func closeOutage() {
        guard var outage = currentOutage else { return }
        outage.end = Date()
        currentOutage = nil
        outages.insert(outage, at: 0)
        if outages.count > Self.maxOutages { outages.removeLast(outages.count - Self.maxOutages) }
        saveLog()
    }

    private func publish() {
        var snap = ConnectivitySnapshot()
        snap.online = online
        snap.interfaceUp = interfaceUp
        snap.probeReachable = probeReachable
        snap.currentOutage = currentOutage
        snap.recentOutages = outages
        handler?(snap)
    }

    // MARK: - Persistence (queue-confined)

    private func loadLog() {
        guard let data = try? Data(contentsOf: logURL),
              let decoded = try? JSONDecoder.iso.decode([OutageRecord].self, from: data) else { return }
        // Any record left open by a prior crash can't be trusted as "ongoing";
        // close it at its own start so it reads as a zero-length blip.
        outages = decoded.map { rec in
            guard rec.end == nil else { return rec }
            var fixed = rec; fixed.end = rec.start; return fixed
        }
    }

    private func saveLog() {
        try? FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder.iso.encode(outages) else { return }
        try? data.write(to: logURL, options: .atomic)
    }

    // MARK: - --dump support (blocking one-shot)

    /// Synchronous single probe for the CLI dump: interface state from a
    /// short-lived path monitor plus one TCP probe. Blocks up to ~`timeout`.
    static func dumpStatus(timeout: TimeInterval = 3)
        -> (interfaceUp: Bool, reachable: Bool, interface: String?) {
        let q = DispatchQueue(label: "metrics.connectivity.dump")
        let mon = NWPathMonitor()
        var interfaceUp = false
        var ifaceName: String?
        let pathSem = DispatchSemaphore(value: 0)
        mon.pathUpdateHandler = { path in
            interfaceUp = (path.status == .satisfied)
            ifaceName = path.availableInterfaces.first?.name
            pathSem.signal()
        }
        mon.start(queue: q)
        _ = pathSem.wait(timeout: .now() + 1)
        mon.cancel()

        var reachable = false
        let probeSem = DispatchSemaphore(value: 0)
        probe(timeout: timeout, on: q) { r in reachable = r; probeSem.signal() }
        _ = probeSem.wait(timeout: .now() + timeout + 1)
        return (interfaceUp, reachable, ifaceName)
    }
}

private extension JSONEncoder {
    static let iso: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }()
}

private extension JSONDecoder {
    static let iso: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()
}
