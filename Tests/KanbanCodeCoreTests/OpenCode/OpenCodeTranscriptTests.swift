import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("OpenCodeTranscript")
struct OpenCodeTranscriptTests {
    /// The session of the live test: a prompt, then assistant steps with
    /// reasoning, tool calls and a reply, as OpenCode 1.18 stores them.
    private func recordedSession() throws -> OpenCodeFixture {
        let fixture = try OpenCodeFixture()
        try fixture.addSession(id: "ses_a")
        let user = try fixture.addMessage(sessionId: "ses_a", role: "user")
        try fixture.addPart(messageId: user, sessionId: "ses_a",
                            json: #"{"type":"text","text":"Read ../outside/note.txt and reply with its content."}"#)
        try fixture.addPart(messageId: user, sessionId: "ses_a",
                            json: #"{"type":"text","text":"Called the Read tool with …","synthetic":true}"#)

        let step1 = try fixture.addMessage(sessionId: "ses_a", role: "assistant", extra: #""modelID":"gemini-3.8-flash""#)
        try fixture.addPart(messageId: step1, sessionId: "ses_a", json: #"{"type":"step-start"}"#)
        try fixture.addPart(messageId: step1, sessionId: "ses_a",
                            json: #"{"type":"reasoning","text":"**Constructing The Path**\n\nI'm determining the path."}"#)
        try fixture.addPart(messageId: step1, sessionId: "ses_a", json: #"""
            {"type":"tool","tool":"read","callID":"call_1","state":{"status":"completed","input":{"filePath":"/tmp/outside/note.txt"},"output":"1: SECRET-WORD-PINEAPPLE"}}
            """#)
        try fixture.addPart(messageId: step1, sessionId: "ses_a",
                            json: #"{"reason":"tool-calls","type":"step-finish","tokens":{"total":1}}"#)

        let step2 = try fixture.addMessage(sessionId: "ses_a", role: "assistant", extra: #""modelID":"gemini-3.8-flash""#)
        try fixture.addPart(messageId: step2, sessionId: "ses_a", json: #"""
            {"type":"tool","tool":"bash","callID":"call_2","state":{"status":"error","input":{"command":"ls /nope"},"error":"No such file"}}
            """#)
        try fixture.addPart(messageId: step2, sessionId: "ses_a", json: #"{"type":"text","text":"SECRET-WORD-PINEAPPLE"}"#)
        return fixture
    }

    @Test("Messages become one user turn and one merged assistant turn")
    func turnShape() throws {
        let fixture = try recordedSession()
        let turns = try OpenCodeTranscript.turns(
            messages: fixture.database.messages(sessionId: "ses_a"),
            parts: fixture.database.parts(sessionId: "ses_a")
        )

        #expect(turns.map(\.role) == ["user", "assistant"])
        #expect(turns[0].textPreview == "Read ../outside/note.txt and reply with its content.")
        #expect(turns[0].contentBlocks.count == 1, "synthetic text is not shown")
        #expect(turns[1].textPreview == "SECRET-WORD-PINEAPPLE")
        #expect(turns[1].modelName == "gemini-3.8-flash")
        #expect(turns[1].lineNumber == 1)
        #expect(turns[1].endLineNumber == 2)
    }

    @Test("Tool parts are a call and its result, in the chat view's tool names")
    func toolBlocks() throws {
        let fixture = try recordedSession()
        let turns = try OpenCodeTranscript.turns(
            messages: fixture.database.messages(sessionId: "ses_a"),
            parts: fixture.database.parts(sessionId: "ses_a")
        )
        let blocks = turns[1].contentBlocks

        guard case .thinking = blocks[0].kind else { Issue.record("expected thinking first"); return }
        guard case .toolUse(let name, let input, let id) = blocks[1].kind else { Issue.record("expected tool use"); return }
        #expect(name == "Read")
        #expect(input["filePath"] == "/tmp/outside/note.txt")
        #expect(input["file_path"] == "/tmp/outside/note.txt")
        #expect(id == "call_1")
        guard case .toolResult(let toolName, let useId) = blocks[2].kind else { Issue.record("expected tool result"); return }
        #expect(toolName == "Read")
        #expect(useId == "call_1")
        #expect(blocks[2].text == "1: SECRET-WORD-PINEAPPLE")

        guard case .toolUse(let bash, _, _) = blocks[3].kind else { Issue.record("expected bash call"); return }
        #expect(bash == "Bash")
        #expect(blocks[4].text == "Error: No such file")
    }

    @Test("A running tool shows its call without a result")
    func runningTool() {
        let blocks = OpenCodeTranscript.toolBlocks([
            "type": "tool", "tool": "bash", "callID": "c",
            "state": ["status": "running", "input": ["command": "sleep 60"]],
        ])
        #expect(blocks.count == 1)
    }

    @Test("Image attachments count, other files are named")
    func files() throws {
        let fixture = try OpenCodeFixture()
        try fixture.addSession(id: "ses_a")
        let user = try fixture.addMessage(sessionId: "ses_a", role: "user")
        try fixture.addPart(messageId: user, sessionId: "ses_a", json: #"{"type":"file","mime":"image/png","url":"data:…"}"#)
        try fixture.addPart(messageId: user, sessionId: "ses_a", json: #"{"type":"file","mime":"text/plain","filename":"notes.md"}"#)
        let turns = try OpenCodeTranscript.turns(
            messages: fixture.database.messages(sessionId: "ses_a"),
            parts: fixture.database.parts(sessionId: "ses_a")
        )
        #expect(turns.count == 1)
        #expect(turns[0].imageCount == 1)
        #expect(turns[0].textPreview == "[file: notes.md]")
    }

    @Test("Messages with nothing to show are skipped")
    func bookkeepingOnly() throws {
        let fixture = try OpenCodeFixture()
        try fixture.addSession(id: "ses_a")
        let step = try fixture.addMessage(sessionId: "ses_a", role: "assistant")
        try fixture.addPart(messageId: step, sessionId: "ses_a", json: #"{"type":"step-start"}"#)
        try fixture.addPart(messageId: step, sessionId: "ses_a", json: #"{"type":"step-finish"}"#)
        let turns = try OpenCodeTranscript.turns(
            messages: fixture.database.messages(sessionId: "ses_a"),
            parts: fixture.database.parts(sessionId: "ses_a")
        )
        #expect(turns.isEmpty)
    }
}
