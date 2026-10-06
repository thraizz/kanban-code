import Foundation
import Testing

@testable import KanbanCodeCore

@Suite("Attention detector")
struct AttentionDetectorTests {
    func json(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    func ask(_ id: String, question: String = "Which database?", options: [String] = ["Postgres", "SQLite"], sidechain: Bool = false) -> String {
        json([
            "type": "assistant", "isSidechain": sidechain, "timestamp": "2026-10-02T10:00:00.000Z",
            "message": ["role": "assistant", "content": [[
                "type": "tool_use", "id": id, "name": "AskUserQuestion",
                "input": ["questions": [[
                    "question": question, "header": "DB", "multiSelect": false,
                    "options": options.map { ["label": $0, "description": "d"] },
                ]]],
            ]]],
        ])
    }

    func plan(_ id: String) -> String {
        json([
            "type": "assistant", "message": ["role": "assistant", "content": [[
                "type": "tool_use", "id": id, "name": "ExitPlanMode", "input": ["plan": "1. Do it\n2. Ship it"],
            ]]],
        ])
    }

    func result(_ id: String) -> String {
        json([
            "type": "user", "message": ["role": "user", "content": [[
                "type": "tool_result", "tool_use_id": id, "content": "The user answered",
            ]]],
        ])
    }

    func prompt(_ text: String) -> String {
        json(["type": "user", "message": ["role": "user", "content": text]])
    }

    @Test("an unanswered question is pending, with its options")
    func pendingQuestion() {
        let decision = AttentionDetector.pendingDecision(inLines: [prompt("hi"), ask("toolu_1")])
        #expect(decision?.kind == .question)
        #expect(decision?.requestId == "att_toolu_1")
        #expect(decision?.title == "DB")
        #expect(decision?.body == "Which database?")
        #expect(decision?.options == ["Postgres", "SQLite"])
    }

    @Test("an answered question is not pending")
    func answered() {
        #expect(AttentionDetector.pendingDecision(inLines: [ask("toolu_1"), result("toolu_1")]) == nil)
    }

    @Test("a typed prompt after the question moves the session on")
    func supersededByPrompt() {
        #expect(AttentionDetector.pendingDecision(inLines: [ask("toolu_1"), prompt("never mind, do X")]) == nil)
    }

    @Test("harness lines in a user turn do not count as a typed prompt")
    func metaPromptIgnored() {
        let lines = [ask("toolu_1"), prompt("<system-reminder>x</system-reminder>")]
        #expect(AttentionDetector.pendingDecision(inLines: lines)?.toolUseId == "toolu_1")
    }

    @Test("subagent questions are ignored")
    func sidechainIgnored() {
        #expect(AttentionDetector.pendingDecision(inLines: [ask("toolu_1", sidechain: true)]) == nil)
    }

    @Test("a plan waiting for approval is pending with approve and keep planning")
    func pendingPlan() {
        let decision = AttentionDetector.pendingDecision(inLines: [plan("toolu_9")])
        #expect(decision?.kind == .planApproval)
        #expect(decision?.options == AttentionDetector.planOptions)
        #expect(decision?.body.contains("Ship it") == true)
    }

    @Test("the newest open decision wins")
    func newestWins() {
        let decision = AttentionDetector.pendingDecision(inLines: [ask("a"), result("a"), plan("b")])
        #expect(decision?.toolUseId == "b")
    }

    @Test("the tail reader drops the partial first line")
    func tailRead() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("t.jsonl").path
        let lines = (0..<50).map { _ in prompt(String(repeating: "x", count: 100)) } + [ask("toolu_7")]
        try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        let tail = AttentionDetector.tailLines(path: path, bytes: 1200)
        #expect(tail.allSatisfy { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) != nil })
        #expect(AttentionDetector.pendingDecision(inLines: tail)?.toolUseId == "toolu_7")
    }
}

@Suite("Attention detector timestamps")
struct AttentionTimestampTests {
    @Test("only user and assistant lines move the conversation on")
    func lastTimestamp() {
        let lines = [
            #"{"type":"assistant","timestamp":"2026-10-02T10:00:00.500Z","message":{"content":[]}}"#,
            #"{"type":"system","timestamp":"2026-10-02T10:05:00.000Z","subtype":"hook"}"#,
            #"{"type":"attachment","timestamp":"2026-10-02T10:06:00.000Z"}"#,
        ]
        let date = AttentionDetector.lastTimestamp(inLines: lines)
        #expect(date == ISO8601DateFormatter.withFractions.date(from: "2026-10-02T10:00:00.500Z"))
    }
}

extension ISO8601DateFormatter {
    static var withFractions: ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }
}
