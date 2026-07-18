import AppKit
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

    /// Injected by `MetricCardView` in the dashboard/popover (#48). Absent in
    /// desktop widgets and previews, where the header stays static.
    @Environment(\.cardCollapse) private var collapse
    /// Injected only when the card renders inside a desktop widget (#42): drives
    /// the theme's background, chrome and text tint.
    @Environment(\.desktopWidgetStyle) private var widgetStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if !(collapse?.collapsed ?? false) {
                content
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Frameless/minimal float on the wallpaper: a soft shadow keeps the
        // text legible without any card chrome behind it.
        .shadow(color: .black.opacity((widgetStyle?.needsLegibilityShadow ?? false) ? 0.55 : 0),
                radius: (widgetStyle?.needsLegibilityShadow ?? false) ? 1.5 : 0, y: 0.5)
        .background(cardBackground)
        .overlay(cardBorder)
    }

    /// The card's fill: standard control background in the dashboard, or the
    /// widget theme's fill/material when rendered as a desktop widget (#42).
    @ViewBuilder private var cardBackground: some View {
        if let style = widgetStyle {
            if style.usesMaterial {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .opacity(style.backgroundOpacity)
            } else if let fill = style.backgroundColor {
                RoundedRectangle(cornerRadius: 11, style: .continuous).fill(fill)
            } else {
                Color.clear // frameless / minimal
            }
        } else {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
        }
    }

    @ViewBuilder private var cardBorder: some View {
        if let style = widgetStyle {
            if style.drawsBorder {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(style.borderColor, lineWidth: 1)
            }
        } else {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
        }
    }

    @ViewBuilder private var header: some View {
        if let collapse {
            HStack(alignment: .center, spacing: 6) {
                // AppKit-clickable title row (a SwiftUI Button here is eaten by
                // the card's .onDrag reorder gesture).
                CardTitleToggle(title: title, collapsed: collapse.collapsed, action: collapse.toggle)
                Spacer(minLength: 8)
                if collapse.collapsed {
                    Text(collapse.summary)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .transition(.opacity)
                } else {
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    if let titleAccessory {
                        titleAccessory
                    }
                }
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold,
                                  design: (widgetStyle?.monospaced ?? false) ? .monospaced : .default))
                    .foregroundStyle(widgetStyle?.textTint ?? Color.secondary)
                Spacer()
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11,
                                      design: (widgetStyle?.monospaced ?? false) ? .monospaced : .default))
                        .foregroundStyle(widgetStyle?.textTint?.opacity(0.8) ?? Color(nsColor: .tertiaryLabelColor))
                }
                if let titleAccessory {
                    titleAccessory
                }
            }
        }
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

    /// Non-nil only inside a desktop widget (#42); the Terminal theme recolors
    /// the arc and center text green.
    @Environment(\.desktopWidgetStyle) private var widgetStyle

    var body: some View {
        // Values just snap to each fresh reading — no per-sample easing/numeric
        // transitions. Those look nice on one gauge, but every card animating
        // simultaneously on each tick kept SwiftUI's display-link render loop
        // running continuously (a full re-render every frame), which pegged a
        // CPU core whenever the dashboard was open. Correctness/energy > polish.
        let clamped = min(max(fraction, 0), 1)
        let arc = widgetStyle?.textTint ?? color
        return ZStack {
            Circle().stroke(arc.opacity(0.15), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: clamped)
                .stroke(arc, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text(centerTop)
                    .font(.system(size: size * 0.22, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(widgetStyle?.textTint ?? Color.primary)
                if let centerBottom {
                    Text(centerBottom)
                        .font(.system(size: size * 0.13))
                        .foregroundStyle(widgetStyle?.textTint ?? Color.secondary)
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
    var hover = State<CGPoint?>(initialValue: nil)

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
    var hover = State<CGPoint?>(initialValue: nil)

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

    /// Non-nil only inside a desktop widget (#42); tints/mono-fonts the row for
    /// the Terminal theme.
    @Environment(\.desktopWidgetStyle) private var widgetStyle

    private var mono: Bool { widgetStyle?.monospaced ?? false }

    var body: some View {
        HStack(spacing: 6) {
            if let dotColor {
                Circle().fill(widgetStyle?.textTint ?? dotColor).frame(width: 7, height: 7)
            }
            Text(label)
                .font(.system(size: 11.5, design: mono ? .monospaced : .default))
                .foregroundStyle(widgetStyle?.textTint ?? Color.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 11.5, weight: .medium, design: mono ? .monospaced : .default))
                .monospacedDigit()
                .foregroundStyle(widgetStyle?.textTint ?? Color.primary)
        }
    }
}

/// A `StatRow` whose value is click-to-copy (feature #49): clicking copies it to
/// the clipboard and flashes a transient checkmark beside it. Used for identity
/// values (IP addresses, SSID, hostname, macOS version). The value is an AppKit
/// button because a SwiftUI tap is swallowed by the card's reorder gesture.
struct CopyableStatRow: View {
    var label: String
    var value: String
    /// What actually gets copied, when it differs from the displayed value.
    var copyText: String? = nil

    // Plain State (not @State): the macro form needs the SwiftUIMacros plugin,
    // which the Command Line Tools toolchain doesn't ship.
    var copied = State(initialValue: false)

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            if copied.wrappedValue {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.green)
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
            CardValueButton(title: value, tooltip: "Click to copy") { copy() }
        }
    }

    private func copy() {
        let text = copyText ?? value
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        withAnimation(.easeOut(duration: 0.15)) { copied.wrappedValue = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            withAnimation(.easeIn(duration: 0.2)) { copied.wrappedValue = false }
        }
    }
}

/// A borderless AppKit button that renders an inline value (monospaced digits,
/// matching `StatRow`'s value styling) and fires on click. Used by
/// `CopyableStatRow` so the click survives the card's drag-to-reorder gesture.
struct CardValueButton: NSViewRepresentable {
    var title: String
    var tooltip: String? = nil
    var action: () -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.bezelStyle = .inline
        button.imagePosition = .noImage
        button.alignment = .right
        button.target = context.coordinator
        button.action = #selector(Coordinator.fire)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        apply(to: button)
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.action = action
        apply(to: nsView)
    }

    private func apply(to button: NSButton) {
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ])
        button.toolTip = tooltip
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func fire() { action() }
    }
}

