import SwiftUI

/// All fan curves over 35…100 °C, with the selected curve highlighted and a
/// dashed marker at the temperature currently driving the loop.
struct FanCurveChart: View {
    var selected: FanMode
    var drivingTempC: Double?
    var useFahrenheit: Bool

    private static let tempMin = 35.0
    private static let tempMax = 100.0
    private static let axisTicks: [Double] = [40, 60, 80, 100]

    var body: some View {
        Canvas { ctx, size in
            let labelBand: CGFloat = 16
            let plot = CGRect(x: 8, y: 8,
                              width: size.width - 16,
                              height: size.height - 16 - labelBand)
            guard plot.width > 10, plot.height > 10 else { return }

            func xPos(_ temp: Double) -> CGFloat {
                let t = min(max(temp, Self.tempMin), Self.tempMax)
                return plot.minX + CGFloat((t - Self.tempMin) / (Self.tempMax - Self.tempMin)) * plot.width
            }
            func yPos(_ fraction: Double) -> CGFloat {
                plot.maxY - CGFloat(min(max(fraction, 0), 1)) * plot.height
            }

            // Sampling targetFraction picks up the flat ends and the jump to
            // full speed at 95 °C without duplicating the curve math.
            func curvePath(_ mode: FanMode) -> Path? {
                guard mode.isCurve else { return nil }
                var path = Path()
                var started = false
                var temp = Self.tempMin
                while temp <= Self.tempMax + 0.001 {
                    guard let f = mode.targetFraction(tempC: min(temp, Self.tempMax)) else { return nil }
                    let pt = CGPoint(x: xPos(temp), y: yPos(f))
                    if started {
                        path.addLine(to: pt)
                    } else {
                        path.move(to: pt)
                        started = true
                    }
                    temp += 0.25
                }
                return path
            }

            // Non-selected curves first so the selected one draws on top.
            for mode in FanMode.allCases where mode.isCurve && mode != selected {
                if let path = curvePath(mode) {
                    ctx.stroke(path, with: .color(.gray.opacity(0.35)), lineWidth: 1)
                }
            }
            if let path = curvePath(selected) {
                ctx.stroke(path, with: .color(.accentColor), lineWidth: 2)
            }

            // Temperature ticks along the bottom.
            for tick in Self.axisTicks {
                let label = Text(Fmt.temp(tick, fahrenheit: useFahrenheit))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                let anchor: UnitPoint = tick >= Self.tempMax ? .topTrailing : .top
                let at = CGPoint(x: tick >= Self.tempMax ? size.width - 1 : xPos(tick),
                                 y: plot.maxY + 3)
                ctx.draw(label, at: at, anchor: anchor)
            }

            // Marker for the temperature currently driving the curve.
            if let temp = drivingTempC {
                let x = xPos(temp)
                var line = Path()
                line.move(to: CGPoint(x: x, y: plot.minY))
                line.addLine(to: CGPoint(x: x, y: plot.maxY))
                ctx.stroke(line, with: .color(.secondary.opacity(0.7)),
                           style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                if let f = selected.targetFraction(tempC: temp) {
                    let dot = CGRect(x: x - 3.5, y: yPos(f) - 3.5, width: 7, height: 7)
                    ctx.fill(Path(ellipseIn: dot), with: .color(.accentColor))
                }
            }
        }
    }
}
