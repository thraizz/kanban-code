import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("Session resources")
struct SessionResourcesTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let mib = 1024 * 1024

    private func card(_ id: String, _ column: KanbanCodeColumn, quietMinutes: Double, canHibernate: Bool = true,
                      isWorking: Bool = false, bytes: Int = 0, browserPids: [Int32] = []) -> HibernationPolicy.LiveCard {
        HibernationPolicy.LiveCard(
            cardId: id, column: column, lastActive: now.addingTimeInterval(-quietMinutes * 60),
            canHibernate: canHibernate, isWorking: isWorking,
            memory: CardMemory(totalBytes: bytes, browserPids: browserPids))
    }

    // MARK: - Policy

    @Test("a quiet Done card is hibernated after the Done limit, not before")
    func doneLimit() {
        let settings = SessionResourceSettings(hibernateDoneAfterMinutes: 60, hibernateIdleAfterHours: nil, closeIdleBrowserAfterMinutes: nil)
        let decisions = HibernationPolicy.decide(
            cards: [card("old", .done, quietMinutes: 61), card("fresh", .done, quietMinutes: 30)],
            settings: settings, now: now)
        #expect(decisions == [.hibernate(cardId: "old", reason: .done)])
    }

    @Test("waiting cards use the idle limit; in progress and backlog never do")
    func idleLimit() {
        let settings = SessionResourceSettings(hibernateDoneAfterMinutes: nil, hibernateIdleAfterHours: 24, closeIdleBrowserAfterMinutes: nil)
        let decisions = HibernationPolicy.decide(
            cards: [
                card("waiting", .waiting, quietMinutes: 25 * 60),
                card("review", .inReview, quietMinutes: 25 * 60),
                card("progress", .inProgress, quietMinutes: 25 * 60),
                card("recent", .waiting, quietMinutes: 60),
            ],
            settings: settings, now: now)
        #expect(Set(decisions.map { "\($0)" }) == Set([
            HibernationPolicy.Decision.hibernate(cardId: "waiting", reason: .idle),
            .hibernate(cardId: "review", reason: .idle),
        ].map { "\($0)" }))
    }

    @Test("working or protected cards are never hibernated")
    func protectedCards() {
        let settings = SessionResourceSettings(hibernateDoneAfterMinutes: 0, closeIdleBrowserAfterMinutes: nil)
        let decisions = HibernationPolicy.decide(
            cards: [
                card("working", .done, quietMinutes: 600, isWorking: true),
                card("open", .done, quietMinutes: 600, canHibernate: false),
            ],
            settings: settings, now: now)
        #expect(decisions.isEmpty)
    }

    @Test("over the session limit the quietest cards go first")
    func sessionLimit() {
        let settings = SessionResourceSettings(hibernateDoneAfterMinutes: nil, hibernateIdleAfterHours: nil,
                                               maxLiveSessions: 2, closeIdleBrowserAfterMinutes: nil)
        let decisions = HibernationPolicy.decide(
            cards: [
                card("a", .inProgress, quietMinutes: 5),
                card("b", .waiting, quietMinutes: 50),
                card("c", .waiting, quietMinutes: 500),
                card("d", .inProgress, quietMinutes: 1, isWorking: true),
            ],
            settings: settings, now: now)
        #expect(decisions == [
            .hibernate(cardId: "b", reason: .sessionLimit),
            .hibernate(cardId: "c", reason: .sessionLimit),
        ])
    }

    @Test("critical pressure stops the biggest quiet cards, up to three")
    func criticalPressure() {
        let settings = SessionResourceSettings(hibernateDoneAfterMinutes: nil, hibernateIdleAfterHours: nil, closeIdleBrowserAfterMinutes: nil)
        let cards = [
            card("small", .waiting, quietMinutes: 60, bytes: 100 * mib),
            card("big1", .waiting, quietMinutes: 60, bytes: 3000 * mib),
            card("big2", .inReview, quietMinutes: 60, bytes: 2000 * mib),
            card("big3", .done, quietMinutes: 60, bytes: 1000 * mib),
            card("bigButBusy", .waiting, quietMinutes: 5, bytes: 9000 * mib),
        ]
        let decisions = HibernationPolicy.decide(cards: cards, settings: settings, pressure: .critical, now: now)
        let ids = Set(decisions.compactMap { if case .hibernate(let id, .memoryPressure) = $0 { id } else { nil } })
        #expect(ids == ["big1", "big2", "big3"])

        var off = settings
        off.relieveMemoryPressure = false
        #expect(HibernationPolicy.decide(cards: cards, settings: off, pressure: .critical, now: now).isEmpty)
    }

    @Test("a quiet card's Playwright browser closes; a working card's does not")
    func browsers() {
        let settings = SessionResourceSettings(hibernateDoneAfterMinutes: nil, hibernateIdleAfterHours: nil, closeIdleBrowserAfterMinutes: 30)
        let decisions = HibernationPolicy.decide(
            cards: [
                card("quiet", .waiting, quietMinutes: 31, browserPids: [42]),
                card("recent", .waiting, quietMinutes: 10, browserPids: [43]),
                card("busy", .inProgress, quietMinutes: 120, isWorking: true, browserPids: [44]),
            ],
            settings: settings, now: now)
        #expect(decisions == [.closeBrowser(cardId: "quiet", pids: [42])])

        // A pressure warning lowers the limit to five minutes.
        let underPressure = HibernationPolicy.decide(
            cards: [card("recent", .waiting, quietMinutes: 10, browserPids: [43])],
            settings: settings, pressure: .warning, now: now)
        #expect(underPressure == [.closeBrowser(cardId: "recent", pids: [43])])
    }

    // MARK: - Measuring

    @Test("process trees add up per pane and find Playwright browsers")
    func measure() {
        let p = SessionProcessTree.Process.init
        let processes = [
            p(10, 1, 1 * mib, "-zsh"),
            p(11, 10, 300 * mib, "claude --dangerously-skip-permissions"),
            p(12, 11, 20 * mib, "npm exec @playwright/mcp@latest"),
            p(13, 12, 200 * mib, "node /x/.bin/playwright-mcp"),
            p(14, 13, 500 * mib, "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome --headless"),
            p(15, 14, 400 * mib, "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Helper (Renderer)"),
            // chrome-devtools-mcp's browser is not closed: it may not reopen one.
            p(16, 11, 30 * mib, "chrome-devtools-mcp"),
            p(17, 16, 600 * mib, "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
            p(20, 1, 1 * mib, "-zsh"),
            p(21, 20, 50 * mib, "npm run dev"),
        ]
        let memory = SessionProcessTree.measure(
            processes: processes,
            paneRoots: [(session: "card-a", pid: 10), (session: "card-a-sh", pid: 20)])
        let a = memory["card-a"]
        #expect(a?.totalBytes == 2051 * mib)
        #expect(a?.browserBytes == 900 * mib)
        #expect(a?.browserPids == [14])
        #expect(a?.topBytes == 600 * mib)
        #expect(memory["card-a-sh"]?.totalBytes == 51 * mib)
    }

    // MARK: - Board

    @Test("a card's memory sums all its terminals; candidates skip open and shell-only cards")
    func candidates() {
        let state = AppState()
        state.links["c1"] = Link(id: "c1", column: .done, lastActivity: now,
                                 sessionLink: SessionLink(sessionId: "s1"),
                                 tmuxLink: TmuxLink(sessionName: "t1", extraSessions: ["t1-sh"]))
        state.links["c2"] = Link(id: "c2", column: .done, lastActivity: now,
                                 sessionLink: SessionLink(sessionId: "s2"),
                                 tmuxLink: TmuxLink(sessionName: "t2", isShellOnly: true))
        state.links["c3"] = Link(id: "c3", column: .waiting, lastActivity: now,
                                 sessionLink: SessionLink(sessionId: "s3"),
                                 tmuxLink: TmuxLink(sessionName: "t3"))
        state.tmuxSessions = ["t1", "t1-sh", "t2", "t3"]
        state.openDrawer = .card("c3")
        let bySession = [
            "t1": CardMemory(totalBytes: 100), "t1-sh": CardMemory(totalBytes: 50),
            "t2": CardMemory(totalBytes: 10), "t3": CardMemory(totalBytes: 1),
        ]
        #expect(state.cardMemory(memoryBySession: bySession)["c1"]?.totalBytes == 150)
        let candidates = Dictionary(uniqueKeysWithValues: state.hibernationCandidates(memoryBySession: bySession).map { ($0.cardId, $0) })
        #expect(candidates["c1"]?.canHibernate == true)
        #expect(candidates["c2"] == nil)
        #expect(candidates["c3"]?.canHibernate == false)
    }

    @Test("hibernating a Done card kills every terminal and keeps the card in place")
    func reducerDone() {
        var state = AppState()
        state.links["c1"] = Link(id: "c1", column: .done, sessionLink: SessionLink(sessionId: "s1"),
                                 tmuxLink: TmuxLink(sessionName: "t1", extraSessions: ["t1-sh"]))
        let effects = Reducer.reduce(state: &state, action: .hibernateCard(cardId: "c1", reason: .done))
        let link = state.links["c1"]
        #expect(link?.tmuxLink == nil)
        #expect(link?.hibernation?.reason == .done)
        #expect(link?.manualOverrides.column == true)
        #expect(link?.column == .done)
        #expect(link?.sessionLink?.sessionId == "s1")
        #expect(effects.contains { if case .killTmuxSessions(let names) = $0 { names == ["t1", "t1-sh"] } else { false } })

        _ = Reducer.reduce(state: &state, action: .resumeCard(cardId: "c1"))
        #expect(state.links["c1"]?.hibernation == nil)
    }

    @Test("an idle card keeps its shell tabs")
    func reducerIdle() {
        var state = AppState()
        state.links["c1"] = Link(id: "c1", column: .waiting, sessionLink: SessionLink(sessionId: "s1"),
                                 tmuxLink: TmuxLink(sessionName: "t1", extraSessions: ["t1-sh"]))
        let effects = Reducer.reduce(state: &state, action: .hibernateCard(cardId: "c1", reason: .idle))
        #expect(state.links["c1"]?.tmuxLink?.isPrimaryDead == true)
        #expect(state.links["c1"]?.tmuxLink?.extraSessions == ["t1-sh"])
        #expect(effects.contains { if case .killTmuxSessions(let names) = $0 { names == ["t1"] } else { false } })
    }

    // MARK: - Settings

    @Test("missing keys keep defaults, null switches a limit off")
    func settingsDecoding() throws {
        let decoded = try JSONDecoder().decode(SessionResourceSettings.self, from: Data(#"{"hibernateIdleAfterHours": null}"#.utf8))
        #expect(decoded.hibernateDoneAfterMinutes == 60)
        #expect(decoded.hibernateIdleAfterHours == nil)
        let roundTrip = try JSONDecoder().decode(SessionResourceSettings.self, from: JSONEncoder().encode(decoded))
        #expect(roundTrip == decoded)
        let settings = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        #expect(settings.resources == SessionResourceSettings())
    }
}
