import Foundation

/// A compact, Codable summary of the latest metrics, written by the main app
/// and read by the WidgetKit extension. Encoded as plain JSON with
/// `.secondsSince1970` dates so both processes agree on the format.
/// Unknown keys in older snapshot files are ignored by JSONDecoder, so
/// removing fields stays backward compatible.
public struct WidgetSnapshot: Codable {
    public var capturedAt: Date
    public var cpuFraction: Double
    public var gpuFraction: Double?
    public var memoryFraction: Double
    public var memoryUsedBytes: UInt64
    public var memoryTotalBytes: UInt64
    public var cpuTempC: Double?
    public var gpuTempC: Double?
    public var fanRPMs: [Double]
    public var downBytesPerSec: Double
    public var upBytesPerSec: Double
    public var dataTodayDownBytes: UInt64
    public var dataTodayUpBytes: UInt64
    public var batteryPercent: Double?
    public var batteryCharging: Bool?

    public init(
        capturedAt: Date = Date(),
        cpuFraction: Double = 0,
        gpuFraction: Double? = nil,
        memoryFraction: Double = 0,
        memoryUsedBytes: UInt64 = 0,
        memoryTotalBytes: UInt64 = 0,
        cpuTempC: Double? = nil,
        gpuTempC: Double? = nil,
        fanRPMs: [Double] = [],
        downBytesPerSec: Double = 0,
        upBytesPerSec: Double = 0,
        dataTodayDownBytes: UInt64 = 0,
        dataTodayUpBytes: UInt64 = 0,
        batteryPercent: Double? = nil,
        batteryCharging: Bool? = nil
    ) {
        self.capturedAt = capturedAt
        self.cpuFraction = cpuFraction
        self.gpuFraction = gpuFraction
        self.memoryFraction = memoryFraction
        self.memoryUsedBytes = memoryUsedBytes
        self.memoryTotalBytes = memoryTotalBytes
        self.cpuTempC = cpuTempC
        self.gpuTempC = gpuTempC
        self.fanRPMs = fanRPMs
        self.downBytesPerSec = downBytesPerSec
        self.upBytesPerSec = upBytesPerSec
        self.dataTodayDownBytes = dataTodayDownBytes
        self.dataTodayUpBytes = dataTodayUpBytes
        self.batteryPercent = batteryPercent
        self.batteryCharging = batteryCharging
    }
}

/// Reads and writes the snapshot at
/// ~/Library/Application Support/Metrics/widget-snapshot.json.
public enum WidgetSnapshotStore {
    /// ~/Library/Application Support/Metrics. Not created here — callers run
    /// their own createDirectory before writing.
    public static var appSupportDirectory: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("Metrics", isDirectory: true)
    }

    public static var fileURL: URL {
        appSupportDirectory.appendingPathComponent("widget-snapshot.json")
    }

    /// Atomically writes the snapshot, creating the directory if needed.
    /// Failures are ignored — the widget just keeps its previous data.
    public static func save(_ snapshot: WidgetSnapshot) {
        let url = fileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Returns nil when the file is missing or corrupt.
    public static func load() -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }
}
