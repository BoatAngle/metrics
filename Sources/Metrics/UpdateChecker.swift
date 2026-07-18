import AppKit
import Foundation
import Observation

/// In-app update check (v2.1). Users who downloaded an old build have no way
/// to learn a fix exists, so once a day Metrics asks the public GitHub API for
/// the latest release and compares it to the running version. Privacy rules:
///   • one anonymous GET, an ephemeral session, nothing about the user is sent;
///   • at most one successful check per ~20 h, re-evaluated by a coarse 6 h
///     timer (never per-second — energy discipline);
///   • the whole feature can be switched off in Settings → About;
///   • every failure is silent — no retries, no logging spam; the next
///     scheduled pass simply tries again.
///
/// The last successful result is persisted in `SettingsStore`, so the "update
/// available" banner survives relaunch without a fresh network hit. When the
/// running version is unknown (a bare `.build/debug/Metrics` executable has no
/// Info.plist), the checker treats itself as unavailable and never reports an
/// update — and never touches the network.
@Observable @MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()

    /// Human-visitable fallback when no per-release URL is known yet.
    static let releasesPage = URL(string: "https://github.com/BoatAngle/metrics/releases/latest")!
    private static let apiURL = URL(string: "https://api.github.com/repos/BoatAngle/metrics/releases/latest")!

    /// First automatic pass runs shortly after launch — never blocking it.
    private static let firstCheckDelay: TimeInterval = 15
    /// The coarse re-evaluation cadence. Each pass is a cheap date compare;
    /// the network is only touched when the 20 h gate below has expired.
    private static let evaluateInterval: TimeInterval = 6 * 3600
    /// Minimum age of the last successful check before the network is hit
    /// again — "once a day" with slack so the check drifts around the clock
    /// instead of landing at the exact same second every 24 h.
    private static let minimumCheckGap: TimeInterval = 20 * 3600
    private static let requestTimeout: TimeInterval = 10

    /// CFBundleShortVersionString of the running app; nil for a bare executable
    /// (no bundle Info.plist), in which case no update is ever reported.
    let currentVersion: String?

    /// True when the last known release is strictly newer than the running
    /// version. Views (settings status line, dashboard banner) observe this.
    private(set) var updateAvailable = false
    /// True while a fetch is in flight (drives the "Checking…" status line).
    private(set) var checking = false

    @ObservationIgnored private var firstTimer: Timer?
    @ObservationIgnored private var periodicTimer: Timer?

    private init() {
        currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        recomputeAvailability()
    }

    // MARK: Persisted state (lives in SettingsStore)

    var enabled: Bool {
        get { SettingsStore.shared.updateChecksEnabled }
        set { SettingsStore.shared.updateChecksEnabled = newValue }
    }
    var lastCheckDate: Date? { SettingsStore.shared.lastUpdateCheckDate }
    var latestKnownVersion: String? { SettingsStore.shared.lastKnownLatestVersion }
    var releaseURL: URL? { SettingsStore.shared.lastKnownReleaseURL.flatMap(URL.init(string:)) }

    // MARK: Lifecycle

    /// Arms the two timers: a one-shot first pass ~15 s after launch and the
    /// coarse 6 h re-evaluation. Launch itself is never delayed — this returns
    /// immediately and all work happens on later run-loop turns.
    func start() {
        guard currentVersion != nil else { return }   // bare executable — never check
        guard firstTimer == nil && periodicTimer == nil else { return }
        firstTimer = Timer.scheduledTimer(withTimeInterval: Self.firstCheckDelay,
                                          repeats: false) { _ in
            Task { @MainActor in await UpdateChecker.shared.scheduledPass() }
        }
        let periodic = Timer.scheduledTimer(withTimeInterval: Self.evaluateInterval,
                                            repeats: true) { _ in
            Task { @MainActor in await UpdateChecker.shared.scheduledPass() }
        }
        periodic.tolerance = 15 * 60   // hours-scale timer; let the system coalesce
        periodicTimer = periodic
    }

    /// One scheduled pass: a date compare, and a network hit only when the
    /// feature is on and the last successful check is stale.
    private func scheduledPass() async {
        guard enabled else { return }
        if let last = lastCheckDate, Date().timeIntervalSince(last) < Self.minimumCheckGap {
            return
        }
        await performCheck()
    }

    // MARK: Manual check

    enum CheckOutcome {
        case updateAvailable   // a newer release is known (fresh or just fetched)
        case upToDate          // fetch succeeded; nothing newer
        case failed            // offline / API error — silent, try again later
        case unavailable       // no bundle version (bare executable)
    }

    /// User-initiated check ("Check Now" button, status-item menu). Always hits
    /// the network — an explicit ask bypasses the once-a-day gate and the
    /// enabled toggle (which governs only the automatic daily check).
    @discardableResult
    func checkNow() async -> CheckOutcome {
        guard currentVersion != nil else { return .unavailable }
        guard await performCheck() else { return .failed }
        return updateAvailable ? .updateAvailable : .upToDate
    }

    /// The status-item menu flavor: check, then open the release page if newer,
    /// else tell the user where they stand with a plain NSAlert.
    func checkNowInteractively() async {
        switch await checkNow() {
        case .updateAvailable:
            openReleasePage()
        case .upToDate:
            presentAlert(title: "You're up to date (\(currentVersion ?? "?"))",
                         text: "Metrics \(latestKnownVersion ?? currentVersion ?? "") is the newest release.")
        case .failed:
            presentAlert(title: "Couldn't check for updates",
                         text: "GitHub couldn't be reached. Check your connection and try again.")
        case .unavailable:
            presentAlert(title: "Updates unavailable",
                         text: "This copy of Metrics is running outside an app bundle, so its version is unknown.")
        }
    }

    /// Opens the newest release's page (falls back to the releases list).
    func openReleasePage() {
        NSWorkspace.shared.open(releaseURL ?? Self.releasesPage)
    }

    private func presentAlert(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = .informational
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: The check itself

    /// One GET; on success persists the result and recomputes availability.
    /// Every failure path returns false with no side effects (and no noise).
    @discardableResult
    private func performCheck() async -> Bool {
        guard currentVersion != nil, !checking else { return false }
        checking = true
        defer { checking = false }
        guard let latest = await Self.fetchLatestRelease() else { return false }
        let settings = SettingsStore.shared
        settings.lastUpdateCheckDate = Date()
        settings.lastKnownLatestVersion = latest.version
        settings.lastKnownReleaseURL = latest.url.absoluteString
        recomputeAvailability()
        return true
    }

    /// GET api.github.com/…/releases/latest via an ephemeral session (no
    /// cookies, no cache, nothing persisted). nil on any failure.
    private static func fetchLatestRelease() async -> (version: String, url: URL)? {
        var request = URLRequest(url: apiURL)
        request.timeoutInterval = requestTimeout
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = requestTimeout * 2
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = object["tag_name"] as? String,
                  let page = (object["html_url"] as? String).flatMap(URL.init(string:))
            else { return nil }
            return (strippedVersion(tag), page)
        } catch {
            return nil   // offline, timeout, TLS, DNS — all silent by design
        }
    }

    private func recomputeAvailability() {
        guard let current = currentVersion, let latest = latestKnownVersion else {
            updateAvailable = false
            return
        }
        updateAvailable = Self.isNewer(remote: latest, than: current)
    }

    // MARK: Version comparison (pure — exercised by --dump)

    /// "v2.1.0" → "2.1.0"; other tags pass through for `parse` to judge.
    static func strippedVersion(_ tag: String) -> String {
        var t = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("v") || t.hasPrefix("V") { t.removeFirst() }
        return t
    }

    /// Dotted-numeric components, nil for anything malformed ("nightly",
    /// "2.1.0-beta", ""). Malformed never compares as newer.
    static func parse(_ version: String) -> [Int]? {
        let stripped = strippedVersion(version)
        guard !stripped.isEmpty else { return nil }
        var numbers: [Int] = []
        for part in stripped.split(separator: ".", omittingEmptySubsequences: false) {
            guard let n = Int(part), n >= 0 else { return nil }
            numbers.append(n)
        }
        return numbers
    }

    /// Numeric dotted compare; missing components count as 0 ("2.1" == "2.1.0").
    /// False whenever either side is malformed — never a spurious banner.
    static func isNewer(remote: String, than current: String) -> Bool {
        guard let r = parse(remote), let c = parse(current) else { return false }
        for i in 0..<max(r.count, c.count) {
            let rv = i < r.count ? r[i] : 0
            let cv = i < c.count ? c[i] : 0
            if rv != cv { return rv > cv }
        }
        return false
    }
}
