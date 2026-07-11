import Foundation
import SMCCore

/// `Metrics --dump`: sample every subsystem once (twice for rate-based ones,
/// 1 s apart), print human-readable values, exit. No GUI — a sanity check that
/// every sampler returns plausible data.
enum DumpRunner {
    static func run() {
        print("Metrics sampler dump —", Date())

        let cpu = CPUSampler()
        let power = PowerSampler()
        let mem = MemorySampler()
        let net = NetworkSampler()
        let disk = DiskSampler()
        let diskIO = DiskIOSampler()
        let driveHealth = DriveHealthSampler()
        let battery = BatterySampler()
        let sensors = SensorsSampler()
        let processes = ProcessSampler()
        let bluetooth = BluetoothSampler()
        let device = DeviceInfoProvider()
        let store = NetworkDataStore()

        // Prime diff-based samplers, wait, then take the real sample.
        _ = cpu.sample()
        _ = power.sample()
        _ = mem.sample()
        _ = net.sample()
        _ = diskIO.sample()
        _ = processes.sample()   // per-pid disk/energy are rate-based too
        Thread.sleep(forTimeInterval: 1.0)

        let c = cpu.sample()
        print("\n[CPU] total \(Fmt.percent(c.totalUsage))  user \(Fmt.percent(c.userUsage))  system \(Fmt.percent(c.systemUsage))  idle \(Fmt.percent(c.idleUsage))")
        print("      cores(\(c.perCore.count)): \(c.perCore.map(Fmt.percent).joined(separator: " "))")
        if c.clusters.isEmpty {
            print("      clusters: (perflevel split unavailable)")
        } else {
            for cluster in c.clusters {
                let loads = cluster.range.map { Fmt.percent(c.perCore[$0]) }.joined(separator: " ")
                print("      [\(cluster.shortName)] \(cluster.name) (\(cluster.coreCount) cores): \(loads)")
            }
        }

        let pw = power.sample()
        if pw.available {
            print("\n[Power] source \(pw.source.rawValue)  total \(Fmt.watts(pw.totalWatts))")
            print("        CPU \(Fmt.watts(pw.cpuWatts))\(pw.cpuDerived ? " (est.)" : "")  GPU \(Fmt.watts(pw.gpuWatts))"
                + "  ANE \(pw.aneWatts.map(Fmt.watts) ?? "–")  DRAM \(pw.dramWatts.map(Fmt.watts) ?? "–")"
                + "  adapter \(pw.adapterWatts.map(Fmt.watts) ?? "–")")
            if pw.clusterFreqs.isEmpty {
                print("        cluster clocks: (unavailable)")
            } else {
                let freqs = pw.clusterFreqs.map {
                    "\($0.name) \($0.megahertz < 1 ? "idle" : Fmt.frequency($0.megahertz)) @ \(String(format: "%.0f%%", $0.activePercent)) active"
                }.joined(separator: "  ")
                print("        clocks: \(freqs)")
            }
        } else {
            print("\n[Power] unavailable")
        }

        let m = mem.sample()
        print("\n[Memory] used \(Fmt.bytes(m.usedBytes)) / \(Fmt.bytes(m.totalBytes)) (\(Fmt.percent(m.usedFraction)))")
        print("         app \(Fmt.bytes(m.appBytes))  wired \(Fmt.bytes(m.wiredBytes))  compressed \(Fmt.bytes(m.compressedBytes))  cached \(Fmt.bytes(m.cachedBytes))")
        print("         swap \(Fmt.bytes(m.swapUsedBytes)) / \(Fmt.bytes(m.swapTotalBytes))  pressure \(String(format: "%.0f%%", m.pressurePercent)) [\(m.pressureLevel.label)]")
        print("         swap activity: in \(rate(m.swapInBytesPerSec))  out \(rate(m.swapOutBytesPerSec))")

        let n = net.sample()
        print("\n[Network] \(n.connection.rawValue) via \(n.interfaceName ?? "?")  ↓ \(rate(n.downBytesPerSec))  ↑ \(rate(n.upBytesPerSec))")
        print("          ssid \(n.ssid ?? "–")  ipv4 \(n.localIPv4 ?? "–")  ipv6 \(n.localIPv6 ?? "–")")
        if let w = n.wifi {
            let ssid = w.ssid ?? (w.ssidHidden ? "hidden (location permission)" : "–")
            let channel = [w.channel.map(String.init), w.band, w.channelWidth]
                .compactMap { $0 }.joined(separator: " ")
            print("          wifi: ssid \(ssid)  bssid \(w.bssid ?? "–")  channel \(channel.isEmpty ? "–" : channel)")
            print("                rssi \(w.rssi.map { "\($0) dBm" } ?? "–")  noise \(w.noise.map { "\($0) dBm" } ?? "–")  snr \(w.snr.map { "\($0) dB" } ?? "–")  phy \(w.txRateMbps.map { String(format: "%.0f Mbps", $0) } ?? "–")")
        }
        let conn = ConnectivityMonitor.dumpStatus()
        let online = conn.interfaceUp && conn.reachable
        print("          connectivity: \(online ? "Online" : "Offline")  interface \(conn.interfaceUp ? "up" : "down")\(conn.interface.map { " (\($0))" } ?? "")  probe \(conn.reachable ? "reachable" : "unreachable")")

        let d = disk.sample()
        print("\n[Disk] \(d.volumes.count) volume(s)")
        for v in d.volumes {
            print("       \(v.name) (\(v.path))\(v.isRoot ? " [root]" : "")\(v.isRemovable ? " [removable]" : ""): \(Fmt.bytes(v.usedBytes)) / \(Fmt.bytes(v.totalBytes)) (\(Fmt.percent(v.usedFraction)))")
        }

        let dio = diskIO.sample()
        print("\n[Disk I/O] read \(rate(dio.readBytesPerSec))  write \(rate(dio.writeBytesPerSec))  (Δread \(Fmt.bytes(dio.deltaReadBytes)), Δwrite \(Fmt.bytes(dio.deltaWriteBytes)))")

        let dh = driveHealth.sample()
        if dh.drives.isEmpty {
            print("\n[Drive Health] no SMART/NVMe data available")
        } else {
            print("\n[Drive Health] \(dh.drives.count) drive(s)")
            for drive in dh.drives {
                print("               \(drive.name) [\(statusName(drive.status))]"
                    + "  wear \(pct(drive.wearPercent))  spare \(pct(drive.availableSparePercent))"
                    + "  written \(drive.dataUnitsWrittenBytes.map(Fmt.bytes) ?? "–")"
                    + "  temp \(opt(drive.temperatureC))°C"
                    + "  poweredOn \(drive.powerOnHours.map { "\($0)h" } ?? "–")")
            }
        }

        let b = battery.sample()
        if b.hasBattery {
            print("\n[Battery] \(String(format: "%.0f%%", b.percent))  charging=\(b.isCharging) plugged=\(b.isPluggedIn)")
            print("          W \(opt(b.watts))  A \(opt(b.amperage))  V \(opt(b.voltage))  cycles \(b.cycleCount.map(String.init) ?? "–")  health \(opt(b.healthPercent))%  temp \(opt(b.temperatureC))°C")
            print("          adapter: \(b.adapterDescription ?? "–")")
            // Charge-limit (feature #11): verify the SMC exposes CHWA before the
            // toggle ships. ui8 1 = cap ~80%, 0 = normal.
            let smc = SMCConnection()
            if smc?.keyInfo("CHWA") != nil {
                let chwa = smc?.readKey("CHWA")?.doubleValue
                print("          charge-limit: CHWA present, value \(chwa.map { String(Int($0)) } ?? "?") (\(chwa == 1 ? "limited to 80%" : "normal"))")
            } else {
                print("          charge-limit: CHWA not present — feature hidden")
            }
        } else {
            print("\n[Battery] none")
        }

        let s = sensors.sample()
        if s.available {
            print("\n[Sensors] cpu \(opt(s.cpuTempC))°C  gpu \(opt(s.gpuTempC))°C  fans \(s.fans.count)")
            for f in s.fans { print("          \(f.name): \(String(format: "%.0f", f.rpm)) rpm") }
            for t in s.extraTemps.prefix(8) { print("          \(t.name): \(String(format: "%.1f", t.celsius))°C") }
        } else {
            print("\n[Sensors] unavailable (SMC not readable on this machine)")
        }

        let g = GPUSampler().sample()
        if g.available {
            print("\n[GPU] \(g.name ?? "GPU")  device \(g.deviceUtilization.map(Fmt.percent) ?? "–")  renderer \(g.rendererUtilization.map(Fmt.percent) ?? "–")  tiler \(g.tilerUtilization.map(Fmt.percent) ?? "–")")
        } else {
            print("\n[GPU] unavailable")
        }

        let p = processes.sample()
        print("\n[Processes] GPU-per-pid: \(p.gpuAvailable ? "available" : "unavailable (no per-client pid mapping on this GPU)")")
        for key in ProcessSortKey.allCases where key != .gpu || p.gpuAvailable {
            print("            top \(key.title):")
            for proc in p.ranked(by: key).prefix(5) { print("            " + procLine(proc, gpu: p.gpuAvailable)) }
        }

        let bt = bluetooth.sample()
        print("\n[Bluetooth] \(bt.count) device(s) with battery info")
        for devi in bt { print("            \(devi.name): \(devi.batteryPercent.map { "\($0)%" } ?? "?") \(devi.kind ?? "")") }

        let dev = device.sample()
        print("\n[Device] \(dev.modelName)  \(dev.chipName)")
        print("         macOS \(dev.osVersionString) (\(dev.buildVersion))  host \(dev.hostname)")
        print("         uptime \(Int(dev.uptimeSeconds / 3600))h  booted \(dev.bootDate.map { "\($0)" } ?? "–")")

        let nd = store.snapshot()
        print("\n[NetworkData] today ↓\(Fmt.bytes(nd.today.down)) ↑\(Fmt.bytes(nd.today.up))  yesterday \(Fmt.bytes(nd.yesterday.total))  7d \(Fmt.bytes(nd.last7Days.total))  30d \(Fmt.bytes(nd.last30Days.total))")

        // History: push this run's samples through the same recorder the
        // engine loop uses, force a maintenance pass, and report what landed.
        var bundle = SampleBundle()
        bundle.cpu = c
        bundle.gpu = g
        bundle.power = pw
        bundle.memory = m
        bundle.network = n
        bundle.disk = d
        bundle.diskIO = dio
        bundle.driveHealth = dh
        bundle.battery = b
        bundle.sensors = s
        HistoryRecorder().record(bundle)
        HistoryStore.shared.runMaintenanceSync()
        let h = HistoryStore.shared.dumpStatsSync()
        print("\n[History] \(h.path)")
        print("          raw rows \(h.rawRows)  rollup rows \(h.rollupRows)  size \(Fmt.bytes(h.sizeBytes))")
        let sem = DispatchSemaphore(value: 0)
        Task {
            let series = await HistoryStore.shared.series(metric: HistoryMetric.cpu, window: 3600)
            let last = series.last.map { String(format: "  last avg %.1f%% (min %.1f, max %.1f)", $0.avg, $0.min, $0.max) } ?? ""
            print("          cpu 1h series: \(series.count) point(s)\(last)")
            sem.signal()
        }
        sem.wait()

        print("\nDone.")
    }

    /// One process row with all per-pid columns (feature #13).
    private static func procLine(_ p: ProcessSample, gpu: Bool) -> String {
        var s = "\(p.name) [\(p.pid)] — cpu \(String(format: "%.1f%%", p.cpuPercent))"
            + "  mem \(Fmt.bytes(p.memoryBytes))"
            + "  disk \(rate(p.diskReadBytesPerSec + p.diskWriteBytesPerSec))"
            + "  energy \(Fmt.watts(p.energyWatts))"
        if gpu { s += "  gpu \(String(format: "%.0f%%", p.gpuPercent ?? 0))" }
        return s
    }

    private static func rate(_ v: Double) -> String { Fmt.bytes(UInt64(max(0, v))) + "/s" }
    private static func opt(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "–" }
    private static func pct(_ v: Double?) -> String { v.map { String(format: "%.0f%%", $0) } ?? "–" }
    private static func statusName(_ s: DriveHealthStatus) -> String {
        switch s {
        case .ok: return "OK"
        case .warning: return "WARN"
        case .failing: return "FAIL"
        case .unknown: return "?"
        }
    }
}
