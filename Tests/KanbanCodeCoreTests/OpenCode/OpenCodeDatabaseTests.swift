import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("OpenCodeDatabase")
struct OpenCodeDatabaseTests {
    @Test("A missing database reads as empty")
    func missingDatabase() throws {
        let database = OpenCodeDatabase(path: "/nonexistent/\(UUID().uuidString)/opencode.db")
        #expect(try database.sessions().isEmpty)
        #expect(try database.session(id: "ses_x") == nil)
        #expect(database.newSessionId(directory: "/work", createdSince: .distantPast) == nil)
    }

    @Test("A database without OpenCode's tables reads as empty")
    func foreignSchema() throws {
        let fixture = try OpenCodeFixture()
        try fixture.exec("DROP TABLE part")
        #expect(try fixture.database.parts(sessionId: "ses_a").isEmpty)
    }

    @Test("Sessions leave out subagent runs and archived sessions")
    func topLevelOnly() throws {
        let fixture = try OpenCodeFixture()
        try fixture.addSession(id: "ses_top")
        try fixture.addSession(id: "ses_child", parentId: "ses_top")
        try fixture.addSession(id: "ses_archived", archived: fixture.tick())

        #expect(try fixture.database.sessions().map(\.id) == ["ses_top"])
        #expect(try fixture.database.session(id: "ses_child")?.parentId == "ses_top")
    }

    @Test("Sessions since a date are the ones updated after it")
    func updatedAfter() throws {
        let fixture = try OpenCodeFixture()
        try fixture.addSession(id: "ses_old", updated: OpenCodeFixture.millis(ago: 3600))
        try fixture.addSession(id: "ses_new", updated: OpenCodeFixture.millis(ago: 5))

        let recent = try fixture.database.sessions(updatedAfter: Date.now.addingTimeInterval(-60))
        #expect(recent.map(\.id) == ["ses_new"])
    }

    @Test("The first prompt skips text OpenCode injected")
    func firstPromptSkipsSynthetic() throws {
        let fixture = try OpenCodeFixture()
        try fixture.addSession(id: "ses_a")
        let user = try fixture.addMessage(sessionId: "ses_a", role: "user")
        try fixture.addPart(messageId: user, sessionId: "ses_a", json: #"{"type":"text","text":"<file contents>","synthetic":true}"#)
        try fixture.addPart(messageId: user, sessionId: "ses_a", json: #"{"type":"text","text":"Fix the login bug"}"#)

        #expect(try fixture.database.firstUserPrompts(sessionIds: ["ses_a"]) == ["ses_a": "Fix the login bug"])
    }

    @Test("Last activity follows part writes, not only the session row")
    func lastActivityFromParts() throws {
        let fixture = try OpenCodeFixture()
        let rowTime = OpenCodeFixture.millis(ago: 600)
        try fixture.addSession(id: "ses_a", created: rowTime, updated: rowTime)
        let assistant = try fixture.addMessage(sessionId: "ses_a", role: "assistant", time: rowTime)
        let partTime = OpenCodeFixture.millis(ago: 2)
        try fixture.addPart(messageId: assistant, sessionId: "ses_a", json: #"{"type":"text","text":"streaming"}"#,
                            time: rowTime, updated: partTime)

        let last = try #require(try fixture.database.lastActivity(sessionIds: ["ses_a"])["ses_a"])
        #expect(Date.now.timeIntervalSince(last) < 10)
    }

    @Test("A launch finds the session created in its directory after it started")
    func newSessionAfterLaunch() throws {
        let fixture = try OpenCodeFixture()
        let launch = Date.now
        try fixture.addSession(id: "ses_before", directory: "/work/project", created: OpenCodeFixture.millis(ago: 600))
        try fixture.addSession(id: "ses_elsewhere", directory: "/work/other", created: OpenCodeFixture.millis(ago: 0))
        #expect(fixture.database.newSessionId(directory: "/work/project", createdSince: launch) == nil)

        try fixture.addSession(id: "ses_launched", directory: "/work/project", created: OpenCodeFixture.millis(ago: 0))
        #expect(fixture.database.newSessionId(directory: "/work/project", createdSince: launch) == "ses_launched")
    }

    @Test("Text search matches message parts")
    func textSearch() throws {
        let fixture = try OpenCodeFixture()
        try fixture.addSession(id: "ses_a")
        try fixture.addSession(id: "ses_b")
        let a = try fixture.addMessage(sessionId: "ses_a", role: "user")
        try fixture.addPart(messageId: a, sessionId: "ses_a", json: #"{"type":"text","text":"Migrate the Postgres schema"}"#)
        let b = try fixture.addMessage(sessionId: "ses_b", role: "user")
        try fixture.addPart(messageId: b, sessionId: "ses_b", json: #"{"type":"text","text":"50%_off banner"}"#)

        #expect(try fixture.database.sessionIds(containing: "postgres") == ["ses_a"])
        #expect(try fixture.database.sessionIds(containing: "%_") == ["ses_b"])
    }

    @Test("Virtual session paths round-trip and are owned by OpenCode")
    func virtualPaths() {
        let path = OpenCodeDatabase.virtualSessionPath(sessionId: "ses_abc", home: "/Users/me")
        #expect(path == "/Users/me/.local/share/opencode/session/ses_abc")
        #expect(OpenCodeDatabase.sessionId(fromVirtualPath: path) == "ses_abc")
        #expect(CodingAssistant.owner(ofSessionPath: path) == .opencode)
        #expect(CodingAssistant.claude.ownedByOther(sessionPath: path))
        #expect(OpenCodeDatabase.sessionId(fromVirtualPath: "/Users/me/.claude/projects/x/abc.jsonl") == nil)
    }

    @Test("OPENCODE_DB overrides the database location")
    func environmentOverride() {
        #expect(OpenCodeDatabase.defaultPath(environment: ["OPENCODE_DB": "/data/oc.db"]) == "/data/oc.db")
        #expect(OpenCodeDatabase.defaultPath(environment: [:]).hasSuffix("/.local/share/opencode/opencode.db"))
    }
}
