import Foundation
import Observation

/// One tick's worth of samples. Slow-cadence metrics are nil on ticks where
/// they weren't re-sampled.
struct SampleBundle {
    var cpu: CPUSnapshot?
    var gpu: GPUSnapshot?
    var power: PowerSnapshot?
    var memory: MemorySnapshot?
    var network: NetworkSnapshot?
    var disk: DiskSnapshot?
    var diskIO: DiskIOSnapshot?
    var driveHealth: DriveHealthSnapshot?
    var battery: BatterySnapshot?
    var sensors: SensorsSnapshot?
    var processes: ProcessesSnapshot?
    var bluetooth: [BluetoothDeviceSample]?
    var device: DeviceSnapshot?
    var networkData: NetworkDataSnapshot?
}

/// Owns all samplers and drives them from a background queue.
/// Fast metrics every tick; disk/battery/sensors every 5; processes/
/// bluetooth/device/network-data every 10; data store flushed every 30.
final class SamplerLoop {
    private let queue = DispatchQueue(label: "metrics.samplers", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var tick = 0

    private let cpuSampler = CPUSampler()
    private let gpuSampler = GPUSampler()
    private let powerSampler = PowerSampler()
    private let memorySampler = MemorySampler()
    private let networkSampler = NetworkSampler()
    private let diskSampler = DiskSampler()
    private let diskIOSampler = DiskIOSampler()
    private let driveHealthSampler = DriveHealthSampler()
    private let batterySampler = BatterySampler()
    private let sensorsSampler = SensorsSampler()
    private let processSampler = ProcessSampler()
    private let bluetoothSampler = BluetoothSampler()
    private let deviceProvider = DeviceInfoProvider()
    private let dataStore = NetworkDataStore()
    private let historyRecorder = HistoryRecorder()

    func start(interval: Double, handler: @escaping (SampleBundle) -> Void) {
        stop()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.1, repeating: interval)
        t.setEventHandler { [weak self] in self?.sampleTick(handler: handler) }
        timer = t
        t.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        queue.sync { dataStore.flush() }
    }

    private func sampleTick(handler: (SampleBundle) -> Void) {
        var bundle = SampleBundle()
        bundle.cpu = cpuSampler.sample()
        bundle.gpu = gpuSampler.sample()
        bundle.power = powerSampler.sample()
        bundle.memory = memorySampler.sample()
        let net = networkSampler.sample()
        bundle.network = net
        dataStore.accumulate(down: net.deltaDownBytes, up: net.deltaUpBytes)
        // Disk throughput is diff-based, so it must be read every tick to keep
        // the live read/write sparklines flowing.
        bundle.diskIO = diskIOSampler.sample()

        if tick % 5 == 0 {
            bundle.disk = diskSampler.sample()
            bundle.driveHealth = driveHealthSampler.sample()
            bundle.battery = batterySampler.sample()
            bundle.sensors = sensorsSampler.sample()
        }
        if tick % 10 == 0 {
            bundle.processes = processSampler.sample()
            bundle.bluetooth = bluetoothSampler.sample()
            bundle.device = deviceProvider.sample()
            bundle.networkData = dataStore.snapshot()
        }
        if tick % 30 == 0 && tick > 0 {
            dataStore.flush()
        }
        tick += 1
        // Cheap append into the local history DB (real work happens on the
        // store's own queue).
        historyRecorder.record(bundle)
        handler(bundle)
    }
}

/// Main-actor observable state the whole UI reads from.
@Observable @MainActor
final class MetricsEngine {
    static let shared = MetricsEngine()
    private let loop = SamplerLoop()
    /// Long-lived, event-driven monitors that live outside the sampler tick so
    /// changing the sampling interval doesn't restart their subprocesses.
    private let networkAppMonitor = NetworkAppMonitor()
    private let connectivityMonitor = ConnectivityMonitor()

    private(set) var cpu = CPUSnapshot.empty
    private(set) var gpu = GPUSnapshot.empty
    private(set) var power = PowerSnapshot.empty
    private(set) var memory = MemorySnapshot.empty
    private(set) var network = NetworkSnapshot.empty
    private(set) var disk = DiskSnapshot.empty
    private(set) var diskIO = DiskIOSnapshot.empty
    private(set) var driveHealth = DriveHealthSnapshot.empty
    private(set) var battery = BatterySnapshot.empty
    private(set) var sensors = SensorsSnapshot.empty
    private(set) var processes = ProcessesSnapshot.empty
    private(set) var bluetooth: [BluetoothDeviceSample] = []
    private(set) var device = DeviceSnapshot.empty
    private(set) var networkData = NetworkDataSnapshot.empty
    /// Top network-using apps (feature #3), refreshed by the nettop monitor.
    private(set) var topNetworkApps: [AppNetworkUsage] = []
    /// Live connectivity + outage log (feature #9).
    private(set) var connectivity = ConnectivitySnapshot.empty

