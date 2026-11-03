import Foundation
import Testing
import KanbanCodeRemoteKit

@testable import KanbanCodeCore

@Suite("Board digest")
struct BoardDigestTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func card(_ id: String, _ name: String, column: KanbanCodeColumn, activity: ActivityState? = nil,
                      minutesAgo: Double = 5, prs: [PRLink] = [], parent: String? = nil,
                      archived: Bool = false) -> KanbanCodeCard {
        KanbanCodeCard(
            link: Link(id: id, name: name, projectPath: "/src/app", column: column,
                       lastActivity: now.addingTimeInterval(-minutesAgo * 60),
                       manuallyArchived: archived, parentCardId: parent, prLinks: prs),
            activityState: activity)
    }

    @Test func anOpenQuestionPutsTheCardFirstWithTheQuestion() {
        let cards = [
            card("a", "Working one", column: .inProgress, activity: .activelyWorking, minutesAgo: 1),
            card("b", "Asking one", column: .waiting, minutesAgo: 30),
        ]
        let request = AttentionRequest(id: "att_1", cardId: "b", kind: .question,
                                       title: "Which database should I use?", body: "")
        let rows = BoardDigest.rows(cards: cards, attention: [request])
        #expect(rows.map(\.cardId) == ["b", "a"])
        #expect(rows[0].standing == .needsYou)
        #expect(rows[0].reason == "question: Which database should I use?")
        #expect(rows[1].standing == .working)
    }

    @Test func aResolvedRequestNoLongerCounts() {
        let request = AttentionRequest(id: "att_1", cardId: "b", kind: .planApproval, title: "Plan",
                                       body: "", resolvedAt: now, resolution: "approve")
        let rows = BoardDigest.rows(cards: [card("b", "B", column: .waiting)], attention: [request])
        #expect(rows[0].standing == .idle)
    }

    @Test func aLastMessageEndingInAQuestionNeedsYou() {
        let rows = BoardDigest.rows(
            cards: [card("b", "B", column: .waiting)], attention: [],
            lastMessages: ["b": "Tests pass.\n\nShould I open the PR now?\n"])
        #expect(rows[0].standing == .needsYou)
        #expect(rows[0].reason == "asked: Should I open the PR now?")
    }

    @Test func aFinishedTurnWithoutAQuestionIsIdle() {
        let rows = BoardDigest.rows(cards: [card("b", "B", column: .waiting)], attention: [],
                                    lastMessages: ["b": "Done. Pushed to the branch."])
        #expect(rows[0].standing == .idle)
        #expect(rows[0].lastMessage == "Done. Pushed to the branch.")
    }

    @Test func aPermissionPromptNeedsYou() {
        let rows = BoardDigest.rows(cards: [card("b", "B", column: .inProgress, activity: .awaitingPermission)],
                                    attention: [])
        #expect(rows[0].standing == .needsYou)
    }

    @Test func aFailingPullRequestInReviewNeedsYou() {
        let rows = BoardDigest.rows(
            cards: [card("r", "R", column: .inReview, prs: [PRLink(number: 42, status: .failing)]),
                    card("s", "S", column: .inReview, prs: [PRLink(number: 43, status: .reviewNeeded)])],
            attention: [])
        #expect(rows.first { $0.cardId == "r" }?.standing == .needsYou)
        #expect(rows.first { $0.cardId == "r" }?.reason == "PR #42 failing")
        #expect(rows.first { $0.cardId == "s" }?.standing == .inReview)
    }

    @Test func archivedAndBareSessionsAreLeftOut() {
        let rows = BoardDigest.rows(
            cards: [card("x", "Archived", column: .done, archived: true),
                    card("y", "Bare", column: .allSessions),
                    card("z", "Kept", column: .backlog)],
            attention: [])
        #expect(rows.map(\.cardId) == ["z"])
        #expect(rows[0].standing == .notStarted)
    }

    @Test func theTextNamesTheParentAndListsDoneCardsOnlyByTitle() {
        let rows = BoardDigest.rows(
            cards: [card("p", "Parent", column: .inProgress, activity: .activelyWorking),
                    card("c", "Child", column: .waiting, parent: "p"),
                    card("d", "Shipped", column: .done)],
            attention: [], lastMessages: ["d": "secret details"])
        let text = BoardDigest.render(rows, now: now)
        #expect(text.contains("Board: 3 cards (1 working, 1 idle, 1 done)"))
        #expect(text.contains("subagent of \"Parent\""))
        #expect(text.contains("## Done (1)\n- Shipped"))
        #expect(!text.contains("secret details"))
        #expect(text.contains("active 5m ago"))
    }

    @Test func longMessagesAreCut() {
        let rows = BoardDigest.rows(cards: [card("b", "B", column: .waiting)], attention: [],
                                    lastMessages: ["b": String(repeating: "word ", count: 200)])
        #expect(rows[0].lastMessage!.count == BoardDigest.messageLimit)
        #expect(rows[0].lastMessage!.hasSuffix("…"))
    }
}

