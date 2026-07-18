import Foundation
import Testing
@testable import Metrics

/// The SQLite history store, against a throwaway database in the system temp
/// directory: rollup math, the raw-tail/rollup seam, aggregates, and the
/// minute → hour → day retention cascade (driven by an injected clock).
struct HistoryStoreTests {
    private func makeStore() -> (store: HistoryStore, dir: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("metrics-tests-\(UUID().uuidString)", isDirectory: true)
        let store = HistoryStore(databaseURL: dir.appendingPathComponent("history.sqlite"))
        return (store, dir)
    }

    @Test func rawTailSeriesAggregatesWithoutDoubleCounting() async {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Three samples in one minute bucket, ~30 min ago.
        let now = Date()
        let bucket = ((now.timeIntervalSince1970 - 1800) / 60).rounded(.down) * 60
        for (i, v) in [10.0, 20, 30].enumerated() {
            store.record(metric: "test.cpu", value: v,
                         at: Date(timeIntervalSince1970: bucket + Double(i)))
        }
        store.runMaintenanceSync(now: now)

        // Short window reads the raw tail; the freshly written minute rollup for
        // the same bucket must not produce a second point.
        let short = await store.series(metric: "test.cpu", window: 7200, endingAt: now)
        #expect(short.count == 1)
        #expect(short.first?.avg == 20)
        #expect(short.first?.min == 10)
        #expect(short.first?.max == 30)

        // A longer window reads the minute rollup itself — same numbers.
        let rolled = await store.series(metric: "test.cpu", window: 36000, endingAt: now)
        #expect(rolled.count == 1)
        #expect(rolled.first?.avg == 20)

        // Unknown metrics stay empty.
        let none = await store.series(metric: "test.nope", window: 7200, endingAt: now)
        #expect(none.isEmpty)
    }

    @Test func aggregateIntegratesOverTime() async {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Minute-aligned so all three samples share one bucket (a straddled
        // boundary would legitimately change the integral).
        let now = Date()
        let base = ((now.timeIntervalSince1970 - 1800) / 60).rounded(.down) * 60
        for (i, v) in [10.0, 20, 30].enumerated() {
            store.record(metric: "test.net", value: v,
                         at: Date(timeIntervalSince1970: base + Double(i)))
        }
        store.runMaintenanceSync(now: now)

        let agg = await store.aggregate(metric: "test.net",
                                        since: now.addingTimeInterval(-7200), until: now)
        #expect(agg != nil)
        #expect(agg?.count == 3)
        #expect(agg?.avg == 20)
        #expect(agg?.min == 10)
        #expect(agg?.max == 30)
        // One minute bucket of avg 20 → time-integral 20 × 60 s.
        #expect(agg?.total == 1200)

        // Edge: no samples in range → nil, not a zeroed aggregate.
        let empty = await store.aggregate(metric: "test.other",
                                          since: now.addingTimeInterval(-7200), until: now)
        #expect(empty == nil)
    }

    @Test func retentionCascadesMinuteToHourToDay() async {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        // A fixed, day-aligned instant so bucket edges are exact.
        let t0 = 1_699_920_000.0
        // Minute A: three samples of 10. Minute B: one sample of 50. The hour
        // average must be count-weighted: (10×3 + 50×1) / 4 = 20, not 30.
        for offset in [0.0, 10, 20] {
            store.record(metric: "test.disk", value: 10, at: Date(timeIntervalSince1970: t0 + offset))
        }
        store.record(metric: "test.disk", value: 50, at: Date(timeIntervalSince1970: t0 + 60))

        // First pass (2 min later): raw → minute, catch-up hour + day rollups.
        store.runMaintenanceSync(now: Date(timeIntervalSince1970: t0 + 120))
        let afterFirst = store.dumpStatsSync()
        #expect(afterFirst.rawRows == 4)
        #expect(afterFirst.rollupRows == 4)   // 2 minute + 1 hour + 1 day

        // Idempotency: an immediate second pass must not change anything.
        store.runMaintenanceSync(now: Date(timeIntervalSince1970: t0 + 120))
        #expect(store.dumpStatsSync().rollupRows == 4)

        // Eight days on: raw (2 h) and minute rollups (7 d) expire; hour and day
        // rollups survive.
        store.runMaintenanceSync(now: Date(timeIntervalSince1970: t0 + 8 * 86400))
        let afterWeek = store.dumpStatsSync()
        #expect(afterWeek.rawRows == 0)
        #expect(afterWeek.rollupRows == 2)

        let minuteRes = await store.series(metric: "test.disk", window: 86400,
                                           endingAt: Date(timeIntervalSince1970: t0 + 86400))
        #expect(minuteRes.isEmpty)            // minute rollups pruned

        let hourRes = await store.series(metric: "test.disk", window: 5 * 86400,
                                         endingAt: Date(timeIntervalSince1970: t0 + 4 * 86400))
        #expect(hourRes.count == 1)
        #expect(hourRes.first?.avg == 20)     // count-weighted, not mean-of-means
        #expect(hourRes.first?.min == 10)
        #expect(hourRes.first?.max == 50)

        let dayRes = await store.series(metric: "test.disk", window: 30 * 86400,
                                        endingAt: Date(timeIntervalSince1970: t0 + 10 * 86400))
        #expect(dayRes.count == 1)
        #expect(dayRes.first?.avg == 20)
        #expect(dayRes.first?.date == Date(timeIntervalSince1970: t0))
    }

    @Test func emptyBatchRecordIsANoOp() async {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.record([], at: Date())
        store.runMaintenanceSync(now: Date())
        #expect(store.dumpStatsSync().rawRows == 0)
        #expect(store.dumpStatsSync().rollupRows == 0)
    }
}
