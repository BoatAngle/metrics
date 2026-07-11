import Foundation

/// Per-app network throughput via a single long-lived `nettop` (feature #3).
///
/// `nettop -P -x -J bytes_in,bytes_out -s 5 -l 0` emits a fresh block of
/// cumulative per-process byte counters every 5 s. Each block begins with a
/// header line ("… bytes_in bytes_out"); we accumulate a block's rows, and when
/// the next header arrives we diff that finished block against the previous one
/// to get per-process rates, aggregate them by app name, and publish the top
/// talkers. One cheap subprocess for the app's lifetime — no per-tick spawns.
final class NetworkAppMonitor {
    /// Ignore anything slower than this so idle background chatter (mDNS,
    /// push) doesn't crowd out real activity; the card hides an empty list.
    private static let idleFloorBytesPerSec: Double = 1024
    /// Cap on how many apps we hand upward (the card shows the top four).
    private static let maxApps = 8

    private let queue = DispatchQueue(label: "metrics.netapps", qos: .utility)
    private var process: Process?
    private var readBuffer = Data()
    private var stopped = false

    /// Counters keyed by "name.pid" for the previous completed block, plus when
    /// it was finalized, so rates use real elapsed wall-clock time.
    private var previousCounters: [String: (down: UInt64, up: UInt64)] = [:]
    private var previousTime: DispatchTime?
    /// Counters accumulating for the block currently being read.
    private var currentCounters: [String: (down: UInt64, up: UInt64)] = [:]
    private var sawHeader = false

    private var handler: (([AppNetworkUsage]) -> Void)?

    /// Starts (or restarts) the monitor. `handler` is invoked on a background
    /// queue whenever a new rate sample is computed.
    func start(handler: @escaping ([AppNetworkUsage]) -> Void) {
        queue.async { [self] in
            self.handler = handler
            stopped = false
            launch()
        }
    }

    /// Terminates the subprocess and stops publishing. Synchronous so the
    /// nettop child is gone before the app exits (an async hop might not run).
    func stop() {
        queue.sync { [self] in
            stopped = true
            teardown()
        }
    }

    // MARK: - Subprocess lifecycle (queue-confined)

    private func launch() {
        teardown()
        readBuffer.removeAll(keepingCapacity: true)
        currentCounters.removeAll(keepingCapacity: true)
        previousCounters.removeAll(keepingCapacity: true)
        previousTime = nil
        sawHeader = false

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        task.arguments = ["-P", "-x", "-J", "bytes_in,bytes_out", "-s", "5", "-l", "0"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.queue.async { self.ingest(data) }
        }
        task.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.handleTermination() }
        }

        do {
            try task.run()
            process = task
        } catch {
            process = nil  // nettop unavailable → degrade silently (no top-apps section)
        }
    }

    private func teardown() {
        if let pipe = process?.standardOutput as? Pipe {
            pipe.fileHandleForReading.readabilityHandler = nil
        }
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
    }

    /// nettop died on its own (not via `stop`): retry once after a short delay
    /// so a transient failure doesn't kill the feature for the whole session.
    private func handleTermination() {
        guard !stopped else { return }
        process = nil
        queue.asyncAfter(deadline: .now() + 5) { [self] in
            guard !stopped else { return }
            launch()
        }
    }

    // MARK: - Parsing (queue-confined)

    private func ingest(_ data: Data) {
        readBuffer.append(data)
        while let newline = readBuffer.firstIndex(of: 0x0A) {
            let lineData = readBuffer[readBuffer.startIndex..<newline]
            readBuffer.removeSubrange(readBuffer.startIndex...newline)
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            process(line: line)
        }
    }

    private func process(line: String) {
        // A header line ("time … bytes_in bytes_out") marks a block boundary:
        // the block we were accumulating is now complete.
        if line.contains("bytes_in") {
            if sawHeader { finishBlock() }
            sawHeader = true
            currentCounters.removeAll(keepingCapacity: true)
            return
        }
        guard sawHeader, let row = Self.parseRow(line) else { return }
        currentCounters[row.key] = (row.down, row.up)
    }

    /// Rates for the just-finished block, diffed against the prior block.
    private func finishBlock() {
        let now = DispatchTime.now()
        defer {
            previousCounters = currentCounters
            previousTime = now
        }
        guard let prevTime = previousTime, !previousCounters.isEmpty else { return }
        let elapsed = Double(now.uptimeNanoseconds &- prevTime.uptimeNanoseconds) / 1_000_000_000
        guard elapsed > 0.5 else { return }

        var byName: [String: (down: Double, up: Double)] = [:]
        for (key, current) in currentCounters {
            guard let prev = previousCounters[key] else { continue }  // new PID → no baseline yet
            let dDown = current.down >= prev.down ? current.down - prev.down : 0
            let dUp = current.up >= prev.up ? current.up - prev.up : 0
            guard dDown > 0 || dUp > 0 else { continue }
            let name = Self.appName(fromKey: key)
            var entry = byName[name] ?? (0, 0)
            entry.down += Double(dDown) / elapsed
            entry.up += Double(dUp) / elapsed
            byName[name] = entry
        }

        let apps = byName
            .map { AppNetworkUsage(name: $0.key, downBytesPerSec: $0.value.down, upBytesPerSec: $0.value.up) }
            .filter { $0.combinedBytesPerSec >= Self.idleFloorBytesPerSec }
            .sorted { $0.combinedBytesPerSec > $1.combinedBytesPerSec }
            .prefix(Self.maxApps)
        handler?(Array(apps))
    }

    /// Splits one data row into ("name.pid", down, up). The row is
    /// `<timestamp> <name.pid> <bytes_in> <bytes_out>`, and the process label
    /// can contain spaces, so we take the first field as the timestamp and the
    /// last two as the counters.
    private static func parseRow(_ line: String) -> (key: String, down: UInt64, up: UInt64)? {
        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard parts.count >= 4,
              let up = UInt64(parts[parts.count - 1]),
              let down = UInt64(parts[parts.count - 2]) else { return nil }
        let label = parts[1..<(parts.count - 2)].joined(separator: " ")
        guard !label.isEmpty else { return nil }
        return (label, down, up)
    }

    /// Drops the trailing ".pid" from a "name.pid" label. Guards against names
    /// that legitimately contain dots by requiring the tail to be all digits.
    private static func appName(fromKey key: String) -> String {
        guard let dot = key.lastIndex(of: "."), dot != key.startIndex else { return key }
        let tail = key[key.index(after: dot)...]
        guard !tail.isEmpty, tail.allSatisfy(\.isNumber) else { return key }
        return String(key[key.startIndex..<dot])
    }
}
