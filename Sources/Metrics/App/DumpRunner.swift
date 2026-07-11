import Foundation

/// `Metrics --dump`: sample every subsystem once (twice for rate-based ones,
/// 1 s apart), print human-readable values, exit. No GUI — a sanity check that
/// every sampler returns plausible data.
enum DumpRunner {
    static func run() {
        print("Metrics sampler dump —", Date())

        let cpu = CPUSampler()
        let mem = MemorySampler()
        let net = NetworkSampler()
        let disk = DiskSampler()
        let battery = BatterySampler()
        let sensors = SensorsSampler()
        let processes = ProcessSampler()
        let bluetooth = BluetoothSampler()
        let device = DeviceInfoProvider()
        let store = NetworkDataStore()

        // Prime diff-based samplers, wait, then take the real sample.
        _ = cpu.sample()
        _ = net.sample()
        Thread.sleep(forTimeInterval: 1.0)

        let c = cpu.sample()
        print("\n[CPU] total \(Fmt.percent(c.totalUsage))  user \(Fmt.percent(c.userUsage))  system \(Fmt.percent(c.systemUsage))  idle \(Fmt.percent(c.idleUsage))")
        print("      cores(\(c.perCore.count)): \(c.perCore.map(Fmt.percent).joined(separator: " "))")

        let m = mem.sample()
        print("\n[Memory] used \(Fmt.bytes(m.usedBytes)) / \(Fmt.bytes(m.totalBytes)) (\(Fmt.percent(m.usedFraction)))")
        print("         app \(Fmt.bytes(m.appBytes))  wired \(Fmt.bytes(m.wiredBytes))  compressed \(Fmt.bytes(m.compressedBytes))  cached \(Fmt.bytes(m.cachedBytes))")
        print("         swap \(Fmt.bytes(m.swapUsedBytes)) / \(Fmt.bytes(m.swapTotalBytes))  pressure \(String(format: "%.0f%%", m.pressurePercent))")

        let n = net.sample()
        print("\n[Network] \(n.connection.rawValue) via \(n.interfaceName ?? "?")  ↓ \(rate(n.downBytesPerSec))  ↑ \(rate(n.upBytesPerSec))")
        print("          ssid \(n.ssid ?? "–")  ipv4 \(n.localIPv4 ?? "–")  ipv6 \(n.localIPv6 ?? "–")")

        let d = disk.sample()
        print("\n[Disk] \(d.volumes.count) volume(s)")
        for v in d.volumes {
            print("       \(v.name) (\(v.path))\(v.isRoot ? " [root]" : "")\(v.isRemovable ? " [removable]" : ""): \(Fmt.bytes(v.usedBytes)) / \(Fmt.bytes(v.totalBytes)) (\(Fmt.percent(v.usedFraction)))")
        }

        let b = battery.sample()
        if b.hasBattery {
            print("\n[Battery] \(String(format: "%.0f%%", b.percent))  charging=\(b.isCharging) plugged=\(b.isPluggedIn)")
            print("          W \(opt(b.watts))  A \(opt(b.amperage))  V \(opt(b.voltage))  cycles \(b.cycleCount.map(String.init) ?? "–")  health \(opt(b.healthPercent))%  temp \(opt(b.temperatureC))°C")
            print("          adapter: \(b.adapterDescription ?? "–")")
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
        print("\n[Processes] top CPU:")
        for proc in p.topCPU.prefix(5) { print("            \(proc.name) — \(String(format: "%.1f%%", proc.cpuPercent)), \(Fmt.bytes(proc.memoryBytes))") }
        print("            top memory:")
        for proc in p.topMemory.prefix(5) { print("            \(proc.name) — \(Fmt.bytes(proc.memoryBytes)), \(String(format: "%.1f%%", proc.cpuPercent))") }

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
        bundle.memory = m
        bundle.network = n
        bundle.disk = d
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

    private static func rate(_ v: Double) -> String { Fmt.bytes(UInt64(max(0, v))) + "/s" }
    private static func opt(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "–" }
}
