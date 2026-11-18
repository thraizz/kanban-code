import Foundation
import Testing

@testable import KanbanCodeCore

/// A session's background agents (Claude Code `Agent` tool) make worktrees,
/// push branches and open pull requests from their own transcripts. Those
/// belong to the card whose session started them, not to cards of their own.
@Suite("Subagent branches")
struct SubagentBranchTests {

    private func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "kanban-code-subagent-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func bash(_ command: String, cwd: String) -> String {
        let escaped = command.replacingOccurrences(of: "\"", with: "\\\"")
        return """
            {"type":"assistant","cwd":"\(cwd)","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"\(escaped)"}}]}}
            """
    }

    private func writeLines(_ path: String, _ lines: [String]) throws {
        try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// A session file with one agent transcript beside it.
    private func makeSession(agentLines: [String]) throws -> (dir: String, session: String, agent: String) {
        let dir = try makeTempDir()
        let session = dir + "/s1.jsonl"
        try writeLines(session, [bash("ls", cwd: "/repo")])
        try FileManager.default.createDirectory(atPath: dir + "/s1/subagents", withIntermediateDirectories: true)
        let agent = dir + "/s1/subagents/agent-a1.jsonl"
        try writeLines(agent, agentLines)
        return (dir, session, agent)
    }

    private func pr(_ number: Int, branch: String, state: String = "MERGED") -> PullRequest {
        PullRequest(
            number: number, title: "PR \(number)", state: state,
            url: "https://github.com/o/r/pull/\(number)", headRefName: branch)
    }

    // MARK: - Reading the commands

    @Test("git -C with -b before the path still names the worktree's branch")
    func worktreeAddWithGitDirAndLeadingB() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/a.jsonl"
        try writeLines(path, [
            bash(
                "ROOT=/repo; git -C $ROOT fetch origin -q && git -C $ROOT worktree add -b chore/repo-cleanup $ROOT/.claude/worktrees/repo-cleanup origin/stage 2>&1 | tail -2",
                cwd: "/repo"),
            bash("cd /repo && git worktree add -q -b chore/lean-comments .claude/worktrees/lean-comments origin/stage", cwd: "/repo"),
            bash("git worktree add .claude/worktrees/x -b feat/after-path", cwd: "/repo"),
        ])

        let found = try await JsonlParser.extractPushedBranches(from: path)

        #expect(Set(found.map(\.branch)) == ["chore/repo-cleanup", "chore/lean-comments", "feat/after-path"])
        #expect(found.allSatisfy { $0.repoPath == "/repo" })
    }

    @Test("git -C names the repository a push runs in")
    func gitDirOptionGivesTheRepo() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/a.jsonl"
        try writeLines(path, [bash("git -C /other/.claude/worktrees/w push -u origin feat/x", cwd: "/repo")])

        let found = try await JsonlParser.extractPushedBranches(from: path)

        #expect(found == [JsonlParser.DiscoveredBranch(branch: "feat/x", repoPath: "/other")])
    }

    @Test("the agent transcripts sit in a folder named after the session")
    func transcriptPaths() throws {
        let s = try makeSession(agentLines: [])
        defer { try? FileManager.default.removeItem(atPath: s.dir) }
        try "{}".write(toFile: s.dir + "/s1/subagents/agent-a1.meta.json", atomically: true, encoding: .utf8)

        #expect(JsonlParser.subagentTranscriptPaths(forSession: s.session) == [s.agent])
        #expect(JsonlParser.subagentTranscriptPaths(forSession: s.dir + "/none.jsonl").isEmpty)
    }

    // MARK: - Recording them on the card

    @Test("an agent's branch is recorded on the card that started it, once")
    func scanRecordsAgentBranches() async throws {
        let s = try makeSession(agentLines: [
            bash("git -C /repo worktree add -b chore/repo-cleanup /repo/.claude/worktrees/repo-cleanup origin/stage", cwd: "/repo"),
        ])
        defer { try? FileManager.default.removeItem(atPath: s.dir) }
        let card = Link(
            projectPath: "/repo", column: .inProgress,
            sessionLink: SessionLink(sessionId: "s1", sessionPath: s.session))

        let first = await BoardStore.scanSubagentBranches(links: [card], offsets: [:])
        #expect(first.links[0].subagentBranches == ["chore/repo-cleanup": "/repo"])
        #expect(first.links[0].worktreeLink == nil)
        #expect(first.offsets[s.agent] != nil)

        // New lines are read from where the last scan stopped.
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: s.agent))
        handle.seekToEndOfFile()
        handle.write((bash("git push -u origin feat/second", cwd: "/repo") + "\n").data(using: .utf8)!)
        try handle.close()
        let second = await BoardStore.scanSubagentBranches(links: first.links, offsets: first.offsets)
        #expect(second.links[0].subagentBranches == ["chore/repo-cleanup": "/repo", "feat/second": "/repo"])
    }

    @Test("a branch the card already knows as its own is not an agent's")
    func scanSkipsOwnBranches() async throws {
        let s = try makeSession(agentLines: [bash("git push origin feat/own", cwd: "/repo")])
        defer { try? FileManager.default.removeItem(atPath: s.dir) }
        let card = Link(
            projectPath: "/repo", column: .waiting,
            sessionLink: SessionLink(sessionId: "s1", sessionPath: s.session),
            discoveredBranches: ["feat/own"])

        let scan = await BoardStore.scanSubagentBranches(links: [card], offsets: [:])

        #expect(scan.links[0].subagentBranches == nil)
    }

    @Test("archived and finished cards are not scanned")
    func scanSkipsIdleCards() async throws {
        let s = try makeSession(agentLines: [bash("git push origin feat/x", cwd: "/repo")])
        defer { try? FileManager.default.removeItem(atPath: s.dir) }
        let done = Link(
            projectPath: "/repo", column: .done,
            sessionLink: SessionLink(sessionId: "s1", sessionPath: s.session))

        let scan = await BoardStore.scanSubagentBranches(links: [done], offsets: [:])

        #expect(scan.links[0].subagentBranches == nil)
        #expect(scan.offsets.isEmpty)
    }

    // MARK: - Reconciling

    private var parent: Link {
        Link(
            id: "card_parent", projectPath: "/repo", column: .inProgress, source: .manual,
            sessionLink: SessionLink(sessionId: "s1", sessionPath: "/p/s1.jsonl"),
            subagentBranches: ["chore/repo-cleanup": "/repo"])
    }

    @Test("an agent's worktree is no orphan and does not become the card's worktree")
    func agentWorktreeIsNotAnOrphan() {
        let snapshot = CardReconciler.DiscoverySnapshot(
            worktrees: ["/repo": [
                Worktree(path: "/repo", branch: "refs/heads/stage"),
                Worktree(path: "/repo/.claude/worktrees/repo-cleanup", branch: "refs/heads/chore/repo-cleanup"),
            ]],
            pullRequests: ["chore/repo-cleanup": pr(3526, branch: "chore/repo-cleanup")]
        )

        let result = CardReconciler.reconcile(existing: [parent], snapshot: snapshot)

        #expect(result.count == 1)
        #expect(result[0].id == "card_parent")
        #expect(result[0].worktreeLink == nil)
        #expect(result[0].prLinks.map(\.number) == [3526])
    }

    @Test("an orphan made before the card knew the branch is absorbed, its worktree not taken")
    func existingOrphanWorktreeIsAbsorbed() {
        let orphan = Link(
            id: "card_orphan", projectPath: "/repo", column: .inReview,
            worktreeLink: WorktreeLink(path: "/repo/.claude/worktrees/repo-cleanup", branch: "chore/repo-cleanup"),
            prLinks: [PRLink(number: 3526, url: "https://github.com/o/r/pull/3526", status: .reviewNeeded)])
        let snapshot = CardReconciler.DiscoverySnapshot(
            worktrees: ["/repo": [
                Worktree(path: "/repo", branch: "refs/heads/stage"),
                Worktree(path: "/repo/.claude/worktrees/repo-cleanup", branch: "refs/heads/chore/repo-cleanup"),
            ]]
        )

        let result = CardReconciler.reconcile(existing: [parent, orphan], snapshot: snapshot)

        #expect(result.map(\.id) == ["card_parent"])
        #expect(result[0].worktreeLink == nil)
        #expect(result[0].prLinks.map(\.number) == [3526])
    }

    @Test("an orphan left with only an agent's pull request merges into the agent's card")
    func prOnlyOrphanMergesIntoOwner() {
        var owner = parent
        owner.prLinks = [PRLink(number: 3526, url: "https://github.com/o/r/pull/3526", status: .merged)]
        let orphan = Link(
            id: "card_orphan", projectPath: "/repo", column: .done,
            prLinks: [PRLink(number: 3526, url: "https://github.com/o/r/pull/3526", status: .merged)])
        let unrelated = Link(
            id: "card_other", projectPath: "/repo", column: .done,
            prLinks: [PRLink(number: 9999, url: "https://github.com/o/r/pull/9999", status: .merged)])

        let orphans = CardReconciler.orphansOfSubagentWork([owner, orphan, unrelated])

        #expect(orphans == ["card_orphan": "card_parent"])
    }

    @Test("an orphan is kept while the agent's card does not carry its pull request yet")
    func orphanKeptUntilOwnerHasThePR() {
        let orphan = Link(
            id: "card_orphan", projectPath: "/repo", column: .done,
            prLinks: [PRLink(number: 3526, url: "https://github.com/o/r/pull/3526", status: .merged)])

        #expect(CardReconciler.orphansOfSubagentWork([parent, orphan]).isEmpty)
    }

    @Test("a named or manual card is never treated as an orphan")
    func namedCardIsNotAnOrphan() {
        var owner = parent
        owner.prLinks = [PRLink(number: 3526, url: "https://github.com/o/r/pull/3526")]
        let named = Link(
            id: "card_named", name: "Mine", projectPath: "/repo",
            prLinks: [PRLink(number: 3526, url: "https://github.com/o/r/pull/3526")])

        #expect(CardReconciler.orphansOfSubagentWork([owner, named]).isEmpty)
    }

    @Test("pull request refresh looks up the agents' branches")
    func refreshScopeIncludesAgentBranches() {
        let scope = PRRefreshScope.collect(links: [parent])
        #expect(scope.branchesByRepo["/repo"]?.contains("chore/repo-cleanup") == true)
    }
}
