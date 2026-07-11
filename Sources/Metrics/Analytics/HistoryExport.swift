import Foundation

/// Serializes recorded history to CSV or JSON for the Settings → Data export
/// (feature #32). Pure data assembly — the caller owns the save panel and the
/// file write.
enum HistoryExport {

    enum Format: String, CaseIterable, Identifiable, Sendable {
        case csv, json
        var id: String { rawValue }
        var title: String { self == .csv ? "CSV" : "JSON" }
        var fileExtension: String { rawValue }
    }

    /// Range presets for the picker; `nil` seconds means "everything on record".
    enum Range: String, CaseIterable, Identifiable, Sendable {
        case day, week, month, quarter, all
        var id: String { rawValue }
        var title: String {
            switch self {
            case .day: return "Last 24 hours"
            case .week: return "Last 7 days"
            case .month: return "Last 30 days"
            case .quarter: return "Last 90 days"
            case .all: return "Everything"
            }
        }
        /// Window handed to HistoryStore; `all` uses a century so the store
        /// falls back to its coarsest (daily) rollups.
        var seconds: TimeInterval {
            switch self {
            case .day: return 86400
            case .week: return 7 * 86400
            case .month: return 30 * 86400
            case .quarter: return 90 * 86400
            case .all: return 100 * 365 * 86400
            }
        }
    }

    /// A human label for a stored metric name, including the dynamic
    /// `fan.N.rpm` and `disk.free.<path>` families.
    static func label(for metric: String) -> String {
        switch metric {
        case HistoryMetric.cpu: return "CPU usage (%)"
        case HistoryMetric.gpu: return "GPU usage (%)"
        case HistoryMetric.powerTotal: return "Power (W)"
        case HistoryMetric.memoryUsed: return "Memory used (bytes)"
        case HistoryMetric.memoryPressure: return "Memory pressure (%)"
        case HistoryMetric.hotspot: return "Hotspot temp (°C)"
        case HistoryMetric.netDown: return "Network down (B/s)"
        case HistoryMetric.netUp: return "Network up (B/s)"
        case HistoryMetric.wifiRSSI: return "Wi-Fi signal (dBm)"
        case HistoryMetric.diskRead: return "Disk read (B/s)"
        case HistoryMetric.diskWrite: return "Disk write (B/s)"
        case HistoryMetric.batteryPercent: return "Battery charge (%)"
        case HistoryMetric.batteryWatts: return "Battery power (W)"
        case HistoryMetric.batteryHealth: return "Battery health (%)"
        case HistoryMetric.batteryCycles: return "Battery cycles"
        case HistoryMetric.batteryPlugged: return "On AC power (0/1)"
        default:
            if metric.hasPrefix("fan."), metric.hasSuffix(".rpm") {
                let id = metric.dropFirst(4).dropLast(4)
                return "Fan \(id) (RPM)"
            }
            if metric.hasPrefix("disk.free.") {
                return "Free space \(metric.dropFirst("disk.free.".count)) (bytes)"
            }
            return metric
        }
    }

    /// Builds the export document for the chosen metrics/range/format. Runs the
    /// per-metric history queries concurrently off the main actor.
    static func build(metrics: [String], range: Range, format: Format,
                      now: Date = Date()) async -> String {
        let end = now
        var seriesByMetric: [(metric: String, points: [HistoryPoint])] = []
        for metric in metrics {
            let points = await HistoryStore.shared.series(
                metric: metric, window: range.seconds, endingAt: end)
            seriesByMetric.append((metric, points))
        }
        switch format {
        case .csv: return csv(seriesByMetric)
        case .json: return json(seriesByMetric, range: range, generated: end)
        }
    }

    // MARK: - Serialization

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func csv(_ series: [(metric: String, points: [HistoryPoint])]) -> String {
        var out = "metric,label,timestamp,avg,min,max\n"
        for entry in series {
            let safeLabel = csvField(label(for: entry.metric))
            let safeMetric = csvField(entry.metric)
            for p in entry.points {
                out += "\(safeMetric),\(safeLabel),\(iso.string(from: p.date)),"
                out += "\(fmt(p.avg)),\(fmt(p.min)),\(fmt(p.max))\n"
            }
        }
        return out
    }

    private static func json(_ series: [(metric: String, points: [HistoryPoint])],
                             range: Range, generated: Date) -> String {
        var root: [String: Any] = [
            "generated": iso.string(from: generated),
            "range": range.rawValue,
        ]
        var seriesObj: [[String: Any]] = []
        for entry in series {
            let points: [[String: Any]] = entry.points.map { p in
                ["t": iso.string(from: p.date), "avg": p.avg, "min": p.min, "max": p.max]
            }
            seriesObj.append([
                "metric": entry.metric,
                "label": label(for: entry.metric),
                "points": points,
            ])
        }
        root["series"] = seriesObj
        guard let data = try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    /// Compact numeric formatting: whole numbers without a trailing ".0", the
    /// rest to a few decimals, avoiding scientific notation for byte counts.
    private static func fmt(_ v: Double) -> String {
        if v == v.rounded() && abs(v) < 1e15 { return String(Int64(v)) }
        return String(format: "%.3f", v)
    }

    private static func csvField(_ s: String) -> String {
        guard s.contains(",") || s.contains("\"") || s.contains("\n") else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
