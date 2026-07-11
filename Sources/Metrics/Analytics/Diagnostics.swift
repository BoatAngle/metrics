import Foundation

/// Verdict for one diagnostic check.
enum DiagnosticStatus: Sendable {
    case pass      // green
    case warn      // amber
    case fail      // red
    case info      // neutral — not applicable / nothing to test
}

/// One row in the diagnostics report: a subsystem, its verdict, and a
/// one-line human explanation.
struct DiagnosticRow: Identifiable, Sendable {
    var title: String
    var status: DiagnosticStatus
    var detail: String
    var id: String { title }
}

struct DiagnosticReport: Sendable {
    var rows: [DiagnosticRow]
    var date: Date
    /// Worst status present, for a headline summary.
    var overall: DiagnosticStatus {
        if rows.contains(where: { $0.status == .fail }) { return .fail }
        if rows.contains(where: { $0.status == .warn }) { return .warn }
        return .pass
    }
}

/// Runs a suite of hardware self-checks over the live snapshots plus a couple
/// of off-main probes (fan RPM history, `pmset` shutdown log). Read-only and
/// safe to run any time (feature #10).
enum Diagnostics {

    @MainActor
    static func run(engine: MetricsEngine, settings: SettingsStore,
                    now: Date = Date()) async -> DiagnosticReport {
        var rows: [DiagnosticRow] = []
        rows.append(await fansRow(engine: engine, useFahrenheit: settings.useFahrenheit, now: now))
        rows.append(sensorsRow(engine: engine, useFahrenheit: settings.useFahrenheit))
        rows.append(batteryRow(engine: engine))
        rows.append(await shutdownRow(now: now))
        rows.append(diskRow(engine: engine))
        rows.append(helperRow(engine: engine))
        return DiagnosticReport(rows: rows, date: now)
    }

    // MARK: - Fans

    @MainActor
    private static func fansRow(engine: MetricsEngine, useFahrenheit: Bool, now: Date) async -> DiagnosticRow {
        let fans = engine.sensors.fans
        guard !fans.isEmpty else {
            return DiagnosticRow(title: "Fans", status: .info,
                                 detail: "No fans detected — this Mac is passively cooled.")
        }
        let spinning = fans.contains { $0.rpm > 0 }
        // A fan reading 0 while another spins is the classic dead-fan signature.
        if let dead = fans.first(where: { $0.rpm <= 0 }), spinning {
            return DiagnosticRow(title: "Fans", status: .fail,
                                 detail: "\(dead.name) reads 0 RPM while other fans are spinning — it may have failed.")
        }
        // Out-of-range readings (below min or above max) point to a bad reading.
        if let bad = fans.first(where: { fan in
            guard let mn = fan.minRPM, let mx = fan.maxRPM, mx > mn else { return false }
            return fan.rpm < mn - 50 || fan.rpm > mx + 50
        }) {
            return DiagnosticRow(title: "Fans", status: .warn,
                                 detail: "\(bad.name) reports \(Int(bad.rpm)) RPM, outside its rated range.")
        }
        // Stuck check: RPM perfectly flat over 20 min while the machine is hot.
        let hotspot = engine.sensors.hotspotC ?? 0
        if hotspot > 80 {
            for fan in fans where fan.rpm > 0 {
                if let agg = await HistoryStore.shared.aggregate(
                    metric: HistoryMetric.fanRPM(fan.id), since: now.addingTimeInterval(-1200), until: now),
                   agg.count >= 20, agg.max == agg.min {
                    return DiagnosticRow(title: "Fans", status: .warn,
                        detail: "\(fan.name) held \(Int(fan.rpm)) RPM for 20 min despite a \(Fmt.temp(hotspot, fahrenheit: useFahrenheit)) hotspot — may be stuck.")
                }
            }
        }
        let names = fans.map { "\($0.name) \(Int($0.rpm)) RPM" }.joined(separator: ", ")
        return DiagnosticRow(title: "Fans", status: .pass,
                             detail: "\(fans.count) fan\(fans.count == 1 ? "" : "s") spinning normally (\(names)).")
    }

