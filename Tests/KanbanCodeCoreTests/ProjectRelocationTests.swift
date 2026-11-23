import Foundation
import Testing
@testable import KanbanCodeCore

@Suite("ProjectRelocation")
struct ProjectRelocationTests {
    let old = "/Users/me/dev/ava.golf"
    let new = "/Users/me/dev/avagolf.com"

    @Test func movesThePathAndWhatIsUnderIt() {
        #expect(ProjectRelocation.relocate(old, from: old, to: new) == new)
        #expect(ProjectRelocation.relocate(old + "/apps/web", from: old, to: new) == new + "/apps/web")
        #expect(ProjectRelocation.relocate(old + "/", from: old + "/", to: new + "/") == new)
    }

    @Test func leavesSiblingsWithTheSamePrefixAlone() {
        #expect(ProjectRelocation.relocate(old + "-worktrees/x", from: old, to: new) == nil)
        #expect(ProjectRelocation.relocate("/Users/me/dev/other", from: old, to: new) == nil)
    }

    @Test func projectKeepsItsSettings() {
        var project = Project(path: old, name: "ava-golf", repoRoot: old + "/repo", visible: false, githubFilter: "is:open", promptTemplate: "t")
        project.color = "someFutureColor"
        let moved = ProjectRelocation.relocate(project, to: new)
        #expect(moved.path == new)
        #expect(moved.name == "ava-golf")
        #expect(moved.repoRoot == new + "/repo")
        #expect(moved.visible == false)
        #expect(moved.githubFilter == "is:open")
        #expect(moved.promptTemplate == "t")
        #expect(moved.color == "someFutureColor")
    }

    @Test func cardPathsFollowAndOtherCardsAreUntouched() {
        var link = Link(projectPath: old)
        link.worktreeLink = WorktreeLink(path: old + "/.claude/worktrees/fix", branch: "fix")
        link.discoveredRepos = ["fix": old, "other": "/elsewhere"]
        let moved = ProjectRelocation.relocate(link, from: old, to: new)
        #expect(moved?.projectPath == new)
        #expect(moved?.worktreeLink?.path == new + "/.claude/worktrees/fix")
        #expect(moved?.discoveredRepos == ["fix": new, "other": "/elsewhere"])
        #expect(ProjectRelocation.relocate(Link(projectPath: "/elsewhere"), from: old, to: new) == nil)
    }

    @Test func findsTranscriptsFiledUnderTheOldFolder() {
        var link = Link(projectPath: old)
        link.sessionLink = SessionLink(sessionId: "abc", sessionPath: "/Users/me/.claude/projects/-Users-me-dev-ava-golf/abc.jsonl")
        #expect(ProjectRelocation.transcriptNeedsMove(link, from: old))
        link.sessionLink = SessionLink(sessionId: "abc", sessionPath: "/Users/me/.claude/projects/-Users-me-dev-ava-golf-worktrees-x/abc.jsonl")
        #expect(!ProjectRelocation.transcriptNeedsMove(link, from: old))
    }

    @MainActor @Test func reducerMovesCardsAndSelection() {
        var state = AppState()
        let card = Link(projectPath: old)
        let other = Link(projectPath: "/elsewhere")
        state.links = [card.id: card, other.id: other]
        state.configuredProjects = [Project(path: old)]
        state.selectedProjectPath = old
        let effects = Reducer.reduce(state: &state, action: .projectRelocated(oldPath: old, newPath: new))
        #expect(state.links[card.id]?.projectPath == new)
        #expect(state.links[other.id]?.projectPath == "/elsewhere")
        #expect(state.selectedProjectPath == new)
        #expect(state.configuredProjects.map(\.path) == [new])
        #expect(effects.count == 1)
    }
}
