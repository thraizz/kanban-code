import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("Pi session store")
struct PiSessionStoreTests {
    @Test("A fork is a new file with a new id that names the original as parent")
    func fork() async throws {
        let fixture = try PiFixture()
        defer { fixture.cleanup() }
        let path = try fixture.write(PiFixture.branchedSession)
        let store = PiSessionStore(sessionsRoot: fixture.sessionsRoot)

        let forkId = try await store.forkSession(sessionPath: path)
        #expect(forkId != PiFixture.sessionId)
        #expect(CodingAssistant.pi.shortSessionId(forkId) != CodingAssistant.pi.shortSessionId(PiFixture.sessionId))

        let dir = (path as NSString).deletingLastPathComponent
        let forkPath = try #require(PiSessionFile.sessionFile(sessionId: forkId, in: dir))
        #expect(MasterEngine.forkedSessionPath(assistant: .pi, sessionId: forkId, directory: dir) == forkPath)
        let metadata = try #require(try PiSessionFile.metadata(from: forkPath))
        #expect(metadata.sessionId == forkId)
        #expect(metadata.parentSession == path)
        #expect(metadata.projectPath == PiFixture.cwd)
        #expect(try PiSessionFile.turns(from: forkPath).map(\.textPreview)
            == PiSessionFile.turns(from: path).map(\.textPreview))
    }

    @Test("Restoring to a turn keeps the file through that turn's last entry")
    func truncate() async throws {
        let fixture = try PiFixture()
        defer { fixture.cleanup() }
        let path = try fixture.write(PiFixture.branchedSession)
        let store = PiSessionStore(sessionsRoot: fixture.sessionsRoot)

        let reply = try PiSessionFile.turns(from: path)[1]
        try await store.truncateSession(sessionPath: path, afterTurn: reply)

        let turns = try PiSessionFile.turns(from: path)
        #expect(turns.map(\.textPreview) == ["Push the branch", "Pushed."])
        #expect(FileManager.default.fileExists(atPath: path + ".bkp"))
    }

    @Test("Another assistant's conversation is written as a Pi session in the project's directory")
    func writeSession() async throws {
        let fixture = try PiFixture()
        defer { fixture.cleanup() }
        let store = PiSessionStore(sessionsRoot: fixture.sessionsRoot)
        let turns = [
            ConversationTurn(index: 0, lineNumber: 0, role: "user", textPreview: "Fix the build",
                             timestamp: "2026-09-30T10:00:00Z",
                             contentBlocks: [ContentBlock(kind: .text, text: "Fix the build")]),
            ConversationTurn(index: 1, lineNumber: 1, role: "assistant", textPreview: "Fixed.",
                             contentBlocks: [
                                ContentBlock(kind: .toolUse(name: "Bash", input: ["command": "swift build"], id: "t1"), text: "Bash"),
                                ContentBlock(kind: .text, text: "Fixed."),
                             ],
                             modelName: "claude-opus-5-5"),
        ]
        let sessionId = PiSessionFile.newSessionId()
        let path = try await store.writeSession(turns: turns, sessionId: sessionId, projectPath: PiFixture.cwd)

        #expect(path.hasPrefix(fixture.sessionsRoot + "/--Users-me-project--/"))
        #expect(PiSessionFile.sessionId(fromFileName: path) == sessionId)
        let metadata = try #require(try PiSessionFile.metadata(from: path))
        #expect(metadata.sessionId == sessionId)
        #expect(metadata.projectPath == PiFixture.cwd)
        let read = try PiSessionFile.turns(from: path)
        #expect(read.map(\.role) == ["user", "assistant"])
        #expect(read[1].textPreview == "[Bash] command: swift build\nFixed.")
        #expect(read[1].modelName == "claude-opus-5-5")
    }

    @Test("Search finds a session by the words in its active branch")
    func search() async throws {
        let fixture = try PiFixture()
        defer { fixture.cleanup() }
        let path = try fixture.write(PiFixture.branchedSession)
        let store = PiSessionStore(sessionsRoot: fixture.sessionsRoot)

        let results = try await store.searchSessions(query: "second answer", paths: [path])
        #expect(results.first?.sessionPath == path)
        #expect(results.first?.snippets.contains { $0.hasPrefix("Pi: ") || $0.hasPrefix("You: ") } == true)
        #expect(try await store.searchSessions(query: "\"Abandoned answer\"", paths: [path]).isEmpty)
    }
}
