import Testing
import Foundation
@testable import KanbanCodeCore

/// Pane captures of OpenCode 1.18 in tmux, trimmed to the lines that matter.
@Suite("PaneOutputParser OpenCode")
struct OpenCodePaneTests {
    static let booting = """
                                                                  ▄
                                 █▀▀█ █▀▀█ █▀▀█ █▀▀▄ █▀▀▀ █▀▀█ █▀▀█ █▀▀█
                                 █  █ █  █ █▀▀▀ █  █ █    █  █ █  █ █▀▀▀
                                 ▀▀▀▀ █▀▀▀ ▀▀▀▀ ▀▀▀▀ ▀▀▀▀ ▀▀▀▀ ▀▀▀▀ ▀▀▀▀
    """

    static let freshHome = """
                                 ▀▀▀▀ █▀▀▀ ▀▀▀▀ ▀▀▀▀ ▀▀▀▀ ▀▀▀▀ ▀▀▀▀ ▀▀▀▀
               ┃
               ┃  Ask anything… "Fix broken tests"
               ┃
               ┃  Build · Gemini 3.8 Flash OpenCode Zen · high
               ╹▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀
                                                   tab agents  ctrl+p commands
      /Users/me/project                                    ⊙ 4 MCP /status    1.18.32
    """

    /// A resumed or finished session: an empty input box, the footer wrapped.
    static let idleInSession = """
         SECRET-WORD-PINEAPPLE
         ▣  Build · Gemini 3.8 Flash · 6.8s
      ┃
      ┃
      ┃
      ┃  Build · Gemini 3.8 Flash OpenCode Zen · high
      ╹▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀
       /Users/me/project                          49.4K (5%) · $0 ctrl+p
                                                                 commands
    """

    static let working = """
      ┃  Line two: reply with exactly the word BANANA and nothing else.
         ▣  Build · Gemini 3.8 Flash
      ┃
      ┃  Build · Gemini 3.8 Flash OpenCode Zen · high
      ╹▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀
       ■■⬝⬝⬝⬝⬝⬝  esc interrupt                           49.4K (5%) · $0.09  ctrl+p commands
    """

    static let permission = """
      ┃  △ Permission required
      ┃    ← Access external directory /Users/me/outside
      ┃  Patterns
      ┃  - /Users/me/outside/*
      ┃   Allow once   Allow always   Reject          ctrl+f fullscreen  ⇆ select  enter confirm
      ┃
    """

    @Test("Not ready while booting")
    func booting() {
        #expect(!PaneOutputParser.isReady(Self.booting, assistant: .opencode))
        #expect(!PaneOutputParser.isReady("", assistant: .opencode))
    }

    @Test("Ready on the home screen and in an idle session")
    func ready() {
        #expect(PaneOutputParser.isReady(Self.freshHome, assistant: .opencode))
        #expect(PaneOutputParser.isReady(Self.idleInSession, assistant: .opencode))
    }

    @Test("Working and waiting on a permission are not ready")
    func notReadyWhileBusy() {
        #expect(!PaneOutputParser.isReady(Self.working, assistant: .opencode))
        #expect(!PaneOutputParser.isReady(Self.permission, assistant: .opencode))
    }

    @Test("Working shows while the footer offers to interrupt")
    func isWorking() {
        #expect(PaneOutputParser.isWorking(Self.working, assistant: .opencode))
        #expect(!PaneOutputParser.isWorking(Self.idleInSession, assistant: .opencode))
    }
}
