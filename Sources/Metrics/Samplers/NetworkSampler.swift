import Foundation
import CoreWLAN
import SystemConfiguration
import Darwin

final class NetworkSampler {
    // Last-seen per-interface counters, keyed by BSD name, so a 32-bit wrap on
    // one interface doesn't corrupt the summed totals.
    private var previousCounters: [String: (down: UInt64, up: UInt64)] = [:]
    private var previousTime: DispatchTime?

    private static let excludedPrefixes = ["utun", "awdl", "llw", "gif", "stf", "bridge", "ap", "anpi"]

    func sample() -> NetworkSnapshot {
        var snapshot = NetworkSnapshot()

        let primary = primaryInterfaceName()
        snapshot.interfaceName = primary

        var counters: [String: (down: UInt64, up: UInt64)] = [:]
        var localIPv4: String?
        var localIPv6: String?

        var addrList: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&addrList) == 0 {
            defer { freeifaddrs(addrList) }
            var cursor = addrList
            while let entry = cursor {
                let ifa = entry.pointee
                cursor = ifa.ifa_next
                guard let addrPtr = ifa.ifa_addr, let namePtr = ifa.ifa_name else { continue }
                let name = String(cString: namePtr)
                let family = addrPtr.pointee.sa_family

                if family == UInt8(AF_LINK) {
                    let flags = Int32(bitPattern: ifa.ifa_flags)
                    guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }
                    guard !Self.excludedPrefixes.contains(where: { name.hasPrefix($0) }) else { continue }
                    guard let dataPtr = ifa.ifa_data else { continue }
                    let data = dataPtr.assumingMemoryBound(to: if_data.self).pointee
                    counters[name] = (UInt64(data.ifi_ibytes), UInt64(data.ifi_obytes))
                } else if let primary, name == primary {
                    if family == UInt8(AF_INET), localIPv4 == nil {
                        var sin = sockaddr_in()
                        memcpy(&sin, addrPtr, MemoryLayout<sockaddr_in>.size)
                        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                        if inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil {
                            localIPv4 = String(cString: buf)
                        }
                    } else if family == UInt8(AF_INET6), localIPv6 == nil {
                        var sin6 = sockaddr_in6()
                        memcpy(&sin6, addrPtr, MemoryLayout<sockaddr_in6>.size)
                        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                        if inet_ntop(AF_INET6, &sin6.sin6_addr, &buf, socklen_t(INET6_ADDRSTRLEN)) != nil {
                            let ip = String(cString: buf)
                            if !ip.hasPrefix("fe80") { localIPv6 = ip }
                        }
                    }
                }
            }
        }

        snapshot.localIPv4 = localIPv4
        snapshot.localIPv6 = localIPv6

        let now = DispatchTime.now()
        var deltaDown: UInt64 = 0
        var deltaUp: UInt64 = 0
        if let prevTime = previousTime {
            for (name, current) in counters {
                guard let prev = previousCounters[name] else { continue }
                deltaDown &+= wrapDelta(current: current.down, previous: prev.down)
                deltaUp &+= wrapDelta(current: current.up, previous: prev.up)
            }
            let elapsed = Double(now.uptimeNanoseconds &- prevTime.uptimeNanoseconds) / 1_000_000_000
            if elapsed > 0 {
                snapshot.downBytesPerSec = Double(deltaDown) / elapsed
                snapshot.upBytesPerSec = Double(deltaUp) / elapsed
            }
        }
        snapshot.deltaDownBytes = deltaDown
        snapshot.deltaUpBytes = deltaUp
        previousCounters = counters
        previousTime = now

        if let primary {
            if let wifi = CWWiFiClient.shared().interface(withName: primary) {
                snapshot.connection = .wifi
                snapshot.ssid = wifi.ssid()
            } else if primary.hasPrefix("en") {
                snapshot.connection = .ethernet
            } else {
                snapshot.connection = .other
            }
        } else {
            snapshot.connection = .none
        }

        return snapshot
    }

    private func primaryInterfaceName() -> String? {
        guard let value = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString),
              let dict = value as? [String: Any],
              let name = dict["PrimaryInterface"] as? String,
              !name.isEmpty else { return nil }
        return name
    }

    // ifi_ibytes/ifi_obytes are 32-bit and wrap around. A counter that went
    // backwards is either a genuine wrap (small delta by construction) or a
    // reset from the interface re-attaching; a wrap delta implausibly large
    // for one tick (> 2 GiB) means a reset, so report 0 rather than corrupt
    // the persisted daily totals.
    private func wrapDelta(current: UInt64, previous: UInt64) -> UInt64 {
        if current >= previous { return current - previous }
        let delta = current &+ 0x1_0000_0000 &- previous
        return delta > 2 << 30 ? 0 : delta
    }
}
