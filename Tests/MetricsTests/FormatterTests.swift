import Foundation
import Testing
@testable import Metrics

/// The String(format:)-based formatters used by the menu bar and cards.
/// (`Fmt.bytes`/`Fmt.date` are locale-dependent and deliberately untested.)
struct FormatterTests {
    @Test func rateScalesThroughUnits() {
        #expect(Fmt.rate(0) == "0 B/s")
        #expect(Fmt.rate(999) == "999 B/s")          // boundary: last B/s value
        #expect(Fmt.rate(1000) == "1.0 KB/s")        // boundary: first KB/s value
        #expect(Fmt.rate(15_000) == "15 KB/s")       // ≥10 drops the decimal
        #expect(Fmt.rate(1_500_000) == "1.5 MB/s")
        #expect(Fmt.rate(2_500_000_000) == "2.50 GB/s")
    }

    @Test func rateClampsNegativeToZero() {
        #expect(Fmt.rate(-5000) == "0 B/s")
    }

    @Test func percentClampsFractionTo0Through100() {
        #expect(Fmt.percent(0.37) == "37%")
        #expect(Fmt.percent(-0.5) == "0%")
        #expect(Fmt.percent(1.5) == "100%")
        #expect(Fmt.percentValue(36.6) == "37%")
    }

    @Test func uptimeDropsSecondsAndLeadsWithLargestUnit() {
        #expect(Fmt.uptime(0) == "0m")
        #expect(Fmt.uptime(3599) == "59m")           // boundary: just under an hour
        #expect(Fmt.uptime(3600) == "1h 0m")
        #expect(Fmt.uptime(90061) == "1d 1h 1m")     // 1d 1h 1m 1s → seconds dropped
    }

    @Test func durationKeepsSecondsForShortSpans() {
        #expect(Fmt.duration(0) == "0s")
        #expect(Fmt.duration(59.4) == "59s")
        #expect(Fmt.duration(60) == "1m 0s")
        #expect(Fmt.duration(3600) == "1h 0m")
        #expect(Fmt.duration(2 * 86400 + 3 * 3600) == "2d 3h")
        #expect(Fmt.duration(-5) == "0s")            // negative clamps, no "-0s"
    }

    @Test func agoBucketsRelativeAges() {
        #expect(Fmt.ago(0) == "now")
        #expect(Fmt.ago(-10) == "now")               // future timestamps read as "now"
        #expect(Fmt.ago(59) == "59s ago")
        #expect(Fmt.ago(60) == "1m ago")
        #expect(Fmt.ago(3600) == "1h ago")
        #expect(Fmt.ago(86400) == "1d ago")
    }

    @Test func wattsSwitchPrecisionAtTen() {
        #expect(Fmt.watts(0) == "0.0 W")
        #expect(Fmt.watts(9.94) == "9.9 W")
        #expect(Fmt.watts(10) == "10 W")
        #expect(Fmt.watts(-3) == "0.0 W")            // negative clamps to zero
    }

    @Test func frequencySwitchesToGHzAt1000MHz() {
        #expect(Fmt.frequency(999) == "999 MHz")
        #expect(Fmt.frequency(1000) == "1.00 GHz")
        #expect(Fmt.frequency(3940) == "3.94 GHz")
    }

    @Test func temperatureConvertsToFahrenheit() {
        #expect(Fmt.temp(0, fahrenheit: true) == "32°F")
        #expect(Fmt.temp(100, fahrenheit: true) == "212°F")
        #expect(Fmt.temp(53.4, fahrenheit: false) == "53°C")
        #expect(Fmt.tempShort(53.6, fahrenheit: false) == "54°")
    }
}
