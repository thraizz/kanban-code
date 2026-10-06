import Testing
import Foundation
@testable import KanbanCodeCore

/// Pane captures of Pi 0.99 in tmux, trimmed to the lines that matter.
@Suite("PaneOutputParser Pi")
struct PiPaneTests {
    static let rule = String(repeating: "─", count: 100)

    static let booted = """
     Pi can explain its own features and look up its docs. Ask it how to use or extend Pi.
     Warning: tmux extended-keys is off. Modified Enter keys may not work.
    \(rule)
    \(rule)
    /Users/me/project (main)
    0.0%/262k (auto)                                          (openrouter) moonshotai/kimi-k2.6 • medium
    """

    static let working = """
     $ sleep 6; echo done (timeout 10s)
     Elapsed 2.0s
    ── ⠙ Working ───────────────────────────────────────────────────────────────────────────────────────
    \(rule)
    /Users/me/project (main)
    ↑2.1k ↓76 R3.7k CH64.0% $0.002 2.2%/262k (auto)           (openrouter) moonshotai/kimi-k2.6 • medium
    """

    static let idle = """
     Took 6.0s
     OK
    \(rule)
    \(rule)
    /Users/me/project (main)
    ↑4.4k ↓106 R7.3k CH61.0% $0.004 2.3%/262k (auto)          (openrouter) moonshotai/kimi-k2.6 • medium
    """

    @Test("Not ready before the editor is drawn")
    func notDrawn() {
        #expect(!PaneOutputParser.isReady("", assistant: .pi))
        #expect(!PaneOutputParser.isReady(" pi v0.99.1\n", assistant: .pi))
    }

    @Test("Ready once the empty editor frame is drawn")
    func booted() {
        #expect(PaneOutputParser.isReady(Self.booted, assistant: .pi))
        #expect(!PaneOutputParser.isWorking(Self.booted, assistant: .pi))
    }

    @Test("Working while the top rule carries a status")
    func working() {
        #expect(!PaneOutputParser.isReady(Self.working, assistant: .pi))
        #expect(PaneOutputParser.isWorking(Self.working, assistant: .pi))
    }

    @Test("Ready again after the reply")
    func idle() {
        #expect(PaneOutputParser.isReady(Self.idle, assistant: .pi))
        #expect(!PaneOutputParser.isWorking(Self.idle, assistant: .pi))
    }

    @Test("A rule with text inside a reply above the editor is not a status")
    func ruleInReply() {
        let pane = "── Summary ──\n" + Self.idle
        #expect(PaneOutputParser.isReady(pane, assistant: .pi))
        #expect(!PaneOutputParser.isWorking(pane, assistant: .pi))
    }
}
