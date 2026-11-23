import Foundation
import Testing

@testable import KanbanCodeCore

/// The name an imported session's card gets, read from its transcript.
@Suite("Naming a card from its conversation")
struct ConversationTitleTests {
    struct NoTitle: Error {}

    private func transcript(_ records: [String]) throws -> String {
        let path = NSTemporaryDirectory() + "conversation-title-\(UUID().uuidString).jsonl"
        try (records.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func user(_ text: String) -> String {
        #"{"type":"user","cwd":"/tmp/repo","message":{"role":"user","content":\#(json(text))}}"#
    }

    private func json(_ text: String) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: [text]), encoding: .utf8)!.dropFirst().dropLast().description
    }

    private var conversation: [String] {
        [
            user("Make the parser accept trailing commas"),
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"On it."}]}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"SECRET TOOL OUTPUT"}]}}"#,
            user("also cover nested arrays in the tests"),
            #"{"type":"ai-title","aiTitle":"Parser trailing commas","sessionId":"s"}"#,
        ]
    }

    @Test("the title model reads the human's prompts, not tool output")
    func generated() async throws {
        let path = try transcript(conversation)
        let seen = Box()
        let name = await ConversationTitle.name(transcriptPath: path) { digest in
            await seen.set(digest)
            return "Trailing commas in the parser"
        }
        #expect(name == "Trailing commas in the parser")
        let digest = try #require(await seen.value)
        #expect(digest.contains("Make the parser accept trailing commas"))
        #expect(digest.contains("also cover nested arrays in the tests"))
        #expect(!digest.contains("SECRET TOOL OUTPUT"))
        // The first prompt is not repeated among the latest ones.
        #expect(digest.components(separatedBy: "Make the parser accept trailing commas").count == 2)
    }

    @Test("the name the user gave the session wins; a branch's own title does not count")
    func customTitle() async throws {
        let named = try transcript(conversation + [#"{"type":"custom-title","customTitle":"Comma fix","sessionId":"s"}"#])
        #expect(await ConversationTitle.name(transcriptPath: named) { _ in "generated" } == "Comma fix")

        let branched = try transcript(conversation + [#"{"type":"custom-title","customTitle":"Make the parser accept (Branch)","sessionId":"s"}"#])
        #expect(await ConversationTitle.name(transcriptPath: branched) { _ in "generated" } == "generated")
    }

    @Test("without a title model, Claude Code's own title is used")
    func fallback() async throws {
        let path = try transcript(conversation)
        #expect(await ConversationTitle.name(transcriptPath: path) { _ in throw NoTitle() } == "Parser trailing commas")
        let missing = NSTemporaryDirectory() + "missing-\(UUID().uuidString).jsonl"
        #expect(await ConversationTitle.name(transcriptPath: missing) { _ in "generated" } == nil)
    }

    @Test("the digest keeps the first request and as many of the latest ones as fit")
    func digestBudget() throws {
        let later = (1...50).map { "request number \($0)" }
        let digest = try #require(ConversationTitle.digest(firstPrompt: "the task", laterPrompts: later, budget: 200))
        #expect(digest.hasPrefix("First request:\nthe task"))
        #expect(digest.contains("- request number 50"))
        #expect(!digest.contains("- request number 1\n"))
        #expect(digest.count <= 200 + "Latest requests:\n".count + 2)
        #expect(ConversationTitle.digest(firstPrompt: nil, laterPrompts: [], budget: 200) == nil)
    }
}

private actor Box {
    var value: String?
    func set(_ text: String) { value = text }
}
