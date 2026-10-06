import Foundation
import Testing
import KanbanCodeRemoteKit
@testable import KanbanCodeCore

/// Builds a Claude Code transcript a line at a time.
struct TranscriptBuilder {
    var lines: [String] = []
    private var clock = ISO8601DateFormatter().date(from: "2026-03-01T10:00:00Z")!

    static func stamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    var now: Date { clock }

    mutating func advance(_ seconds: TimeInterval) { clock = clock.addingTimeInterval(seconds) }

    private mutating func add(_ object: [String: Any]) {
        var object = object
        object["timestamp"] = Self.stamp(clock)
        if object["uuid"] == nil { object["uuid"] = "uuid-\(lines.count)" }
        lines.append(String(data: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8)!)
        clock = clock.addingTimeInterval(60)
    }

    /// A user record as Claude Code writes a prompt entered in the session.
    mutating func user(_ text: String, uuid: String? = nil, extra: [String: Any] = [:]) {
        var object: [String: Any] = ["type": "user", "message": ["role": "user", "content": text],
                                     "origin": ["kind": "human"], "cwd": "/tmp/project"]
        if let uuid { object["uuid"] = uuid }
        for (key, value) in extra { object[key] = value }
        add(object)
    }

    mutating func assistant(_ text: String) {
        add(["type": "assistant", "message": ["role": "assistant", "model": "claude-test",
                                              "content": [["type": "text", "text": text]]]])
    }

    mutating func toolCall(_ name: String) {
        add(["type": "assistant", "message": ["role": "assistant", "model": "claude-test",
                                              "content": [["type": "tool_use", "id": "t\(lines.count)", "name": name, "input": ["command": "ls"]]]]])
        add(["type": "user", "toolUseResult": ["stdout": "ok"],
             "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t\(lines.count - 1)", "content": "ok"]]]])
    }

    /// Byte offset the line at `index` starts at.
    func offset(_ index: Int) -> Int {
        lines.prefix(index).reduce(0) { $0 + $1.utf8.count + 1 }
    }

    func write() throws -> String {
        let path = NSTemporaryDirectory() + "side-chat-\(UUID().uuidString).jsonl"
        try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }
}

@Suite("Side chat: the human's last message")
struct HumanMessageFinderTests {
    /// He asks, the agent answers, then other senders write in the user role.
    private func busySession() -> TranscriptBuilder {
        var t = TranscriptBuilder()
        t.user("first thing I asked")                                             // 0
        t.assistant("on it")                                                      // 1
        t.user("fix the login redirect and tell me when it is merged")            // 2
        t.toolCall("Bash")                                                        // 3, 4
        t.assistant("The redirect is fixed and merged. Full report follows.")     // 5
        t.user("[Message from @reviewer]: please add a changelog line")           // 6
        t.assistant("Added the changelog line.")                                  // 7
        t.user("<task-notification>\n<task-id>b1</task-id>\n<summary>CI finished</summary>\n</task-notification>",
               extra: ["origin": ["kind": "task-notification"]])                  // 8
        t.user("[DM from @ops]: deploy window is at 5")                           // 9
        t.user("[Self-compact follow-up from this card]: keep babysitting the PR") // 10
        t.user("Another Claude session sent a message: ping")                     // 11
        t.assistant("Still watching the PR.")                                     // 12
        return t
    }

    @Test func messagesDeliveredByAgentsAfterHisAreSkipped() throws {
        let t = busySession()
        let path = try t.write()
        let last = try #require(HumanMessageFinder.find(transcriptPath: path))
        #expect(last.text == "fix the login redirect and tell me when it is merged")
        #expect(last.offset == t.offset(2))
        #expect(last.scopeStart == t.offset(2))
    }

    @Test func recordsThatAreNotPromptsAreNeverHis() throws {
        var t = TranscriptBuilder()
        t.user("the real one")
        t.assistant("ok")
        t.user("looks typed but is meta", extra: ["isMeta": true])
        t.user("a compaction summary", extra: ["isCompactSummary": true])
        t.user("from the harness", extra: ["origin": ["kind": "auto-continue"]])
        t.user("<system-reminder>be careful</system-reminder>")
        t.user("[Request interrupted by user]")
        let path = try t.write()
        #expect(HumanMessageFinder.find(transcriptPath: path)?.text == "the real one")
    }