// MARK: - AppKit card controls (shared)

/// A bordered AppKit push button usable inside a dashboard card. A SwiftUI
/// `Button` there is dead — the card's `.onDrag` reorder gesture eats its taps —
/// so clicks are handled at the AppKit layer instead. `prominent` gives the
/// accent-tinted call-to-action look.
struct CardPushButton: NSViewRepresentable {
    var title: String
    var systemImage: String? = nil
    var prominent: Bool = false
    var enabled: Bool = true
    var action: () -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: title, target: context.coordinator,
                              action: #selector(Coordinator.fire))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        button.setContentHuggingPriority(.required, for: .horizontal)
        apply(to: button)
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.action = action
        apply(to: nsView)
    }

    private func apply(to button: NSButton) {
        button.title = title
        button.isEnabled = enabled
        button.bezelColor = prominent ? .controlAccentColor : nil
        if let systemImage {
            button.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: title)
            button.imagePosition = .imageLeading
        } else {
            button.image = nil
            button.imagePosition = .noImage
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func fire() { action() }
    }
}

/// The AppKit-clickable card title row used by the collapsible cards (#48): a
/// chevron plus the card title, styled to match the static title. NSButton for
/// the same drag-gesture reason as `CardPushButton`.
struct CardTitleToggle: NSViewRepresentable {
    var title: String
    var collapsed: Bool
    var action: () -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.bezelStyle = .inline
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.alignment = .left
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        button.target = context.coordinator
        button.action = #selector(Coordinator.fire)
        button.setContentHuggingPriority(.required, for: .horizontal)
        apply(to: button)
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.action = action
        apply(to: nsView)
    }

    private func apply(to button: NSButton) {
        button.image = NSImage(systemSymbolName: collapsed ? "chevron.right" : "chevron.down",
                               accessibilityDescription: nil)
        button.contentTintColor = .secondaryLabelColor
        button.attributedTitle = NSAttributedString(string: "  " + title, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        button.toolTip = collapsed ? "Expand card" : "Collapse card"
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func fire() { action() }
    }
}

/// A borderless AppKit chevron+label header that toggles a card section open.
/// NSButton for the same drag-gesture reason as `CardPushButton`.
struct CardDisclosureHeader: NSViewRepresentable {
    var title: String
    var expanded: Bool
    var action: () -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.bezelStyle = .inline
        button.imagePosition = .imageLeading
        button.alignment = .left
        button.contentTintColor = .secondaryLabelColor
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        button.target = context.coordinator
        button.action = #selector(Coordinator.fire)
        button.setContentHuggingPriority(.required, for: .horizontal)
        apply(to: button)
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.action = action
        apply(to: nsView)
    }

    private func apply(to button: NSButton) {
        button.image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right",
                               accessibilityDescription: nil)
        button.attributedTitle = NSAttributedString(string: "  " + title, attributes: [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func fire() { action() }
    }
}

struct ProgressBar: View {
    var fraction: Double
    var color: Color = .accentColor
    var height: CGFloat = 5

    /// Non-nil only inside a desktop widget (#42): Terminal recolors the fill.
    @Environment(\.desktopWidgetStyle) private var widgetStyle

    var body: some View {
        let fill = widgetStyle?.textTint ?? color
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(fill.opacity(0.15))
                Capsule()
                    .fill(fill)
                    .frame(width: max(height, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: height)
    }
}
