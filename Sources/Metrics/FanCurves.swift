import Foundation

/// How Metrics drives the fans.
enum FanMode: String, Codable, CaseIterable, Identifiable {
    case auto, quiet, balanced, performance, manual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Auto"
        case .quiet: return "Quiet"
        case .balanced: return "Balanced"
        case .performance: return "Performance"
        case .manual: return "Manual"
        }
    }

    var subtitle: String {
        switch self {
        case .auto: return "Apple's default fan curve. Metrics doesn't touch the fans."
        case .quiet: return "Lets the machine run warmer before spinning up."
        case .balanced: return "Reacts sooner than Apple's curve for steadier temperatures."
        case .performance: return "Always keeps air moving and ramps hard — full speed at a 68 °C hotspot."
        case .manual: return "Fixed target speed per fan."
        }
    }

    /// A tiny SF Symbol glyph for the active mode, shown on the Fan RPM menu bar
    /// item (#38).
    var glyph: String {
        switch self {
        case .auto: return "a.circle"
        case .quiet: return "moon.fill"
        case .balanced: return "circle.lefthalf.filled"
        case .performance: return "bolt.fill"
        case .manual: return "hand.point.up.left.fill"
        }
    }

    /// Advances to the next mode, wrapping — used by the "cycle fan mode" click
    /// action (#37).
    var next: FanMode {
        let all = FanMode.allCases
        let idx = all.firstIndex(of: self) ?? 0
        return all[(idx + 1) % all.count]
    }

    /// Curve control points: (°C, fraction of the fan's min→max speed range).
    /// nil for modes that don't drive a curve.
    var curvePoints: [(temp: Double, fraction: Double)]? {
        switch self {
        case .auto, .manual:
            return nil
        // Curves are driven by the HOTTEST CPU/GPU sensor (hotspot), which
        // runs 5–15 °C above the average under load — that's what Apple's
        // controller reacts to. Floors matter too: Apple also watches package
        // power and chassis sensors, so it spins fans well above minimum
        // while dies still read "cool". Performance keeps a healthy baseline
        // and saturates early — it must never move less air than Auto would.
        case .quiet:
            return [(58, 0), (72, 0.30), (86, 0.60), (94, 1)]
        case .balanced:
            return [(42, 0.12), (55, 0.42), (68, 0.75), (82, 1)]
        case .performance:
            return [(38, 0.35), (50, 0.55), (60, 0.85), (68, 1)]
        }
    }

    var isCurve: Bool { curvePoints != nil }

    /// Fraction of the fan's speed range for a temperature, linearly
    /// interpolated between control points. The >= 95 °C short-circuit is a
    /// safety invariant: full speed at 95 °C no matter what future curve
    /// edits do (today every curve's last point is already 1.0).
    func targetFraction(tempC: Double) -> Double? {
        guard let points = curvePoints, let first = points.first, let last = points.last else {
            return nil
        }
        if tempC >= 95 { return 1 }
        if tempC <= first.temp { return first.fraction }
        for i in 1..<points.count {
            let (t0, f0) = points[i - 1]
            let (t1, f1) = points[i]
            if tempC <= t1 {
                return f0 + (f1 - f0) * (tempC - t0) / (t1 - t0)
            }
        }
        return last.fraction
    }
}
