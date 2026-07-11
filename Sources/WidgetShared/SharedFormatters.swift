import Foundation

/// Formatting helpers shared by the app and the widget extension.
/// UI-thread use only (formatters aren't thread-safe).
public enum SharedFmt {
    private static let fileBytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file // decimal units, like Finder
        f.allowsNonnumericFormatting = false // "0 KB", not "Zero KB"
        return f
    }()

    /// "1.14 TB", "482.3 MB" — decimal units.
    public static func bytes(_ v: UInt64) -> String {
        fileBytes.string(fromByteCount: Int64(clamping: v))
    }

    /// Transfer rate: "0 B/s", "1.2 MB/s".
    public static func rate(_ bytesPerSec: Double) -> String {
        let v = max(0, bytesPerSec)
        if v < 1000 { return String(format: "%.0f B/s", v) }
        let kb = v / 1000
        if kb < 1000 { return String(format: kb < 10 ? "%.1f KB/s" : "%.0f KB/s", kb) }
        let mb = kb / 1000
        if mb < 1000 { return String(format: mb < 10 ? "%.1f MB/s" : "%.0f MB/s", mb) }
        return String(format: "%.2f GB/s", mb / 1000)
    }

    /// 0...1 fraction → "37%".
    public static func percent(_ fraction: Double) -> String {
        String(format: "%.0f%%", min(max(fraction, 0), 1) * 100)
    }
}
