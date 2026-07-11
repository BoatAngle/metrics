import Foundation
import SMCCore

final class SensorsSampler {
    private let smc: SMCConnection?
    private let tempKeys: Set<String>   // every SMC key starting with "T"
    private let fanCount: Int

    private static let intelCPUKeys = ["TC0P", "TC0H", "TC0D", "TC0E", "TC0F"]

    init() {
        let connection = SMCConnection()
        var temps = Set<String>()
        var fans = 0
        if let connection {
            let count = min(connection.keyCount(), 16_384)
            for i in 0..<count {
                if let name = connection.keyName(atIndex: i), name.hasPrefix("T") {
                    temps.insert(name)
                }
            }
            fans = connection.fanCount()
        }
        smc = connection
        tempKeys = temps
        fanCount = fans
    }

    func sample() -> SensorsSnapshot {
        guard let smc else { return .empty }
        var snap = SensorsSnapshot()

        func readTemp(_ key: String) -> Double? {
            guard tempKeys.contains(key),
                  let v = smc.readKey(key)?.doubleValue,
                  v >= 1, v <= 125 else { return nil }
            return v
        }

        // CPU: Apple Silicon per-core keys first, then Intel proximity/die keys.
        // Keep the hottest sensor alongside the average: fan control needs the
        // hotspot (averaging idle E-cores with loaded P-cores reads too cool).
        let coreVals = tempKeys.filter { $0.hasPrefix("Tp") }.compactMap(readTemp)
        if !coreVals.isEmpty {
            snap.cpuTempC = average(coreVals)
            snap.cpuTempMaxC = coreVals.max()
        } else {
            snap.cpuTempC = Self.intelCPUKeys.lazy.compactMap(readTemp).first
            snap.cpuTempMaxC = snap.cpuTempC
        }

        // GPU: "Tg…" on Apple Silicon, "TG…" on Intel.
        let gpuVals = tempKeys.filter { $0.lowercased().hasPrefix("tg") }.compactMap(readTemp)
        if !gpuVals.isEmpty {
            snap.gpuTempC = average(gpuVals)
            snap.gpuTempMaxC = gpuVals.max()
        }

        snap.extraTemps = extraTemps(readTemp)
        snap.fans = fans(smc)
        snap.available = snap.cpuTempC != nil || snap.gpuTempC != nil
            || !snap.fans.isEmpty || !snap.extraTemps.isEmpty
        return snap
    }

    private func extraTemps(_ readTemp: (String) -> Double?) -> [NamedTemp] {
        var extras: [NamedTemp] = []
        var seen = Set<String>()

        func add(_ label: String, _ celsius: Double) {
            guard extras.count < 8, !seen.contains(label) else { return }
            seen.insert(label)
            extras.append(NamedTemp(name: label, celsius: celsius))
        }

        let curated: [(key: String, label: String)] = [
            ("TA0P", "Ambient"),
            ("TW0P", "Airport"),
            ("Ts0P", "Palm Rest L"),
            ("Ts1P", "Palm Rest R"),
            ("TB1T", "Bottom L"),
            ("TB2T", "Bottom R"),
            ("TH0P", "SSD"),
            ("TH0A", "SSD"),
            ("TH0B", "SSD"),
            ("TH0C", "SSD")
        ]
        for (key, label) in curated {
            if let v = readTemp(key) { add(label, v) }
        }

        // Apple Silicon airflow sensors.
        let airflow = ["TaLP", "TaRP"].compactMap(readTemp)
        if !airflow.isEmpty {
            add("Airflow", average(airflow))
        }
        return extras
    }

    /// Mean of a non-empty array (callers guard emptiness).
    private func average(_ values: [Double]) -> Double {
        values.reduce(0, +) / Double(values.count)
    }

    private func fans(_ smc: SMCConnection) -> [FanInfo] {
        guard fanCount > 0 else { return [] }
        var fans: [FanInfo] = []
        for i in 0..<fanCount {
            guard let rpm = smc.readKey("F\(i)Ac")?.doubleValue, rpm >= 0 else { continue }
            let name: String
            if fanCount == 2 {
                name = i == 0 ? "Left" : "Right"
            } else {
                name = "Fan \(i + 1)"
            }
            fans.append(FanInfo(
                id: i,
                name: name,
                rpm: rpm,
                minRPM: smc.readKey("F\(i)Mn")?.doubleValue,
                maxRPM: smc.readKey("F\(i)Mx")?.doubleValue
            ))
        }
        return fans
    }
}
