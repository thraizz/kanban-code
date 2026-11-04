import Testing
@testable import KanbanCode

@Suite("ToolbarVisibility")
struct ToolbarVisibilityTests {
    // MARK: - Normal mode (not expanded)

    @Test("Normal mode: all controls visible")
    func normalMode() {
        let v = ToolbarVisibility(isExpandedDetail: false, hasSelectedCard: true)
        #expect(v.showBoardControls == true)
        #expect(v.showViewModePicker == true)
        #expect(v.showInspectorToggle == true)
        #expect(v.showExpandedCardInfo == false)
    }

    @Test("Normal mode without card: no expanded card info")
    func normalModeNoCard() {
        let v = ToolbarVisibility(isExpandedDetail: false, hasSelectedCard: false)
        #expect(v.showBoardControls == true)
        #expect(v.showViewModePicker == true)
        #expect(v.showInspectorToggle == true)
        #expect(v.showExpandedCardInfo == false)
    }

    // MARK: - Expanded mode

    @Test("Expanded: board controls, picker, inspector toggle and card info visible")
    func expanded() {
        let v = ToolbarVisibility(isExpandedDetail: true, hasSelectedCard: true)
        #expect(v.showBoardControls == true)
        #expect(v.showViewModePicker == true)
        #expect(v.showInspectorToggle == true)
        #expect(v.showExpandedCardInfo == true)
    }

    // MARK: - Expanded without card

    @Test("Expanded without card: no expanded card info, inspector toggle still visible")
    func expandedNoCard() {
        let v = ToolbarVisibility(isExpandedDetail: true, hasSelectedCard: false)
        #expect(v.showExpandedCardInfo == false)
        #expect(v.showInspectorToggle == true)
        #expect(v.showViewModePicker == true)
    }
}
