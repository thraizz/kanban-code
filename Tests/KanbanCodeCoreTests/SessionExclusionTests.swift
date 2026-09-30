import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("SessionExclusion")
struct SessionExclusionTests {
    private let scheduledPrompt = """
        <scheduled-task name="nightly-report" file="/Users/me/.claude/scheduled-tasks/nightly-report/SKILL.md">
        Summarize yesterday's commits.
        </scheduled-task>
        """

    private func discovered(id: String, prompt: String) -> Link {
        Link(id: id, projectPath: "/test/dev", column: .allSessions, source: .discovered, promptBody: prompt)
    }

    @Test("No rules hide nothing")
    func emptyRules() {
        let link = discovered(id: "c1", prompt: scheduledPrompt)
        #expect(SessionExclusion().excludes(link: link, session: nil) == false)
    }

    @Test("Hide scheduled tasks matches the Claude Desktop scheduled-task prompt")
    func scheduledTask() {
        let rules = SessionExclusion(hideScheduledTasks: true)
        #expect(rules.excludes(link: discovered(id: "c1", prompt: scheduledPrompt), session: nil))
        #expect(!rules.excludes(link: discovered(id: "c2", prompt: "fix the login bug"), session: nil))
    }

    @Test("A scheduled task is recognized from the session's first prompt too")
    func scheduledTaskFromSession() {
        let rules = SessionExclusion(hideScheduledTasks: true)
        let link = Link(id: "c1", column: .allSessions, source: .discovered)
        let session = Session(id: "s1", firstPrompt: scheduledPrompt)
        #expect(rules.excludes(link: link, session: session))
    }

    @Test("A plain pattern matches anywhere in the prompt, ignoring case")
    func plainPattern() {
        let rules = SessionExclusion(titlePatterns: ["NIGHTLY-REPORT"])
        #expect(rules.excludes(link: discovered(id: "c1", prompt: scheduledPrompt), session: nil))
        #expect(!rules.excludes(link: discovered(id: "c2", prompt: "weekly digest"), session: nil))
    }

    @Test("A glob pattern matches the whole prompt")
    func globPattern() {
        let rules = SessionExclusion(titlePatterns: ["<scheduled-task name=\"weekly-*"])
        #expect(rules.excludes(
            link: discovered(id: "c1", prompt: "<scheduled-task name=\"weekly-digest\">\nx\n</scheduled-task>"),
            session: nil
        ))
        #expect(!rules.excludes(link: discovered(id: "c2", prompt: scheduledPrompt), session: nil))
    }

    @Test("Blank patterns are ignored")
    func blankPattern() {
        let rules = SessionExclusion(titlePatterns: ["  "])
        #expect(rules.isEmpty)
        #expect(!rules.excludes(link: discovered(id: "c1", prompt: "anything"), session: nil))
    }

    @Test("A claimed card is never hidden")
    func claimedCardStays() {
        let rules = SessionExclusion(hideScheduledTasks: true, titlePatterns: ["nightly"])
        var link = discovered(id: "c1", prompt: scheduledPrompt)
        link.pinnedAt = .now
        #expect(!rules.excludes(link: link, session: nil))

        let manual = Link(id: "c2", column: .backlog, source: .manual, promptBody: scheduledPrompt)
        #expect(!rules.excludes(link: manual, session: nil))
    }

    @Test("settingsLoaded applies the rules to the board right away")
    func reducerHidesMatchingCards() {
        var state = AppState()
        state.links["c1"] = discovered(id: "c1", prompt: scheduledPrompt)
        state.links["c2"] = discovered(id: "c2", prompt: "add jj mapping to esc esc")
        state.rebuildCards()
        #expect(state.filteredCards.count == 2)

        _ = Reducer.reduce(state: &state, action: .settingsLoaded(
            projects: [], excludedPaths: [], remote: nil,
            sessionExclusion: SessionExclusion(hideScheduledTasks: true)
        ))
        #expect(state.filteredCards.map(\.id) == ["c2"])
        #expect(state.cards(in: .allSessions).map(\.id) == ["c2"])
        // The card still exists; it is only hidden.
        #expect(state.cards.count == 2)

        state.selectedProjectPath = "/test/dev"
        state.rebuildCards()
        #expect(state.filteredCards.map(\.id) == ["c2"])

        _ = Reducer.reduce(state: &state, action: .settingsLoaded(
            projects: [], excludedPaths: [], remote: nil
        ))
        #expect(state.filteredCards.count == 2)
    }

    @Test("Global view settings without session exclusion decode to no rules")
    func decodesOldSettings() throws {
        let json = #"{"excludedPaths":["/tmp/x"]}"#.data(using: .utf8)!
        let view = try JSONDecoder().decode(GlobalViewSettings.self, from: json)
        #expect(view.excludedPaths == ["/tmp/x"])
        #expect(view.sessionExclusion == SessionExclusion())
    }

    @Test("Session exclusion round-trips through settings JSON")
    func roundTrips() throws {
        let view = GlobalViewSettings(sessionExclusion: SessionExclusion(hideScheduledTasks: true, titlePatterns: ["foo*"]))
        let decoded = try JSONDecoder().decode(GlobalViewSettings.self, from: JSONEncoder().encode(view))
        #expect(decoded.sessionExclusion == view.sessionExclusion)
    }
}
