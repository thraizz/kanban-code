import SwiftUI

/// The handle between two panes that sizes them: a hairline, or the gap
/// between two floating panels.
///
/// Splits in this app are built from this rather than `NSSplitView` (which
/// is what `.inspector`, `NavigationSplitView`, `HSplitView` and `VSplitView`
/// are). While its divider is dragged, the split view runs its own
/// event-tracking loop, and AppKit counts every update-constraints pass in
/// that loop against one display cycle, with a limit of about the number of
/// views in the window. Live content re-marks constraints a few times per
/// drag step, so a few seconds of dragging went past the limit and the app
/// crashed ("more Update Constraints in Window passes than there are views in
/// the window", or a crash in `swift_beginAccess` right after it). A drag
/// gesture gets each mouse event through the normal event loop, so every step
/// is its own display cycle and the count starts over.
struct PaneResizeHandle: View {
    enum Style {
        /// A hairline, as a split view draws its divider.
        case line
        /// Empty space between two panels that draw their own edges.
        case gap
    }

    /// The direction the handle moves in: `.horizontal` for the handle
    /// between panes side by side, `.vertical` for panes stacked.
    let axis: Axis
    var style: Style = .line
    /// The distance moved along the axis since the drag began.
    let onChanged: (Double) -> Void
    let onEnded: () -> Void

    @Environment(\.colorSchemeContrast) private var contrast

    /// The room a handle of this style takes in the layout.
    static func thickness(_ style: Style) -> Double {
        switch style {
        case .line: 1
        case .gap: 8
        }
    }

    private static let grabSize: Double = 9

    var body: some View {
        let horizontal = axis == .horizontal
        let thickness = Self.thickness(style)
        let grab = max(thickness, Self.grabSize)
        lineOrGap
            .frame(width: horizontal ? thickness : nil, height: horizontal ? nil : thickness)
            .frame(maxWidth: horizontal ? nil : .infinity, maxHeight: horizontal ? .infinity : nil)
            .overlay {
                // Wider than a hairline, so over the edges of both panes and
                // drawn above them.
                Color.clear
                    .frame(width: horizontal ? grab : nil, height: horizontal ? nil : grab)
                    .contentShape(Rectangle())
                    .pointerStyle(horizontal ? .columnResize : .rowResize)
                    .gesture(drag)
            }
            .zIndex(1)
    }

    @ViewBuilder
    private var lineOrGap: some View {
        switch style {
        case .line:
            // With Increase Contrast a split view's divider is near white,
            // which the separator colour is not.
            Rectangle().fill(
                contrast == .increased
                    ? Color(nsColor: .secondaryLabelColor)
                    : Color(nsColor: .separatorColor))
        case .gap:
            Color.clear
        }
    }

    private var drag: some Gesture {
        // Global coordinates: the handle moves with the drag, so translation
        // measured in its own space would shift under the pointer.
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                onChanged(axis == .horizontal ? value.translation.width : value.translation.height)
            }
            .onEnded { _ in onEnded() }
    }
}
