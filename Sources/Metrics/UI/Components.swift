import SwiftUI

// MARK: - Card container

struct CardContainer<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
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

// MARK: - Bar histogram (rolling)

/// Trailing-aligned rolling bar chart of 0...1 values.
struct BarHistogram: View {
    var values: [Double]
    var capacity: Int = 60
    var color: Color = .accentColor

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
        }
    }
}

// MARK: - Sparkline

/// Line + soft fill, adaptively scaled to the visible maximum.
struct Sparkline: View {
    var values: [Double]
    var capacity: Int = 120
    var color: Color = .accentColor

    var body: some View {
        Canvas { ctx, size in
            let vals = Array(values.suffix(capacity))
            guard vals.count > 1 else { return }
            let maxV = max(vals.max() ?? 1, 0.000_001)
            let stepX = size.width / CGFloat(max(capacity - 1, 1))
            let startX = size.width - CGFloat(vals.count - 1) * stepX

            var line = Path()
            for (i, v) in vals.enumerated() {
                let y = size.height - CGFloat(v / maxV) * (size.height - 2) - 1
                let pt = CGPoint(x: startX + CGFloat(i) * stepX, y: y)
                if i == 0 { line.move(to: pt) } else { line.addLine(to: pt) }
            }
            var fill = line
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: startX, y: size.height))
            fill.closeSubpath()
            ctx.fill(fill, with: .color(color.opacity(0.12)))
            ctx.stroke(line, with: .color(color), lineWidth: 1.5)
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
