import SwiftUI
import UniformTypeIdentifiers

/// One metric card by kind — shared by the popover and the dashboard window.
/// Cards for unavailable hardware render nothing.
struct MetricCardView: View {
    let kind: CardKind

    var body: some View {
        switch kind {
        case .cpu: CPUCard()
        case .gpu: GPUCard()
        case .memory: MemoryCard()
        case .disk: DiskCard()
        case .network: NetworkCard()
        case .networkData: NetworkDataCard()
        case .battery: BatteryCard()
        case .sensors: SensorsCard()
        case .fans: FansCard()
        case .processes: ProcessesCard()
        case .bluetooth: BluetoothCard()
        case .device: DeviceCard()
        }
    }
}

// MARK: - Drag-and-drop reordering

/// Live-reorders `SettingsStore.cardOrder` as a dragged card passes over
/// other cards, so the layout rearranges while the drag is still in flight.
private struct CardDropDelegate: DropDelegate {
    let kind: CardKind
    let dragging: Binding<CardKind?>

    func dropEntered(info: DropInfo) {
        guard let dragged = dragging.wrappedValue, dragged != kind else { return }
        // DropDelegate callbacks arrive on the main thread; hop onto the
        // main actor to touch the settings store.
        MainActor.assumeIsolated {
            let settings = SettingsStore.shared
            var order = settings.cardOrder
            guard let from = order.firstIndex(of: dragged),
                  let to = order.firstIndex(of: kind),
                  from != to else { return }
            order.move(fromOffsets: IndexSet(integer: from),
                       toOffset: to > from ? to + 1 : to)
            settings.cardOrder = order // reassign whole array so observation fires
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging.wrappedValue = nil // reordering already happened live
        return true
    }
}

/// Fallback target on the container behind the cards: catches drops that land
/// in gaps or padding so the dragged card's faded state never sticks.
private struct CardDropResetDelegate: DropDelegate {
    let dragging: Binding<CardKind?>

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging.wrappedValue = nil
        return true
    }
}

private extension View {
    /// Makes a card draggable and a live-reorder drop target.
    func cardReorderable(_ kind: CardKind, dragging: Binding<CardKind?>) -> some View {
        self
            .opacity(dragging.wrappedValue == kind ? 0.4 : 1)
            .onDrag {
                // Starting a drag also clears any state a cancelled drag
                // might have left behind.
                dragging.wrappedValue = kind
                return NSItemProvider(object: kind.rawValue as NSString)
            }
            .onDrop(of: [.text], delegate: CardDropDelegate(kind: kind, dragging: dragging))
    }
}

/// The popover content: header + scrollable stack of metric cards in the
/// user's chosen order.
struct DashboardView: View {
    @Environment(SettingsStore.self) private var settings
    var openDashboard: () -> Void
    var openSettings: () -> Void
    var quit: () -> Void

    // Plain State (not @State): the macro form needs the SwiftUIMacros plugin,
    // which the Command Line Tools toolchain doesn't ship. SwiftUI picks up
    // stored DynamicProperty values by reflection, so this behaves the same.
    private var draggingCard = State(initialValue: CardKind?.none)

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(visibleCards) { kind in
                        MetricCardView(kind: kind)
                            .cardReorderable(kind, dragging: draggingCard.projectedValue)
                    }
                }
                .padding(12)
                .animation(.default, value: visibleCards)
                .onDrop(of: [.text],
                        delegate: CardDropResetDelegate(dragging: draggingCard.projectedValue))
            }
        }
        .frame(width: 360, height: 580)
    }

    private var visibleCards: [CardKind] {
        settings.cardOrder.filter { !settings.hiddenCards.contains($0) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Metrics")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button(action: openDashboard) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Open dashboard window")
            Button(action: openSettings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Settings")
            Button(action: quit) {
                Image(systemName: "power")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Quit Metrics")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

}

/// The standalone dashboard window: a device header plus the cards packed
/// into balanced columns (masonry-style, no row gaps).
struct DashboardWindowView: View {
    @Environment(MetricsEngine.self) private var engine
    @Environment(SettingsStore.self) private var settings
    var openSettings: () -> Void

    // Plain State (not @State): the macro form needs the SwiftUIMacros plugin,
    // which the Command Line Tools toolchain doesn't ship. SwiftUI picks up
    // stored DynamicProperty values by reflection, so this behaves the same.
    private var draggingCard = State(initialValue: CardKind?.none)

    var body: some View {
        VStack(spacing: 0) {
            // macOS Tahoe AppKit bug (FB21850950): a scroll view whose top
            // edge touches the content view's top bleeds its scrolled rows
            // into the titlebar. One point of breathing room prevents it.
            Color.clear.frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    masonry
                }
                .padding(20)
            }
        }
        // Empty edge set: don't let the background bleed into the titlebar,
        // which would flip the window into full-size-content mode and draw
        // scrolled cards through the titlebar.
        .background(Color(nsColor: .underPageBackgroundColor), ignoresSafeAreaEdges: [])
        .frame(minWidth: 720, minHeight: 480)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(engine.device.modelName.isEmpty ? "This Mac" : engine.device.modelName)
                    .font(.system(size: 17, weight: .semibold))
                Text(headerSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: openSettings) {
                Label("Settings", systemImage: "gearshape")
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 2)
    }

    private var headerSubtitle: String {
        var parts: [String] = []
        if !engine.device.chipName.isEmpty { parts.append(engine.device.chipName) }
        if !engine.device.osVersionString.isEmpty { parts.append("macOS " + engine.device.osVersionString) }
        if engine.device.uptimeSeconds > 0 { parts.append("up " + Fmt.uptime(engine.device.uptimeSeconds)) }
        return parts.isEmpty ? "Gathering system info…" : parts.joined(separator: "  ·  ")
    }

    private var masonry: some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(0..<balancedColumns.count, id: \.self) { column in
                VStack(spacing: 14) {
                    ForEach(balancedColumns[column]) { kind in
                        MetricCardView(kind: kind)
                            .cardReorderable(kind, dragging: draggingCard.projectedValue)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .animation(.default, value: visibleCards)
        .onDrop(of: [.text],
                delegate: CardDropResetDelegate(dragging: draggingCard.projectedValue))
    }

    private var visibleCards: [CardKind] {
        settings.cardOrder.filter { !settings.hiddenCards.contains($0) }
    }

    /// Greedy shortest-column packing by estimated card height, so the two
    /// columns come out roughly even instead of row-aligned with gaps.
    private var balancedColumns: [[CardKind]] {
        var columns: [[CardKind]] = [[], []]
        var heights: [CGFloat] = [0, 0]
        for kind in visibleCards {
            let target = heights[0] <= heights[1] ? 0 : 1
            columns[target].append(kind)
            heights[target] += kind.estimatedCardHeight
        }
        return columns
    }
}

private extension CardKind {
    /// Rough rendered heights used only for column balancing.
    var estimatedCardHeight: CGFloat {
        switch self {
        case .cpu: return 230
        case .gpu: return 200
        case .memory: return 230
        case .disk: return 150
        case .network: return 210
        case .networkData: return 130
        case .battery: return 250
        case .sensors: return 230
        case .fans: return 200
        case .processes: return 220
        case .bluetooth: return 90
        case .device: return 170
        }
    }
}
