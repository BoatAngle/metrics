import Foundation

/// What the transport should do with one decoded request line.
enum ControlOutcome {
    /// Send this single JSON line back and keep waiting for the next request.
    case reply(String)
    /// Begin streaming this metric once per second (the `watch` command).
    case watch(metric: String)
}

/// The newline-delimited JSON control protocol spoken over the Unix-domain
/// socket. Pure request→outcome mapping; the transport owns the socket and the
/// watch timer. Every reply is a single compact JSON object with an `ok` flag.
enum ControlProtocol {
    static func handle(line: String, source: ControlValueSource) -> ControlOutcome {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cmd = (obj["cmd"] as? String)?.lowercased() else {
            return .reply(errorJSON("malformed request (expected JSON with a 'cmd' field)"))
        }

        switch cmd {
        case "get":
            guard let metric = (obj["metric"] as? String)?.lowercased() else {
                return .reply(errorJSON("get: missing 'metric'"))
            }
            if let v = source.value(for: metric) {
                return .reply(okJSON(["metric": metric, "value": v]))
            }
            return .reply(errorJSON("unknown metric '\(metric)'", extra: ["available": source.metricKeys()]))

        case "snapshot":
            return .reply(okJSON(["snapshot": source.snapshotObject()]))

        case "fan":
            guard let mode = (obj["mode"] as? String)?.lowercased() else {
                return .reply(errorJSON("fan: missing 'mode'"))
            }
            switch source.setFan(mode: mode) {
            case .success(let applied): return .reply(okJSON(["mode": applied]))
            case .failure(let reason): return .reply(errorJSON(reason))
            }

        case "watch":
            guard let metric = (obj["metric"] as? String)?.lowercased() else {
                return .reply(errorJSON("watch: missing 'metric'"))
            }
            guard source.value(for: metric) != nil else {
                return .reply(errorJSON("unknown metric '\(metric)'", extra: ["available": source.metricKeys()]))
            }
            return .watch(metric: metric)

        default:
            return .reply(errorJSON("unknown command '\(cmd)' (get, snapshot, fan, watch)"))
        }
    }

    /// One streamed watch line: `{"metric":"cpu","value":"12%"}`.
    static func watchLine(metric: String, source: ControlValueSource) -> String {
        okJSON(["metric": metric, "value": source.value(for: metric) ?? "n/a"])
    }

    // MARK: - JSON encoding (compact, single line)

    static func okJSON(_ fields: [String: Any]) -> String {
        var obj: [String: Any] = ["ok": true]
        for (k, v) in fields { obj[k] = v }
        return encode(obj)
    }

    static func errorJSON(_ message: String, extra: [String: Any] = [:]) -> String {
        var obj: [String: Any] = ["ok": false, "error": message]
        for (k, v) in extra { obj[k] = v }
        return encode(obj)
    }

    private static func encode(_ obj: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return "{\"ok\":false,\"error\":\"internal encoding error\"}"
        }
        return str
    }
}
