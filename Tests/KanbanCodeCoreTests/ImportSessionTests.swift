import Foundation
import Testing

@testable import KanbanCodeCore

/// File › Import Claude Code Session and `kanban import`: a session started
/// in another terminal comes onto the board and continues in Kanban Code.
/// Resuming starts a real tmux session, so these stop short of it: they
/// cover finding the session, the card, and the wait for a session still
/// open elsewhere.
@Suite("Importing a Claude Code session")
struct ImportSessionTests {
    let sessionId = "854054b6-24ff-45e2-bdb9-8feb1f70caf1"

    struct Fixture {
        let engine: MasterEngine
        let store: BoardStore
        let projectPath: String
        let transcript: String
    }

    /// A transcript under a Claude projects folder; with `running`, this test
    /// process stands in for the Claude process that still has it open.
    @MainActor private func makeFixture(running: Bool, card: Link? = nil) throws -> Fixture {
        let dir = NSTemporaryDirectory() + "kanban-import-\(UUID().uuidString)"
        let projects = dir + "/claude-projects"
        let sessions = dir + "/claude-sessions"
        let projectPath = dir + "/my-repo"
        let folder = projects + "/" + SessionFileMover.encodeProjectPath(projectPath)
        for path in [folder, sessions, projectPath] {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        if running {
            try #"{"pid":\#(getpid()),"sessionId":"\#(sessionId)","kind":"interactive"}"#
                .write(toFile: sessions + "/\(getpid()).json", atomically: true, encoding: .utf8)
        }
        let transcript = folder + "/\(sessionId).jsonl"
        try #"{"type":"user","cwd":"\#(projectPath)","sessionId":"\#(sessionId)","timestamp":"2026-11-19T12:13:29.000Z","message":{"role":"user","content":"fix the flaky test"}}"#
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
        engine.platform.claudeProjectsDirectory = projects
        // Never the real title model in a test.
        engine.platform.titleConversation = { _ in "Fix the flaky parser test" }
        if let card { store.dispatch(.createManualTask(card)) }
        return Fixture(engine: engine, store: store, projectPath: projectPath, transcript: transcript)
    }

    /// Stops the wait the import started, so it does not outlive the test.
    @MainActor private func stopWaiting(_ fixture: Fixture, cardId: String) {
        fixture.store.dispatch(.archiveCard(cardId: cardId))
    }

    @Test("the id is found in a bare id, a resume line and a transcript path")
    func sessionIdParsing() {
        #expect(MasterEngine.claudeSessionId(in: " 854054B6-24FF-45E2-BDB9-8FEB1F70CAF1\n") == sessionId)
        #expect(MasterEngine.claudeSessionId(in: "claude --resume \(sessionId)") == sessionId)
        #expect(MasterEngine.claudeSessionId(in: "~/.claude/projects/-Users-me-repo/\(sessionId).jsonl") == sessionId)
        #expect(MasterEngine.claudeSessionId(in: "854054b6-24ff") == nil)
        #expect(MasterEngine.claudeSessionId(in: "") == nil)
    }

    @Test("text without an id, or an id with no transcript, is refused")
    @MainActor func refused() async throws {
        let fixture = try makeFixture(running: false)
        await #expect(throws: SessionImportError.noSessionId("not an id")) {
            try await fixture.engine.importClaudeSession("not an id")
        }
        let unknown = "00000000-0000-4000-8000-000000000000"
        await #expect(throws: SessionImportError.transcriptNotFound(unknown)) {
            try await fixture.engine.importClaudeSession(unknown)
        }
        #expect(fixture.store.state.links.isEmpty)
    }

    @Test("a session with no card gets one, on the board, in the folder it ran in")
    @MainActor func newCard() async throws {
        let fixture = try makeFixture(running: true)
        let imported = try await fixture.engine.importClaudeSession(sessionId)
        defer { stopWaiting(fixture, cardId: imported.cardId) }

        let link = try #require(fixture.store.state.links[imported.cardId])
        #expect(link.sessionLink?.sessionId == sessionId)
        #expect(link.sessionLink?.sessionPath == fixture.transcript)
        #expect(link.projectPath == fixture.projectPath)
        #expect(link.column == .waiting)
        #expect(fixture.store.state.selectedCardId == imported.cardId)
    }

    @Test("a card without a name is named from its conversation; a named one keeps its name")
    @MainActor func naming() async throws {
        let fixture = try makeFixture(running: true)
        let imported = try await fixture.engine.importClaudeSession(sessionId)
        defer { stopWaiting(fixture, cardId: imported.cardId) }
        for _ in 0..<50 where fixture.store.state.links[imported.cardId]?.name == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(fixture.store.state.links[imported.cardId]?.name == "Fix the flaky parser test")

        let named = Link(
            id: "card_named", name: "My own name", projectPath: "/tmp/repo", column: .waiting,
            source: .discovered, sessionLink: SessionLink(sessionId: sessionId, sessionPath: fixture.transcript))
        let other = try makeFixture(running: true, card: named)
        let again = try await other.engine.importClaudeSession(sessionId)
        defer { stopWaiting(other, cardId: again.cardId) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(other.store.state.links["card_named"]?.name == "My own name")
    }

    @Test("a session still open in a terminal waits for it to be quit instead of starting a second process")
    @MainActor func waitsForExit() async throws {
        let fixture = try makeFixture(running: true)
        let imported = try await fixture.engine.importClaudeSession("claude --resume \(sessionId)")
        defer { stopWaiting(fixture, cardId: imported.cardId) }

        guard case .waitingForExit(let process) = imported.outcome else {
            Issue.record("expected a wait, got \(imported.outcome)")
            return
        }
        #expect(process.pid == getpid())
        #expect(imported.outcome.commandStatus == "waiting")
        #expect(fixture.store.state.links[imported.cardId]?.isLaunching != true)
        #expect(fixture.engine.importsWaitingForExit.contains(sessionId))
        // A second import of the same session does not wait twice.
        let again = try await fixture.engine.importClaudeSession(sessionId)
        #expect(again.cardId == imported.cardId)
        #expect(fixture.store.state.links.count == 1)
    }

    @Test("an archived card of the session comes back onto the board")
    @MainActor func archivedCard() async throws {
        let card = Link(
            id: "card_archived", projectPath: "/tmp/repo", column: .allSessions,
            manuallyArchived: true, source: .discovered,
            sessionLink: SessionLink(sessionId: sessionId, sessionPath: "/tmp/elsewhere.jsonl"),
            headless: true)
        let fixture = try makeFixture(running: true, card: card)
        let imported = try await fixture.engine.importClaudeSession(sessionId)
        defer { stopWaiting(fixture, cardId: imported.cardId) }

        #expect(imported.cardId == "card_archived")
        let link = try #require(fixture.store.state.links["card_archived"])
        #expect(!link.manuallyArchived)
        #expect(link.headless == false)
        #expect(link.column == .waiting)
        #expect(fixture.store.state.links.count == 1)
    }

    @Test("a session that already runs in Kanban Code is only selected")
    @MainActor func alreadyRunning() async throws {
        let card = Link(
            id: "card_live", projectPath: "/tmp/repo", column: .inProgress, source: .discovered,
            sessionLink: SessionLink(sessionId: sessionId, sessionPath: "/tmp/live.jsonl"),
            tmuxLink: TmuxLink(sessionName: "claude-854054b6"))
        let fixture = try makeFixture(running: false, card: card)
        let imported = try await fixture.engine.importClaudeSession(sessionId)

        #expect(imported == SessionImport(cardId: "card_live", sessionId: sessionId, outcome: .alreadyRunning))
        #expect(fixture.store.state.selectedCardId == "card_live")
        #expect(fixture.store.state.links["card_live"]?.isLaunching != true)
    }

    @Test("a process counts as running only while its pid has the same start time")
    func processRuns() throws {
        let started = ClaudeLiveSessions.systemProcessInfo(getpid())?.started
        #expect(MasterEngine.processRuns(pid: getpid(), started: started))
        #expect(!MasterEngine.processRuns(pid: getpid(), started: .distantPast))

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        let pid = child.processIdentifier
        #expect(MasterEngine.processRuns(pid: pid, started: nil))
        child.terminate()
        child.waitUntilExit()
        #expect(!MasterEngine.processRuns(pid: pid, started: nil))
    }
}
