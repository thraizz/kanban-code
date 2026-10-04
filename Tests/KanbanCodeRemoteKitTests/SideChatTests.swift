import Foundation
import Testing
@testable import KanbanCodeRemoteKit

@Suite("Side chat: catch-up answer")
struct CatchUpParserTests {
    static let lines = """
        {"section": "asked", "text": "Fix the login redirect.", "refs": ["m1"]}
        {"section": "status", "text": "Done, the fix is merged.", "refs": ["m12"]}
        {"section": "report", "text": "Full report", "refs": ["m12"]}
        {"section": "facts", "text": "The redirect loop came from a stale cookie.", "refs": ["m7", "m9"]}
        {"section": "waiting", "text": "Approve the production deploy.", "refs": ["m12"]}
        {"section": "other", "text": "A reviewer asked for a changelog line.", "refs": ["m14"]}
        """

    @Test func jsonLinesBecomeSectionsInTheFixedOrder() throws {
        // The model wrote "other" before "waiting": the order is fixed.
        let shuffled = Self.lines.split(separator: "\n").reversed().joined(separator: "\n")
        let summary = try #require(CatchUpParser.parse(shuffled))
        #expect(summary.sections.map(\.id) == ["asked", "status", "facts", "waiting", "other"])
        #expect(summary.sections.map(\.title) == ["What you asked", "Where it stands", "Key facts", "Waiting on you", "What else happened"])
        #expect(summary.sections[2].items.first?.refs == ["m7", "m9"])
        #expect(summary.report?.text == "Full report")
        #expect(summary.report?.refs == ["m12"])
    }

    @Test func emptySectionsAreLeftOut() throws {
        let summary = try #require(CatchUpParser.parse(#"{"section":"status","text":"Still running.","refs":["m3"]}"#))
        #expect(summary.sections.map(\.id) == ["status"])
        #expect(summary.report == nil)
    }

    @Test func aCodeFenceAndProseAroundTheLinesAreIgnored() throws {
        let text = "Here is the catch-up:\n```json\n" + Self.lines + "\n```\nHope it helps."
        let summary = try #require(CatchUpParser.parse(text))
        #expect(summary.sections.count == 5)
    }

    @Test func anAnswerStillStreamingShowsTheLinesThatArrived() throws {
        let partial = """
            {"section": "asked", "text": "Fix the login redirect.", "refs": ["m1"]}
            {"section": "status", "text": "Done, the fix is mer
            """
        let summary = try #require(CatchUpParser.parse(partial))
        #expect(summary.sections.map(\.id) == ["asked"])
    }

    @Test func oneJSONDocumentWithSectionsParsesToo() throws {
        let document = """
            {"sections": [
              {"id": "status", "title": "Status", "items": [{"text": "In progress.", "refs": ["m4"]}]},
              {"id": "asked", "items": [{"text": "Add dark mode.", "refs": ["[m1]"]}]}
            ], "report": {"ref": "m9", "label": "Full report"}}
            """
        let summary = try #require(CatchUpParser.parse(document))
        #expect(summary.sections.map(\.id) == ["asked", "status"])
        #expect(summary.sections[0].items[0].refs == ["m1"])
        #expect(summary.report?.refs == ["m9"])
    }

    @Test func aDocumentMayNameItsReportByMessageId() throws {
        let document = """
            {"sections":[{"id":"status","items":[{"text":"Done.","refs":["m12"]}]}],"report":"m12"}
            """
        let summary = try #require(CatchUpParser.parse(document))
        #expect(summary.report == CatchUpSummary.Item(id: 1, text: "Full report", refs: ["m12"]))
    }

    @Test func citationsLeftInTheTextBecomeRefs() throws {
        let summary = try #require(CatchUpParser.parse(#"{"section":"facts","text":"Tests pass [m5] and CI is green [M6].","refs":[5]}"#))
        let item = summary.sections[0].items[0]
        #expect(item.text == "Tests pass and CI is green.")
        #expect(item.refs == ["m5", "m6"])
    }

