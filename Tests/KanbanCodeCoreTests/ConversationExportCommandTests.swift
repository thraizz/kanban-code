import Foundation
import Testing
@testable import KanbanCodeCore

@Suite("ConversationExportCommand")
struct ConversationExportCommandTests {
    private static let transcript = [
        #"{"type":"user","uuid":"u1","message":{"role":"user","content":"Please fix the build"}}"#,
        #"{"type":"assistant","uuid":"a1","message":{"role":"assistant","content":[{"type":"text","text":"Running the tests."},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"swift test"}}]}}"#,
        #"{"type":"user","uuid":"u2","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}"#,
        #"{"type":"assistant","uuid":"a2","message":{"role":"assistant","content":[{"type":"text","text":"All green."}]}}"#,
    ].joined(separator: "\n") + "\n"

    private func sandbox() throws -> String {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Parses card and path flags")
    func parsesFlags() throws {
        let command = try ConversationExportCommand.parse([
            "--card", "card_1", "--home", "/h", "--path", "/p.jsonl", "--assistant", "codex",
            "--title", "T", "--session-id", "s1",
        ])
        #expect(command == ConversationExportCommand(
            cardId: "card_1", home: "/h", sessionPath: "/p.jsonl", assistant: .codex, title: "T", sessionId: "s1"
        ))
    }

    @Test("Refuses a call with neither card nor path, and unknown flags")
    func refusesBadArguments() {
        #expect(throws: ConversationExportCommand.Failure.self) { try ConversationExportCommand.parse([]) }
        #expect(throws: ConversationExportCommand.Failure.self) { try ConversationExportCommand.parse(["--card"]) }
        #expect(throws: ConversationExportCommand.Failure.self) { try ConversationExportCommand.parse(["--path", "x", "--nope"]) }
        #expect(throws: ConversationExportCommand.Failure.self) { try ConversationExportCommand.parse(["--path", "x", "--assistant", "vim"]) }
    }

    @Test("Streams the card's transcript exactly as the app exports it")
    func streamsCardLikeTheApp() async throws {
        let home = try sandbox()
        let path = (home as NSString).appendingPathComponent("session-1.jsonl")
        try Self.transcript.write(toFile: path, atomically: true, encoding: .utf8)
        let link = Link(
            id: "card_export",
            name: "Fix the build",
            sessionLink: SessionLink(sessionId: "session-1", sessionPath: path)
        )
        try await CoordinationStore(basePath: home).writeLinks([link])

        var pieces: [String] = []
        try await ConversationExportCommand(cardId: "card_export", home: home).run { pieces.append($0) }
        let streamed = pieces.joined()

        let expected = try await ConversationMarkdownExporter.exportMarkdown(
            title: link.displayTitle,
            assistant: .claude,
            sessionId: "session-1",
            sessionPath: path,
            sessionStore: ClaudeCodeSessionStore()
        )
        #expect(streamed == expected)
        #expect(pieces.count > 2)
        #expect(streamed.hasPrefix("# Fix the build\n\n_Assistant: Claude Code_\n_Session: `session-1`_\n\n## User\n\nPlease fix the build"))
        #expect(streamed.hasSuffix("## Claude Code\n\nAll green.\n"))
    }

    @Test("Reads the mirrored copy of a card another master owns")
    func readsPeerMirror() async throws {
        let home = try sandbox()
        let mirror = PeerTranscriptMirror.mirrorPath(
            directory: (home as NSString).appendingPathComponent("peers"),
            machineId: "box",
            sessionId: "session-2"
        )
        try FileManager.default.createDirectory(
            atPath: (mirror as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Self.transcript.write(toFile: mirror, atomically: true, encoding: .utf8)
        let link = Link(
            id: "card_peer",
            name: "Box card",
            sessionLink: SessionLink(sessionId: "session-2", sessionPath: "/root/.claude/projects/x/session-2.jsonl"),
            ownerMachine: "box"
        )
        try await CoordinationStore(basePath: home).writeLinks([link])

        let resolved = try await ConversationExportCommand(cardId: "card_peer", home: home).resolve()
        #expect(resolved.sessionPath == mirror)
        #expect(resolved.title == "Box card")
    }

    @Test("A missing card or transcript fails with a message")
    func failsOnMissingInputs() async throws {
        let home = try sandbox()
        try await CoordinationStore(basePath: home).writeLinks([Link(id: "card_empty", name: "Empty")])
        await #expect(throws: ConversationExportCommand.Failure.self) {
            try await ConversationExportCommand(cardId: "card_nope", home: home).resolve()
        }
        await #expect(throws: ConversationExportCommand.Failure.self) {
            try await ConversationExportCommand(cardId: "card_empty", home: home).resolve()
        }
    }

    @Test("Guesses the assistant of a bare transcript path")
    func guessesAssistant() {
        #expect(ConversationExportCommand.guessAssistant(path: "/u/.codex/sessions/2026/rollout-1.jsonl") == .codex)
        #expect(ConversationExportCommand.guessAssistant(path: "/u/.gemini/tmp/x/chats/session.json") == .gemini)
        #expect(ConversationExportCommand.guessAssistant(path: "/u/.claude/projects/p/abc.jsonl") == .claude)
    }
}
