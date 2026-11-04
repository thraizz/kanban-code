import SwiftUI

/// Two panes stacked, with a handle between them that sizes the top one.
/// Replaces `VSplitView`, an `NSSplitView`: see `PaneResizeHandle` for why.
struct StackedPaneSplit<Top: View, Bottom: View>: View {
    private let rule: PaneSizeRule
    private let top: Top
    private let bottom: Bottom

    @AppStorage private var storedHeight: Double
    /// The height while a drag is under way. Stored once, when it ends.
    @State private var dragHeight: Double?
    @State private var dragStartHeight: Double?
    @State private var containerHeight: Double = 0

    /// `storageKey` names the default the top pane's height is kept under.
    init(
        rule: PaneSizeRule,
        storageKey: String,
        @ViewBuilder top: () -> Top,
        @ViewBuilder bottom: () -> Bottom
    ) {
        _storedHeight = AppStorage(wrappedValue: rule.ideal, storageKey)
        self.rule = rule
        self.top = top()
        self.bottom = bottom()
    }

    private var topHeight: Double {
        rule.resolved(
            dragHeight ?? storedHeight, container: containerHeight,
            handle: PaneResizeHandle.thickness(.line))
    }

    var body: some View {
        VStack(spacing: 0) {
            top
                .frame(height: topHeight, alignment: .top)
                .frame(maxWidth: .infinity)
            PaneResizeHandle(axis: .vertical) { translation in
                let start = dragStartHeight ?? topHeight
                if dragStartHeight == nil { dragStartHeight = start }
                let next = rule.resolved(
                    start + translation, container: containerHeight,
                    handle: PaneResizeHandle.thickness(.line))
                if next != topHeight { dragHeight = next }
            } onEnded: {
                if let dragHeight { storedHeight = dragHeight }
                dragHeight = nil
                dragStartHeight = nil
            }
            bottom
                .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
                .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .onGeometryChange(for: Double.self) { $0.size.height } action: { containerHeight = $0 }
    }
}
