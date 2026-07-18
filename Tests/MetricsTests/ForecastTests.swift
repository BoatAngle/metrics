import Foundation
import Testing
@testable import Metrics

private func dailyPoints(startingAt t0: TimeInterval, values: [Double]) -> [HistoryPoint] {
    values.enumerated().map { i, v in
        HistoryPoint(date: Date(timeIntervalSince1970: t0 + Double(i) * 86400),
                     avg: v, min: v, max: v)
    }
}

/// Disk-growth forecast (least-squares fit of free bytes per day).
struct DiskForecastTests {
    private let t0: TimeInterval = 1_700_000_000

    @Test func fewerThanThreeDaysIsCollecting() {
        #expect(DiskForecast.compute(points: [], currentFreeBytes: 1e9) == .collecting)
        let two = dailyPoints(startingAt: t0, values: [2e11, 1e11])
        #expect(DiskForecast.compute(points: two, currentFreeBytes: 1e11) == .collecting)
    }

    @Test func cleanDownwardTrendProjectsDaysToFull() {
        // Losing exactly 100 GB/day with 100 GB left → full in 1 day.
        let points = dailyPoints(startingAt: t0, values: [3e11, 2e11, 1e11])
        guard case .fillingUp(let days) = DiskForecast.compute(points: points, currentFreeBytes: 1e11) else {
            Issue.record("expected .fillingUp")
            return
        }
        #expect(abs(days - 1.0) < 1e-9)
    }

    @Test func upwardTrendIsSteady() {
        let points = dailyPoints(startingAt: t0, values: [1e11, 2e11, 3e11])
        #expect(DiskForecast.compute(points: points, currentFreeBytes: 3e11) == .steady)
    }

    @Test func noisyFitIsSteady() {
        // Slope is negative but r² ≈ 0.11 — well under the 0.6 guard.
        let points = dailyPoints(startingAt: t0, values: [100, 200, 50])
        #expect(DiskForecast.compute(points: points, currentFreeBytes: 100) == .steady)
    }

    @Test func identicalTimestampsAreSteadyNotCrash() {
        // sxx == 0 (all samples at one instant) must not divide by zero.
        let points = (0..<3).map { _ in
            HistoryPoint(date: Date(timeIntervalSince1970: t0), avg: 1e11, min: 1e11, max: 1e11)
        }
        #expect(DiskForecast.compute(points: points, currentFreeBytes: 1e11) == .steady)
    }

    @Test func projectionBeyondHorizonIsSteady() {
        // Perfect fit, but ~10 000 days out — outside the useful horizon.
        let points = dailyPoints(startingAt: t0, values: [1000, 999.9, 999.8])
        #expect(DiskForecast.compute(points: points, currentFreeBytes: 1000) == .steady)
    }
}

/// Battery-health decay projection (crossing the 80% service threshold).
struct BatteryHealthProjectionTests {
    private let day: TimeInterval = 86400

    @Test func tooFewPointsIsCollectingThenNoProjection() {
        let now = Date()
        #expect(BatteryHealthProjection.compute(points: [], now: now) == .collecting)
        let five = dailyPoints(startingAt: now.timeIntervalSince1970 - 4 * day,
                               values: [100, 99.5, 99, 98.5, 98])
        #expect(BatteryHealthProjection.compute(points: five, now: now) == .noProjection)
    }

    @Test func steadyDeclineProjectsCrossingDate() {
        // 0.5%/day from 100%, last point today at 93.5% → hits 80 in 27 days.
        let now = Date()
        let t0 = now.timeIntervalSince1970 - 13 * day
        let points = dailyPoints(startingAt: t0, values: (0..<14).map { 100 - 0.5 * Double($0) })
        guard case .reaches80(let date) = BatteryHealthProjection.compute(points: points, now: now) else {
            Issue.record("expected .reaches80")
            return
        }
        let expected = t0 + 40 * day   // (100 − 80) / 0.5 days after t0
        #expect(abs(date.timeIntervalSince1970 - expected) < 60)
    }

    @Test func flatHealthNeverProjects() {
        let now = Date()
        let points = dailyPoints(startingAt: now.timeIntervalSince1970 - 13 * day,
                                 values: Array(repeating: 95.0, count: 14))
        #expect(BatteryHealthProjection.compute(points: points, now: now) == .noProjection)
    }

    @Test func alreadyBelow80NeverProjects() {
        // Declining nicely, but current fitted health is 75.5 — past the threshold.
        let now = Date()
        let points = dailyPoints(startingAt: now.timeIntervalSince1970 - 13 * day,
                                 values: (0..<14).map { 82 - 0.5 * Double($0) })
        #expect(BatteryHealthProjection.compute(points: points, now: now) == .noProjection)
    }
}
