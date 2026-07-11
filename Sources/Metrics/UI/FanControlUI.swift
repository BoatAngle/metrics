import SwiftUI

// Fan-control UI helpers shared by FansCard and FansSettingsTab, so the
// dashboard card and the Settings tab can't drift apart. Each view keeps
// only its own layout and its own State storage for slider values.

extension FanControl {
    /// What the mode pickers bind to: shows the mode actually in effect,
    /// writes the user's chosen mode.
    var modeBinding: Binding<FanMode> {
        Binding(
            get: { self.effectiveMode },
            set: { self.mode = $0 }
        )
    }
}

/// Live curve status: "Hotspot 52°C → Left 2,900 rpm · Right 3,100 rpm",
/// or "Hotspot 52°C → —" before the curve loop has produced targets.
/// nil before the first temperature reading — callers show their own
/// "Waiting for first reading…" placeholder.
@MainActor
func fanCurveStatusText(engine: MetricsEngine, fans: FanControl,
                        useFahrenheit: Bool) -> String? {
    guard let tempC = fans.drivingTempC else { return nil }
    let temp = Fmt.temp(tempC, fahrenheit: useFahrenheit)
    let targets = engine.sensors.fans.compactMap { fan -> String? in
        guard let rpm = fans.currentTargets[fan.id] else { return nil }
        return "\(fan.name) \(Int(rpm.rounded()).formatted()) rpm"
    }
    guard !targets.isEmpty else { return "Hotspot \(temp) → —" }
    return "Hotspot \(temp) → " + targets.joined(separator: " · ")
}

/// A manual-fan slider binding backed by a per-view `[fanID: rpm]` store:
/// reads the clamped value, writes the raw drag value.
func fanSliderBinding(for fan: FanInfo, store: Binding<[Int: Double]>) -> Binding<Double> {
    Binding(
        get: { fan.clampedSliderValue(store.wrappedValue[fan.id]) },
        set: { store.wrappedValue[fan.id] = $0 }
    )
}

extension FanInfo {
    /// Slider range: the fan's reported min…max, falling back to a sane
    /// 1200…6000 when the SMC omits limits or reports an inverted range.
    var controlRange: ClosedRange<Double> {
        let lo = minRPM ?? 1200
        let hi = maxRPM ?? 6000
        return lo < hi ? lo...hi : 1200...6000
    }

    /// The slider position: the stored drag value if there is one, else the
    /// live RPM, clamped into the control range either way.
    func clampedSliderValue(_ stored: Double?) -> Double {
        let r = controlRange
        return min(max(stored ?? rpm, r.lowerBound), r.upperBound)
    }
}
