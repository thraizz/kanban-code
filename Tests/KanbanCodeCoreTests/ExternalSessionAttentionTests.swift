import Foundation
import Testing

@testable import KanbanCodeCore

/// A discovered card whose Claude Code runs in a Ghostty window, not in a
/// Kanban tmux session, and stops on a permission prompt. The card used to
/// read "session ended" with a Resume button, and the permission request
/// was withdrawn a second after it was raised.
@Suite("Sessions running outside Kanban Code")
struct ExternalSessionAttentionTests {
    let sessionId = "bb6d7885-f8f3-40aa-a155-acb50ff067be"

    @MainActor private func makeEngine(running: Bool) throws -> (MasterEngine, BoardStore) {
        let dir = NSTemporaryDirectory() + "kanban-external-\(UUID().uuidString)"
        let sessions = dir + "/claude-sessions"
        try FileManager.default.createDirectory(atPath: sessions, withIntermediateDirectories: true)
        if running {
            // This test process stands in for the Claude process.
            try #"{"pid":\#(getpid()),"sessionId":"\#(sessionId)","kind":"interactive"}"#
                .write(toFile: sessions + "/\(getpid()).json", atomically: true, encoding: .utf8)
        }
        let transcript = dir + "/\(sessionId).jsonl"
        try #"{"type":"user","timestamp":"2026-11-16T12:13:29.000Z","message":{"role":"user","content":"check the logs"}}"#
            .appending("\n").write(toFile: transcript, atomically: true, encoding: .utf8)

        let store = BoardStore(
            effectHandler: EffectHandler(coordinationStore: CoordinationStore(basePath: dir)),
            discovery: ClaudeCodeSessionDiscovery(),
            coordinationStore: CoordinationStore(basePath: dir)
        )
        let rush = RushCliAdapter(executable: "/nonexistent/rush")
        let engine = MasterEngine(store: store, settingsStore: SettingsStore(basePath: dir),
                                  launcher: LaunchSession(tmux: RoutingTmuxAdapter(rush: rush)),
                                  tmux: RoutingTmuxAdapter(rush: rush), registry: CodingAssistantRegistry())
        engine.platform.claudeSessionsDirectory = sessions
        store.dispatch(.createManualTask(Link(
            id: "card_ext", name: "Check the production logs", projectPath: dir, column: .waiting,
            sessionLink: SessionLink(sessionId: sessionId, sessionPath: transcript))))
        return (engine, store)
    }

    @Test("its permission request stays open, the card says where it runs, and resume is refused")
    @MainActor func runningElsewhere() async throws {
        let (engine, store) = try makeEngine(running: true)
        engine.raisePermissionRequest(sessionId: sessionId, message: "Claude needs your permission to use Bash", at: .now)
        await engine.scanAttention()

        #expect(store.state.openAttentionRequests.contains { $0.sessionId == sessionId && $0.kind == .permission })
        let card = try #require(store.state.cards.first { $0.id == "card_ext" })
        #expect(card.sessionStatus.isElsewhere)
        #expect(!card.sessionStatus.canResume)
        #expect(!engine.resume(cardId: "card_ext", runRemotely: false, commandOverride: nil))
        #expect(store.state.links["card_ext"]?.isLaunching != true)
    }

    @Test("once its process is gone, the request is withdrawn and the card offers the resume")
    @MainActor func gone() async throws {
        let (engine, store) = try makeEngine(running: false)
        engine.raisePermissionRequest(sessionId: sessionId, message: "Claude needs your permission to use Bash", at: .now)
        await engine.scanAttention()

        #expect(!store.state.openAttentionRequests.contains { $0.sessionId == sessionId })
        let card = try #require(store.state.cards.first { $0.id == "card_ext" })
        #expect(card.sessionStatus == .ended)
    }
}
