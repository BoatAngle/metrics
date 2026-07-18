import Foundation
import Testing
@testable import Metrics

/// Billing-cycle windowing (feature #28): clamped monthly cycle starts and the
/// daily-history sum. All dates pinned to a UTC gregorian calendar so results
/// don't depend on the machine's timezone.
struct BillingCycleTests {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func point(_ y: Int, _ m: Int, _ d: Int, down: UInt64, up: UInt64 = 0) -> DailyDataPoint {
        DailyDataPoint(day: date(y, m, d), down: down, up: up)
    }

    @Test func sumsOnlyDaysInsideTheCycle() {
        let daily = [
            point(2026, 2, 28, down: 10),   // previous cycle — excluded
            point(2026, 3, 1, down: 20, up: 2),    // cycle start — included
            point(2026, 3, 15, down: 30, up: 3),   // today — included
        ]
        let usage = BillingCycleUsage.compute(daily: daily, startDay: 1,
                                              now: date(2026, 3, 15), calendar: cal)
        #expect(usage.start == date(2026, 3, 1))
        #expect(usage.nextStart == date(2026, 4, 1))
        #expect(usage.down == 50)
        #expect(usage.up == 5)
        #expect(usage.total == 55)
        #expect(usage.daysLeft == 17)
    }

    @Test func day31ClampsToShortMonths() {
        // A "31st" start reaching into February lands on Feb 28 (2026 isn't leap).
        let daily = [
            point(2026, 1, 30, down: 1),    // before the Jan 31 start — excluded
            point(2026, 1, 31, down: 2),    // included
            point(2026, 2, 14, down: 4),    // included
            point(2026, 2, 28, down: 8),    // next cycle's first day — excluded
        ]
        let usage = BillingCycleUsage.compute(daily: daily, startDay: 31,
                                              now: date(2026, 2, 15), calendar: cal)
        #expect(usage.start == date(2026, 1, 31))
        #expect(usage.nextStart == date(2026, 2, 28))
        #expect(usage.down == 6)
        #expect(usage.daysLeft == 13)
    }

    @Test func cycleStartingTodayCountsToday() {
        // April has 30 days, so a "31st" cycle starts Apr 30 — which is today.
        let usage = BillingCycleUsage.compute(daily: [point(2026, 4, 30, down: 7)],
                                              startDay: 31,
                                              now: date(2026, 4, 30), calendar: cal)
        #expect(usage.start == date(2026, 4, 30))
        #expect(usage.nextStart == date(2026, 5, 31))   // May really has a 31st
        #expect(usage.down == 7)
        #expect(usage.daysLeft == 31)
    }

    @Test func outOfRangeStartDayIsClamped() {
        let zero = BillingCycleUsage.compute(daily: [], startDay: 0,
                                             now: date(2026, 3, 15), calendar: cal)
        #expect(zero.start == date(2026, 3, 1))          // 0 → day 1
        let huge = BillingCycleUsage.compute(daily: [], startDay: 99,
                                             now: date(2026, 3, 15), calendar: cal)
        #expect(huge.start == date(2026, 2, 28))         // 99 → 31 → clamped into Feb
    }

    @Test func emptyHistoryIsZeroUsage() {
        let usage = BillingCycleUsage.compute(daily: [], startDay: 1,
                                              now: date(2026, 3, 15), calendar: cal)
        #expect(usage.total == 0)
    }
}