@Suite("Orchestrator")
struct OrchestratorTests {
    @Test func thePromptCarriesTheDigestTheRecentExchangesAndTheQuestion() {
        let history = (1...8).map { OrchestratorTurn(question: "q\($0)", answer: "a\($0)") }
        let prompt = OrchestratorPrompt.build(digest: "DIGEST", history: history, question: "What is blocked?")
        #expect(prompt.hasPrefix("<board-digest>\nDIGEST\n</board-digest>"))
        #expect(!prompt.contains("Human: q2\n"))
        #expect(prompt.contains("Human: q3\n"))
        #expect(prompt.contains("You: a8"))
        #expect(prompt.hasSuffix("What is blocked?"))
    }

    @Test func theRunIsUnsavedAndLimitedToBash() {
        let args = ClaudeOrchestratorRunner.arguments(settingsPath: "/s.json", model: "sonnet")
        #expect(args.contains("--no-session-persistence"))
        #expect(!args.contains("--resume"))
        #expect(args.firstIndex(of: "--tools").map { args[$0 + 1] } == "Bash")
        #expect(args.suffix(2) == ["--model", "sonnet"])
    }

    /// Runs the hook script with a PreToolUse payload; returns its decision.
    private func decision(tool: String, command: String? = nil) throws -> String {
        let dir = NSTemporaryDirectory() + "orch-hook-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let script = dir + "/hook.sh"
        try ClaudeOrchestratorRunner.hookScript.write(toFile: script, atomically: true, encoding: .utf8)
        var input: [String: Any] = ["hook_event_name": "PreToolUse", "tool_name": tool]
        if let command { input["tool_input"] = ["command": command] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        try process.run()
        stdin.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: input))
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let json = try JSONSerialization.jsonObject(with: out) as? [String: Any]
        let specific = json?["hookSpecificOutput"] as? [String: Any]
        return specific?["permissionDecision"] as? String ?? "none"
    }

    @Test func theHookAllowsReadOnlyKanbanCommands() throws {
        #expect(try decision(tool: "Bash", command: "kanban transcript card_123 -n 10") == "allow")
        #expect(try decision(tool: "Bash", command: "kanban show card_1") == "allow")
        #expect(try decision(tool: "Bash", command: "kanban list --json") == "allow")
        #expect(try decision(tool: "Bash", command: "kanban conversation show swift-otter --card c") == "allow")
        #expect(try decision(tool: "Bash", command: "kanban status") == "allow")
    }

    @Test func theHookRefusesEverythingElse() throws {
        #expect(try decision(tool: "Bash", command: "kanban send card_1 hi") == "deny")
        #expect(try decision(tool: "Bash", command: "kanban archive card_1") == "deny")
        #expect(try decision(tool: "Bash", command: "kanban conversation new") == "deny")
        #expect(try decision(tool: "Bash", command: "kanban show c; rm -rf ~") == "deny")
        #expect(try decision(tool: "Bash", command: "kanban show $(whoami)") == "deny")
        #expect(try decision(tool: "Bash", command: "kanban show c | sh") == "deny")
        #expect(try decision(tool: "Bash", command: "kanban show c && ls") == "deny")
        #expect(try decision(tool: "Bash", command: "kanban show c\nrm x") == "deny")
        #expect(try decision(tool: "Bash", command: "ls ~") == "deny")
        #expect(try decision(tool: "Bash", command: "kanbanx show") == "deny")
        #expect(try decision(tool: "Write") == "deny")
        #expect(try decision(tool: "Edit") == "deny")
    }
}
