import Foundation
import SQLite3
import WidgetShared

/// One aggregated point in a history series.
struct HistoryPoint: Equatable, Sendable {
    var date: Date
    var avg: Double
    var min: Double
    var max: Double
}

/// Summary statistics for a metric over an arbitrary time range (feature #25).
/// `total` integrates the stored value across time (Σ avg × bucketSeconds), so
/// for a rate metric (B/s) it is the total transferred over the range in bytes.
struct HistoryAggregate: Sendable {
    var avg: Double         // count-weighted mean of the stored value
    var min: Double
    var max: Double
    var count: Int          // number of raw samples represented
    var total: Double       // time-integral of the value (bytes for a rate metric)
    var firstDate: Date
    var lastDate: Date
}

/// `sqlite3_bind_text` needs SQLITE_TRANSIENT so SQLite copies the string;
/// the C macro doesn't import into Swift, so recreate it.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Local time-series recorder backed by SQLite at
/// ~/Library/Application Support/Metrics/history.sqlite (system libsqlite3,
/// no external packages). Everything stays on this Mac.
///
/// Storage design — raw samples land in `samples` and are downsampled on a
/// once-a-minute maintenance pass into `rollups` (avg/min/max per bucket):
///   raw samples   → kept ~2 hours
///   per-minute    → kept 7 days
///   per-hour      → kept 90 days
///   per-day       → kept forever
///
/// Maintenance is a pure recompute: each pass re-aggregates every bucket
/// whose source data is still fully retained (INSERT OR REPLACE), so passes
/// are idempotent, partial current buckets refresh as data arrives, and the
/// first pass after launch catches up on anything a previous run never got
/// to. No progress bookkeeping to corrupt or fall behind.
///
/// All DB work happens on a dedicated serial queue; `record` is a cheap
/// enqueue safe to call from any thread (the engine's sampler queue calls it
/// every tick). Reads are async and never block the main actor.
final class HistoryStore: @unchecked Sendable {
    static let shared = HistoryStore()

    // MARK: Tuning

    private static let rawRetention: TimeInterval = 2 * 3600
    private static let minuteRetention: TimeInterval = 7 * 86400
    private static let hourRetention: TimeInterval = 90 * 86400
    private static let maintenanceInterval: TimeInterval = 60

    /// Rollup bucket widths in seconds. Buckets are UTC-aligned
    /// (floor(ts / resolution) * resolution) so the math is stable across
    /// timezone and DST changes.
    private enum Resolution {
        static let minute = 60
        static let hour = 3600
        static let day = 86400
    }

    static var databaseURL: URL {
        WidgetSnapshotStore.appSupportDirectory.appendingPathComponent("history.sqlite")
    }

    /// Where this instance's database lives. The shared store uses
    /// `Self.databaseURL`; tests inject a temp path via `init(databaseURL:)`.
    let databaseURL: URL

    // MARK: State (queue-confined after init)

    private let queue = DispatchQueue(label: "metrics.history", qos: .utility)
    private var db: OpaquePointer?
    private var insertStatement: OpaquePointer?
    private var maintenanceTimer: DispatchSourceTimer?
    /// False until the first maintenance pass after launch, which recomputes
    /// hour/day rollups over the full source retention to close any gap left
    /// by a previous run (e.g. quit mid-hour, then relaunched days later).
    private var didCatchUpRecompute = false

    private convenience init() {
        self.init(databaseURL: Self.databaseURL)
    }