    @Test func textThatIsNotJSONFallsBackToMarkdown() {
        #expect(CatchUpParser.parse("You asked for a fix. It is done.") == nil)
        #expect(CatchUpParser.parse("") == nil)
        #expect(CatchUpParser.parse(#"{"unrelated": true}"#) == nil)
        // The entry then shows the text as it is.
        var entry = SideChatState.Entry(id: "r1", kind: .catchup, question: "Catch me up", answer: "  It is **done**.  ", isRunning: false)
        #expect(entry.catchUp == nil)
        #expect(entry.answerText == "It is **done**.")
        entry.answer = Self.lines
        #expect(entry.catchUp != nil)
    }

    @Test func theSummaryReadsAsMarkdownForAFollowUp() throws {
        let summary = try #require(CatchUpParser.parse(Self.lines))
        let markdown = summary.markdown
        #expect(markdown.contains("**What you asked**\n- Fix the login redirect. [m1]"))
        #expect(markdown.contains("- The redirect loop came from a stale cookie. [m7] [m9]"))
        #expect(markdown.hasSuffix("Full report [m12]"))
    }
}

@Suite("Side chat: commands, state and handoff")
struct SideChatStateTests {
    @Test func theComposerCommands() {
        #expect(SideChatCommand.parse("/catchup") == .catchup)
        #expect(SideChatCommand.parse("  /catchup \n") == .catchup)
        #expect(SideChatCommand.parse("/btw why did the test fail?") == .btw("why did the test fail?"))
        #expect(SideChatCommand.parse("/btw") == .btw(""))
        #expect(SideChatCommand.parse("/BTW what now") == .btw("what now"))
        // Prompts and other commands go to the session.
        #expect(SideChatCommand.parse("/compact") == nil)
        #expect(SideChatCommand.parse("/btwx hello") == nil)
        #expect(SideChatCommand.parse("btw this is a prompt") == nil)
        #expect(SideChatCommand.parse("/catchup on the PR please") == nil)
    }

    private func run(_ id: String, _ state: RemoteSideChatRun.State, _ text: String, kind: RemoteSideChatKind = .btw) -> RemoteSideChatRun {
        RemoteSideChatRun(id: id, cardId: "card_1", kind: kind, state: state, text: text)
    }

    @Test func aQuestionShowsAtOnceThenStreamsThenSettles() {
        var state = SideChatState()
        state.apply(.asked(localId: "local-1", kind: .btw, question: "what is the status?"))
        #expect(state.isOpen)
        #expect(state.entries.count == 1)
        #expect(state.isRunning)
        #expect(state.history.isEmpty)

        state.apply(.started(localId: "local-1", run: run("side_1", .running, "")))
        #expect(state.entries[0].id == "side_1")
        #expect(state.runningId == "side_1")

        state.apply(.progress(run("side_1", .running, "Tests are")))
        #expect(state.entries[0].answer == "Tests are")
        #expect(state.isRunning)

        state.apply(.progress(run("side_1", .done, "Tests are green.")))
        #expect(!state.isRunning)
        #expect(state.history == [RemoteSideChatExchange(question: "what is the status?", answer: "Tests are green.")])
    }

    @Test func aFollowUpCarriesTheEarlierExchanges() {
        var state = SideChatState()
        state.apply(.asked(localId: "a", kind: .catchup, question: SideChatState.catchUpQuestion))
        state.apply(.started(localId: "a", run: run("side_1", .done, CatchUpParserTests.lines, kind: .catchup)))
        state.apply(.asked(localId: "b", kind: .btw, question: "which cookie?"))
        // The running question is not history yet; the catch-up reads as markdown.
        #expect(state.history.count == 1)
        #expect(state.history[0].question == "Catch me up")
        #expect(state.history[0].answer.contains("**Waiting on you**"))
    }

    @Test func aFailedRunShowsItsErrorAndLeavesWhenTheNextIsAsked() {
        var state = SideChatState()
        state.apply(.asked(localId: "a", kind: .btw, question: "one"))
        state.apply(.failed(id: "a", message: "This card has no conversation yet."))
        #expect(state.entries[0].error == "This card has no conversation yet.")
        #expect(!state.isRunning)
        #expect(state.history.isEmpty)
        state.apply(.asked(localId: "b", kind: .btw, question: "two"))
        #expect(state.entries.map(\.question) == ["two"])

        state.apply(.started(localId: "b", run: run("side_2", .running, "half")))
        state.apply(.progress(run("side_2", .failed, "half")))
        #expect(state.entries[0].error == "The side chat failed.")
    }

