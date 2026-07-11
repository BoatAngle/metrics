import Foundation
import WidgetShared

/// Shared formatting helpers. UI-thread use only (formatters aren't thread-safe).
enum Fmt {
    /// "1.14 TB", "482.3 MB" — decimal units.
    static func bytes(_ v: UInt64) -> String { SharedFmt.bytes(v) }

    /// Transfer rate: "0 B/s", "1.2 MB/s".
    static func rate(_ bytesPerSec: Double) -> String { SharedFmt.rate(bytesPerSec) }

    /// 0...1 fraction → "37%".
    static func percent(_ fraction: Double) -> String { SharedFmt.percent(fraction) }

    /// "3d 4h 12m" / "4h 12m" / "12m".
    static func uptime(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let mins = (total % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h \(mins)m" }
        if hours > 0 { return "\(hours)h \(mins)m" }
        return "\(mins)m"
    }

    /// Temperature with unit conversion.
    static func temp(_ celsius: Double, fahrenheit: Bool) -> String {
        if fahrenheit { return String(format: "%.0f°F", celsius * 9 / 5 + 32) }
        return String(format: "%.0f°C", celsius)
    }

    /// Degrees-only temperature ("53°"), unit implied by context.
    static func tempShort(_ celsius: Double, fahrenheit: Bool) -> String {
        String(format: "%.0f°", fahrenheit ? celsius * 9 / 5 + 32 : celsius)
    }

    private static let mediumDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    static func date(_ d: Date) -> String { mediumDate.string(from: d) }
}
