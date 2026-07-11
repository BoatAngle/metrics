import Foundation

/// Canonical metric names for the history database. Percentages are stored
/// 0…100, byte quantities as raw bytes, temperatures in °C.
enum HistoryMetric {
    static let cpu = "cpu.usage"                    // %
    static let gpu = "gpu.usage"                    // %
    static let powerTotal = "power.total"           // W
    static let memoryUsed = "memory.used"           // bytes
    static let memoryPressure = "memory.pressure"   // %
    static let hotspot = "temp.hotspot"             // °C
    static let netDown = "net.down"                 // B/s
    static let netUp = "net.up"                     // B/s
    static let diskRead = "disk.read"               // B/s
    static let diskWrite = "disk.write"             // B/s
    static let batteryPercent = "battery.percent"   // %
    static let batteryWatts = "battery.watts"       // W, signed (+ charging)
    static let batteryHealth = "battery.health"     // %
    static let batteryCycles = "battery.cycles"     // count

    static func fanRPM(_ id: Int) -> String { "fan.\(id).rpm" }
    static func diskFree(_ volumePath: String) -> String { "disk.free.\(volumePath)" }
}

/// Maps each engine tick's SampleBundle onto history metrics and appends
/// them to the HistoryStore. Slow-changing per-volume free space is
/// throttled to every ~5 minutes. Called from the sampler queue only.
final class HistoryRecorder {
    private static let diskRecordInterval: TimeInterval = 5 * 60
    private var lastDiskRecord = Date.distantPast

    func record(_ bundle: SampleBundle) {
        var samples: [(metric: String, value: Double)] = []
        if let v = bundle.cpu {
            samples.append((HistoryMetric.cpu, v.totalUsage * 100))
        }
        if let v = bundle.gpu, v.available {
            samples.append((HistoryMetric.gpu, v.usageFraction * 100))
        }
        if let v = bundle.power, v.available {
            samples.append((HistoryMetric.powerTotal, v.totalWatts))
        }
        if let v = bundle.memory {
            samples.append((HistoryMetric.memoryUsed, Double(v.usedBytes)))
            samples.append((HistoryMetric.memoryPressure, v.pressurePercent))
        }
        if let v = bundle.network {
            samples.append((HistoryMetric.netDown, v.downBytesPerSec))
            samples.append((HistoryMetric.netUp, v.upBytesPerSec))
        }
        if let v = bundle.diskIO {
            samples.append((HistoryMetric.diskRead, v.readBytesPerSec))
            samples.append((HistoryMetric.diskWrite, v.writeBytesPerSec))
        }
        if let v = bundle.sensors, v.available {
            if let hotspot = v.hotspotC {
                samples.append((HistoryMetric.hotspot, hotspot))
            }
            for fan in v.fans {
                samples.append((HistoryMetric.fanRPM(fan.id), fan.rpm))
            }
        }
        if let v = bundle.battery, v.hasBattery {
            samples.append((HistoryMetric.batteryPercent, v.percent))
            if let watts = v.watts { samples.append((HistoryMetric.batteryWatts, watts)) }
            if let health = v.healthPercent { samples.append((HistoryMetric.batteryHealth, health)) }
            if let cycles = v.cycleCount { samples.append((HistoryMetric.batteryCycles, Double(cycles))) }
        }
        if let v = bundle.disk, Date().timeIntervalSince(lastDiskRecord) >= Self.diskRecordInterval {
            lastDiskRecord = Date()
            for volume in v.volumes {
                samples.append((HistoryMetric.diskFree(volume.path), Double(volume.availableBytes)))
            }
        }
        guard !samples.isEmpty else { return }
        HistoryStore.shared.record(samples)
    }
}
