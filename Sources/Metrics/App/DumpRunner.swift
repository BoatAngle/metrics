import AppKit
import Carbon.HIToolbox
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

        dumpAnalytics(device: dev, network: n, memory: m, power: pw, sensors: s, store: store)
        dumpAlerts(sensors: s)
        dumpMenuBar(cpu: c, gpu: g, memory: m, network: n, sensors: s, battery: b)
        dumpPolish()
        dumpWidgets()
        dumpUpdates()

        print("\nDone.")
    }

    /// Update check (v2.1). Headless: no network, no timers — reports the
    /// persisted state and exercises the pure dotted-version compare. Run as a
    /// bare executable there's no Info.plist, so the current version prints as
    /// unknown and no update is ever reported.
    private static func dumpUpdates() {
        MainActor.assumeIsolated {
            let u = UpdateChecker.shared
            let s = SettingsStore.shared
            print("\n[Updates] daily check \(s.updateChecksEnabled ? "enabled" : "disabled")"
                + "  current \(u.currentVersion ?? "unknown (no bundle)")")
            print("          last successful check \(s.lastUpdateCheckDate.map(Fmt.date) ?? "never")"
                + "  latest known \(s.lastKnownLatestVersion ?? "–")"
                + "  update available \(u.updateAvailable)")
            // Version-compare edge cases: newer, equal, older remote, short
            // form, and a malformed tag (which must never report an update).
            let cases: [(remote: String, current: String, expect: Bool)] = [
                ("v2.1.1", "2.1.0", true),
                ("2.1.0", "2.1.0", false),
                ("v2.0.2", "2.1.0", false),
                ("2.1", "2.1.0", false),
                ("2.10.0", "2.9.9", true),
                ("nightly", "2.1.0", false),
            ]
            let allOK = cases.allSatisfy { UpdateChecker.isNewer(remote: $0.remote, than: $0.current) == $0.expect }
            print("          version compare: \(allOK ? "ok" : "MISMATCH") (\(cases.count) case(s))")
        }
    }

    /// Desktop widget upgrades + Focus/Gaming mode (Package 13, #41–#44). GUI
    /// windows can't launch headlessly, so this exercises the pure pieces: theme
    /// style resolution, the magnetic-snap math, the config/profile codecs, and
    /// the Focus-mode detection heuristics.
    private static func dumpWidgets() {
        print("\n[Widgets] theme styles (frameless / material / opacity):")
        for theme in WidgetTheme.allCases {
            var cfg = DesktopWidgetConfig()
            cfg.theme = theme
            cfg.backgroundOpacity = 0.6
            let st = cfg.style
            print("          \(theme.title): frameless \(st.frameless)  material \(st.usesMaterial)"
                + "  bg-opacity \(String(format: "%.1f", st.backgroundOpacity))  mono \(st.monospaced)"
                + "  tint \(st.textTint == nil ? "—" : "green")")
        }
        print("          scale factors: " + WidgetScale.allCases
            .map { "\($0.title)=\(String(format: "%.2f", $0.factor))" }.joined(separator: " "))

        // Snapping: near-edge, far-edge and grid, plus a no-snap miss.
        let guides: [CGFloat] = [0, 200, 508]
        let cases: [(String, CGFloat, CGFloat)] = [
            ("near edge → guide 200", 205, 100), // left edge 205 snaps to guide 200
            ("far edge → guide 508", 405, 100),  // right edge 505 snaps to guide 508 → x 408
            ("grid fallback", 41, 100),          // no guide near → nearest 8-grid = 40
            ("grid fallback", 123, 100),         // no guide near → nearest 8-grid = 120
        ]
        print("          snap (guides \(guides.map { Int($0) })):")
        for (name, value, extent) in cases {
            let snapped = WidgetSnap.snap(value: value, extent: extent, lines: guides)
            print("            \(name): \(Int(value)) → \(Int(snapped))")
        }

        // Config + profile persistence round-trip.
        var cfg = DesktopWidgetConfig()
        cfg.scale = .large; cfg.theme = .terminal; cfg.frameless = true; cfg.backgroundOpacity = 0.25
        let profile = LayoutProfile(
            name: "Desk", displaySignature: "69732096:3456x2234", autoSwitch: true,
            enabled: [CardKind.cpu.rawValue, CardKind.memory.rawValue],
            configs: [CardKind.cpu.rawValue: cfg],
            frames: [CardKind.cpu.rawValue: WidgetFrame(relX: 40, relY: 80, width: 304, height: 210,
                                                        displayID: 69732096)])
        if let data = try? JSONEncoder().encode(profile),
           let back = try? JSONDecoder().decode(LayoutProfile.self, from: data) {
            print("          profile codec: \(back == profile ? "ok" : "MISMATCH") "
                + "(\(back.enabled.count) widget(s), \(data.count) bytes, auto-switch \(back.autoSwitch))")
        } else {
            print("          profile codec: ENCODE/DECODE FAILED")
        }

        // Focus-mode detection heuristics (headless: no screens/frontmost app).
        MainActor.assumeIsolated {
            let full = FocusModeController.anyAppFullScreen()
            let front = FocusModeController.chosenAppFrontmost(bundleID: "com.apple.dt.Xcode")
            print("          focus heuristics: any-fullscreen \(full)  chosen-frontmost \(front)"
                + "  focus-interval \(Int(FocusModeController.focusInterval))s")
        }
    }

    /// Dashboard & popover polish (Package 12). Only the pure hotkey-formatting
    /// path can be exercised headlessly (collapse/pin/context-menu are GUI-only);
    /// this confirms the Carbon key-name table and modifier rendering resolve.
    private static func dumpPolish() {
        let cases: [(name: String, keyCode: Int, mods: NSEvent.ModifierFlags)] = [
            ("toggle dashboard", kVK_ANSI_M, [.command, .option]),
            ("focus mode", kVK_F5, [.control, .shift]),
            ("space combo", kVK_Space, [.command]),
        ]
        print("\n[Polish] global-hotkey display strings:")
        for c in cases {
            let b = HotkeyCenter.Binding(keyCode: c.keyCode, modifiers: Int(c.mods.rawValue))
            print("         \(c.name): \(b.displayString)")
        }
    }

    /// Menu bar overhaul (Package 11, features #33–#40). Exercises the non-UI
    /// logic the GUI can't be launched to test: legacy→instance migration,
    /// custom-format token rendering, and reactive-color classification.
    private static func dumpMenuBar(cpu c: CPUSnapshot, gpu g: GPUSnapshot, memory m: MemorySnapshot,
                                    network n: NetworkSnapshot, sensors s: SensorsSnapshot,
                                    battery b: BatterySnapshot) {
        let legacy: [MenuBarWidgetKind] = [.cpuPercent, .cpuGraph, .network, .temperature, .battery]
        let migrated = WidgetInstance.migrate(from: legacy)
        print("\n[Menu Bar] migrated \(legacy.count) legacy item(s) → instances:")
        for inst in migrated {
            let thr = inst.kind.defaultThresholds.map { "warn \(Int($0.warn)) crit \(Int($0.crit))" } ?? "none"
            print("           \(inst.kind.title) [\(inst.style.title)]  width \(Int(MenuBarLayout.width(for: inst)))  thresholds \(thr)")
        }

        let values = MenuFormatValues(
            cpuPercent: c.totalUsage * 100,
            gpuPercent: g.available ? g.usageFraction * 100 : nil,
            memPercent: m.usedFraction * 100,
            hotspotC: s.hotspotC ?? s.cpuTempC,
            netDownBytesPerSec: n.downBytesPerSec,
            netUpBytesPerSec: n.upBytesPerSec,
            fanRPM: s.fans.map(\.rpm).max(),
            batteryPercent: b.hasBattery ? b.percent : nil,
            useFahrenheit: false)
        let template = "{cpu} {gpu} {mem} {hot}° ↓{net.down} ↑{net.up} {fan.rpm}rpm {batt}"
        print("           format \"\(template)\" → \(MenuFormat.render(template, values))")

        func band(_ v: Double, _ w: Double, _ cr: Double) -> String {
            switch LoadLevel.evaluate(value: v, warn: w, crit: cr) {
            case .normal: return "normal"
            case .warn: return "warn"
            case .crit: return "crit"
            }
        }
        print("           reactive: cpu \(band(c.totalUsage * 100, 80, 90))  memory-pressure \(m.pressureLevel.label)"
            + (s.hotspotC.map { "  hotspot \(band($0, 85, 95))" } ?? ""))

        // Persistence round-trip over every optional payload (feature #38) — the
        // migration/decode paths can't be exercised from the GUI here.
        var sensor = WidgetInstance(kind: .sensor, style: .gauge, clickAction: .openCard,
                                    sensorName: "Hotspot", sensorLabel: "HOT")
        sensor.reactiveColor = true; sensor.warnThreshold = 70; sensor.critThreshold = 85
        let rich = migrated + [
            sensor,
            WidgetInstance(kind: .combined, combinedMetrics: [.cpu, .memory, .disk]),
            WidgetInstance(kind: .format, formatString: "{cpu} {hot}°"),
            WidgetInstance(kind: .fanRPM, fanIndex: 0),
            WidgetInstance(kind: .topProcess),
        ]
        if let data = try? JSONEncoder().encode(rich),
           let back = try? JSONDecoder().decode([WidgetInstance].self, from: data) {
            print("           codec round-trip: \(back == rich ? "ok" : "MISMATCH") "
                + "(\(back.count) items, \(data.count) bytes)")
        } else {
            print("           codec round-trip: ENCODE/DECODE FAILED")
        }

        // Stable slots: each configured instance's autosaveName and whether a
        // position is saved (seeded at item creation, then owned by AppKit).
        MainActor.assumeIsolated {
            let configured = SettingsStore.shared.widgetInstances
            print("           autosave slots (\(configured.count) configured, focus \"\(MenuBarPositions.focusName)\"):")
            for (index, inst) in configured.enumerated() {
                let name = MenuBarPositions.name(for: inst.id)
                let pos = MenuBarPositions.savedPosition(name)
                    .map { String(format: "saved %.0f", $0) }
                    ?? "unseeded (will seed \(Int(MenuBarPositions.seed(at: index))))"
                print("           \(name) [\(inst.kind.title)] \(pos)")
            }
        }
    }

    /// Session stats (#25), records (#26), weekly summary (#30/#31) and export
    /// (#32). The history reads run on the store queue, so the semaphore wait
    /// here (on the main thread) never deadlocks. Diagnostics (#10) are
    /// main-actor and engine-driven, so they're exercised from the UI, not here.
    private static func dumpAnalytics(device dev: DeviceSnapshot, network n: NetworkSnapshot,
                                      memory m: MemorySnapshot, power pw: PowerSnapshot,
                                      sensors s: SensorsSnapshot, store: NetworkDataStore) {
        // Records live on a main-actor store; DumpRunner runs on the main thread.
        MainActor.assumeIsolated {
            let r = RecordsStore.shared
            r.record(sensors: s, fans: s.fans, network: n, memory: m, power: pw)
            print("\n[Records] all-time:")
            printRecord("hottest sensor", r.allTime.hottestSensor) { String(format: "%.1f°C", $0) }
            printRecord("peak fan", r.allTime.peakFanRPM) { "\(Int($0)) rpm" }
            printRecord("peak network", r.allTime.peakNetworkBurst) { rate($0) }
            printRecord("lowest free mem", r.allTime.lowestFreeMemory) { Fmt.bytes(UInt64(max(0, $0))) }
            printRecord("peak power", r.allTime.peakPowerWatts) { Fmt.watts($0) }
        }

        let daily = store.snapshot().daily
        let boot = dev.bootDate ?? Date().addingTimeInterval(-3600)
        let sem = DispatchSemaphore(value: 0)
        Task {
            let session = await SessionStats.load(since: boot)
            let weekly = await WeeklySummary.load(days: 7, networkDaily: daily)
            let metrics = await HistoryStore.shared.distinctMetrics()

            print("\n[Session] since boot \(Fmt.date(boot)):")
            print("          CPU avg \(pct(session.avgCPU)) peak \(pct(session.peakCPU))  "
                + "GPU avg \(pct(session.avgGPU)) peak \(pct(session.peakGPU))")
            print("          hotspot avg \(optC(session.avgHotspot)) peak \(optC(session.peakHotspot))  "
                + "net ↓\(optBytes(session.netDownBytes)) ↑\(optBytes(session.netUpBytes))")

            let hot = weekly.hottestDay?.peakC.map { String(format: "%.0f°C", $0) } ?? "–"
            print("\n[This Week] \(weekly.days.count) day cells  hottest \(hot)  data \(Fmt.bytes(weekly.totalDataBytes))"
                + "  battery \(String(format: "%.1fh", weekly.hoursOnBattery)) / plugged \(String(format: "%.1fh", weekly.hoursPlugged))")

            print("\n[Export] \(metrics.count) distinct metric(s): \(metrics.prefix(12).joined(separator: ", "))"
                + (metrics.count > 12 ? " …" : ""))
            let csv = await HistoryExport.build(metrics: Array(metrics.prefix(2)), range: .day, format: .csv)
            print("          sample CSV: \(csv.split(separator: "\n").count) line(s)")
            sem.signal()
        }
        sem.wait()
    }

    private static func printRecord(_ name: String, _ e: RecordsStore.Entry?,
                                    format: (Double) -> String) {
        if let e {
            print("          \(name): \(format(e.value))  (\(e.label), \(Fmt.date(e.date)))")
        } else {
            print("          \(name): –")
        }
    }

    private static func optC(_ v: Double?) -> String { v.map { String(format: "%.0f°C", $0) } ?? "–" }
    private static func optBytes(_ v: Double?) -> String { v.map { Fmt.bytes(UInt64(max(0, $0))) } ?? "–" }

    /// Alerts dry-run (features #15–#23): load the persisted rules, show the
    /// quiet-hours/DND config, and print each rule with its threshold. No
    /// notifications are posted — headless has no bundle, so the notifier is a
    /// no-op here anyway.
    private static func dumpAlerts(sensors: SensorsSnapshot) {
        MainActor.assumeIsolated {
            let store = AlertStore()
            let (rules, config) = store.load()
            let s = SettingsStore.shared
            let notif = AlertNotifier.shared.isAvailable ? "available" : "no bundle (headless)"
            print("\n[Alerts] \(rules.count) rule(s); notifications \(notif)")
            let quiet = s.quietHoursEnabled
                ? "\(hhmm(s.quietHoursStartMinutes))–\(hhmm(s.quietHoursEndMinutes))"
                : "off"
            let focus = FocusState.isActive().map { $0 ? "on" : "off" } ?? "unknown"
            print("         quiet hours \(quiet)  DND-suppress \(s.suppressDuringDND)  Focus \(focus)  data-budget \(config.dataBudgetEnabled ? "on" : "off")")
            if let names = Optional(AlertEngine.availableSensorNames(engineSensors: sensors)), !names.isEmpty {
                print("         sensor rules can target: \(names.joined(separator: ", "))")
            }
            for r in rules {
                let ctx: String
                if r.metric.needsSensor { ctx = " (\(r.sensorName ?? "—"))" }
                else if r.metric.needsVolume { ctx = " (\(r.volumePath ?? "boot"))" }
                else { ctx = "" }
                let thr = r.metric.isLevel
                    ? r.metric.format(r.threshold, fahrenheit: s.useFahrenheit)
                    : "\(r.comparator.symbol) \(r.metric.format(r.threshold, fahrenheit: s.useFahrenheit))"
                print("         [\(r.enabled ? "on " : "off")] \(r.name): \(r.metric.title)\(ctx) \(thr)"
                    + "  sustain \(Int(r.sustainSeconds))s  cooldown \(Int(r.cooldownSeconds))s"
                    + (r.quietHoursBypass ? "  [bypass]" : "")
                    + (r.escalationFanMode.map { "  → fan \($0.title)" } ?? ""))
            }
            let recent = AlertEngine.shared.history.entries.prefix(3)
            if recent.isEmpty {
                print("         history: (none recorded)")
            } else {
                for e in recent {
                    print("         history: \(Fmt.date(e.date))  \(e.ruleName)  peak \(e.peakText)")
                }
            }
        }
    }

    private static func hhmm(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
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
