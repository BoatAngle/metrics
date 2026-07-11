import SwiftUI

// MARK: - Card container

struct CardContainer<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    /// Optional trailing badge shown beside the subtitle (e.g. the memory
    /// pressure dot). AnyView keeps the container non-generic over it so every
    /// existing call site compiles unchanged.
    var titleAccessory: AnyView? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                if let titleAccessory {
                    titleAccessory
                }
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
        )
    }
}

// MARK: - Donut gauge

struct DonutGauge: View {
    var fraction: Double
    var size: CGFloat = 64
    var lineWidth: CGFloat = 7
    var color: Color = .accentColor
    var centerTop: String
    var centerBottom: String? = nil

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.15), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text(centerTop)
                    .font(.system(size: size * 0.22, weight: .semibold))
                    .monospacedDigit()
                if let centerBottom {
                    Text(centerBottom)
                        .font(.system(size: size * 0.13))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .padding(lineWidth / 2)
    }
}

// MARK: - Hover crosshair (shared by the live and history charts)

/// Draws a vertical crosshair line, an optional value dot, and a compact
/// value/time tooltip box. Used by the live `Sparkline`/`BarHistogram` scrub
/// (feature #47) and by `HistoryChart`, so they read identically.
func drawChartCrosshair(in ctx: inout GraphicsContext, size: CGSize,
                        x: CGFloat, dotY: CGFloat?,
                        value: String, caption: String, color: Color) {
    var line = Path()
    line.move(to: CGPoint(x: x, y: 0))
    line.addLine(to: CGPoint(x: x, y: size.height))
    ctx.stroke(line, with: .color(color.opacity(0.4)),
               style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
    if let dotY {
        ctx.fill(Path(ellipseIn: CGRect(x: x - 2.5, y: dotY - 2.5, width: 5, height: 5)),
                 with: .color(color))
    }

    // One mixed-weight line ("37% · 5s ago") so the box fits even the shortest
    // live charts (~22 pt) without clipping.
    let label = Text(value).font(.system(size: 10, weight: .semibold)).foregroundStyle(.primary)
        + Text("  " + caption).font(.system(size: 9)).foregroundStyle(.secondary)
    let text = ctx.resolve(label)
    let ts = text.measure(in: size)
    let padH: CGFloat = 5, padV: CGFloat = 2
    let boxW = ts.width + padH * 2
    let boxH = ts.height + padV * 2
    // Prefer the pointer's right; flip left near the trailing edge.
    var bx = x + 6
    if bx + boxW > size.width { bx = x - 6 - boxW }
    bx = min(max(bx, 0), max(0, size.width - boxW))
    let boxRect = CGRect(x: bx, y: 0, width: boxW, height: boxH)
    ctx.fill(Path(roundedRect: boxRect, cornerRadius: 4),
             with: .color(Color(nsColor: .controlBackgroundColor).opacity(0.92)))
    ctx.stroke(Path(roundedRect: boxRect, cornerRadius: 4),
               with: .color(color.opacity(0.35)), lineWidth: 0.75)
    ctx.draw(text, at: CGPoint(x: bx + padH, y: padV), anchor: .topLeading)
}

// MARK: - Bar histogram (rolling)

/// Trailing-aligned rolling bar chart of 0...1 values. When `valueLabel` is
/// supplied the chart becomes scrubbable: hovering shows a crosshair with the
/// exact value and how long ago that sample was taken.
struct BarHistogram: View {
    var values: [Double]
    var capacity: Int = 60
    var color: Color = .accentColor
    /// nil → not scrubbable (e.g. the tiny menu-bar graphs).
    var valueLabel: ((Double) -> String)? = nil
    var sampleInterval: Double = 1

    // Plain State (not @State): the macro form needs the SwiftUIMacros plugin,
    // which the Command Line Tools toolchain doesn't ship.
    private var hover = State<CGPoint?>(initialValue: nil)

    var body: some View {
        Canvas { ctx, size in
            let n = max(1, capacity)
            let slot = size.width / CGFloat(n)
            let barW = max(1, slot - 1)
            let vals = Array(values.suffix(n))
            let pad = n - vals.count
            for (i, v) in vals.enumerated() {
                let clamped = min(max(v, 0), 1)
                let h = max(1.5, CGFloat(clamped) * size.height)
                let x = CGFloat(pad + i) * slot
                let rect = CGRect(x: x, y: size.height - h, width: barW, height: h)
                ctx.fill(Path(rect), with: .color(color.opacity(0.9)))
            }
            if let valueLabel, let p = hover.wrappedValue, !vals.isEmpty {
                let i = min(max(Int(p.x / slot) - pad, 0), vals.count - 1)
                let clamped = min(max(vals[i], 0), 1)
                let dotY = size.height - max(1.5, CGFloat(clamped) * size.height)
                let age = Double(vals.count - 1 - i) * sampleInterval
                drawChartCrosshair(in: &ctx, size: size,
                                   x: CGFloat(pad + i) * slot + barW / 2, dotY: dotY,
                                   value: valueLabel(vals[i]), caption: Fmt.ago(age), color: color)
            }
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            guard valueLabel != nil else { return }
            if case .active(let p) = phase { hover.wrappedValue = p } else { hover.wrappedValue = nil }
        }
    }
}

// MARK: - Sparkline

/// Line + soft fill. Scales from zero to the visible maximum by default, or
/// between the visible min and max when `autoBaseline` is set (better for
/// values that never approach zero, like temperatures). Supplying
/// `valueLabel` makes it scrubbable, same as `BarHistogram`.
struct Sparkline: View {
    var values: [Double]
    var capacity: Int = 120
    var color: Color = .accentColor
    var autoBaseline: Bool = false
    var valueLabel: ((Double) -> String)? = nil
    var sampleInterval: Double = 1

    // Plain State (not @State): the macro form needs the SwiftUIMacros plugin,
    // which the Command Line Tools toolchain doesn't ship.
    private var hover = State<CGPoint?>(initialValue: nil)

    var body: some View {
        Canvas { ctx, size in
            let vals = Array(values.suffix(capacity))
            guard vals.count > 1 else { return }
            let maxV = vals.max() ?? 1
            let minV = autoBaseline ? (vals.min() ?? 0) : 0
            let span = max(maxV - minV, 0.000_001)
            let stepX = size.width / CGFloat(max(capacity - 1, 1))
            let startX = size.width - CGFloat(vals.count - 1) * stepX
            func yFor(_ v: Double) -> CGFloat {
                size.height - CGFloat((v - minV) / span) * (size.height - 2) - 1
            }

            var line = Path()
            for (i, v) in vals.enumerated() {
                let pt = CGPoint(x: startX + CGFloat(i) * stepX, y: yFor(v))
                if i == 0 { line.move(to: pt) } else { line.addLine(to: pt) }
            }
            var fill = line
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: startX, y: size.height))
            fill.closeSubpath()
            ctx.fill(fill, with: .color(color.opacity(0.12)))
            ctx.stroke(line, with: .color(color), lineWidth: 1.5)

            if let valueLabel, let p = hover.wrappedValue {
                let rawI = Int(((p.x - startX) / stepX).rounded())
                let i = min(max(rawI, 0), vals.count - 1)
                let age = Double(vals.count - 1 - i) * sampleInterval
                drawChartCrosshair(in: &ctx, size: size,
                                   x: startX + CGFloat(i) * stepX, dotY: yFor(vals[i]),
                                   value: valueLabel(vals[i]), caption: Fmt.ago(age), color: color)
            }
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            guard valueLabel != nil else { return }
            if case .active(let p) = phase { hover.wrappedValue = p } else { hover.wrappedValue = nil }
        }
    }
}

// MARK: - Rows & bars

struct StatRow: View {
    var label: String
    var value: String
    var dotColor: Color? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let dotColor {
                Circle().fill(dotColor).frame(width: 7, height: 7)
            }
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 11.5, weight: .medium))
                .monospacedDigit()
        }
    }
}

struct ProgressBar: View {
    var fraction: Double
    var color: Color = .accentColor
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(color.opacity(0.15))
                Capsule()
                    .fill(color)
                    .frame(width: max(height, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: height)
    }
}