    @Test func aSessionOnlyAgentsWroteInHasNoHumanMessage() throws {
        var t = TranscriptBuilder()
        t.user("You are running as subagent card card_9.\nPost the summary")
        t.assistant("posted")
        t.user("[Message from @parent]: thanks")
        let path = try t.write()
        #expect(HumanMessageFinder.find(transcriptPath: path) == nil)
    }

    @Test func rushRecordDecidesWhenTheSessionHasOne() throws {
        var t = TranscriptBuilder()
        t.user("what he typed in the rush composer", uuid: "human-uuid")   // 0
        t.assistant("done")
        // A script sent this with `rush session send`: no marker, so only
        // rush's record can tell it is not his.
        t.user("status check from a cron script")
        t.assistant("all good")
        let path = try t.write()

        // Without a record the unmarked message is taken as typed.
        #expect(HumanMessageFinder.find(transcriptPath: path)?.text == "status check from a cron script")

        let byUuid = [RushHumanMessage(at: nil, text: "changed text", uuid: "human-uuid")]
        #expect(HumanMessageFinder.find(transcriptPath: path, rushRecord: byUuid)?.offset == t.offset(0))
        let byText = [RushHumanMessage(at: nil, text: "what he typed  in the rush composer\n", uuid: nil)]
        #expect(HumanMessageFinder.find(transcriptPath: path, rushRecord: byText)?.offset == t.offset(0))

        // A session older than the record (an empty list) falls back.
        #expect(HumanMessageFinder.find(transcriptPath: path, rushRecord: [])?.text == "status check from a cron script")
    }

    @Test func whatTheKanbanChatSentCountsNextToTheRushRecord() throws {
        var t = TranscriptBuilder()
        t.user("typed in the rush composer", uuid: "rush-uuid")   // 0
        t.assistant("done")
        // Sent from the Kanban chat through a rush that marked nothing.
        t.user("typed in the Kanban chat")                        // 2
        t.assistant("on it")
        t.user("status check from a cron script")
        t.assistant("all good")
        let path = try t.write()
        let rush = [RushHumanMessage(at: nil, text: "typed in the rush composer", uuid: "rush-uuid")]
        let kanban = [HumanMessageRecord(at: Date(timeIntervalSince1970: 0), text: "typed in the Kanban chat")]

        #expect(HumanMessageFinder.find(transcriptPath: path, rushRecord: rush)?.offset == t.offset(0))
        #expect(HumanMessageFinder.find(transcriptPath: path, record: kanban, rushRecord: rush)?.offset == t.offset(2))
    }

    @Test func rushIsToldTheFirstPromptIsHis() {
        let request = RushStartRequest(cwd: "/repo", sessionId: "sid", resume: false, prompt: "hi")
        let marked = RushCliAdapter.startArguments(request, promptFile: "-", human: true)
        #expect(marked.contains("--human"))
        #expect(marked.firstIndex(of: "--human") == marked.firstIndex(of: "--prompt-file").map { $0 + 2 })
        #expect(!RushCliAdapter.startArguments(request, promptFile: "-").contains("--human"))
        // A start with no prompt has nothing to mark.
        #expect(!RushCliAdapter.startArguments(request, promptFile: nil, human: true).contains("--human"))
    }

    @Test func aQueuedPromptCountsFromWhenHeWroteIt() throws {
        var t = TranscriptBuilder()
        t.user("start the migration")                 // 0
        t.assistant("migration running")              // 1
        let writtenAt = t.now.addingTimeInterval(-30) // he queued this while the turn ran
        t.toolCall("Bash")                            // 2, 3
        t.assistant("migration finished")             // 4
        t.user("and then run the smoke tests")        // 5: the queue let it go here
        t.assistant("smoke tests pass")               // 6
        let path = try t.write()
        let record = [HumanMessageRecord(at: writtenAt, text: "and then run the smoke tests")]

        let last = try #require(HumanMessageFinder.find(transcriptPath: path, record: record))
        #expect(last.offset == t.offset(5))
        #expect(last.at == writtenAt)
        // What happened while it waited is news to him: the scope starts
        // with the first record written after he queued it.
        #expect(last.scopeStart == t.offset(2))

        // A prompt sent at once starts at itself.
        let direct = [HumanMessageRecord(at: ISO8601DateFormatter().date(from: "2026-03-01T10:06:00Z")!, text: "and then run the smoke tests")]
        #expect(HumanMessageFinder.find(transcriptPath: path, record: direct)?.scopeStart == t.offset(5))
    }

