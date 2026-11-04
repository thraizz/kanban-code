import SwiftUI

/// Size rules for the pane of a split: the sidebar, the card detail, the
/// Overview's card list.
struct PaneSizeRule: Equatable {
    var minimum: Double
    var ideal: Double
    var maximum: Double
    /// What the rest of the split keeps while the pane is above its minimum.
    var minimumRest: Double

    static let sidebar = PaneSizeRule(minimum: 280, ideal: 320, maximum: 720, minimumRest: 400)
    static let cardDetail = PaneSizeRule(minimum: 600, ideal: 800, maximum: 1000, minimumRest: 280)
    static let overviewList = PaneSizeRule(minimum: 120, ideal: 280, maximum: .infinity, minimumRest: 200)

    /// The size the pane takes for a wanted size, in a container this big
    /// beside a handle this thick. A container of 0 means not measured yet.
    ///
    /// In a small container the pane shrinks first, down to its minimum, and
    /// the rest keeps `minimumRest`. Below that the rest gives way: the pane's
    /// content does not fit in less than its minimum, and laid out smaller it
    /// spills over its neighbour.
    func resolved(_ wanted: Double, container: Double, handle: Double) -> Double {
        let clamped = min(max(wanted, minimum), maximum)
        guard container > 0 else { return clamped.rounded() }
        let available = max(0, container - handle)
        let room = available - minimumRest
        return (room >= minimum ? min(clamped, room) : min(minimum, available)).rounded()
    }
}

/// Main content with a pane beside it, on its leading or trailing edge, and
/// a handle between them that sizes the pane. Replaces `NavigationSplitView`
/// and `.inspector`, both `NSSplitView`s: see `PaneResizeHandle` for why.
struct SidePaneSplit<Main: View, Pane: View>: View {
    private let edge: HorizontalEdge
    private let isPaneOpen: Bool
    private let rule: PaneSizeRule
    private let handleStyle: PaneResizeHandle.Style
    private let main: Main
    private let pane: Pane

    @AppStorage private var storedWidth: Double
    /// The width while a drag is under way. Stored once, when it ends.
    @State private var dragWidth: Double?
    @State private var dragStartWidth: Double?
    @State private var containerWidth: Double = 0

    /// `storageKey` names the default the pane's width is kept under.
    init(
        edge: HorizontalEdge,
        isPaneOpen: Bool,
        rule: PaneSizeRule,
        storageKey: String,
        handleStyle: PaneResizeHandle.Style = .line,
        @ViewBuilder main: () -> Main,
        @ViewBuilder pane: () -> Pane
    ) {
        self.edge = edge
        self.isPaneOpen = isPaneOpen
        self.rule = rule
        self.handleStyle = handleStyle
        self.main = main()
        self.pane = pane()
        _storedWidth = AppStorage(wrappedValue: rule.ideal, storageKey)
    }

    private var paneWidth: Double {
        rule.resolved(
            dragWidth ?? storedWidth, container: containerWidth,
            handle: PaneResizeHandle.thickness(handleStyle))
    }

    var body: some View {
        HStack(spacing: 0) {
            if edge == .leading, isPaneOpen {
                sizedPane
                handle
            }
            main
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if edge == .trailing, isPaneOpen {
                handle
                sizedPane
            }
        }
        // The window's minimum size comes from its content. Left to the
        // pane's fixed width, it would change on every drag step.
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .onGeometryChange(for: Double.self) { $0.size.width } action: { containerWidth = $0 }
    }

    /// Content wider than the pane runs off on the pane's outer side, never
    /// back over the main content.
    private var sizedPane: some View {
        pane
            .frame(width: paneWidth, alignment: edge == .leading ? .trailing : .leading)
            .frame(maxHeight: .infinity)
    }

    private var handle: some View {
        PaneResizeHandle(axis: .horizontal, style: handleStyle) { translation in
            let start = dragStartWidth ?? paneWidth
            if dragStartWidth == nil { dragStartWidth = start }
            let wanted = edge == .leading ? start + translation : start - translation
            let next = rule.resolved(
                wanted, container: containerWidth, handle: PaneResizeHandle.thickness(handleStyle))
            if next != paneWidth { dragWidth = next }
        } onEnded: {
            if let dragWidth { storedWidth = dragWidth }
            dragWidth = nil
            dragStartWidth = nil
        }
    }
}
