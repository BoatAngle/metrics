import Foundation

/// Samples per-process CPU/memory by shelling out to /bin/ps.
/// Runs on the sampler queue every 10th sample tick (~10s at the default
/// 1s interval; the interval is user-configurable); guarded by a 2s watchdog.
final class ProcessSampler {

    func sample() -> ProcessesSnapshot {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        // -c: bare executable name in comm; "=" suppresses headers.
        task.arguments = ["-Aceo", "pid=,pcpu=,rss=,comm="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
        } catch {
            return .empty
        }

        let watchdog = DispatchWorkItem {
            if task.isRunning { task.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2, execute: watchdog)

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        watchdog.cancel()

        guard task.terminationReason == .exit, task.terminationStatus == 0 else {
            return .empty
        }

        let output = String(decoding: data, as: UTF8.self)
        return Self.parse(output)
    }

    private static func parse(_ output: String) -> ProcessesSnapshot {
        var samples: [ProcessSample] = []
        samples.reserveCapacity(700)

        for line in output.split(separator: "\n") {
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
                  let rssKB = UInt64(rssField) else { continue }

            var name = rest
            while let last = name.last, last == " " || last == "\t" || last == "\r" {
                name = name.dropLast()
            }
            guard !name.isEmpty, name != "ps" else { continue }

            samples.append(ProcessSample(pid: pid,
                                         name: String(name),
                                         cpuPercent: cpu,
                                         memoryBytes: rssKB &* 1024))
        }

        guard !samples.isEmpty else { return .empty }

        let byCPU = samples.sorted { $0.cpuPercent > $1.cpuPercent }
        let nonZeroCPU = byCPU.filter { $0.cpuPercent > 0 }
        let topCPU = Array((nonZeroCPU.count >= 6 ? nonZeroCPU : byCPU).prefix(6))
        let topMemory = Array(samples.sorted { $0.memoryBytes > $1.memoryBytes }.prefix(6))
        return ProcessesSnapshot(topCPU: topCPU, topMemory: topMemory)
    }
}
