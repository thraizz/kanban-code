import Darwin
import Testing
@testable import KanbanCode

@Suite("SystemTray")
struct SystemTrayTests {
    @Test("Active-session shutdown PIDs are deduplicated and sanitized")
    func uniqueActiveSessionPIDs() {
        let pids = SystemTray.uniqueActiveSessionPIDs([123, 0, -1, nil, 123, 456])

        #expect(pids == Set<pid_t>([123, 456]))
    }

    @Test("Menu is not rebuilt when content is unchanged")
    func noRebuildWhenUnchanged() {
        let a = SystemTray.MenuContent.make(active: [("A", true)], waiting: ["W"])
        let b = SystemTray.MenuContent.make(active: [("A", true)], waiting: ["W"])
        #expect(!SystemTray.needsMenuRebuild(previous: a, current: b))
    }

    @Test("Menu is rebuilt on first build and when titles, kinds or sections change")
    func rebuildOnChange() {
        let base = SystemTray.MenuContent.make(active: [("A", true)], waiting: [])
        #expect(SystemTray.needsMenuRebuild(previous: nil, current: base))
        #expect(SystemTray.needsMenuRebuild(previous: base, current: .make(active: [("B", true)], waiting: [])))
        #expect(SystemTray.needsMenuRebuild(previous: base, current: .make(active: [("A", false)], waiting: [])))
        #expect(SystemTray.needsMenuRebuild(previous: base, current: .make(active: [("A", true)], waiting: ["W"])))
        #expect(SystemTray.needsMenuRebuild(previous: base, current: .make(active: [], waiting: [])))
    }

    @Test("Cards beyond the visible limit do not trigger a rebuild")
    func hiddenCardsIgnored() {
        let five = (0..<5).map { ("c\($0)", false) }
        let seven = five + [("c5", false), ("c6", true)]
        #expect(!SystemTray.needsMenuRebuild(
            previous: .make(active: five, waiting: []),
            current: .make(active: seven, waiting: [])))
    }
}
