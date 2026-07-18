import Foundation
import Testing
@testable import Metrics

/// Pure pieces of the alerts engine: comparator semantics, the adapter-wattage
/// parser, and rule reconfiguration when the user switches metric.
@MainActor
struct AlertRuleTests {
    @Test func comparatorsAreStrict() {
        #expect(AlertComparator.above.matches(90.1, 90))
        #expect(!AlertComparator.above.matches(90, 90))     // equal never trips
        #expect(AlertComparator.below.matches(9.9, 10))
        #expect(!AlertComparator.below.matches(10, 10))
    }

    @Test func parsesAdapterWattage() {
        #expect(AlertEngine.ratedAdapterWatts("96W USB-C Power Adapter") == 96)
        #expect(AlertEngine.ratedAdapterWatts("Apple 140W Charger") == 140)
        #expect(AlertEngine.ratedAdapterWatts("10w brick") == 10)     // lowercase w
        #expect(AlertEngine.ratedAdapterWatts("96W") == 96)           // bare rating
    }

    @Test func adapterParserRejectsUnratedDescriptions() {
        #expect(AlertEngine.ratedAdapterWatts(nil) == nil)
        #expect(AlertEngine.ratedAdapterWatts("USB-C Power Adapter") == nil)
        #expect(AlertEngine.ratedAdapterWatts("5V 2A") == nil)        // volts ≠ watts
        #expect(AlertEngine.ratedAdapterWatts("") == nil)
    }

    @Test func newRuleSeedsMetricDefaults() {
        let rule = AlertRule.new(metric: .cpuUsage)
        #expect(rule.name == "High CPU usage")
        #expect(rule.comparator == .above)
        #expect(rule.threshold == 90)
        #expect(rule.enabled)
    }

    @Test func reconfigureResetsDefaultsAndClearsStaleContext() {
        var rule = AlertRule.new(metric: .tempSensor)
        rule.sensorName = "Airflow"
        rule.actions = [.notify, .setFanMode(.performance)]

        let r = rule.reconfigured(for: .volumeFreePercent)
        #expect(r.metric == .volumeFreePercent)
        #expect(r.comparator == .below)                 // low-space alerts trip downward
        #expect(r.threshold == 10)
        #expect(r.name == "Low disk space")             // suggested name tracks the metric
        #expect(r.sensorName == nil)                    // sensor context is stale now
        #expect(r.actions == [.notify])                 // fan escalation is temperature-only
    }

    @Test func reconfigureKeepsCustomizedName() {
        var rule = AlertRule.new(metric: .cpuUsage)
        rule.name = "My special rule"
        #expect(rule.reconfigured(for: .gpuUsage).name == "My special rule")
    }

    @Test func reconfigureClearsChargingOnlyOffBatteryMetrics() {
        var rule = AlertRule.new(metric: .batteryPercent)
        rule.chargingOnly = true
        #expect(!rule.reconfigured(for: .cpuUsage).chargingOnly)
    }

    @Test func snoozeStateFollowsTheClock() {
        var rule = AlertRule.new(metric: .cpuUsage)
        #expect(!rule.isSnoozed)                        // nil → active
        rule.snoozedUntil = Date().addingTimeInterval(60)
        #expect(rule.isSnoozed)
        rule.snoozedUntil = Date().addingTimeInterval(-60)
        #expect(!rule.isSnoozed)                        // expired snooze
    }

    @Test func sensorNamesListOnlyAvailableSensors() {
        var sensors = SensorsSnapshot()
        sensors.cpuTempC = 55
        sensors.extraTemps = [NamedTemp(name: "Airflow", celsius: 41)]
        // GPU temp is nil, so "GPU" must not be offered.
        #expect(AlertEngine.availableSensorNames(engineSensors: sensors) == ["CPU", "Airflow"])
        #expect(AlertEngine.availableSensorNames(engineSensors: SensorsSnapshot()) == [])
    }

    @Test func hotspotPrefersHottestMaxSensor() {
        var sensors = SensorsSnapshot()
        #expect(sensors.hotspotC == nil)                // no readings at all
        sensors.cpuTempC = 50
        sensors.gpuTempC = 60
        #expect(sensors.hotspotC == 60)
        sensors.cpuTempMaxC = 72                        // hottest single core wins
        #expect(sensors.hotspotC == 72)
    }
}