    @Test func aPromptStillInTheQueueIsHisLastMessage() throws {
        var t = TranscriptBuilder()
        t.user("start the migration")       // 0
        t.assistant("migration running")    // 1
        let writtenAt = t.now.addingTimeInterval(-10)
        t.assistant("still running")        // 2
        let path = try t.write()
        let record = [HumanMessageRecord(at: writtenAt, text: "stop after step three")]
        let later = t.now.addingTimeInterval(3600)

        let queued = try #require(HumanMessageFinder.find(
            transcriptPath: path, record: record, queuedTexts: ["stop after step three"], now: later))
        #expect(queued.text == "stop after step three")
        #expect(queued.offset == nil)
        #expect(queued.scopeStart == t.offset(2))

        // No longer queued and never delivered (he removed it): not his last.
        let removed = try #require(HumanMessageFinder.find(transcriptPath: path, record: record, now: later))
        #expect(removed.text == "start the migration")
    }

    @Test func aRecordOfAnotherSessionIsIgnored() throws {
        var t = TranscriptBuilder()
        t.user("only message")
        t.assistant("ok")
        let path = try t.write()
        let record = [HumanMessageRecord(at: t.now, text: "written for the session before", sessionId: "old")]
        let last = HumanMessageFinder.find(transcriptPath: path, sessionId: "new", record: record, queuedTexts: ["written for the session before"])
        #expect(last?.text == "only message")
    }

    @Test func theSameMessageIsRecognisedThroughSpacingAndMarkers() {
        #expect(HumanMessageFinder.sameText("fix  the\nlogin", "fix the login"))
        #expect(HumanMessageFinder.sameText("look at this screenshot please, it is broken", "look at this screenshot please, it is broken [Image #1]"))
        #expect(!HumanMessageFinder.sameText("yes", "yes please do the whole thing"))
        #expect(!HumanMessageFinder.sameText("", ""))
    }

    @Test func theLogKeepsWhatHeSentPerCard() throws {
        let home = NSTemporaryDirectory() + "human-log-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: home) }
        let log = HumanMessageLog(kanbanHome: home)
        #expect(log.read(cardId: "card_1").isEmpty)
        let first = HumanMessageRecord(at: Date(timeIntervalSince1970: 1_700_000_000), text: "one", sessionId: "s1")
        log.append(cardId: "card_1", first)
        log.append(cardId: "card_1", first) // the same send reported twice
        log.append(cardId: "card_1", HumanMessageRecord(at: Date(timeIntervalSince1970: 1_700_000_100), text: "two"))
        log.append(cardId: "card_2", HumanMessageRecord(text: "other card"))
        log.append(cardId: "card_1", HumanMessageRecord(text: "   "))
        #expect(log.read(cardId: "card_1").map(\.text) == ["one", "two"])
        #expect(log.read(cardId: "card_1").first == first)
        #expect(log.read(cardId: "card_2").map(\.text) == ["other card"])
        // A card id never leaves the folder.
        log.append(cardId: "../escape", HumanMessageRecord(text: "x"))
        #expect(!FileManager.default.fileExists(atPath: home + "/escape.jsonl"))
        #expect(FileManager.default.fileExists(atPath: home + "/human-messages/___escape.jsonl"))
    }

    @Test func theLogIsCutBackWhenItGrows() throws {
        let home = NSTemporaryDirectory() + "human-log-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: home) }
        let log = HumanMessageLog(kanbanHome: home)
        for i in 0..<(HumanMessageLog.keep * 2 + 5) {
            log.append(cardId: "card_1", HumanMessageRecord(at: Date(timeIntervalSince1970: Double(i)), text: "message \(i)"))
        }
        let kept = log.read(cardId: "card_1")
        #expect(kept.count <= HumanMessageLog.keep * 2)
        #expect(kept.last?.text == "message \(HumanMessageLog.keep * 2 + 4)")
    }
}

