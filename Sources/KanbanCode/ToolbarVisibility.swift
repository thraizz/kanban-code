/// Pure-logic model determining which toolbar items are visible in each mode.
/// Extracted from ContentView so it can be unit-tested independently.
struct ToolbarVisibility {
    let isExpandedDetail: Bool
    let hasSelectedCard: Bool

    /// New task, refresh, dark mode, sidebar toggle. The sidebar is a panel
    /// under the window toolbar, with no toolbar of its own, so these stay in
    /// the window's whether it is open or not.
    var showBoardControls: Bool { true }

    /// Kanban/list segmented picker — always visible (toggles between kanban and expanded+sidebar).
    var showViewModePicker: Bool { true }

    /// Inspector toggle (sidebar.right) — always visible.
    /// In expanded mode it deselects the card, showing the empty state.
    var showInspectorToggle: Bool { true }

    /// Expanded card info (title, tab picker, editor, actions).
    var showExpandedCardInfo: Bool {
        isExpandedDetail && hasSelectedCard
    }
}
