import Foundation
import WidgetKit
import WidgetShared

/// Publishes the engine's latest readings for the WidgetKit extension:
/// saves a snapshot on every call and asks WidgetKit to reload timelines
/// at most once every 5 minutes.
@MainActor
enum WidgetPublisher {
    private static var lastReload = Date.distantPast
    private static let reloadInterval: TimeInterval = 300

    static func publish(from engine: MetricsEngine) {
        let snapshot = WidgetSnapshot(
            capturedAt: Date(),
            cpuFraction: engine.cpu.totalUsage,
            gpuFraction: engine.gpu.available ? engine.gpu.usageFraction : nil,
            memoryFraction: engine.memory.usedFraction,
            memoryUsedBytes: engine.memory.usedBytes,
            memoryTotalBytes: engine.memory.totalBytes,
            cpuTempC: engine.sensors.cpuTempC,
            gpuTempC: engine.sensors.gpuTempC,
            fanRPMs: engine.sensors.fans.map(\.rpm),
            downBytesPerSec: engine.network.downBytesPerSec,
            upBytesPerSec: engine.network.upBytesPerSec,
            dataTodayDownBytes: engine.networkData.today.down,
            dataTodayUpBytes: engine.networkData.today.up,
            batteryPercent: engine.battery.hasBattery ? engine.battery.percent : nil,
            batteryCharging: engine.battery.hasBattery ? engine.battery.isCharging : nil
        )
        WidgetSnapshotStore.save(snapshot)

        let now = Date()
        if now.timeIntervalSince(lastReload) >= reloadInterval {
            lastReload = now
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}