@Suite("Side chat: sending marks what the human wrote")
struct HumanPromptReducerTests {
    private func state(with prompt: QueuedPrompt, session: String) -> AppState {
        let state = AppState()
        var link = Link(id: "card_1", name: "a card", projectPath: "/tmp/project")
        link.tmuxLink = TmuxLink(sessionName: session)
        link.sessionLink = SessionLink(sessionId: "session-1")
        link.queuedPrompts = [prompt]
        state.links[link.id] = link
        return state
    }

    @Test func aPromptHeWroteIsRecordedAtTheTimeHeWroteItAndSentAsHuman() {
        let writtenAt = Date(timeIntervalSince1970: 1_700_000_000)
        let prompt = QueuedPrompt(id: "p1", body: "ship it", humanWrittenAt: writtenAt)
        var state = state(with: prompt, session: "rush-abc12345")
        let effects = Reducer.reduce(state: &state, action: .sendQueuedPrompt(cardId: "card_1", promptId: "p1"))

        var recorded: (String, String, Date, String?)?
        var sentAsHuman: Bool?
        for effect in effects {
            if case .recordHumanMessage(let cardId, let text, let at, let sessionId) = effect { recorded = (cardId, text, at, sessionId) }
            if case .sendPromptToTmux(_, _, _, let human) = effect { sentAsHuman = human }
        }
        #expect(recorded?.0 == "card_1")
        #expect(recorded?.1 == "ship it")
        #expect(recorded?.2 == writtenAt)
        #expect(recorded?.3 == "session-1")
        #expect(sentAsHuman == true)
    }

    @Test func aPromptAnAgentQueuedIsNotRecorded() {
        // A channel message, a self-compact nudge, a prompt from `kanban send`.
        let prompt = QueuedPrompt(id: "p1", body: "[Message from #ops @bot]: go", imagePaths: ["/tmp/a.png"])
        var state = state(with: prompt, session: "claude-abc")
        let effects = Reducer.reduce(state: &state, action: .sendQueuedPrompt(cardId: "card_1", promptId: "p1"))
        var sentAsHuman: Bool?
        for effect in effects {
            if case .recordHumanMessage = effect { Issue.record("an agent's prompt was recorded as the human's") }
            if case .sendPromptWithImagesToTmux(_, _, _, _, let human) = effect { sentAsHuman = human }
        }
        #expect(sentAsHuman == false)
        #expect(!prompt.isHuman)
    }

    @Test func aQueuedPromptKeepsWhoWroteItThroughTheCardFile() throws {
        let prompt = QueuedPrompt(id: "p1", body: "later", humanWrittenAt: Date(timeIntervalSince1970: 1_700_000_000))
        let decoded = try JSONDecoder().decode(QueuedPrompt.self, from: JSONEncoder().encode(prompt))
        #expect(decoded == prompt)
        // A card file written before this field reads as not his.
        let old = try JSONDecoder().decode(QueuedPrompt.self, from: Data(#"{"id":"p0","body":"x","sendAutomatically":true}"#.utf8))
        #expect(!old.isHuman)
    }

    @Test func rushIsAskedForTheHumanRecordOnlyWhenItsHelpListsIt() {
        let old = "rush session send <id> [--now] [--image PATH]...\n  rush session info <id> [--json]"
        let new = old + "\n  rush session send <id> --human\n  rush session human <id> [--json]"
        #expect(!RushCliAdapter.helpListsHumanRecord(old))
        #expect(RushCliAdapter.helpListsHumanRecord(new))
        #expect(RushCliAdapter.parseHumanMessages("null") == [])
        #expect(RushCliAdapter.parseHumanMessages("") == [])
        let parsed = RushCliAdapter.parseHumanMessages(#"[{"at":"2026-03-01T10:00:00Z","text":"hello","uuid":"u1"},{"text":"no uuid"}]"#)
        #expect(parsed == [RushHumanMessage(at: "2026-03-01T10:00:00Z", text: "hello", uuid: "u1"), RushHumanMessage(text: "no uuid")])
        #expect(RushCliAdapter.parseHumanMessages("rush: unknown session command") == nil)
    }
}
