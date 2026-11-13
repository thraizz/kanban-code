import Foundation
import Testing

@testable import KanbanCodeCore

/// A pane whose foreground program the test sets.
private final class PaneTmux: TmuxManagerPort, @unchecked Sendable {
    private let lock = NSLock()
    private var _command: String?
    private var _sent: [String] = []
    init(command: String?) { _command = command }
    var command: String? {
        get { lock.withLock { _command } }
        set { lock.withLock { _command = newValue } }
    }
    var sent: [String] { lock.withLock { _sent } }

    func paneCommand(sessionName: String) async throws -> String? { command }
    func listSessions() async throws -> [TmuxSession] { [] }
    func createSession(name: String, path: String, command: String?) async throws {}
    func killSession(name: String) async throws {}
    func findSessionForWorktree(sessions: [TmuxSession], worktreePath: String, branch: String?) -> TmuxSession? { nil }
    func sendPrompt(to sessionName: String, text: String) async throws { lock.withLock { _sent.append(text) } }
    func pastePrompt(to sessionName: String, text: String) async throws { lock.withLock { _sent.append(text) } }
    func pasteText(to sessionName: String, text: String) async throws {}
    func submitPrompt(to sessionName: String) async throws {}
    func capturePane(sessionName: String) async throws -> String { "" }
    func sendBracketedPaste(to sessionName: String) async throws {}
    func isAvailable() async -> Bool { true }
}

private final class Dispatched: @unchecked Sendable {
    private let lock = NSLock()
    private var _actions: [Action] = []
    func add(_ action: Action) { lock.withLock { _actions.append(action) } }
    var requeued: [(String, QueuedPrompt, QueuedPromptPlacement)] {
        lock.withLock {
            _actions.compactMap {
                if case .addQueuedPrompt(let card, let prompt, let placement) = $0 { return (card, prompt, placement) }
                return nil
            }
        }
    }
}

@Suite("Prompts to a pane without its assistant")
struct PromptToBareShellTests {
    private func handler(_ tmux: PaneTmux) -> EffectHandler {
        EffectHandler(
            coordinationStore: CoordinationStore(basePath: NSTemporaryDirectory() + "kanban-shell-\(UUID().uuidString)"),
            tmuxAdapter: tmux,
            assistantStartWait: .milliseconds(600)
        )
    }

    @Test("a prompt to a bare shell is not typed into it and goes back to the front of the queue")
    func bareShellRequeues() async {
        let tmux = PaneTmux(command: "zsh")
        let dispatched = Dispatched()
        let prompt = QueuedPrompt(body: "if there are no more findings, merge to stage")
        await handler(tmux).execute(
            .sendPromptToTmux(sessionName: "claude-1", promptBody: prompt.body, assistant: .claude,
                              requeue: PromptRequeue(cardId: "card_1", prompt: prompt)),
            dispatch: { dispatched.add($0) })
        #expect(tmux.sent.isEmpty)
        let requeued = dispatched.requeued
        #expect(requeued.count == 1)
        #expect(requeued.first?.0 == "card_1")
        #expect(requeued.first?.1.id == prompt.id)
        #expect(requeued.first?.1.sendAutomatically == false)
        #expect(requeued.first?.2 == .front)
    }

    @Test("a prompt waits for an assistant that is still starting")
    func waitsForStart() async {
        let tmux = PaneTmux(command: "-zsh")
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            tmux.command = "2.1.300"
        }
        await handler(tmux).execute(
            .sendPromptToTmux(sessionName: "claude-1", promptBody: "go on", assistant: .claude),
            dispatch: { _ in })
        #expect(tmux.sent == ["go on"])
    }

    @Test("a running assistant, or a pane that can't be asked, takes the prompt at once")
    func runningAssistantSends() async {
        for command in ["claude", "2.1.300", nil] as [String?] {
            let tmux = PaneTmux(command: command)
            await handler(tmux).execute(
                .sendPromptToTmux(sessionName: "claude-1", promptBody: "go on", assistant: .claude),
                dispatch: { _ in })
            #expect(tmux.sent == ["go on"])
        }
    }

    @Test("a resume whose folder is gone continues in the worktree's repository")
    func fallbackDirectory() {
        let existing: Set<String> = ["/r/repo", "/r"]
        let exists = { existing.contains($0) }
        #expect(MasterEngine.resumeFallbackDirectory(
            for: "/r/repo/.claude/worktrees/x", projectPath: "/r/repo/.claude/worktrees/x", exists: exists) == "/r/repo")
        #expect(MasterEngine.resumeFallbackDirectory(
            for: "/r/repo/wt/x", projectPath: "/r/repo", exists: exists) == "/r/repo")
        #expect(MasterEngine.resumeFallbackDirectory(
            for: "/r/other/deep/x", projectPath: nil, exists: exists) == "/r")
        #expect(MasterEngine.resumeFallbackDirectory(for: "/gone/x", projectPath: nil, exists: exists) == nil)
    }
}
