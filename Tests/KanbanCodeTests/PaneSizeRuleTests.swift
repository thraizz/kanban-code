import Testing
@testable import KanbanCode

@Suite("PaneSizeRule")
struct PaneSizeRuleTests {
    private let rule = PaneSizeRule(minimum: 600, ideal: 800, maximum: 1000, minimumRest: 280)
    private let handle: Double = 1

    private func resolved(_ wanted: Double, container: Double) -> Double {
        rule.resolved(wanted, container: container, handle: handle)
    }

    @Test("A wanted size inside the range is kept")
    func insideRange() {
        #expect(resolved(750, container: 2000) == 750)
    }

    @Test("A wanted size outside the range is clamped to it")
    func clampedToRange() {
        #expect(resolved(200, container: 2000) == rule.minimum)
        #expect(resolved(5000, container: 2000) == rule.maximum)
    }

    @Test("Before the container is measured, only the range applies")
    func unmeasuredContainer() {
        #expect(resolved(900, container: 0) == 900)
    }

    @Test("A small container shrinks the pane and leaves the rest its minimum")
    func smallContainer() {
        #expect(resolved(900, container: 1000) == 1000 - handle - rule.minimumRest)
    }

    @Test("Too small for both minimums, the pane keeps its minimum and the rest gives way")
    func paneKeepsMinimum() {
        #expect(resolved(900, container: 650) == rule.minimum)
    }

    @Test("A container smaller than the pane minimum goes all to the pane")
    func tinyContainer() {
        #expect(resolved(800, container: 400) == 400 - handle)
    }

    @Test("Sizes are whole points")
    func roundsToWholePoints() {
        #expect(resolved(700.4, container: 2000) == 700)
    }

    @Test("No maximum: a wanted size is limited only by the room left")
    func unbounded() {
        let list = PaneSizeRule.overviewList
        #expect(list.resolved(5000, container: 1000, handle: handle) == 1000 - handle - list.minimumRest)
    }

    @Test("A handle's thickness comes out of the room")
    func gapHandle() {
        let gap = PaneResizeHandle.thickness(.gap)
        #expect(rule.resolved(900, container: 1000, handle: gap) == 1000 - gap - rule.minimumRest)
    }
}
