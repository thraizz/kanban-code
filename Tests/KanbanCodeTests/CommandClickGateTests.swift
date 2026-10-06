import Testing

@testable import KanbanCode

@Suite("Cmd+click gate")
struct CommandClickGateTests {
    private let link = "https://github.com/langwatch/langwatch/pull/8411"

    @Test("A cmd+click on a link keeps both press and release from the program and opens once")
    func cmdClickKeepsWholeClick() {
        var gate = CommandClickGate()
        #expect(gate.mouseDown(command: true, link: link) == .consume)
        #expect(gate.mouseDragged() == .consume)
        #expect(gate.mouseUp(link: link) == .open(link))
        // A later release, with no press kept, is the program's.
        #expect(gate.mouseUp(link: link) == .pass)
    }

    @Test("A plain click on a link goes to the program whole")
    func plainClickPasses() {
        var gate = CommandClickGate()
        #expect(gate.mouseDown(command: false, link: link) == .pass)
        #expect(gate.mouseDragged() == .pass)
        #expect(gate.mouseUp(link: link) == .pass)
    }

    @Test("A cmd+press off a link goes to the program, and so does its release over one")
    func cmdPressOffLinkPasses() {
        var gate = CommandClickGate()
        #expect(gate.mouseDown(command: true, link: nil) == .pass)
        #expect(gate.mouseUp(link: link) == .pass)
    }

    @Test("A kept press released off its link opens nothing and the program still sees no release")
    func releasedElsewhere() {
        var gate = CommandClickGate()
        #expect(gate.mouseDown(command: true, link: link) == .consume)
        #expect(gate.mouseUp(link: nil) == .consume)
        #expect(gate.mouseDown(command: true, link: link) == .consume)
        #expect(gate.mouseUp(link: "https://example.com") == .consume)
    }

    @Test("A release after cmd came up still opens the link the press was kept for")
    func cmdLetGoBeforeRelease() {
        var gate = CommandClickGate()
        #expect(gate.mouseDown(command: true, link: link) == .consume)
        #expect(gate.mouseUp(link: link) == .open(link))
    }
}
