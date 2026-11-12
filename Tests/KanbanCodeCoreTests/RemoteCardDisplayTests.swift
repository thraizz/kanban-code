import Foundation
import KanbanCodeRemoteKit
import Testing

@testable import KanbanCodeCore

/// The fields that let a remote client draw and filter the board as the Mac
/// does: project color, model, memory and the hidden flag.
@Suite("Remote card display fields")
struct RemoteCardDisplayTests {
    private let scheduledPrompt = "<scheduled-task name=\"nightly\">\nreport\n</scheduled-task>"

    private func sessionCard(id: String, path: String = "/Users/me/acme") -> Link {
        Link(id: id, name: "Task \(id)", projectPath: path, column: .inProgress, source: .manual,
             sessionLink: SessionLink(sessionId: "s-\(id)", sessionPath: "/tmp/\(id).jsonl"))
    }

    private func worktreeOnly(id: String) -> Link {
        Link(id: id, projectPath: "/Users/me/acme", column: .backlog, source: .discovered,
             worktreeLink: WorktreeLink(path: "/Users/me/acme/.claude/worktrees/\(id)", branch: "feat/\(id)"))
    }

    private func discovered(id: String, prompt: String, path: String = "/Users/me/acme") -> Link {
        Link(id: id, projectPath: path, column: .allSessions, source: .discovered, promptBody: prompt,
             sessionLink: SessionLink(sessionId: "s-\(id)", sessionPath: "/tmp/\(id).jsonl"))
    }

    // MARK: Colors

    @Test("every palette color has a distinct #rrggbb hex")
    func hexFormat() {
        let hexes = ProjectColor.allCases.map(\.hex)
        #expect(Set(hexes).count == ProjectColor.allCases.count)
        for hex in hexes {
            #expect(hex.range(of: "^#[0-9a-f]{6}$", options: .regularExpression) != nil)
        }
    }

    @Test("projectColor is the configured color, else the automatic one, as CardView resolves it")
    func projectColorResolution() {
        let projects = [
            Project(path: "/Users/me/acme", color: .orange),
            Project(path: "/Users/me/other"),
        ]
        let display = RemoteBoardMapper.Display(projects: projects)
        let configured = RemoteBoardMapper.card(KanbanCodeCard(link: sessionCard(id: "a")), liveSessions: [], display: display)
        #expect(configured.projectColor == ProjectColor.orange.hex)

        let automatic = RemoteBoardMapper.card(KanbanCodeCard(link: sessionCard(id: "b", path: "/Users/me/other")),
                                               liveSessions: [], display: display)
        #expect(automatic.projectColor == ProjectColor.automatic(path: "/Users/me/other", in: projects).hex)
        #expect(automatic.projectColor == ProjectColor.allCases[1].hex)

        let unconfigured = RemoteBoardMapper.card(KanbanCodeCard(link: sessionCard(id: "c", path: "/tmp/loose")),
                                                  liveSessions: [], display: display)
        #expect(unconfigured.projectColor == ProjectColor.hashed("/tmp/loose").hex)

        let noPath = RemoteBoardMapper.card(KanbanCodeCard(link: Link(id: "d", column: .backlog)), liveSessions: [])
        #expect(noPath.projectColor == nil)
    }

    @Test("board projects carry their color")
    func boardProjectColors() {
        let projects = [Project(path: "/Users/me/acme"), Project(path: "/Users/me/other", color: .brown)]
        let board = RemoteBoardMapper.board(cards: [], projects: projects, liveSessions: [])
        #expect(board.projects.map(\.color) == [ProjectColor.blue.hex, ProjectColor.brown.hex])
    }

    // MARK: Model and memory

    @Test("model and memoryBytes come from the card's live model and memory")
    func modelAndMemory() {
        let card = KanbanCodeCard(link: sessionCard(id: "a"), liveModel: "opus",
                                  memory: CardMemory(totalBytes: 832 * 1024 * 1024))
        let remote = RemoteBoardMapper.card(card, liveSessions: [])
        #expect(remote.model == "opus")
        #expect(remote.memoryBytes == 832 * 1024 * 1024)

        let idle = RemoteBoardMapper.card(KanbanCodeCard(link: sessionCard(id: "b")), liveSessions: [])
        #expect(idle.model == nil)
        #expect(idle.memoryBytes == nil)
    }

    // MARK: Hidden