    /// Testing seam: a store rooted at an explicit database path. Behavior is
    /// identical to the shared store; only the file location differs.
    init(databaseURL: URL) {
        self.databaseURL = databaseURL
        queue.async { [self] in openDatabase() }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.maintenanceInterval,
                       repeating: Self.maintenanceInterval)
        timer.setEventHandler { [weak self] in self?.performMaintenance(now: Date()) }
        maintenanceTimer = timer
        timer.resume()
    }

    // MARK: - Recording

    /// Generic seam: append one sample for any metric name. Later features
    /// (per-app data, power watts, …) can record through this without
    /// touching the store. `date` may lag "now" by up to the raw retention
    /// (~2 h); anything older is dropped before it can be summarized.
    func record(metric: String, value: Double, at date: Date = Date()) {
        record([(metric: metric, value: value)], at: date)
    }

    /// Appends a batch of samples stamped with the same instant, in a single
    /// transaction. Cheap for callers: the actual insert runs on the store's
    /// own queue.
    func record(_ samples: [(metric: String, value: Double)], at date: Date = Date()) {
        guard !samples.isEmpty else { return }
        let ts = date.timeIntervalSince1970
        queue.async { [self] in
            guard db != nil, let insert = insertStatement else { return }
            exec("BEGIN")
            for sample in samples {
                sqlite3_reset(insert)
                sqlite3_bind_text(insert, 1, sample.metric, -1, SQLITE_TRANSIENT)
                sqlite3_bind_double(insert, 2, ts)
                sqlite3_bind_double(insert, 3, sample.value)
                _ = sqlite3_step(insert)
            }
            exec("COMMIT")
        }
    }

    // MARK: - Reading

    /// Series for the trailing `window` seconds, at a resolution matched to
    /// the window: ≤ 2 h → per-minute plus the not-yet-rolled-up raw tail,
    /// ≤ 26 h → per-minute rollups, ≤ 8 d → per-hour, beyond → per-day.
    func series(metric: String, window: TimeInterval, endingAt end: Date = Date()) async -> [HistoryPoint] {
        await onQueue { [self] in
            let start = end.timeIntervalSince1970 - window
            switch window {
            case ...(2 * 3600):
                return minuteSeriesWithRawTail(metric: metric, since: start)
            case ...(26 * 3600):
                return rollupSeries(metric: metric, resolution: Resolution.minute, since: start)
            case ...(8 * 86400):
                return rollupSeries(metric: metric, resolution: Resolution.hour, since: start)
            default:
                return rollupSeries(metric: metric, resolution: Resolution.day, since: start)
            }
        }
    }

    /// Summary stats for a metric over `[start, end]`, at the same
    /// resolution `series` would pick for the range (feature #25). nil when the
    /// range holds no recorded samples for the metric.
    func aggregate(metric: String, since start: Date, until end: Date = Date()) async -> HistoryAggregate? {
        await onQueue { [self] in
            aggregateSync(metric: metric,
                          start: start.timeIntervalSince1970,
                          end: end.timeIntervalSince1970)
        }
    }

    /// One aggregated point per local calendar day over the trailing `days`,
    /// built from the per-hour rollups grouped into the viewer's timezone
    /// (features #30/#31). `max` is that day's peak, `avg` its mean. Newest
    /// last. Hour rollups are retained ~90 days, so this covers week and month.
    func localDailyRollups(metric: String, days: Int, endingAt end: Date = Date()) async -> [HistoryPoint] {
        await onQueue { [self] in
            let tz = Double(TimeZone.current.secondsFromGMT(for: end))
            let start = end.timeIntervalSince1970 - Double(max(days, 1)) * 86400
            return queryPoints("""
                SELECT CAST((bucket + ?3) / 86400 AS INTEGER) * 86400 - ?3 AS day,
                       SUM(avg * count) / SUM(count), MIN(min), MAX(max)
                FROM rollups
                WHERE metric = ?1 AND resolution = \(Resolution.hour) AND bucket >= ?2
                GROUP BY day ORDER BY day
                """) { stmt in
                sqlite3_bind_text(stmt, 1, metric, -1, SQLITE_TRANSIENT)
                sqlite3_bind_double(stmt, 2, start)
                sqlite3_bind_double(stmt, 3, tz)
            }
        }
    }

    /// Every metric name that has recorded data, for the export series picker
    /// (feature #32). Sorted; drawn from rollups (the durable store).
    func distinctMetrics() async -> [String] {
        await onQueue { [self] in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT DISTINCT metric FROM rollups ORDER BY metric",
                                     -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
            defer { sqlite3_finalize(stmt) }
            var names: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let c = sqlite3_column_text(stmt, 0) { names.append(String(cString: c)) }
            }
            return names
        }
    }

    /// Size of the database on disk (main file + WAL sidecars), for Settings.
    func databaseSizeBytes() async -> UInt64 {
        await onQueue { [self] in sizeOnDisk() }
    }

    /// Drops every sample and rollup and shrinks the file back down.
    func deleteAllHistory() async {
        await onQueue { [self] in
            exec("DELETE FROM samples")
            exec("DELETE FROM rollups")
            exec("VACUUM")
            exec("PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }

    // MARK: - --dump support (CLI only; blocks on the store queue)

    /// `now` is injectable so tests can drive the retention clock forward.
    func runMaintenanceSync(now: Date = Date()) {
        queue.sync { performMaintenance(now: now) }
    }

    func dumpStatsSync() -> (path: String, rawRows: Int, rollupRows: Int, sizeBytes: UInt64) {
        queue.sync { [self] in
            (databaseURL.path,
             scalarInt("SELECT COUNT(*) FROM samples"),
             scalarInt("SELECT COUNT(*) FROM rollups"),
             sizeOnDisk())
        }
    }

    // MARK: - Setup

    private func openDatabase() {
        try? FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &handle,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                              nil) == SQLITE_OK, let handle else {
            sqlite3_close(handle) // per SQLite docs, close even a failed open
            return               // store stays inert; recording no-ops
        }
        db = handle
        exec("PRAGMA journal_mode = WAL")
        exec("PRAGMA synchronous = NORMAL")
        exec("""
            CREATE TABLE IF NOT EXISTS samples(
                metric TEXT NOT NULL,
                ts     REAL NOT NULL,
                value  REAL NOT NULL)
            """)
        exec("CREATE INDEX IF NOT EXISTS idx_samples_metric_ts ON samples(metric, ts)")
        exec("""
            CREATE TABLE IF NOT EXISTS rollups(
                metric     TEXT NOT NULL,
                resolution INTEGER NOT NULL,
                bucket     REAL NOT NULL,
                avg        REAL NOT NULL,
                min        REAL NOT NULL,
                max        REAL NOT NULL,
                count      INTEGER NOT NULL,
                PRIMARY KEY(metric, resolution, bucket)) WITHOUT ROWID
            """)
        var insert: OpaquePointer?
        if sqlite3_prepare_v2(handle, "INSERT INTO samples(metric, ts, value) VALUES(?1, ?2, ?3)",
                              -1, &insert, nil) == SQLITE_OK {
            insertStatement = insert
        }
    }

    // MARK: - Maintenance (downsample + prune)

    /// Recomputes raw → minute → hour → day rollups, then prunes expired
    /// data — one transaction, on the store queue, never touching the main
    /// actor. Each level re-aggregates only buckets whose source data is
    /// still fully retained, so replacing is always safe; pruning runs after
    /// the rollups so nothing is dropped before it's been summarized.
    private func performMaintenance(now: Date) {
        guard db != nil else { return }
        let ts = now.timeIntervalSince1970
        // First minute bucket still fully covered by raw samples. Buckets
        // before it may have lost rows to pruning; their rollups were
        // computed by earlier passes while the data was complete.
        let safeRawStart = bucketFloor(ts - Self.rawRetention, Resolution.minute)
            + Double(Resolution.minute)
        // Steady state only re-aggregates the coarse buckets the minute
        // window can touch; the catch-up pass sweeps the whole source
        // retention once per launch. Catch-up starts are aligned up to the
        // next bucket whose sources are all still retained, so a boundary
        // bucket is never replaced by an aggregate of partially-pruned data.
        let hourStart = didCatchUpRecompute
            ? bucketFloor(safeRawStart, Resolution.hour)
            : bucketFloor(ts - Self.minuteRetention, Resolution.hour) + Double(Resolution.hour)
        let dayStart = didCatchUpRecompute
            ? bucketFloor(safeRawStart, Resolution.day)
            : bucketFloor(ts - Self.hourRetention, Resolution.day) + Double(Resolution.day)

        exec("BEGIN")
        rollUpRaw(since: safeRawStart)
        rollUp(from: Resolution.minute, to: Resolution.hour, since: hourStart)
        rollUp(from: Resolution.hour, to: Resolution.day, since: dayStart)
        exec("DELETE FROM samples WHERE ts < \(ts - Self.rawRetention)")
        exec("DELETE FROM rollups WHERE resolution = \(Resolution.minute) AND bucket < \(ts - Self.minuteRetention)")
        exec("DELETE FROM rollups WHERE resolution = \(Resolution.hour) AND bucket < \(ts - Self.hourRetention)")
        exec("COMMIT")
        didCatchUpRecompute = true
    }

    /// Re-aggregates raw samples at/after `since` into per-minute rollups
    /// (including the partial current minute — the next pass refreshes it).
    private func rollUpRaw(since: TimeInterval) {
        run("""
            INSERT OR REPLACE INTO rollups(metric, resolution, bucket, avg, min, max, count)
            SELECT metric, \(Resolution.minute),
                   CAST(ts / \(Resolution.minute) AS INTEGER) * \(Resolution.minute),
                   AVG(value), MIN(value), MAX(value), COUNT(*)
            FROM samples WHERE ts >= ?1
            GROUP BY 1, 3
            """) { stmt in
            sqlite3_bind_double(stmt, 1, since)
        }
    }

    /// Re-aggregates finer rollups at/after `since` into coarser buckets;
    /// averages are re-weighted by sample count so they stay exact.
    private func rollUp(from src: Int, to dst: Int, since: TimeInterval) {
        run("""
            INSERT OR REPLACE INTO rollups(metric, resolution, bucket, avg, min, max, count)
            SELECT metric, \(dst),
                   CAST(bucket / \(dst) AS INTEGER) * \(dst),
                   SUM(avg * count) / SUM(count), MIN(min), MAX(max), SUM(count)
            FROM rollups WHERE resolution = \(src) AND bucket >= ?1
            GROUP BY 1, 3
            """) { stmt in
            sqlite3_bind_double(stmt, 1, since)
        }
    }

    private func bucketFloor(_ ts: TimeInterval, _ resolution: Int) -> TimeInterval {
        (ts / Double(resolution)).rounded(.down) * Double(resolution)
    }

    // MARK: - Queries (store queue only)

    /// Short windows aggregate raw samples on the fly, so they're current to
    /// the second; minute rollups fill in only the buckets old enough that
    /// raw rows may already be pruned. The boundary between the two is a
    /// minute edge, so no bucket is counted twice.
    private func minuteSeriesWithRawTail(metric: String, since start: TimeInterval) -> [HistoryPoint] {
        let safeRawStart = bucketFloor(Date().timeIntervalSince1970 - Self.rawRetention,
                                       Resolution.minute) + Double(Resolution.minute)
        var points = rollupSeries(metric: metric, resolution: Resolution.minute,
                                  since: start, before: safeRawStart)
        points += queryPoints("""
            SELECT CAST(ts / \(Resolution.minute) AS INTEGER) * \(Resolution.minute) AS bucket,
                   AVG(value), MIN(value), MAX(value)
            FROM samples WHERE metric = ?1 AND ts >= ?2
            GROUP BY bucket ORDER BY bucket
            """) { stmt in
            sqlite3_bind_text(stmt, 1, metric, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 2, Swift.max(start, safeRawStart))
        }
        return points
    }

    private func rollupSeries(metric: String, resolution: Int, since start: TimeInterval,
                              before end: TimeInterval = .greatestFiniteMagnitude) -> [HistoryPoint] {
        queryPoints("""
            SELECT bucket, avg, min, max FROM rollups
            WHERE metric = ?1 AND resolution = ?2 AND bucket >= ?3 AND bucket < ?4
            ORDER BY bucket
            """) { stmt in
            sqlite3_bind_text(stmt, 1, metric, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 2, Int32(resolution))
            sqlite3_bind_double(stmt, 3, start)
            sqlite3_bind_double(stmt, 4, end)
        }
    }

    /// Running fold of bucketed rows into aggregate statistics.
    private struct AggAcc {
        var sumAvgCount = 0.0
        var sumCount = 0.0
        var minV = Double.greatestFiniteMagnitude
        var maxV = -Double.greatestFiniteMagnitude
        var integral = 0.0
        var firstBucket = Double.greatestFiniteMagnitude
        var lastEdge = -Double.greatestFiniteMagnitude
    }

    /// Aggregates a metric over `[start, end)` at the same resolution `series`
    /// would use, mirroring its raw-tail handling so short windows stay current
    /// to the second. Buckets contribute `avg × bucketSeconds` to the integral.
    private func aggregateSync(metric: String, start: TimeInterval, end: TimeInterval) -> HistoryAggregate? {
        var acc = AggAcc()
        let window = end - start
        switch window {
        case ...(2 * 3600):
            // Minute rollups up to the raw retention edge, raw samples grouped
            // by minute after it — the same split `series` uses.
            let safeRawStart = bucketFloor(Date().timeIntervalSince1970 - Self.rawRetention,
                                           Resolution.minute) + Double(Resolution.minute)
            foldRollups(metric: metric, resolution: Resolution.minute,
                        start: start, end: Swift.min(end, safeRawStart), into: &acc)
            foldRawByMinute(metric: metric,
                            start: Swift.max(start, safeRawStart), end: end, into: &acc)
        case ...(26 * 3600):
            foldRollups(metric: metric, resolution: Resolution.minute, start: start, end: end, into: &acc)
        case ...(8 * 86400):
            foldRollups(metric: metric, resolution: Resolution.hour, start: start, end: end, into: &acc)
        default:
            foldRollups(metric: metric, resolution: Resolution.day, start: start, end: end, into: &acc)
        }
        guard acc.sumCount > 0 else { return nil }
        return HistoryAggregate(avg: acc.sumAvgCount / acc.sumCount,
                                min: acc.minV, max: acc.maxV, count: Int(acc.sumCount),
                                total: acc.integral,
                                firstDate: Date(timeIntervalSince1970: acc.firstBucket),
                                lastDate: Date(timeIntervalSince1970: acc.lastEdge))
    }

    private func foldRollups(metric: String, resolution: Int,
                             start: TimeInterval, end: TimeInterval, into acc: inout AggAcc) {
        guard end > start else { return }
        foldBuckets("""
            SELECT bucket, avg, min, max, count FROM rollups
            WHERE metric = ?1 AND resolution = ?2 AND bucket >= ?3 AND bucket < ?4
            """, bucketSeconds: Double(resolution), into: &acc) { stmt in
            sqlite3_bind_text(stmt, 1, metric, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 2, Int32(resolution))
            sqlite3_bind_double(stmt, 3, start)
            sqlite3_bind_double(stmt, 4, end)
        }
    }

    private func foldRawByMinute(metric: String, start: TimeInterval, end: TimeInterval,
                                 into acc: inout AggAcc) {
        guard end > start else { return }
        foldBuckets("""
            SELECT CAST(ts / \(Resolution.minute) AS INTEGER) * \(Resolution.minute) AS bucket,
                   AVG(value), MIN(value), MAX(value), COUNT(*)
            FROM samples WHERE metric = ?1 AND ts >= ?2 AND ts < ?3 GROUP BY bucket
            """, bucketSeconds: Double(Resolution.minute), into: &acc) { stmt in
            sqlite3_bind_text(stmt, 1, metric, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 2, start)
            sqlite3_bind_double(stmt, 3, end)
        }
    }

    /// Folds rows shaped (bucket, avg, min, max, count) into `acc`.
    private func foldBuckets(_ sql: String, bucketSeconds: Double,
                             into acc: inout AggAcc, bind: (OpaquePointer) -> Void) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        while sqlite3_step(stmt) == SQLITE_ROW {
            let bucket = sqlite3_column_double(stmt, 0)
            let avg = sqlite3_column_double(stmt, 1)
            let mn = sqlite3_column_double(stmt, 2)
            let mx = sqlite3_column_double(stmt, 3)
            let count = Double(sqlite3_column_int64(stmt, 4))
            acc.sumAvgCount += avg * count
            acc.sumCount += count
            acc.minV = Swift.min(acc.minV, mn)
            acc.maxV = Swift.max(acc.maxV, mx)
            acc.integral += avg * bucketSeconds
            acc.firstBucket = Swift.min(acc.firstBucket, bucket)
            acc.lastEdge = Swift.max(acc.lastEdge, bucket + bucketSeconds)
        }
    }

    private func queryPoints(_ sql: String, bind: (OpaquePointer) -> Void) -> [HistoryPoint] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        var points: [HistoryPoint] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            points.append(HistoryPoint(date: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0)),
                                       avg: sqlite3_column_double(stmt, 1),
                                       min: sqlite3_column_double(stmt, 2),
                                       max: sqlite3_column_double(stmt, 3)))
        }
        return points
    }

    // MARK: - Helpers (store queue only)

    private func scalarInt(_ sql: String) -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private func run(_ sql: String, bind: (OpaquePointer) -> Void) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        _ = sqlite3_step(stmt)
    }

    private func onQueue<T: Sendable>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    private func sizeOnDisk() -> UInt64 {
        let base = databaseURL.path
        return [base, base + "-wal", base + "-shm"].reduce(0) { total, path in
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            return total &+ ((attributes?[.size] as? NSNumber)?.uint64Value ?? 0)
        }
    }
}