    private(set) var cpuHistory = RingBuffer(capacity: 120)
    private(set) var gpuHistory = RingBuffer(capacity: 120)
    private(set) var powerHistory = RingBuffer(capacity: 120)
    private(set) var memoryHistory = RingBuffer(capacity: 120)
    private(set) var downHistory = RingBuffer(capacity: 120)
    private(set) var upHistory = RingBuffer(capacity: 120)
    /// Wi-Fi signal (dBm) for the Network card's RSSI sparkline (feature #8).
    private(set) var rssiHistory = RingBuffer(capacity: 120)
    private(set) var diskReadHistory = RingBuffer(capacity: 120)
    private(set) var diskWriteHistory = RingBuffer(capacity: 120)
    /// Hottest CPU/GPU reading, in °C. Sampled on the sensor cadence (every
    /// few ticks), so it fills more slowly than the per-tick histories.
    private(set) var hotspotHistory = RingBuffer(capacity: 120)

    /// How often a fresh snapshot is written for the WidgetKit extension.
    private static let widgetPublishInterval: TimeInterval = 30
    @ObservationIgnored private var lastWidgetPublish = Date.distantPast

    func start(interval: Double) {
        loop.start(interval: interval) { bundle in
            Task { @MainActor in
                MetricsEngine.shared.apply(bundle)
            }
        }
    }

    func restart(interval: Double) {
        start(interval: interval)
    }

    func stop() {
        loop.stop()
    }

    /// Starts the event-driven monitors once, at launch. Kept separate from
    /// `start(interval:)` so a sampling-interval change never restarts them.
    func startMonitors() {
        networkAppMonitor.start { [weak self] apps in
            Task { @MainActor in self?.topNetworkApps = apps }
        }
        connectivityMonitor.start { [weak self] snapshot in
            Task { @MainActor in self?.connectivity = snapshot }
        }
    }

    func stopMonitors() {
        networkAppMonitor.stop()
        connectivityMonitor.stop()
    }

    private func apply(_ b: SampleBundle) {
        if let v = b.cpu {
            cpu = v
            cpuHistory.append(v.totalUsage)
        }
        if let v = b.gpu {
            gpu = v
            gpuHistory.append(v.usageFraction)
        }
        if let v = b.power {
            power = v
            powerHistory.append(v.totalWatts)
        }
        if let v = b.memory {
            memory = v
            memoryHistory.append(v.usedFraction)
        }
        if let v = b.network {
            network = v
            downHistory.append(v.downBytesPerSec)
            upHistory.append(v.upBytesPerSec)
            if let rssi = v.wifi?.rssi { rssiHistory.append(Double(rssi)) }
        }
        if let v = b.disk { disk = v }
        if let v = b.diskIO {
            diskIO = v
            diskReadHistory.append(v.readBytesPerSec)
            diskWriteHistory.append(v.writeBytesPerSec)
        }
        if let v = b.driveHealth { driveHealth = v }
        if let v = b.battery {
            battery = v
            // End a one-time "charge to 100%" once the pack is full or unplugged.
            BatteryChargeControl.shared.evaluateAutoReenable(percent: v.percent,
                                                             isPluggedIn: v.isPluggedIn)
        }
        if let v = b.sensors {
            sensors = v
            if let hotspot = v.hotspotC { hotspotHistory.append(hotspot) }
        }
        if let v = b.processes { processes = v }
        if let v = b.bluetooth { bluetooth = v }
        if let v = b.device { device = v }
        if let v = b.networkData { networkData = v }

        // Evaluate alert rules against the freshly applied snapshots (features
        // #15–#23). Cheap: a few comparisons per enabled rule.
        AlertEngine.shared.evaluate(from: self)

        if Date().timeIntervalSince(lastWidgetPublish) >= Self.widgetPublishInterval {
            lastWidgetPublish = Date()
            WidgetPublisher.publish(from: self)
        }
    }
}
