import WidgetKit
import SwiftUI
import WidgetShared

// MARK: - Bundle

@main
struct MetricsWidgetBundle: WidgetBundle {
    var body: some Widget {
        SystemWidget()
        BatteryWidget()
        NetworkWidget()
    }
}

// MARK: - Timeline

struct MetricsEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

/// One provider shared by all Metrics widgets. The app writes the snapshot file
/// every ~30 s and nudges WidgetKit; the .after policy is just a safety net so
/// widgets eventually refresh even if the app isn't running.
struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> MetricsEntry {
        MetricsEntry(date: .now, snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (MetricsEntry) -> Void) {
        completion(MetricsEntry(date: .now, snapshot: WidgetSnapshotStore.load() ?? .placeholder))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MetricsEntry>) -> Void) {
        let now = Date()
        let entry = MetricsEntry(date: now, snapshot: WidgetSnapshotStore.load() ?? .placeholder)
        completion(Timeline(entries: [entry], policy: .after(now.addingTimeInterval(15 * 60))))
    }
}

extension WidgetSnapshot {
    /// Sample data for the widget gallery and redacted placeholders.
    static var placeholder: WidgetSnapshot {
        var s = WidgetSnapshot()
        s.capturedAt = .now
        s.cpuFraction = 0.27
        s.gpuFraction = 0.18
        s.memoryFraction = 0.54
        s.memoryUsedBytes = 17_300_000_000
        s.memoryTotalBytes = 32_000_000_000
        s.cpuTempC = 52
        s.gpuTempC = 48
        s.fanRPMs = [1_240]
        s.downBytesPerSec = 1_200_000
        s.upBytesPerSec = 240_000
        s.dataTodayDownBytes = 2_400_000_000
        s.dataTodayUpBytes = 512_000_000
        s.batteryPercent = 76
        s.batteryCharging = false
        return s
    }
}
