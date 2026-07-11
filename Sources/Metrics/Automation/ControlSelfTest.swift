import Foundation

/// `Metrics --control-selftest`: a headless harness that exercises the real
/// control socket end-to-end against a fake value source — the transport, the
/// wire protocol, and (if the binary is present next to us) the `metricsctl`
/// CLI. No GUI, no engine, no NSApplication. Exits non-zero on any failure.
enum ControlSelfTest {
    static func run() {
        let path = "/tmp/metrics-selftest-\(getpid()).sock"
        let server = MetricsControlServer()
        let fake = FakeControlSource()
        guard server.start(source: fake, path: path) else {
            FileHandle.standardError.write(Data("control self-test: server failed to start\n".utf8))
            exit(1)
        }
        defer { server.stop() }

        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("  [\(ok ? "ok  " : "FAIL")] \(name)" + (detail.isEmpty ? "" : " — \(detail)"))
            if !ok { failures += 1 }
        }

        print("control self-test — socket \(path)")
        print("• in-process protocol")

        if let r = roundTrip(path, #"{"cmd":"get","metric":"cpu"}"#) {
            check("get cpu", r.contains("\"value\":\"42%\"") && r.contains("\"ok\":true"), r)
        } else { check("get cpu", false, "no reply") }

        if let r = roundTrip(path, #"{"cmd":"get","metric":"bogus"}"#) {
            check("get unknown → error", r.contains("\"ok\":false") && r.contains("available"), r)
        } else { check("get unknown → error", false, "no reply") }

        if let r = roundTrip(path, #"{"cmd":"snapshot"}"#) {
            check("snapshot", r.contains("\"snapshot\"") && r.contains("\"ok\":true"))
        } else { check("snapshot", false, "no reply") }

        if let r = roundTrip(path, #"{"cmd":"fan","mode":"quiet"}"#) {
            check("fan quiet", r.contains("\"mode\":\"quiet\"") && r.contains("\"ok\":true"), r)
        } else { check("fan quiet", false, "no reply") }

        if let r = roundTrip(path, #"{"cmd":"fan","mode":"nope"}"#) {
            check("fan bad mode → error", r.contains("\"ok\":false"), r)
        } else { check("fan bad mode → error", false, "no reply") }

        if let r = roundTrip(path, "this is not json") {
            check("malformed → error", r.contains("\"ok\":false"), r)
        } else { check("malformed → error", false, "no reply") }

        // watch: read two streamed lines from one persistent connection.
        do {
            let fd = openClient(path)
            if fd >= 0 {
                writeAll(fd, #"{"cmd":"watch","metric":"cpu"}"#)
                let l1 = readLine(fd)
                let l2 = readLine(fd)
                close(fd)
                let ok = (l1?.contains("\"metric\":\"cpu\"") ?? false)
                    && (l2?.contains("\"value\"") ?? false)
                check("watch streams two lines", ok, "\(l1 ?? "nil") / \(l2 ?? "nil")")
            } else { check("watch streams two lines", false, "connect failed") }
        }

        // CLI end-to-end, if metricsctl was built alongside us.
        if let cli = metricsctlPath() {
            print("• metricsctl CLI (\(cli))")
            let env = ["METRICSCTL_SOCK": path]
            let get = runProcess(cli, ["get", "cpu"], env: env).trimmingCharacters(in: .whitespacesAndNewlines)
            check("metricsctl get cpu", get == "42%", get)
            let json = runProcess(cli, ["json"], env: env)
            check("metricsctl json", json.contains("cpu"), "")
            let fan = runProcess(cli, ["fan", "balanced"], env: env)
            check("metricsctl fan balanced", fan.contains("balanced"), fan.trimmingCharacters(in: .whitespacesAndNewlines))
            check("metricsctl watch cpu (2 lines)", runProcessWatch(cli, ["watch", "cpu"], env: env, lines: 2))
        } else {
            print("• metricsctl CLI not found next to Metrics — skipping CLI checks")
        }

        print(failures == 0 ? "\nAll control checks passed." : "\n\(failures) control check(s) FAILED.")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - Raw socket client

    private static func openClient(_ path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { rawPtr in
            rawPtr.withMemoryRebound(to: CChar.self, capacity: 104) { dst in
                path.withCString { strncpy(dst, $0, 103) }
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
        }
        if r != 0 { close(fd); return -1 }
        return fd
    }

    private static func writeAll(_ fd: Int32, _ s: String) {
        let bytes = Array((s + "\n").utf8)
        bytes.withUnsafeBytes { buf in
            var off = 0
            while off < buf.count {
                let n = write(fd, buf.baseAddress!.advanced(by: off), buf.count - off)
                if n <= 0 { break }
                off += n
            }
        }
    }

    private static func readLine(_ fd: Int32) -> String? {
        var data = Data()
        var byte: UInt8 = 0
        while true {
            let n = read(fd, &byte, 1)
            if n <= 0 { return data.isEmpty ? nil : String(decoding: data, as: UTF8.self) }
            if byte == 0x0A { return String(decoding: data, as: UTF8.self) }
            data.append(byte)
        }
    }

    private static func roundTrip(_ path: String, _ request: String) -> String? {
        let fd = openClient(path)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        writeAll(fd, request)
        return readLine(fd)
    }

    // MARK: - metricsctl subprocess

    private static func metricsctlPath() -> String? {
        let exe = CommandLine.arguments.first ?? ""
        let dir = (exe as NSString).deletingLastPathComponent
        let candidate = dir.isEmpty ? "metricsctl" : dir + "/metricsctl"
        return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
    }

    private static func runProcess(_ path: String, _ args: [String], env: [String: String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        var e = ProcessInfo.processInfo.environment
        for (k, v) in env { e[k] = v }
        p.environment = e
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    private static func runProcessWatch(_ path: String, _ args: [String], env: [String: String], lines: Int) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        var e = ProcessInfo.processInfo.environment
        for (k, v) in env { e[k] = v }
        p.environment = e
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return false }
        let handle = out.fileHandleForReading
        var newlines = 0
        let deadline = Date().addingTimeInterval(5)
        while newlines < lines && Date() < deadline {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            newlines += chunk.filter { $0 == 0x0A }.count
        }
        p.terminate()
        p.waitUntilExit()
        return newlines >= lines
    }
}

/// Canned value source for the self-test — no engine, deterministic values.
private final class FakeControlSource: ControlValueSource {
    private var fanMode = "auto"

    func value(for metric: String) -> String? {
        switch metric {
        case "cpu": return "42%"
        case "gpu": return "17%"
        case "memory": return "63%"
        case "hotspot": return "58°C"
        case "ip": return "192.168.1.42"
        default: return nil
        }
    }

    func snapshotObject() -> [String: Any] {
        ["cpu": ["usage_percent": 42.0], "memory": ["used_percent": 63.0], "fan_mode": fanMode]
    }

    func metricKeys() -> [String] { ["cpu", "gpu", "memory", "hotspot", "ip"] }

    func setFan(mode: String) -> FanSetResult {
        let valid = ["auto", "quiet", "balanced", "performance", "manual"]
        guard valid.contains(mode) else { return .failure("unknown fan mode '\(mode)'") }
        fanMode = mode
        return .success(mode)
    }
}
