import Foundation

// metricsctl — a tiny command-line client for the Metrics app's control socket.
// Speaks the newline-delimited JSON protocol over a Unix-domain socket. No
// SwiftUI, no shared code — just Foundation and raw BSD sockets.

let socketPath = ProcessInfo.processInfo.environment["METRICSCTL_SOCK"]
    ?? FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Metrics/metricsctl.sock").path

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func usage() -> Never {
    print("""
    metricsctl — command-line control for the Metrics app

    Usage:
      metricsctl get <metric>     print a metric's current value
      metricsctl json             print a full snapshot as pretty JSON
      metricsctl fan <mode>       set the fan mode
      metricsctl watch <metric>   stream a metric once per second (Ctrl-C to stop)

    Fan modes:  auto  quiet  balanced  performance  manual
    Metrics:    cpu gpu memory swap power cpu-temp gpu-temp hotspot
                battery net-down net-up disk ip fan

    The Metrics app must be running. Override the socket with METRICSCTL_SOCK.
    """)
    exit(2)
}

func openSocket() -> Int32 {
    if socketPath.utf8.count >= 104 { die("socket path too long: \(socketPath)") }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    if fd < 0 { die("socket() failed (errno \(errno))") }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    _ = withUnsafeMutablePointer(to: &addr.sun_path) { rawPtr in
        rawPtr.withMemoryRebound(to: CChar.self, capacity: 104) { dst in
            socketPath.withCString { strncpy(dst, $0, 103) }
        }
    }
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    let result = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
    }
    if result != 0 {
        close(fd)
        die("Cannot reach the Metrics app (no control socket at \(socketPath)). Is Metrics running?")
    }
    return fd
}

func send(_ fd: Int32, _ line: String) {
    let bytes = Array((line + "\n").utf8)
    bytes.withUnsafeBytes { buf in
        var off = 0
        while off < buf.count {
            let n = write(fd, buf.baseAddress!.advanced(by: off), buf.count - off)
            if n <= 0 { break }
            off += n
        }
    }
}

func receive(_ fd: Int32) -> String? {
    var data = Data()
    var byte: UInt8 = 0
    while true {
        let n = read(fd, &byte, 1)
        if n <= 0 { return data.isEmpty ? nil : String(decoding: data, as: UTF8.self) }
        if byte == 0x0A { return String(decoding: data, as: UTF8.self) }
        data.append(byte)
    }
}

func encodeRequest(_ obj: [String: Any]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else {
        die("could not encode request")
    }
    return String(decoding: data, as: UTF8.self)
}

func decode(_ line: String) -> [String: Any]? {
    guard let d = line.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
}

func errorText(_ obj: [String: Any]) -> String {
    let base = obj["error"] as? String ?? "request failed"
    if let available = obj["available"] as? [String] {
        return base + "\navailable metrics: " + available.joined(separator: ", ")
    }
    return base
}

/// One request → one reply, for the non-streaming commands.
func requestReply(_ request: [String: Any]) -> [String: Any] {
    let fd = openSocket()
    defer { close(fd) }
    send(fd, encodeRequest(request))
    guard let reply = receive(fd), let obj = decode(reply) else {
        die("no response from Metrics")
    }
    return obj
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { usage() }

switch command {
case "get":
    guard args.count >= 2 else { die("usage: metricsctl get <metric>") }
    let obj = requestReply(["cmd": "get", "metric": args[1]])
    if obj["ok"] as? Bool == true, let value = obj["value"] as? String {
        print(value)
    } else {
        die(errorText(obj))
    }

case "json":
    let obj = requestReply(["cmd": "snapshot"])
    if obj["ok"] as? Bool == true, let snapshot = obj["snapshot"] {
        guard let data = try? JSONSerialization.data(withJSONObject: snapshot,
                                                     options: [.prettyPrinted, .sortedKeys]) else {
            die("could not format snapshot")
        }
        print(String(decoding: data, as: UTF8.self))
    } else {
        die(errorText(obj))
    }

case "fan":
    guard args.count >= 2 else { die("usage: metricsctl fan <auto|quiet|balanced|performance|manual>") }
    let obj = requestReply(["cmd": "fan", "mode": args[1]])
    if obj["ok"] as? Bool == true, let mode = obj["mode"] as? String {
        print("fan mode: \(mode)")
    } else {
        die(errorText(obj))
    }

case "watch":
    guard args.count >= 2 else { die("usage: metricsctl watch <metric>") }
    let fd = openSocket()
    send(fd, encodeRequest(["cmd": "watch", "metric": args[1]]))
    while let line = receive(fd) {
        guard let obj = decode(line) else { continue }
        if obj["ok"] as? Bool == false { close(fd); die(errorText(obj)) }
        if let value = obj["value"] as? String {
            print(value)
            fflush(stdout)
        }
    }
    close(fd)

case "-h", "--help", "help":
    usage()

default:
    die("unknown command '\(command)'. Run 'metricsctl --help'.")
}
