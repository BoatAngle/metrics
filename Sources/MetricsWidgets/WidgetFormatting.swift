import Foundation
import WidgetShared

/// Formatting helpers local to the widget extension. Kept deliberately simple:
/// no access to app settings, so temperatures are always °C.
enum WFmt {
    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short // "3:04 PM"
        return f
    }()

    /// "1.14 TB", "482.3 MB" — decimal units.
    static func bytes(_ v: UInt64) -> String { SharedFmt.bytes(v) }

    /// Transfer rate: "0 B/s", "1.2 MB/s".
    static func rate(_ bytesPerSec: Double) -> String { SharedFmt.rate(bytesPerSec) }

    /// 0...1 fraction → "37%".
    static func percent(_ fraction: Double) -> String { SharedFmt.percent(fraction) }

    /// "52°C".
    static func temp(_ celsius: Double) -> String {
        String(format: "%.0f°C", celsius)
    }

    /// "1240" (RPM value only; caller adds the unit label).
    static func rpm(_ v: Double) -> String {
        String(format: "%.0f", max(0, v))
    }

    /// "3:04 PM" — used by the "as of" footer.
    static func time(_ d: Date) -> String {
        clock.string(from: d)
    }
}
