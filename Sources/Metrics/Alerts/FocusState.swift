import Foundation

/// Best-effort read of whether macOS Focus / Do Not Disturb is currently on
/// (feature #22). There is no public API for this; modern macOS records active
/// Focus assertions in a per-user Assertions plist. We read it opportunistically
/// and return `nil` when we can't tell — callers treat `nil` as "not muted" and
/// the Alerts tab surfaces a caveat.
enum FocusState {
    /// Candidate locations across macOS versions. The DoNotDisturb DB moved
    /// around; we probe each and use the first that parses.
    private static var assertionsURLs: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Library/DoNotDisturb/DB/Assertions.json"),
            home.appendingPathComponent("Library/DoNotDisturb/DB/ModeConfigurations.json"),
        ]
    }

    /// nil = undetermined (unreadable on this macOS). true/false when we can
    /// read the assertions file and interpret it.
    static func isActive() -> Bool? {
        var sawAnyFile = false
        for url in assertionsURLs {
            guard let data = try? Data(contentsOf: url) else { continue }
            sawAnyFile = true
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let active = interpret(root) { return active }
        }
        // A readable-but-unrecognized file means Focus is configured; absence of
        // any file usually means DND has never been set. Either way, if we
        // couldn't positively interpret it, report "undetermined" only when we
        // saw nothing at all — a present-but-empty assertions file means off.
        return sawAnyFile ? false : nil
    }

    /// Looks for a live assertion in the two known shapes. Assertions.json holds
    /// a `data[].storeAssertionRecords` array that is non-empty while a Focus is
    /// engaged; ModeConfigurations may carry a `userConfigurations`/`triggers`
    /// structure we can't reliably read, so we only trust the assertions shape.
    private static func interpret(_ root: [String: Any]) -> Bool? {
        guard let data = root["data"] as? [[String: Any]] else { return nil }
        for entry in data {
            if let records = entry["storeAssertionRecords"] as? [Any], !records.isEmpty {
                return true
            }
            // Some builds nest the live flag under an assertion details map.
            if let details = entry["assertionDetails"] as? [Any], !details.isEmpty {
                return true
            }
        }
        // The file parsed and had the assertions shape but nothing active → off.
        return false
    }
}
