import Foundation

/// Hosts the `metricsctl` control socket: a Unix-domain stream socket speaking
/// the newline-delimited JSON `ControlProtocol`. Raw BSD sockets (no NIO), all
/// accept/read work driven by GCD DispatchSources on one background queue, so
/// there's no runloop dependency and it works headlessly in the self-test.
final class MetricsControlServer {
    static let shared = MetricsControlServer()

    /// `~/Library/Application Support/Metrics/metricsctl.sock`.
    static var defaultSocketPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Metrics", isDirectory: true)
            .appendingPathComponent("metricsctl.sock")
            .path
    }

    private let queue = DispatchQueue(label: "com.harrisonbraun.metrics.control")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clients: [ObjectIdentifier: ClientConnection] = [:]
    private var source: ControlValueSource?
    private var path = ""

    /// Binds and starts listening. Returns false (and logs) if the socket can't
    /// be created — the app keeps running, just without CLI control.
    @discardableResult
    func start(source: ControlValueSource, path: String = defaultSocketPath) -> Bool {
        var ok = false
        queue.sync { ok = bindAndListen(source: source, path: path) }
        return ok
    }

    /// Tears down the listener, drops every client, and removes the socket file.
    /// Teardown is async on `queue` (not `queue.sync`): the live source reads
    /// engine state via `DispatchQueue.main.sync` from that queue, so blocking
    /// the main thread here on `queue.sync` could cross-deadlock with an
    /// in-flight watch tick. A lingering socket file is harmless — `start()`
    /// unlinks any stale one before binding.
    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.acceptSource?.cancel()
            self.acceptSource = nil
            for (_, c) in self.clients { c.close() }
            self.clients.removeAll()
            if !self.path.isEmpty { unlink(self.path) }
            self.listenFD = -1
            self.source = nil
        }
    }

    // MARK: - Setup (runs on `queue`)

    private func bindAndListen(source: ControlValueSource, path: String) -> Bool {
        self.source = source
        self.path = path

        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // sockaddr_un.sun_path holds 104 bytes including the NUL terminator.
        guard path.utf8.count < 104 else {
            NSLog("Metrics: control socket path too long (%d bytes): %@", path.utf8.count, path)
            return false
        }

        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            NSLog("Metrics: control socket() failed: %d", errno)
            return false
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { rawPtr in
            rawPtr.withMemoryRebound(to: CChar.self, capacity: 104) { dst in
                path.withCString { src in
                    strncpy(dst, src, 103)
                }
            }
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, addrLen) }
        }
        guard bound == 0 else {
            NSLog("Metrics: control bind() failed: %d", errno)
            close(fd)
            return false
        }
        guard listen(fd, 8) == 0 else {
            NSLog("Metrics: control listen() failed: %d", errno)
            close(fd)
            unlink(path)
            return false
        }
        chmod(path, 0o600) // owner-only

        listenFD = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptPending() }
        src.setCancelHandler { close(fd) }
        acceptSource = src
        src.resume()
        return true
    }

    private func acceptPending() {
        let clientFD = accept(listenFD, nil, nil)
        guard clientFD >= 0 else { return }
        guard let source else { close(clientFD); return }
        let conn = ClientConnection(fd: clientFD, queue: queue, source: source) { [weak self] conn in
            self?.clients[ObjectIdentifier(conn)] = nil
        }
        clients[ObjectIdentifier(conn)] = conn
        conn.start()
    }
}

/// One accepted client connection. Buffers incoming bytes, dispatches complete
/// newline-terminated request lines through `ControlProtocol`, and owns a
/// per-connection watch timer. All methods run on the server's `queue`.
private final class ClientConnection {
    private let fd: Int32
    private let queue: DispatchQueue
    private let source: ControlValueSource
    private let onClose: (ClientConnection) -> Void
    private var readSource: DispatchSourceRead?
    private var watchTimer: DispatchSourceTimer?
    private var buffer = Data()
    private var closed = false

    init(fd: Int32, queue: DispatchQueue, source: ControlValueSource,
         onClose: @escaping (ClientConnection) -> Void) {
        self.fd = fd
        self.queue = queue
        self.source = source
        self.onClose = onClose
    }

    func start() {
        let capturedFD = fd
        let rs = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        rs.setEventHandler { [weak self] in self?.readAvailable() }
        rs.setCancelHandler { Darwin.close(capturedFD) }
        readSource = rs
        rs.resume()
    }

    func close() {
        guard !closed else { return }
        closed = true
        watchTimer?.cancel()
        watchTimer = nil
        readSource?.cancel()
        readSource = nil
        onClose(self)
    }

    private func readAvailable() {
        var tmp = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &tmp, tmp.count)
        if n == 0 { close(); return }
        if n < 0 {
            if errno == EAGAIN || errno == EINTR { return }
            close(); return
        }
        buffer.append(contentsOf: tmp[0..<n])

        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            let line = String(decoding: lineData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            dispatch(line)
        }
    }

    private func dispatch(_ line: String) {
        switch ControlProtocol.handle(line: line, source: source) {
        case .reply(let json):
            writeLine(json)
        case .watch(let metric):
            startWatch(metric)
        }
    }

    private func startWatch(_ metric: String) {
        watchTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0)
        timer.setEventHandler { [weak self] in
            guard let self, !self.closed else { return }
            self.writeLine(ControlProtocol.watchLine(metric: metric, source: self.source))
        }
        watchTimer = timer
        timer.resume()
    }

    private func writeLine(_ line: String) {
        guard !closed else { return }
        var bytes = Array((line + "\n").utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { buf in
                write(fd, buf.baseAddress, buf.count)
            }
            if written > 0 {
                offset += written
            } else {
                if written < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                close() // client hung up
                return
            }
        }
    }
}
