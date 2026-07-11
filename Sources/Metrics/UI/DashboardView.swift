import SwiftUI
import UniformTypeIdentifiers

/// One metric card by kind — shared by the popover and the dashboard window.
/// Cards for unavailable hardware render nothing.
struct MetricCardView: View {
    let kind: CardKind
    /// When true (dashboard/popover), the card gets a collapsible, clickable
    /// title and a one-line summary while collapsed (#48). Desktop widgets pass
    /// false so they keep their full always-on layout.
    var collapsible: Bool = false

    @Environment(MetricsEngine.self) private var engine
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        card.environment(\.cardCollapse, collapseContext)
    }

    @ViewBuilder private var card: some View {
        switch kind {
        case .cpu: CPUCard()
        case .gpu: GPUCard()
        case .power: PowerCard()
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

    /// The collapse state + live summary handed to `CardContainer` (#48). Nil
    /// when this card isn't collapsible, which leaves the container unchanged.
    private var collapseContext: CardCollapseContext? {
        guard collapsible else { return nil }
        return CardCollapseContext(
            collapsed: settings.collapsedCards.contains(kind),
            summary: CardSummary.line(for: kind, engine: engine, settings: settings),
            toggle: {
                withAnimation(.easeInOut(duration: 0.25)) { settings.toggleCollapsed(kind) }
            })
    }
}

// MARK: - Right-click card menu (feature #49)

private extension View {
    /// Right-click context menu shared by the popover and dashboard cards:
    /// hide, move to top, and add/remove the desktop widget.
    func cardContextMenu(_ kind: CardKind, settings: SettingsStore) -> some View {
        contextMenu {
            Button {
                withAnimation { _ = settings.hiddenCards.insert(kind) }
            } label: {
                Label("Hide Card", systemImage: "eye.slash")
            }
            Button {
                withAnimation { settings.moveCardToTop(kind) }
            } label: {
                Label("Move to Top", systemImage: "arrow.up.to.line")
            }
            // Fans has no desktop widget (matches the Widgets settings tab).
            if kind != .fans {
                let isWidget = settings.desktopWidgets.contains(kind)
                Button {
                    settings.toggleDesktopWidget(kind)
                    // A freshly added widget floats immediately so it can be
                    // dragged into place (same behavior as the settings toggle).
                    if !isWidget { DesktopWidgetController.shared.arranging = true }
                } label: {
                    Label(isWidget ? "Remove Desktop Widget" : "Add Desktop Widget",
                          systemImage: isWidget ? "rectangle.badge.minus" : "rectangle.badge.plus")
                }
            }
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
    /// Makes a card draggable and a live-reorder drop target. Dragging lifts the
    /// card — a slight scale + shadow — and the spring settles it on drop (#50),
    /// replacing the old flat 0.4-opacity feedback.
    func cardReorderable(_ kind: CardKind, dragging: Binding<CardKind?>) -> some View {
        let lifted = dragging.wrappedValue == kind
        return self
            .scaleEffect(lifted ? 1.02 : 1)
            .shadow(color: .black.opacity(lifted ? 0.22 : 0),
                    radius: lifted ? 10 : 0, y: lifted ? 5 : 0)
            .opacity(lifted ? 0.97 : 1)
            .zIndex(lifted ? 1 : 0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: lifted)
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
    /// Pin support (#45): the controller-owned observable that both this header
    /// and the popover's close behavior read. Nil in contexts without a
    /// pinnable popover.
    var popoverState: PopoverState? = nil
    var onTogglePin: (() -> Void)? = nil

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
                    ForEach(settings.visibleCards) { kind in
                        MetricCardView(kind: kind, collapsible: true)
                            .cardReorderable(kind, dragging: draggingCard.projectedValue)
                            .cardContextMenu(kind, settings: settings)
                    }
                }
                .padding(12)
                .animation(.default, value: settings.visibleCards)
                .onDrop(of: [.text],
                        delegate: CardDropResetDelegate(dragging: draggingCard.projectedValue))
            }
        }
        .frame(width: 360, height: 580)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Metrics")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if let popoverState, let onTogglePin {
                Button(action: onTogglePin) {
                    Image(systemName: popoverState.pinned ? "pin.fill" : "pin")
                }
                .buttonStyle(.plain)
                .foregroundStyle(popoverState.pinned ? Color.accentColor : Color.secondary)
                .help(popoverState.pinned
                      ? "Unpin — clicking away closes the popover again"
                      : "Pin — keep the popover open when clicking away")
            }
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
    @Environment(DashboardNavigator.self) private var navigator
    var openSettings: () -> Void
    var openWeekly: () -> Void

    // Plain State (not @State): the macro form needs the SwiftUIMacros plugin,
    // which the Command Line Tools toolchain doesn't ship. SwiftUI picks up
    // stored DynamicProperty values by reflection, so this behaves the same.
    private var draggingCard = State(initialValue: CardKind?.none)
    /// The card currently pulsing from a deep-link/menu-bar focus (#37).
    private var highlightedCard = State(initialValue: CardKind?.none)

    var body: some View {
        VStack(spacing: 0) {
            // macOS Tahoe AppKit bug (FB21850950): a scroll view whose top
            // edge touches the content view's top bleeds its scrolled rows
            // into the titlebar. One point of breathing room prevents it.
            Color.clear.frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header
                        masonry
                    }
                    .padding(20)
                }
                // Driven by metrics://card/<kind> and the "open dashboard at
                // card" menu bar click: scroll the requested card to the top
                // whenever the navigator bumps its nonce.
                .onChange(of: navigator.scrollNonce) {
                    guard let target = navigator.scrollTarget else { return }
                    withAnimation { proxy.scrollTo(target, anchor: .top) }
                }
                // Brief highlight pulse on the focused card (#37).
                .onChange(of: navigator.highlightNonce) {
                    guard let target = navigator.highlightTarget else { return }
                    highlightedCard.wrappedValue = target
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        if highlightedCard.wrappedValue == target { highlightedCard.wrappedValue = nil }
                    }
                }
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
            Button(action: openWeekly) {
                Label("This Week", systemImage: "calendar")
            }
            .controlSize(.small)
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
                        MetricCardView(kind: kind, collapsible: true)
                            .cardReorderable(kind, dragging: draggingCard.projectedValue)
                            .cardContextMenu(kind, settings: settings)
                            .overlay(cardHighlight(kind))
                            .id(kind) // scroll target for metrics://card/<kind>
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .animation(.default, value: settings.visibleCards)
        .onDrop(of: [.text],
                delegate: CardDropResetDelegate(dragging: draggingCard.projectedValue))
    }

    /// The deep-link highlight ring drawn over a focused card (#37).
    @ViewBuilder private func cardHighlight(_ kind: CardKind) -> some View {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(Color.accentColor, lineWidth: 2)
            .opacity(highlightedCard.wrappedValue == kind ? 1 : 0)
            .animation(.easeInOut(duration: 0.4), value: highlightedCard.wrappedValue)
            .allowsHitTesting(false)
    }

    /// Greedy shortest-column packing by estimated card height, so the two
    /// columns come out roughly even instead of row-aligned with gaps. A
    /// collapsed card (#48) counts as a single summary line.
    private var balancedColumns: [[CardKind]] {
        var columns: [[CardKind]] = [[], []]
        var heights: [CGFloat] = [0, 0]
        for kind in settings.visibleCards {
            let target = heights[0] <= heights[1] ? 0 : 1
            columns[target].append(kind)
            heights[target] += settings.collapsedCards.contains(kind) ? 46 : kind.estimatedCardHeight
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
        case .power: return 220
        case .memory: return 260
        case .disk: return 300
        case .network: return 340
        case .networkData: return 190
        case .battery: return 310
        case .sensors: return 260
        case .fans: return 200
        case .processes: return 220
        case .bluetooth: return 90
        case .device: return 340
        }
    }
}
