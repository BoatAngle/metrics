import Foundation
import Darwin

/// Samples per-process CPU/memory (via /bin/ps) plus per-pid disk throughput
/// and energy (via proc_pid_rusage byte/energy counters) and, where the
/// platform exposes it, GPU utilization. Runs on the sampler queue every 10th
/// tick (~10s at the default 1s interval; the interval is user-configurable),
/// guarded by a 2s watchdog on the ps subprocess.
final class ProcessSampler {

    /// Cumulative rusage counters from the previous sample, per pid, plus the
    /// wall-clock instant they were read — the deltas over elapsed time give
    /// live disk/energy rates. Rebuilt each pass, which also prunes dead pids.
    private struct Cumulative {
        var diskRead: UInt64
        var diskWritten: UInt64
        var energyNJ: UInt64
    }
    private var previous: [Int32: Cumulative] = [:]
    private var previousTime: Date?

    private let gpuSampler = ProcessGPUSampler()

    /// How many rows to keep per column in the bounded working set.
    private static let perColumnTop = 8

    func sample() -> ProcessesSnapshot {
        guard let output = runPS() else { return .empty }

        let now = Date()
        let elapsed = previousTime.map { now.timeIntervalSince($0) } ?? 0
        previousTime = now

        let gpuByPID = gpuSampler.sample()
        let gpuAvailable = !gpuByPID.isEmpty

        var samples: [ProcessSample] = []
        samples.reserveCapacity(700)
        var newPrev: [Int32: Cumulative] = [:]
        newPrev.reserveCapacity(700)

        for line in output.split(separator: "\n") {
            guard var s = Self.parseLine(line) else { continue }

            if let cum = Self.rusage(for: s.pid) {
                newPrev[s.pid] = cum
                if elapsed > 0, let prev = previous[s.pid] {
                    s.diskReadBytesPerSec = rate(cum.diskRead, prev.diskRead, over: elapsed)
                    s.diskWriteBytesPerSec = rate(cum.diskWritten, prev.diskWritten, over: elapsed)
                    // ri_energy_nj is nanojoules; delta/elapsed → nW → W.
                    s.energyWatts = rate(cum.energyNJ, prev.energyNJ, over: elapsed) / 1_000_000_000
                }
            }
            if let gpu = gpuByPID[s.pid] { s.gpuPercent = gpu }
            samples.append(s)
        }

        previous = newPrev
        guard !samples.isEmpty else { return .empty }

        return ProcessesSnapshot(processes: Self.boundedWorkingSet(samples, gpuAvailable: gpuAvailable),
                                 gpuAvailable: gpuAvailable)
    }

    // MARK: - ps subprocess

    private func runPS() -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        // -c: bare executable name in comm; "=" suppresses headers.
        task.arguments = ["-Aceo", "pid=,pcpu=,rss=,comm="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do { try task.run() } catch { return nil }

        let watchdog = DispatchWorkItem {
            if task.isRunning { task.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2, execute: watchdog)

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        watchdog.cancel()

        guard task.terminationReason == .exit, task.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Parses one `pid pcpu rss comm` line into a partial sample.
    private static func parseLine(_ line: Substring) -> ProcessSample? {
        var rest = line.drop(while: { $0 == " " || $0 == "\t" })
        func takeField() -> Substring? {
            let field = rest.prefix(while: { $0 != " " && $0 != "\t" })
            guard !field.isEmpty else { return nil }
            rest = rest[field.endIndex...].drop(while: { $0 == " " || $0 == "\t" })
            return field
        }
        guard let pidField = takeField(),
              let cpuField = takeField(),
              let rssField = takeField(),
              let pid = Int32(pidField),
              let cpu = Double(cpuField),
              let rssKB = UInt64(rssField) else { return nil }

        var name = rest
        while let last = name.last, last == " " || last == "\t" || last == "\r" {
            name = name.dropLast()
        }
        guard !name.isEmpty, name != "ps" else { return nil }

        return ProcessSample(pid: pid, name: String(name),
                             cpuPercent: cpu, memoryBytes: rssKB &* 1024)
    }

    private func rate(_ current: UInt64, _ prev: UInt64, over seconds: TimeInterval) -> Double {
        guard current >= prev, seconds > 0 else { return 0 }  // guard counter resets
        return Double(current - prev) / seconds
    }

    // MARK: - proc_pid_rusage

    /// Cumulative disk-io / energy counters for a pid, or nil when unreadable
    /// (rusage is denied for processes owned by other users without root).
    private static func rusage(for pid: Int32) -> Cumulative? {
        var info = rusage_info_v6()
        let rc = withUnsafeMutablePointer(to: &info) { p -> Int32 in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V6, rebound)
            }
        }
        guard rc == 0 else { return nil }
        return Cumulative(diskRead: info.ri_diskio_bytesread,
                          diskWritten: info.ri_diskio_byteswritten,
                          energyNJ: info.ri_energy_nj)
    }

    // MARK: - Bounded working set

    /// Keeps the union of the top rows across every sort column so the card can
    /// rank by any column with correct top-N results, without shipping the full
    /// ~600-row table into the observable snapshot.
    private static func boundedWorkingSet(_ all: [ProcessSample], gpuAvailable: Bool) -> [ProcessSample] {
        var picked: [Int32: ProcessSample] = [:]
        var keys: [ProcessSortKey] = [.cpu, .memory, .disk, .energy]
        if gpuAvailable { keys.append(.gpu) }
        for key in keys {
            for p in all.sorted(by: { $0.metric(for: key) > $1.metric(for: key) }).prefix(perColumnTop) {
                picked[p.pid] = p
            }
        }
        return Array(picked.values)
    }
}
