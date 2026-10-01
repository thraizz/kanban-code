import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("Pi session files")
struct PiSessionFileTests {
    @Test("Directory names encode the working directory the way Pi does")
    func directoryName() {
        #expect(PiSessionFile.directoryName(forCwd: "/Users/me/dev/project") == "--Users-me-dev-project--")
        #expect(PiSessionFile.directoryName(forCwd: "/private/tmp/claude-501/-Users-me")
            == "--private-tmp-claude-501--Users-me--")
    }

    @Test("File names carry the creation time and the id")
    func fileNames() {
        let date = Date(timeIntervalSince1970: 1_790_791_840.25)
        let name = PiSessionFile.fileName(sessionId: PiFixture.sessionId, createdAt: date)
        #expect(name == "2026-09-30T18-10-40-250Z_\(PiFixture.sessionId).jsonl")
        #expect(PiSessionFile.sessionId(fromFileName: "/x/\(name)") == PiFixture.sessionId)
    }

    @Test("New ids are version 7 UUIDs that start with the time")
    func newSessionId() {
        let date = Date(timeIntervalSince1970: 1_790_791_840.25)
        let id = PiSessionFile.newSessionId(at: date)
        #expect(UUID(uuidString: id) != nil)
        #expect(id.hasPrefix("01a0f382-f1fa-7"))
        #expect(PiSessionFile.newSessionId(at: date) != id)
    }

    @Test("Metadata comes from the header and the active branch")
    func metadata() throws {
        let fixture = try PiFixture()
        defer { fixture.cleanup() }
        let path = try fixture.write(PiFixture.branchedSession)

        let metadata = try #require(try PiSessionFile.metadata(from: path))
        #expect(metadata.sessionId == PiFixture.sessionId)
        #expect(metadata.projectPath == PiFixture.cwd)
        #expect(metadata.firstPrompt == "Push the branch")
        #expect(metadata.name == "Pi support")
        // u1, a1, a2, u3, a4: the abandoned branch does not count.
        #expect(metadata.messageCount == 5)
        #expect(metadata.parentSession == nil)
    }

    @Test("The transcript follows the branch that ends at the last entry")
    func transcriptFollowsActiveBranch() throws {
        let fixture = try PiFixture()
        defer { fixture.cleanup() }
        let path = try fixture.write(PiFixture.branchedSession)

        let turns = try PiSessionFile.turns(from: path)
        #expect(turns.map(\.role) == ["user", "assistant", "user", "assistant"])
        #expect(turns[0].textPreview == "Push the branch")
        #expect(turns[2].textPreview == "Second question")
        #expect(turns[2].imageCount == 1)
        #expect(turns[3].textPreview == "Second answer")
        #expect(!turns.contains { $0.textPreview.contains("Abandoned") })
    }

    @Test("A reply's steps and tool results are one assistant bubble")
    func assistantBubble() throws {
        let fixture = try PiFixture()
        defer { fixture.cleanup() }
        let path = try fixture.write(PiFixture.branchedSession)

        let reply = try PiSessionFile.turns(from: path)[1]
        #expect(reply.textPreview == "Pushed.")
        #expect(reply.modelName == "moonshotai/kimi-k2.6")
        #expect(reply.contentBlocks.count == 4)
        guard case .thinking = reply.contentBlocks[0].kind else { Issue.record("no thinking"); return }
        guard case .toolUse(let name, let input, let id) = reply.contentBlocks[1].kind else {
            Issue.record("no tool call"); return
        }
        #expect(name == "Bash")
        #expect(input["command"] == "git push -u origin feat/pi-support")
        #expect(input["timeout"] == nil)
        #expect(id == "functions.bash:0")
        guard case .toolResult(let toolName, let toolUseId) = reply.contentBlocks[2].kind else {
            Issue.record("no tool result"); return
        }
        #expect(toolName == "Bash")
        #expect(toolUseId == "functions.bash:0")
        #expect(reply.contentBlocks[2].text == "pushed\n")
    }

    @Test("Turn offsets point at the entries they start and end with")
    func offsets() throws {
        let fixture = try PiFixture()
        defer { fixture.cleanup() }
        let path = try fixture.write(PiFixture.branchedSession)
        let data = try Data(contentsOf: URL(fileURLWithPath: path))

        func line(at offset: Int) -> String {
            let end = data[offset...].firstIndex(of: UInt8(ascii: "\n")) ?? data.count
            return String(decoding: data[offset..<end], as: UTF8.self)
        }
        let reply = try PiSessionFile.turns(from: path)[1]
        #expect(line(at: reply.lineNumber).contains(#""id":"a1""#))
        #expect(line(at: reply.endLineNumber).contains(#""id":"a2""#))
    }

    @Test("Pushed and created branches are found in bash tool calls")
    func pushedBranches() throws {
        let fixture = try PiFixture()
        defer { fixture.cleanup() }
        let path = try fixture.write(PiFixture.branchedSession)
        #expect(try PiSessionFile.extractPushedBranches(from: path).map(\.branch) == ["feat/pi-support"])
    }

    @Test("A failed request with no content shows its error")
    func errorReply() throws {
        let fixture = try PiFixture()
        defer { fixture.cleanup() }
        let path = try fixture.write([
            PiFixture.header(),
            #"{"type":"message","id":"u1","parentId":null,"timestamp":"2026-09-30T18:13:00.000Z","message":{"role":"user","content":"hi","timestamp":1}}"#,
            #"{"type":"message","id":"a1","parentId":"u1","timestamp":"2026-09-30T18:13:01.000Z","message":{"role":"assistant","content":[],"stopReason":"error","errorMessage":"401 Unauthorized","timestamp":2}}"#,
        ])
        let turns = try PiSessionFile.turns(from: path)
        #expect(turns.last?.textPreview == "Error: 401 Unauthorized")
    }

    @Test("Discovery lists sessions with messages and skips empty ones")
    func discovery() async throws {
        let fixture = try PiFixture()
        defer { fixture.cleanup() }
        let path = try fixture.write(PiFixture.branchedSession)
        try fixture.write([PiFixture.header(id: "01a0f385-6201-717b-b0eb-d7226a1b0fbd")],
                          sessionId: "01a0f385-6201-717b-b0eb-d7226a1b0fbd")

        let sessions = try await PiSessionDiscovery(sessionsRoot: fixture.sessionsRoot).discoverSessions()
        #expect(sessions.count == 1)
        let session = try #require(sessions.first)
        #expect(session.id == PiFixture.sessionId)
        #expect(session.assistant == .pi)
        #expect(session.jsonlPath == path)
        #expect(session.name == "Pi support")
        #expect(session.projectPath == PiFixture.cwd)
    }
}