    @Test("hiddenReason names each rule the Mac board hides by")
    func hiddenReasons() {
        let display = RemoteBoardMapper.Display(
            sessionExclusion: SessionExclusion(hideScheduledTasks: true, titlePatterns: ["dependabot"]),
            pathExclusion: PathExclusion(["/Users/me/scratch"])
        )
        func reason(_ link: Link) -> String? {
            let remote = RemoteBoardMapper.card(KanbanCodeCard(link: link), liveSessions: [], display: display)
            #expect(remote.hidden == (remote.hiddenReason != nil))
            return remote.hiddenReason
        }
        #expect(reason(sessionCard(id: "a")) == nil)
        #expect(reason(discovered(id: "b", prompt: scheduledPrompt)) == "scheduledTask")
        #expect(reason(discovered(id: "c", prompt: "Bump Dependabot config")) == "titlePattern")
        #expect(reason(worktreeOnly(id: "d")) == "worktreeOnly")
        #expect(reason(sessionCard(id: "e", path: "/Users/me/scratch/tool")) == "excludedPath")
    }

    @Test("a worktree card that is launching, busy or has a terminal is not hidden")
    func worktreeExceptions() {
        var launching = worktreeOnly(id: "a")
        launching.isLaunching = true
        #expect(KanbanCodeCard(link: launching).boardHiddenReason(sessionExclusion: .init(), pathExclusion: .none) == nil)
        #expect(KanbanCodeCard(link: worktreeOnly(id: "b"), isBusy: true)
            .boardHiddenReason(sessionExclusion: .init(), pathExclusion: .none) == nil)
        var withTerminal = worktreeOnly(id: "c")
        withTerminal.tmuxLink = TmuxLink(sessionName: "card-c")
        #expect(KanbanCodeCard(link: withTerminal).boardHiddenReason(sessionExclusion: .init(), pathExclusion: .none) == nil)
    }

    @Test("hidden on the wire is exactly what the board's filtered cards leave out")
    func hiddenMatchesBoardFilter() {
        var state = AppState()
        let links = [
            sessionCard(id: "shown"),
            discovered(id: "scheduled", prompt: scheduledPrompt),
            discovered(id: "pattern", prompt: "nightly dependabot sweep"),
            discovered(id: "plain", prompt: "fix the login bug"),
            worktreeOnly(id: "branch"),
            sessionCard(id: "excluded", path: "/Users/me/scratch"),
        ]
        for link in links { state.links[link.id] = link }
        state.excludedPaths = ["/Users/me/scratch"]
        state.sessionExclusion = SessionExclusion(hideScheduledTasks: true, titlePatterns: ["dependabot"])
        state.rebuildCards()

        let board = RemoteBoardMapper.board(
            cards: state.cards, projects: [], liveSessions: [],
            sessionExclusion: state.sessionExclusion, pathExclusion: state.pathExclusion
        )
        let shownOnWire = Set(board.cards.filter { !$0.hidden }.map(\.id))
        #expect(shownOnWire == Set(state.filteredCards.map(\.id)))
        #expect(shownOnWire == ["shown", "plain"])
        #expect(board.cards.count == links.count)
    }

    // MARK: Encoding

    @Test("the new fields round-trip, and defaults are left out of the JSON")
    func encoding() throws {
        let card = RemoteCard(id: "c1", title: "t", column: .backlog, updatedAt: Date(timeIntervalSince1970: 0),
                              projectColor: "#0091ff", model: "opus", memoryBytes: 1_234,
                              hidden: true, hiddenReason: "worktreeOnly")
        let data = try JSONEncoder.remote.encode(card)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["projectColor"] as? String == "#0091ff")
        #expect(json["model"] as? String == "opus")
        #expect(json["memoryBytes"] as? Int == 1_234)
        #expect(json["hidden"] as? Bool == true)
        #expect(json["hiddenReason"] as? String == "worktreeOnly")
        #expect(try JSONDecoder.remote.decode(RemoteCard.self, from: data) == card)

        let plain = RemoteCard(id: "c2", title: "t", column: .backlog, updatedAt: Date(timeIntervalSince1970: 0))
        let plainJSON = try #require(JSONSerialization.jsonObject(with: JSONEncoder.remote.encode(plain)) as? [String: Any])
        for key in ["projectColor", "model", "memoryBytes", "hidden", "hiddenReason"] {
            #expect(plainJSON[key] == nil)
        }
    }

    @Test("an old server's card and project decode with the defaults")
    func decodesOldPayload() throws {
        let card = try JSONDecoder.remote.decode(RemoteCard.self, from: Data("""
            {"id":"c1","title":"t","column":"backlog","assistant":"claude","runtime":"none","updatedAt":"2026-09-26T10:00:00.000Z"}
            """.utf8))
        #expect(card.projectColor == nil && card.model == nil && card.memoryBytes == nil)
        #expect(card.hidden == false && card.hiddenReason == nil)
        let project = try JSONDecoder.remote.decode(RemoteProject.self, from: Data(#"{"path":"/a","name":"a"}"#.utf8))
        #expect(project.color == nil)
    }
}