    @Test func dismissingForgetsTheSideChat() {
        var state = SideChatState()
        state.apply(.opened)
        #expect(state.isOpen && state.entries.isEmpty)
        state.apply(.asked(localId: "a", kind: .btw, question: "one"))
        state.apply(.dismissed)
        #expect(state == SideChatState())
        // Progress of a run dismissed meanwhile changes nothing.
        state.apply(.progress(run("side_1", .done, "late")))
        #expect(state.entries.isEmpty)
    }

    @Test func aRunKeepsItsScopeAndRefs() {
        var state = SideChatState()
        state.apply(.asked(localId: "a", kind: .catchup, question: "Catch me up"))
        var started = run("side_1", .running, "", kind: .catchup)
        started.since = RemoteSideChatSince(text: "fix the login", at: Date(timeIntervalSince1970: 10), offset: 400)
        started.refs = [RemoteSideChatRef(ref: "m1", offset: 400, role: "you", preview: "fix the login")]
        state.apply(.started(localId: "a", run: started))
        // A later frame without them keeps what the first carried.
        state.apply(.progress(run("side_1", .done, "x", kind: .catchup)))
        #expect(state.entries[0].since?.offset == 400)
        #expect(state.entries[0].ref("m1")?.offset == 400)
        #expect(state.entries[0].ref("m2") == nil)
    }

    @Test func bringingTheSideChatToTheMainChatPutsTheReplyFirst() {
        let entries = [
            SideChatState.Entry(id: "1", kind: .btw, question: "which cookie?", answer: "The session cookie.", isRunning: false),
            SideChatState.Entry(id: "2", kind: .btw, question: "broken", answer: "", isRunning: false, error: "failed"),
        ]
        let prompt = SideChatHandoff.mainChatPrompt(reply: "  Then clear it on logout too.  ", entries: entries)
        #expect(prompt.hasPrefix("Then clear it on logout too.\n\n---\n"))
        #expect(prompt.contains("I asked: which cookie?\nThe side chat answered:\nThe session cookie."))
        #expect(!prompt.contains("broken"))
    }

    @Test func aCitationFindsItsMessageByTranscriptOffset() {
        let messages = [
            RemoteMessage(id: "100.0", role: .user, text: "fix it"),
            RemoteMessage(id: "250.0", role: .assistant, text: "Looking."),
            RemoteMessage(id: "250.1", role: .tool, text: "Bash ls"),
            RemoteMessage(id: "900.0", role: .tool, text: "Read file"),
            RemoteMessage(id: "900.1", role: .assistant, text: "Done."),
            RemoteMessage(id: "pending-abc", role: .user, text: "thanks"),
        ]
        func ref(_ offset: Int) -> RemoteSideChatRef { RemoteSideChatRef(ref: "m1", offset: offset, role: "assistant", preview: "") }
        #expect(ref(250).message(in: messages)?.id == "250.0")
        #expect(ref(900).message(in: messages)?.id == "900.1")
        // A record merged into an earlier turn lands on that turn.
        #expect(ref(600).message(in: messages)?.id == "250.1")
        #expect(ref(250).isLoaded(in: messages))
        // Older than everything loaded: the chat has to read back first.
        #expect(!ref(40).isLoaded(in: messages))
        #expect(ref(40).message(in: messages) == nil)
        #expect(!ref(40).isLoaded(in: []))
    }

    @Test func theModelsRoundTripAsJSON() throws {
        let run = RemoteSideChatRun(
            id: "side_1", cardId: "card_1", kind: .catchup, state: .running, text: "x",
            since: RemoteSideChatSince(text: "hello", at: Date(timeIntervalSince1970: 1_700_000_000), offset: 12),
            refs: [RemoteSideChatRef(ref: "m1", offset: 12, role: "you", at: nil, preview: "hello")])
        let data = try JSONEncoder.remote.encode(run)
        #expect(try JSONDecoder.remote.decode(RemoteSideChatRun.self, from: data) == run)
        let request = try JSONDecoder.remote.decode(RemoteSideChatRequest.self, from: Data(#"{"kind":"catchup"}"#.utf8))
        #expect(request == RemoteSideChatRequest(kind: .catchup))
        // An older client's prompt has no `human`.
        let prompt = try JSONDecoder.remote.decode(RemotePromptRequest.self, from: Data(#"{"text":"hi"}"#.utf8))
        #expect(prompt.human == nil)
    }
}
