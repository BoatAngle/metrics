import Foundation
import Darwin

/// One socket a process holds open, reduced to a printable line (feature #14).
struct SocketConn: Identifiable {
    var proto: String            // "TCP" / "UDP"
    var state: String?           // "LISTEN" / "ESTABLISHED" (TCP only)
    var local: String            // "addr:port"
    var remote: String?          // "addr:port" when connected
    let id = UUID()
}

/// Everything the inspector popover shows, gathered lazily off the sampling
/// loop. Optional fields degrade to "unavailable" rather than failing.
struct ProcessDetails {
    var pid: Int32
    var name: String
    var executablePath: String?
    var arguments: [String]?      // nil = couldn't read (SIP / other user)
    var parentName: String?
    var parentPID: Int32?
    var threadCount: Int?
    var residentBytes: UInt64?
    var openFileCount: Int?
    var sockets: [SocketConn] = []
}

/// Pulls per-process detail via libproc + sysctl. Every call is best-effort and
/// bounded; nothing here runs inside the sampler tick.
enum ProcessInspector {

    /// Gathers all detail for `pid`. Safe to call off the main actor.
    static func load(pid: Int32, name: String) -> ProcessDetails {
        var d = ProcessDetails(pid: pid, name: name)
        d.executablePath = path(of: pid)
        d.arguments = arguments(of: pid)

        if let bsd = bsdInfo(of: pid) {
            d.parentPID = Int32(bitPattern: bsd.pbi_ppid)
            d.parentName = processName(of: Int32(bitPattern: bsd.pbi_ppid))
        }
        if let task = taskInfo(of: pid) {
            d.threadCount = Int(task.pti_threadnum)
            d.residentBytes = task.pti_resident_size
        }
        let (fdCount, sockets) = fileDescriptors(of: pid)
        d.openFileCount = fdCount
        d.sockets = sockets
        return d
    }

    // MARK: - Path / name / args

    private static func path(of pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        let rc = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard rc > 0 else { return nil }
        let p = String(cString: buf)
        return p.isEmpty ? nil : p
    }

    private static func processName(of pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: 256)
        let rc = proc_name(pid, &buf, UInt32(buf.count))
        guard rc > 0 else { return nil }
        let n = String(cString: buf)
        return n.isEmpty ? nil : n
    }

    /// Command-line arguments (excluding argv[0]) via KERN_PROCARGS2. Returns
    /// nil when the kernel denies the read (SIP-protected / other-user procs).
    private static func arguments(of pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size >= 4 else { return nil }

        var argc: Int32 = 0
        withUnsafeMutableBytes(of: &argc) { $0.copyBytes(from: buf[0..<4]) }
        guard argc >= 0 else { return nil }

        var i = 4
        // Skip the executable path string.
        while i < size && buf[i] != 0 { i += 1 }
        // Skip the run of NUL padding after it.
        while i < size && buf[i] == 0 { i += 1 }

        var args: [String] = []
        var count = 0
        while count < Int(argc) && i < size {
            let start = i
            while i < size && buf[i] != 0 { i += 1 }
            if i > start {
                args.append(String(decoding: buf[start..<i], as: UTF8.self))
            }
            i += 1  // step over the terminator
            count += 1
        }
        // argv[0] duplicates the executable path — drop it for a cleaner view.
        return args.isEmpty ? [] : Array(args.dropFirst())
    }

    // MARK: - proc_pidinfo structs

    private static func bsdInfo(of pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let sz = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sz) == sz ? info : nil
    }

    private static func taskInfo(of pid: Int32) -> proc_taskinfo? {
        var info = proc_taskinfo()
        let sz = Int32(MemoryLayout<proc_taskinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, sz) == sz ? info : nil
    }

    // MARK: - File descriptors / sockets

    /// Returns the open-file count and the listening/established TCP + UDP
    /// sockets held by the process.
    private static func fileDescriptors(of pid: Int32) -> (Int?, [SocketConn]) {
        let bufSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bufSize > 0 else { return (nil, []) }
        let capacity = Int(bufSize) / MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        let rc = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, bufSize)
        guard rc > 0 else { return (nil, []) }
        let count = Int(rc) / MemoryLayout<proc_fdinfo>.stride

        var sockets: [SocketConn] = []
        for i in 0..<min(count, fds.count) where fds[i].proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            if let conn = socketConn(pid: pid, fd: fds[i].proc_fd) {
                sockets.append(conn)
            }
        }
        // Listening sockets first, then the rest, and keep the list tight.
        sockets.sort { ($0.state == "LISTEN" ? 0 : 1) < ($1.state == "LISTEN" ? 0 : 1) }
        return (count, Array(sockets.prefix(16)))
    }

    private static func socketConn(pid: Int32, fd: Int32) -> SocketConn? {
        var si = socket_fdinfo()
        let sz = Int32(MemoryLayout<socket_fdinfo>.size)
        guard proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, &si, sz) == sz else { return nil }

        switch Int(si.psi.soi_kind) {
        case SOCKINFO_TCP:
            let tcp = si.psi.soi_proto.pri_tcp
            let ini = tcp.tcpsi_ini
            let state = tcpStateLabel(tcp.tcpsi_state)
            // Only listening / established are interesting.
            guard state == "LISTEN" || state == "ESTABLISHED" else { return nil }
            let local = endpoint(ini, foreign: false)
            let remote = state == "ESTABLISHED" ? endpoint(ini, foreign: true) : nil
            return SocketConn(proto: "TCP", state: state, local: local, remote: remote)
        case SOCKINFO_IN:
            let ini = si.psi.soi_proto.pri_in
            let proto = Int(si.psi.soi_protocol) == Int(IPPROTO_UDP) ? "UDP" : "IP"
            let local = endpoint(ini, foreign: false)
            let fport = Int(UInt16(truncatingIfNeeded: ini.insi_fport).byteSwapped)
            let remote = fport > 0 ? endpoint(ini, foreign: true) : nil
            return SocketConn(proto: proto, state: nil, local: local, remote: remote)
        default:
            return nil
        }
    }

    /// Formats one end of an IP socket as "addr:port".
    private static func endpoint(_ ini: in_sockinfo, foreign: Bool) -> String {
        let port = Int(UInt16(truncatingIfNeeded: foreign ? ini.insi_fport : ini.insi_lport).byteSwapped)
        let addr: String
        if ini.insi_vflag & UInt8(INI_IPV6) != 0 {
            var a6 = foreign ? ini.insi_faddr.ina_6 : ini.insi_laddr.ina_6
            var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            inet_ntop(AF_INET6, &a6, &buf, socklen_t(INET6_ADDRSTRLEN))
            let s = String(cString: buf)
            addr = s.isEmpty || s == "::" ? "*" : "[\(s)]"
        } else {
            var a4 = foreign ? ini.insi_faddr.ina_46.i46a_addr4 : ini.insi_laddr.ina_46.i46a_addr4
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &a4, &buf, socklen_t(INET_ADDRSTRLEN))
            let s = String(cString: buf)
            addr = s.isEmpty || s == "0.0.0.0" ? "*" : s
        }
        return "\(addr):\(port)"
    }

    private static func tcpStateLabel(_ state: Int32) -> String {
        switch state {
        case Int32(TSI_S_LISTEN): return "LISTEN"
        case Int32(TSI_S_ESTABLISHED): return "ESTABLISHED"
        case Int32(TSI_S_CLOSED): return "CLOSED"
        case Int32(TSI_S_TIME_WAIT): return "TIME_WAIT"
        default: return "OTHER"
        }
    }
}
