import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("OpenCodeSessionStore and discovery")
struct OpenCodeSessionStoreTests {
    private func path(_ id: String) -> String {
        OpenCodeDatabase.virtualSessionPath(sessionId: id, home: "/Users/me")
    }

    private func sessionWithPrompt(_ fixture: OpenCodeFixture, id: String, prompt: String, title: String = "Title") throws {
        try fixture.addSession(id: id, title: title)
        let user = try fixture.addMessage(sessionId: id, role: "user")
        try fixture.addPart(messageId: user, sessionId: id, json: #"{"type":"text","text":"\#(prompt)"}"#)
        let reply = try fixture.addMessage(sessionId: id, role: "assistant")
        try fixture.addPart(messageId: reply, sessionId: id, json: #"{"type":"text","text":"Done."}"#)
    }

    @Test("Discovery maps sessions to OpenCode cards with virtual paths")
    func discovery() async throws {
        let fixture = try OpenCodeFixture()
        try sessionWithPrompt(fixture, id: "ses_a", prompt: "Fix the flaky test", title: "Flaky test fix")
        try sessionWithPrompt(fixture, id: "ses_b", prompt: "Rename the module", title: "New session - 2026-09-30T08:00:00.000Z")
        try fixture.addSession(id: "ses_sub", parentId: "ses_a")

        let discovery = OpenCodeSessionDiscovery(database: fixture.database, home: "/Users/me")
        let sessions = try await discovery.discoverSessions().sorted { $0.id < $1.id }

        #expect(sessions.map(\.id) == ["ses_a", "ses_b"])
        #expect(sessions[0].assistant == .opencode)
        #expect(sessions[0].name == "Flaky test fix")
        #expect(sessions[0].firstPrompt == "Fix the flaky test")
        #expect(sessions[0].projectPath == "/work/project")
        #expect(sessions[0].messageCount == 2)
        #expect(sessions[0].jsonlPath == path("ses_a"))
        #expect(sessions[1].name == nil, "the placeholder title is not a name")
        #expect(sessions[1].displayTitle == "Rename the module")
    }

    @Test("The store reads a transcript by virtual path")
    func readTranscript() async throws {
        let fixture = try OpenCodeFixture()
        try sessionWithPrompt(fixture, id: "ses_a", prompt: "Hello")
        let store = OpenCodeSessionStore(database: fixture.database)

        let turns = try await store.readTranscript(sessionPath: path("ses_a"))
        #expect(turns.map(\.textPreview) == ["Hello", "Done."])

        await #expect(throws: SessionStoreError.self) {
            _ = try await store.readTranscript(sessionPath: path("ses_missing"))
        }
        await #expect(throws: OpenCodeSessionStore.StoreError.self) {
            _ = try await store.readTranscript(sessionPath: "/Users/me/.claude/projects/p/x.jsonl")
        }
    }

    @Test("Forking and truncating are refused, not faked")
    func unsupportedWrites() async throws {
        let fixture = try OpenCodeFixture()
        try sessionWithPrompt(fixture, id: "ses_a", prompt: "Hello")
        let store = OpenCodeSessionStore(database: fixture.database)
        await #expect(throws: OpenCodeSessionStore.StoreError.self) {
            _ = try await store.forkSession(sessionPath: path("ses_a"), targetDirectory: nil)
        }
        let turn = ConversationTurn(index: 0, lineNumber: 0, role: "user", textPreview: "Hello")
        await #expect(throws: OpenCodeSessionStore.StoreError.self) {
            try await store.truncateSession(sessionPath: path("ses_a"), afterTurn: turn)
        }
    }

    @Test("Search finds sessions by their text and returns their paths")
    func search() async throws {
        let fixture = try OpenCodeFixture()
        try sessionWithPrompt(fixture, id: "ses_a", prompt: "Migrate the postgres schema")
        try sessionWithPrompt(fixture, id: "ses_b", prompt: "Style the login button")
        let store = OpenCodeSessionStore(database: fixture.database)

        let results = try await store.searchSessions(query: "postgres", paths: [path("ses_a"), path("ses_b")])
        #expect(results.map(\.sessionPath) == [path("ses_a")])
        #expect(results.first?.snippets.first?.contains("postgres") == true)
    }

    @Test("Pushed and created branches come from bash tool calls")
    func pushedBranches() throws {
        let fixture = try OpenCodeFixture()
        try fixture.addSession(id: "ses_a")
        let step = try fixture.addMessage(sessionId: "ses_a", role: "assistant")
        try fixture.addPart(messageId: step, sessionId: "ses_a", json: #"""
            {"type":"tool","tool":"bash","state":{"status":"completed","input":{"command":"git checkout -b feat/login && git push -u origin feat/login"}}}
            """#)
        try fixture.addPart(messageId: step, sessionId: "ses_a", json: #"""
            {"type":"tool","tool":"bash","state":{"status":"completed","input":{"command":"git push origin main"}}}
            """#)

        let branches = try OpenCodeSessionStore.extractPushedBranches(sessionPath: path("ses_a"), database: fixture.database)
        #expect(branches.map(\.branch) == ["feat/login"])
    }
}
