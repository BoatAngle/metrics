import Foundation
import Observation
import SMCCore

/// Battery charge-limit control (AlDente-style) via the SMC key "CHWA"
/// (ui8: 1 = cap charging at ~80%, 0 = charge to full). Reads happen
/// in-process through SMCCore; writes go through the same setuid-root helper
/// FanControl installs (`chargelimit <0|1>`), so the two share the install /
/// version state — a current helper drives both fans and the charge limit.
///
/// Nothing is restored on quit: the limit is meant to persist in hardware.
/// CHWA is re-read at launch so the UI reflects whatever the SMC actually
/// holds (whether Metrics, AlDente, or a previous run last set it).
@Observable @MainActor
final class BatteryChargeControl {
    static let shared = BatteryChargeControl()

    /// True when this Mac's SMC exposes CHWA. When false the whole feature is
    /// hidden — the toggle would write a key that doesn't exist.
    let supported: Bool

    /// The user's persistent intent: keep charging capped at ~80%. Seeded from
    /// CHWA at launch and toggled by the card.
    private(set) var limitEnabled = false
    /// A one-time full charge requested while the limit is on: CHWA is cleared
    /// until the pack hits ~99% or the charger is unplugged, then re-applied.
    private(set) var chargingToFull = false

    private(set) var busy = false
    private(set) var lastError: String? = nil

    /// Reused for CHWA reads. Writes never touch this — the helper owns those.
    @ObservationIgnored private let smc: SMCConnection?

    /// Ready to issue charge-limit writes: the shared helper is installed and
    /// current (the v3+ helper is the one that understands `chargelimit`).
    var canControl: Bool { FanControl.shared.canControlFans }

    private init() {
        let connection = SMCConnection()
        smc = connection
        supported = connection?.keyInfo("CHWA") != nil
        if supported {
            limitEnabled = Self.readCHWA(connection) == 1
        }
    }

    // MARK: - Reads

    private static func readCHWA(_ smc: SMCConnection?) -> Int? {
        guard let value = smc?.readKey("CHWA")?.doubleValue else { return nil }
        return value >= 0.5 ? 1 : 0
    }

    /// Re-reads CHWA from the SMC and adopts it as the current intent, unless a
    /// one-time full charge is in flight (then CHWA is deliberately 0 and must
    /// not clobber the user's "keep limiting" intent).
    func reconcileFromHardware() {
        guard supported, !chargingToFull, let chwa = Self.readCHWA(smc) else { return }
        limitEnabled = chwa == 1
    }

    // MARK: - Writes

    /// Turn the 80% limit on or off. Cancels any in-flight one-time full charge.
    func setLimit(_ enabled: Bool) {
        guard supported else { return }
        guard canControl else {
            lastError = "Battery helper not installed or outdated."
            return
        }
        limitEnabled = enabled
        chargingToFull = false
        Task { await applyDesired() }
    }

    /// Clear the limit for a single full charge. Only meaningful while limited;
    /// the engine loop re-applies the limit at ~99% or on unplug.
    func chargeToFullOnce() {
        guard supported, canControl, limitEnabled, !chargingToFull else { return }
        chargingToFull = true
        Task { await applyDesired() }
    }

    /// Called from the engine loop on each battery sample. Ends a one-time full
    /// charge once the pack is essentially full or the charger disconnects,
    /// restoring the 80% cap.
    func evaluateAutoReenable(percent: Double, isPluggedIn: Bool) {
        guard chargingToFull else { return }
        guard percent >= 99 || !isPluggedIn else { return }
        chargingToFull = false
        Task { await applyDesired() }
    }

    /// CHWA value the current state calls for: capped only while the limit is on
    /// and no one-time full charge is running.
    private var desiredCHWA: Int { (limitEnabled && !chargingToFull) ? 1 : 0 }

    private func applyDesired() async {
        guard supported, canControl else { return }
        guard !busy else { return }
        busy = true
        lastError = nil
        defer { busy = false }

        let target = desiredCHWA
        let result = await Self.run(FanControl.helperPath, ["chargelimit", String(target)])
        if result.status != 0 {
            lastError = Self.failureText(result, fallback: "Could not change the charge limit.")
        }
        // Reflect whatever actually stuck (best-effort; a failed write leaves
        // the hardware unchanged, and this re-syncs the UI to it).
        reconcileFromHardware()
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
}
