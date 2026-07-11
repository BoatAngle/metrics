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

    /// Already-scaled percentage value (0...100) → "37%". For history series
    /// that store percentages directly.
    static func percentValue(_ value: Double) -> String { String(format: "%.0f%%", value) }

    /// Power in watts: "0.4 W" under ten, "18 W" above (whole watts read cleaner
    /// at higher draw).
    static func watts(_ w: Double) -> String {
        let v = max(0, w)
        return v < 10 ? String(format: "%.1f W", v) : String(format: "%.0f W", v)
    }

    /// Clock in MHz → "3.94 GHz" / "912 MHz".
    static func frequency(_ megahertz: Double) -> String {
        megahertz >= 1000
            ? String(format: "%.2f GHz", megahertz / 1000)
            : String(format: "%.0f MHz", megahertz)
    }

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

    /// Temperature with unit suffix ("53°C" / "127°F").
    static func temp(_ celsius: Double, fahrenheit: Bool) -> String {
        String(format: fahrenheit ? "%.0f°F" : "%.0f°C", converted(celsius, fahrenheit: fahrenheit))
    }

    /// Degrees-only temperature ("53°"), unit implied by context.
    static func tempShort(_ celsius: Double, fahrenheit: Bool) -> String {
        String(format: "%.0f°", converted(celsius, fahrenheit: fahrenheit))
    }

    private static func converted(_ celsius: Double, fahrenheit: Bool) -> Double {
        fahrenheit ? celsius * 9 / 5 + 32 : celsius
    }

    /// Relative age of a past sample: "3s ago" / "5m ago" / "2h ago" / "4d ago".
    static func ago(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s <= 0 { return "now" }
        if s < 60 { return "\(s)s ago" }
        let m = s / 60
        if m < 60 { return "\(m)m ago" }
        let h = m / 60
        if h < 24 { return "\(h)h ago" }
        return "\(h / 24)d ago"
    }

    private static let mediumDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    static func date(_ d: Date) -> String { mediumDate.string(from: d) }
}
