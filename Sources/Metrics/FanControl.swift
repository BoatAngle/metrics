import Foundation
import Observation

/// Talks to the setuid-root helper that performs privileged SMC fan writes.
/// Reading fan state stays in SensorsSampler; this only installs the helper
/// and issues set/auto commands.
@Observable @MainActor
final class FanControl {
    static let shared = FanControl()

    static let helperPath = "/Library/Application Support/Metrics/metrics-fan-helper"
    /// Must match `helperVersion` in the helper's main.swift.
    static let expectedHelperVersion = 3

    private(set) var helperInstalled = false
    /// Installed but older than the app expects — offer a reinstall.
    private(set) var helperNeedsUpdate = false
    private(set) var busy = false
    private(set) var lastError: String? = nil
    /// Fans currently under manual control this session.
    private(set) var manualFans: Set<Int> = []

    /// Ready to issue fan commands: installed and up to date.
    var canControlFans: Bool { helperInstalled && !helperNeedsUpdate }

    /// The mode actually in effect: falls back to .auto when the helper
    /// can't be driven.
    var effectiveMode: FanMode { canControlFans ? mode : .auto }

    /// Name of another fan-control app whose daemon is running, if any.
    private(set) var conflictingController: String? = nil

    @ObservationIgnored private var conflictTimer: Timer? = nil