    // MARK: - Sensors

    @MainActor
    private static func sensorsRow(engine: MetricsEngine, useFahrenheit: Bool) -> DiagnosticRow {
        let s = engine.sensors
        guard s.available else {
            return DiagnosticRow(title: "Sensors", status: .fail,
                                 detail: "SMC temperature sensors are not readable on this Mac.")
        }
        var readings: [(String, Double)] = []
        if let c = s.cpuTempC { readings.append(("CPU", c)) }
        if let g = s.gpuTempC { readings.append(("GPU", g)) }
        for t in s.extraTemps { readings.append((t.name, t.celsius)) }

        let implausible = readings.filter { $0.1 <= 0 || $0.1 >= 110 }
        if let bad = implausible.first {
            return DiagnosticRow(title: "Sensors", status: .warn,
                detail: "\(bad.0) reads \(Fmt.temp(bad.1, fahrenheit: useFahrenheit)) — an implausible value; the sensor may be faulty.")
        }
        // Heuristic floor: Apple Silicon Macs expose many probes. A near-empty
        // set usually means limited SMC access rather than a healthy read.
        if readings.count < 3 {
            return DiagnosticRow(title: "Sensors", status: .warn,
                detail: "Only \(readings.count) temperature sensor\(readings.count == 1 ? "" : "s") reporting — fewer than expected.")
        }
        return DiagnosticRow(title: "Sensors", status: .pass,
            detail: "\(readings.count) temperature sensors reporting, all within plausible range.")
    }

    // MARK: - Battery

    @MainActor
    private static func batteryRow(engine: MetricsEngine) -> DiagnosticRow {
        let b = engine.battery
        guard b.hasBattery else {
            return DiagnosticRow(title: "Battery", status: .info,
                                 detail: "No battery — this is a desktop Mac.")
        }
        var issues: [String] = []
        if let health = b.healthPercent, health < 80 {
            issues.append("health is \(Int(health.rounded()))% (Apple's service threshold is 80%)")
        }
        if let cycles = b.cycleCount, cycles > 1000 {
            issues.append("\(cycles) charge cycles is high")
        }
        if !issues.isEmpty {
            return DiagnosticRow(title: "Battery", status: .warn,
                                 detail: issues.joined(separator: "; ").capitalizingFirst + ".")
        }
        let health = b.healthPercent.map { "\(Int($0.rounded()))% health" } ?? "health unavailable"
        let cycles = b.cycleCount.map { ", \($0) cycles" } ?? ""
        return DiagnosticRow(title: "Battery", status: .pass, detail: "\(health)\(cycles).")
    }

    // MARK: - Abnormal shutdowns (pmset -g log)

