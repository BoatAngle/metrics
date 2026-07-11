import SwiftUI

// MARK: - Render styles (#35)

/// Vertical bar meter: a rounded track with a bottom-anchored fill.
struct MeterBar: View {
    var fraction: Double
    var color: Color
    var width: CGFloat = 6
    var height: CGFloat = 15

    var body: some View {
        let clamped = min(max(fraction, 0), 1)
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(color.opacity(0.18))
            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(color)
                .frame(height: max(1.5, height * clamped))
        }
        .frame(width: width, height: height)
    }
}

/// Horizontal mini meter used inside Combined-item rows (#34).
struct HMeter: View {
    var fraction: Double
    var color: Color
    var width: CGFloat = 22
    var height: CGFloat = 4

    var body: some View {
        let clamped = min(max(fraction, 0), 1)
        ZStack(alignment: .leading) {
            Capsule().fill(color.opacity(0.2))
            Capsule().fill(color).frame(width: max(1.5, width * clamped))
        }
        .frame(width: width, height: height)
    }
}

/// Tiny circular gauge ring — no center text at menu bar size.
struct MiniGauge: View {
    var fraction: Double
    var color: Color
    var size: CGFloat = 15

    var body: some View {
        let clamped = min(max(fraction, 0), 1)
        ZStack {
            Circle().stroke(color.opacity(0.2), lineWidth: 2.5)
            Circle().trim(from: 0, to: clamped)
                .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
    }
}

/// Colored status dot: the reactive color is the whole signal.
struct ColorDot: View {
    var color: Color
    var size: CGFloat = 9

    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
    }
}

/// Fixed 0…1 line graph. Unlike `Sparkline` it never rescales to the visible
/// maximum, so line height reads as absolute load.
struct MiniLineGraph: View {
    var values: [Double]      // 0…1
    var color: Color

    var body: some View {
        Canvas { ctx, size in
            let vals = Array(values.suffix(30))
            guard vals.count > 1 else { return }
            let stepX = size.width / CGFloat(max(vals.count - 1, 1))
            func y(_ v: Double) -> CGFloat {
                size.height - CGFloat(min(max(v, 0), 1)) * (size.height - 1) - 0.5
            }
            var line = Path()
            for (i, v) in vals.enumerated() {
                let pt = CGPoint(x: CGFloat(i) * stepX, y: y(v))
                if i == 0 { line.move(to: pt) } else { line.addLine(to: pt) }
            }
            var fill = line
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()
            ctx.fill(fill, with: .color(color.opacity(0.15)))
            ctx.stroke(line, with: .color(color), lineWidth: 1.3)
        }
    }
}

// MARK: - Layout

/// Fixed status-item widths per instance (kept off the live value so the menu
/// bar never shifts as digits change). Shared by the item view and the status
/// controller, which sizes the NSStatusItem to match.
enum MenuBarLayout {
    static func width(for inst: WidgetInstance) -> CGFloat {
        switch inst.kind {
        case .network: return 68
        case .format: return 118
        case .topProcess: return 98
        case .combined: return 62
        case .fanRPM: return styleWidth(inst.style, textBase: 56)
        case .sensor: return styleWidth(inst.style, textBase: 58)
        case .gpu: return styleWidth(inst.style, textBase: 58)
        default: return styleWidth(inst.style, textBase: 54)
        }
    }

    private static func styleWidth(_ style: WidgetRenderStyle, textBase: CGFloat) -> CGFloat {
        switch style {
        case .text: return textBase
        case .lineGraph: return 50
        case .barMeter: return 22
        case .gauge: return 26
        case .dot: return 20
        }
    }
}