    /// Check for third-party fan controllers, then keep re-checking every
    /// 30 s so the warning clears itself once the other app quits. Matches
    /// the GUI app by exact name — Macs Fan Control's root daemon lingers
    /// after quit but is inert without the app driving it.
    func detectConflicts() {
        runConflictCheck()
        guard conflictTimer == nil else { return }
        conflictTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in FanControl.shared.runConflictCheck() }
        }
    }

    private func runConflictCheck() {
        Task {
            let result = await Self.run("/usr/bin/pgrep", ["-x", "Macs Fan Control"])
            self.conflictingController = result.status == 0 ? "Macs Fan Control" : nil
        }
    }

    // MARK: - Curve mode state

    /// Last temperature the curve loop acted on.
    private(set) var drivingTempC: Double? = nil
    /// Fan index -> last target RPM written by the curve loop.
    private(set) var currentTargets: [Int: Double] = [:]

    private var curveTimer: Timer? = nil
    /// True once the curve loop has successfully written at least one fan.
    private var curveEngaged = false
    /// Prevents overlapping ticks if helper writes ever outlast the interval.
    private var curveTickRunning = false
    private var consecutiveMisses = 0
    private var consecutiveFailedTicks = 0

    private static let curveInterval: TimeInterval = 5
    /// Skip helper writes when the new target is within this of the last one.
    private static let curveDeadbandRPM: Double = 100

    /// How Metrics drives the fans. Setting this persists the choice and
    /// engages or disengages the temperature-driven curve loop.
    var mode: FanMode {
        get { SettingsStore.shared.fanMode }
        set {
            let old = SettingsStore.shared.fanMode
            guard newValue != old else { return }
            SettingsStore.shared.fanMode = newValue

            switch newValue {
            case .auto:
                stopCurveLoop()
                let hadControl = curveEngaged || !manualFans.isEmpty
                clearCurveState()
                manualFans.removeAll()
                if hadControl {
                    Task { await Self.sendAutoAll() }
                }
            case .quiet, .balanced, .performance:
                guard canControlFans else {
                    lastError = "Install the fan helper before choosing a fan curve."
                    SettingsStore.shared.fanMode = .auto
                    return
                }
                lastError = nil
                startCurveLoop()
            case .manual:
                stopCurveLoop()
                if curveEngaged {
                    Task { await Self.sendAutoAll() }
                }
                clearCurveState()
            }
        }
    }

    /// Called from the app delegate once the engine is running: re-engage a
    /// persisted curve mode. If the helper is missing or outdated, quietly
    /// fall back to auto — no error banner at launch.
    func engagePersistedModeAtLaunch() {
        guard SettingsStore.shared.fanMode.isCurve else { return }
        guard canControlFans else {
            SettingsStore.shared.fanMode = .auto
            return
        }
        startCurveLoop()
    }

    private init() {
        refreshHelperStatus()
    }

    func refreshHelperStatus() {
        var st = stat()
        let installed = stat(Self.helperPath, &st) == 0
            && st.st_uid == 0
            && (st.st_mode & mode_t(S_ISUID)) != 0
        helperInstalled = installed
        guard installed else {
            helperNeedsUpdate = false
            return
        }
        // The version check runs the helper as a child process — do it off
        // the main actor so init and the Fans UI never block on its exit.
        Task { @MainActor in
            let version = await Self.installedHelperVersion()
            self.helperNeedsUpdate = self.helperInstalled && version != Self.expectedHelperVersion
        }
    }

    /// Runs the installed helper's `version` command (no root needed).
    /// nil when absent or from a build predating versioning.
    private nonisolated static func installedHelperVersion() async -> Int? {
        let result = await run(helperPath, ["version"])
        guard result.status == 0 else { return nil }
        return Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Install

    func installHelper() async {
        guard !busy else { return }
        busy = true
        lastError = nil
        defer { busy = false }

        guard let bundled = Bundle.main.url(forResource: "metrics-fan-helper", withExtension: nil) else {
            lastError = "Bundled helper not found — rebuild the app bundle."
            return
        }
        let dest = Self.helperPath
        let dir = (dest as NSString).deletingLastPathComponent
        let shell = "mkdir -p \(Self.shellQuote(dir))"
            + " && cp -f \(Self.shellQuote(bundled.path)) \(Self.shellQuote(dest))"
            + " && chown root:wheel \(Self.shellQuote(dest))"
            + " && chmod 4755 \(Self.shellQuote(dest))"
        let script = "do shell script \"\(Self.appleScriptQuote(shell))\" with administrator privileges"

        let result = await Self.run("/usr/bin/osascript", ["-e", script])
        if result.status != 0 {
            let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if err.contains("-128") {
                lastError = "Installation cancelled."
            } else {
                lastError = err.isEmpty ? "Installation failed (exit \(result.status))." : err
            }
        }
        refreshHelperStatus()
    }

    // MARK: - Fan commands

    func setManual(fan index: Int, rpm: Double) async {
        guard canControlFans else {
            lastError = "Helper not installed or outdated."
            return
        }
        guard !busy else { return }
        busy = true
        lastError = nil
        defer { busy = false }

        let result = await Self.run(Self.helperPath, ["set", String(index), String(Int(rpm.rounded()))])
        if result.status == 0 {
            manualFans.insert(index)
        } else {
            lastError = Self.failureText(result, fallback: "Could not set fan speed.")
        }
    }

    /// Called from applicationWillTerminate — must be synchronous.
    func restoreAllAutoOnQuit() {
        curveTimer?.invalidate()
        curveTimer = nil
        guard helperInstalled, !manualFans.isEmpty || curveEngaged else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.helperPath)
        process.arguments = ["auto", "all"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return }
        process.waitUntilExit()
        manualFans.removeAll()
        curveEngaged = false
        currentTargets.removeAll()
    }

    // MARK: - Curve loop

    private func startCurveLoop() {
        curveTimer?.invalidate()
        consecutiveMisses = 0
        consecutiveFailedTicks = 0
        let timer = Timer.scheduledTimer(withTimeInterval: Self.curveInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.curveTick()
            }
        }
        timer.tolerance = 1
        curveTimer = timer
        Task { await curveTick() }
    }

    private func stopCurveLoop() {
        curveTimer?.invalidate()
        curveTimer = nil
    }

    private func clearCurveState() {
        curveEngaged = false
        currentTargets.removeAll()
        drivingTempC = nil
        consecutiveMisses = 0
        consecutiveFailedTicks = 0
    }

    /// One pass of the curve: read the hottest CPU/GPU temperature and steer
    /// each fan toward the curve's target RPM. Never touches `busy` — that
    /// flag gates UI buttons only.
    private func curveTick() async {
        guard !curveTickRunning else { return }
        curveTickRunning = true
        defer { curveTickRunning = false }

        let mode = self.mode
        guard mode.isCurve, curveTimer != nil else { return }

        let sensors = MetricsEngine.shared.sensors
        // Hotspot, not average: Apple's controller chases the hottest sensor,
        // and averaging idle cores would make every curve undershoot Auto.
        guard let temp = sensors.hotspotC else {
            consecutiveMisses += 1
            if consecutiveMisses >= 3 {
                await revertToAuto(message: "Lost temperature readings — fans returned to automatic.")
            }
            return
        }
        consecutiveMisses = 0
        drivingTempC = temp

        guard let fraction = mode.targetFraction(tempC: temp) else { return }

        var tickFailure: String? = nil
        for fan in sensors.fans {
            guard let minRPM = fan.minRPM, let maxRPM = fan.maxRPM, minRPM < maxRPM else { continue }
            let target = (minRPM + fraction * (maxRPM - minRPM)).rounded()
            if let last = currentTargets[fan.id], abs(target - last) < Self.curveDeadbandRPM { continue }
            let result = await Self.run(Self.helperPath, ["set", String(fan.id), String(Int(target))])
            // The user may have left the curve mode while we awaited.
            guard self.mode.isCurve, curveTimer != nil else { return }
            if result.status == 0 {
                currentTargets[fan.id] = target
                curveEngaged = true
            } else {
                tickFailure = Self.failureText(result, fallback: "Could not set fan speed.")
            }
        }

        if let failure = tickFailure {
            consecutiveFailedTicks += 1
            lastError = failure
            if consecutiveFailedTicks >= 3 {
                await revertToAuto(message: failure)
            }
        } else {
            consecutiveFailedTicks = 0
        }
    }

    /// Stop driving the curve and hand the fans back to the SMC. Used when
    /// the loop loses its temperature source or the helper keeps failing.
    private func revertToAuto(message: String) async {
        stopCurveLoop()
        SettingsStore.shared.fanMode = .auto
        let wasEngaged = curveEngaged
        clearCurveState()
        lastError = message
        if wasEngaged {
            await Self.sendAutoAll()
            manualFans.removeAll()
        }
    }

    /// Returns every fan to Apple's automatic control, best-effort.
    /// (restoreAllAutoOnQuit keeps its own synchronous Process version —
    /// applicationWillTerminate cannot await.)
    private nonisolated static func sendAutoAll() async {
        _ = await run(helperPath, ["auto", "all"])
    }

    // MARK: - Process plumbing

    private struct CommandResult {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    private nonisolated static func run(_ path: String, _ arguments: [String]) async -> CommandResult {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            process.terminationHandler = { proc in
                let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                continuation.resume(returning: CommandResult(status: proc.terminationStatus, stdout: out, stderr: err))
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: CommandResult(status: -1, stdout: "", stderr: error.localizedDescription))
            }
        }
    }

    private static func failureText(_ result: CommandResult, fallback: String) -> String {
        let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return err.isEmpty ? "\(fallback) (exit \(result.status))" : err
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptQuote(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