    private static func shutdownRow(now: Date) async -> DiagnosticRow {
        let log = await runProcess("/usr/bin/pmset", ["-g", "log"])
        guard !log.isEmpty else {
            return DiagnosticRow(title: "Power / Shutdowns", status: .info,
                                 detail: "Shutdown history is unavailable (pmset returned nothing).")
        }
        let cutoff = now.addingTimeInterval(-30 * 86400)
        var abnormal: [(date: Date?, code: Int)] = []
        for line in log.split(separator: "\n") where line.contains("Shutdown Cause") {
            guard let code = trailingInt(after: "Shutdown Cause", in: String(line)) else { continue }
            let date = leadingDate(in: String(line))
            // Codes < 0 are abnormal (thermal, SMC, forced power-off). 5 = clean.
            guard code < 0 else { continue }
            if let date, date < cutoff { continue }   // keep undated entries (recent logs)
            abnormal.append((date, code))
        }
        guard !abnormal.isEmpty else {
            return DiagnosticRow(title: "Power / Shutdowns", status: .pass,
                                 detail: "No abnormal shutdowns recorded in the last 30 days.")
        }
        let recent = abnormal.max { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
        let when = recent?.date.map { " on \(Fmt.date($0))" } ?? ""
        let status: DiagnosticStatus = abnormal.count >= 2 ? .fail : .warn
        return DiagnosticRow(title: "Power / Shutdowns", status: status,
            detail: "\(abnormal.count) abnormal shutdown\(abnormal.count == 1 ? "" : "s") in 30 days (latest cause \(recent?.code ?? 0)\(when)).")
    }

    // MARK: - Disk health

    @MainActor
    private static func diskRow(engine: MetricsEngine) -> DiagnosticRow {
        let drives = engine.driveHealth.drives
        guard !drives.isEmpty else {
            return DiagnosticRow(title: "Disk Health", status: .info,
                                 detail: "SMART/NVMe health data isn't available for this drive.")
        }
        if let failing = drives.first(where: { $0.status == .failing }) {
            return DiagnosticRow(title: "Disk Health", status: .fail,
                                 detail: "\(failing.name) reports a SMART failure — back up and have it checked.")
        }
        if let warning = drives.first(where: { $0.status == .warning }) {
            let wear = warning.wearPercent.map { " (\(Int($0.rounded()))% wear)" } ?? ""
            return DiagnosticRow(title: "Disk Health", status: .warn,
                                 detail: "\(warning.name) is nearing its endurance limit\(wear).")
        }
        let names = drives.map(\.name).joined(separator: ", ")
        return DiagnosticRow(title: "Disk Health", status: .pass,
                             detail: "SMART status healthy (\(names)).")
    }

    // MARK: - Helper

    @MainActor
    private static func helperRow(engine: MetricsEngine) -> DiagnosticRow {
        guard !engine.sensors.fans.isEmpty else {
            return DiagnosticRow(title: "Fan Helper", status: .info,
                                 detail: "No controllable fans, so the privileged helper isn't needed.")
        }
        let fc = FanControl.shared
        if fc.helperInstalled && !fc.helperNeedsUpdate {
            return DiagnosticRow(title: "Fan Helper", status: .pass,
                                 detail: "Privileged fan helper is installed and current.")
        }
        if fc.helperNeedsUpdate {
            return DiagnosticRow(title: "Fan Helper", status: .warn,
                                 detail: "Fan helper is installed but outdated — reinstall it from Settings › Fans.")
        }
        return DiagnosticRow(title: "Fan Helper", status: .info,
                             detail: "Fan helper isn't installed, so fan-speed control is disabled (optional).")
    }

    // MARK: - Parsing helpers

    /// First integer following `keyword` in `line` (skips ":" and whitespace).
    private static func trailingInt(after keyword: String, in line: String) -> Int? {
        guard let range = line.range(of: keyword) else { return nil }
        var rest = line[range.upperBound...].drop { $0 == ":" || $0 == " " || $0 == "\t" }
        var digits = ""
        if rest.first == "-" { digits.append("-"); rest = rest.dropFirst() }
        for ch in rest { if ch.isNumber { digits.append(ch) } else { break } }
        return Int(digits)
    }

    /// Parses the "yyyy-MM-dd HH:mm:ss ±ZZZZ" stamp pmset puts at line start.
    private static func leadingDate(in line: String) -> Date? {
        guard line.count >= 25 else { return nil }
        let prefix = String(line.prefix(25))
        return pmsetDate.date(from: prefix)
    }

    private static let pmsetDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return f
    }()

    /// Captures a process's stdout. Returns "" on any launch failure.
    private static func runProcess(_ path: String, _ arguments: [String]) async -> String {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
            }
            do { try process.run() }
            catch {
                process.terminationHandler = nil
                continuation.resume(returning: "")
            }
        }
    }
}

private extension String {
    var capitalizingFirst: String {
        isEmpty ? self : prefix(1).uppercased() + dropFirst()
    }
}
