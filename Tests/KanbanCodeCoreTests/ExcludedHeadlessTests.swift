import Testing
import Foundation
@testable import KanbanCodeCore

/// Headless runs (`claude -p`) in a folder excluded from the global view
/// are not tracked: no session, no card.
@Suite("Excluded headless sessions")
struct ExcludedHeadlessTests {

    // MARK: - PathExclusion

    @Test("A folder entry excludes itself and everything below it")
    func folderEntry() {
        let exclusion = PathExclusion(["/Users/me/judge-lab/"])
        #expect(exclusion.matches("/Users/me/judge-lab"))
        #expect(exclusion.matches("/Users/me/judge-lab/runs/1"))
        #expect(!exclusion.matches("/Users/me/judge-lab-other"))
        #expect(!exclusion.matches(nil))
    }

    @Test("A glob entry matches the full path or the folder name")
    func globEntry() {
        let full = PathExclusion(["/Users/me/judge-lab/**/*"])
        #expect(full.matches("/Users/me/judge-lab/runs/1"))
        #expect(!full.matches("/Users/me/other"))
        let name = PathExclusion(["scratch-*"])
        #expect(name.matches("/anywhere/scratch-42"))
        #expect(!name.matches("/anywhere/project"))
    }

    @Test("Only project directories named after an excluded path are probed")
    func claudeDirCandidates() {
        let exclusion = PathExclusion(["/Users/me/judge-lab", "/Users/me/bench/*"])
        #expect(exclusion.mayMatchClaudeProjectDir("-Users-me-judge-lab"))
        #expect(exclusion.mayMatchClaudeProjectDir("-Users-me-judge-lab-runs"))
        #expect(exclusion.mayMatchClaudeProjectDir("-Users-me-bench-x"))
        #expect(!exclusion.mayMatchClaudeProjectDir("-Users-me-kanban"))
        #expect(PathExclusion(["scratch-*"]).mayMatchClaudeProjectDir("-Users-me-kanban"))
        #expect(!PathExclusion.none.mayMatchClaudeProjectDir("-Users-me-judge-lab"))
    }

    // MARK: - Discovery

    private func makeClaudeDir() throws -> (root: String, project: String) {
        let root = NSTemporaryDirectory() + "kanban-excluded-headless-\(UUID().uuidString)"
        let project = root + "/-Users-me-judge-lab"
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        return (root, project)
    }

    private func writeSession(_ id: String, in dir: String, entrypoint: String, cwd: String = "/Users/me/judge-lab") throws {
        try [
            #"{"type":"queue-operation","operation":"enqueue","sessionId":"\#(id)"}"#,
            #"{"type":"user","entrypoint":"\#(entrypoint)","cwd":"\#(cwd)","message":{"role":"user","content":"Judge this"}}"#,
            #"{"type":"assistant","entrypoint":"\#(entrypoint)","message":{"content":[{"type":"text","text":"ok"}]}}"#,
        ].joined(separator: "\n").write(toFile: "\(dir)/\(id).jsonl", atomically: true, encoding: .utf8)
    }

    @Test("Discovery skips headless runs in an excluded folder, keeps interactive ones, and brings them back when the entry goes")
    func discoverySkipsAndRestores() async throws {
        let (root, project) = try makeClaudeDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try writeSession("h1", in: project, entrypoint: "sdk-cli")
        try writeSession("i1", in: project, entrypoint: "cli")

        let discovery = ClaudeCodeSessionDiscovery(claudeDir: root)
        discovery.setHeadlessExclusion(PathExclusion(["/Users/me/judge-lab"]))
        #expect(try await discovery.discoverSessions().map(\.id) == ["i1"])

        discovery.setHeadlessExclusion(.none)
        #expect(Set(try await discovery.discoverSessions().map(\.id)) == ["h1", "i1"])

        discovery.setHeadlessExclusion(PathExclusion(["/Users/me/judge-lab"]))
        #expect(try await discovery.discoverSessions().map(\.id) == ["i1"])
    }

    @Test("A skipped transcript is not read again while the exclusion holds")
    func skippedTranscriptNotReread() async throws {
        let (root, project) = try makeClaudeDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try writeSession("h1", in: project, entrypoint: "sdk-cli")

        let discovery = ClaudeCodeSessionDiscovery(claudeDir: root)
        discovery.setHeadlessExclusion(PathExclusion(["/Users/me/judge-lab"]))
        #expect(try await discovery.discoverSessions().isEmpty)

        // Were it read again, this content would make it an interactive
        // session. A new file changes the directory mtime to force a rescan.
        try writeSession("h1", in: project, entrypoint: "cli")
        try writeSession("i2", in: project, entrypoint: "cli")
        #expect(try await discovery.discoverSessions().map(\.id) == ["i2"])
    }

    @Test("Headless runs outside the excluded folder are still discovered")
    func otherFoldersUntouched() async throws {
        let (root, _) = try makeClaudeDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let other = root + "/-Users-me-judge-lab-other"
        try FileManager.default.createDirectory(atPath: other, withIntermediateDirectories: true)
        try writeSession("h2", in: other, entrypoint: "sdk-cli", cwd: "/Users/me/judge-lab-other")

        let discovery = ClaudeCodeSessionDiscovery(claudeDir: root)
        discovery.setHeadlessExclusion(PathExclusion(["/Users/me/judge-lab"]))
        #expect(try await discovery.discoverSessions().map(\.id) == ["h2"])
    }

    // MARK: - Reducer

    private func card(_ id: String, headless: Bool?, project: String = "/Users/me/judge-lab", isLaunching: Bool? = nil, name: String? = nil) -> Link {
        Link(
            id: id, name: name, projectPath: project, column: .allSessions,
            source: .discovered, promptBody: "Judge this",
            sessionLink: SessionLink(sessionId: "s-\(id)"),
            isLaunching: isLaunching, headless: headless
        )
    }

    @Test("Reconcile drops unclaimed headless cards in an excluded folder, and only those")
    func reconcileDropsExcludedHeadless() {
        let state = AppState()
        let links = [
            card("h1", headless: true),
            card("i1", headless: nil),
            card("launching", headless: true, isLaunching: true),
            card("named", headless: true, name: "Keep me"),
            card("elsewhere", headless: true, project: "/Users/me/kanban"),
        ]
        for link in links { state.links[link.id] = link }
        _ = Reducer.reduce(state: state, action: .settingsLoaded(
            projects: [], excludedPaths: ["/Users/me/judge-lab"], remote: nil))

        let effects = Reducer.reduce(state: state, action: .reconciled(ReconciliationResult(
            links: links, sessions: [], activityMap: [:], tmuxSessions: []
        )))

        #expect(Set(state.links.keys) == ["i1", "launching", "named", "elsewhere"])
        #expect(state.tombstones["h1"] != nil)
        #expect(state.tombstones["h1"]?.promptBody == nil)
        #expect(effects.contains { if case .persistLinks = $0 { true } else { false } })
    }
}
