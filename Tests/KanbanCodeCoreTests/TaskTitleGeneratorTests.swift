import Foundation
import Testing

@testable import KanbanCodeCore

@Suite("Task title generator")
struct TaskTitleGeneratorTests {

    @Test("clean keeps the first line without quotes, markdown or trailing period")
    func clean() {
        #expect(TaskTitleGenerator.clean("Fix worktree removal on archive") == "Fix worktree removal on archive")
        #expect(TaskTitleGenerator.clean("\"Fix login bug.\"") == "Fix login bug")
        #expect(TaskTitleGenerator.clean("**Fix flaky reconciler test**\n\nCan't fix yet: ...") == "Fix flaky reconciler test")
        #expect(TaskTitleGenerator.clean("\n  Title: Add dark mode\n") == "Add dark mode")
        #expect(TaskTitleGenerator.clean("# Speed up branch discovery") == "Speed up branch discovery")
        #expect(TaskTitleGenerator.clean(String(repeating: "a", count: 200)).count == TaskTitleGenerator.maxTitleCharacters)
        #expect(TaskTitleGenerator.clean("  \n ").isEmpty)
    }

    @Test("the OpenRouter key comes from the environment, then opencode's auth.json")
    func openRouterKey() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let auth = dir.appendingPathComponent("auth.json").path
        try #"{"openrouter":{"type":"api","key":"sk-or-file"}}"#.write(toFile: auth, atomically: true, encoding: .utf8)

        #expect(TaskTitleGenerator.openRouterKey(environment: ["OPENROUTER_API_KEY": "sk-or-env"], opencodeAuthPath: auth) == "sk-or-env")
        #expect(TaskTitleGenerator.openRouterKey(environment: [:], opencodeAuthPath: auth) == "sk-or-file")
        #expect(TaskTitleGenerator.openRouterKey(environment: [:], opencodeAuthPath: dir.appendingPathComponent("none").path) == nil)
    }

    @Test("a prompt with nothing in it is refused before any request")
    func emptyPrompt() async {
        await #expect(throws: TaskTitleGenerator.GenerationError.self) {
            try await TaskTitleGenerator.generate(prompt: "  \n")
        }
    }

    @Test("a card is untitled while its name is empty or its prompt's first line")
    func needsTitle() {
        let prompt = "fix the login bug\nit fails on Safari"
        #expect(TaskTitleGenerator.placeholderName(for: prompt) == "fix the login bug")
        #expect(TaskTitleGenerator.needsTitle(Link(name: nil, column: .backlog, promptBody: prompt)))
        #expect(TaskTitleGenerator.needsTitle(Link(name: "fix the login bug", column: .backlog, promptBody: prompt)))
        #expect(!TaskTitleGenerator.needsTitle(Link(name: "Safari login", column: .backlog, promptBody: prompt)))
        #expect(!TaskTitleGenerator.needsTitle(Link(name: nil, column: .backlog)))
    }

    @Test("creating a manual card without a title asks for one, once")
    func createRequestsTitle() {
        let state = AppState()
        let link = Link(id: "c1", name: "fix the login bug", column: .backlog, source: .manual, promptBody: "fix the login bug")
        let effects = Reducer.reduce(state: state, action: .createManualTask(link))
        #expect(effects.contains { if case .generateTitle(cardId: "c1", prompt: "fix the login bug") = $0 { true } else { false } })

        // The same action as an upsert of an existing card does not ask again.
        let again = Reducer.reduce(state: state, action: .createManualTask(link))
        #expect(!again.contains { if case .generateTitle = $0 { true } else { false } })

        let titled = Link(id: "c2", name: "Safari login", column: .backlog, source: .manual, promptBody: "fix the login bug")
        #expect(!Reducer.reduce(state: state, action: .createManualTask(titled))
            .contains { if case .generateTitle = $0 { true } else { false } })
    }

    @Test("a generated title replaces the placeholder, never a name the user gave")
    func titleGenerated() {
        let state = AppState()
        _ = Reducer.reduce(state: state, action: .createManualTask(
            Link(id: "c1", name: "fix the login bug", column: .backlog, source: .manual, promptBody: "fix the login bug")))
        _ = Reducer.reduce(state: state, action: .titleGenerated(cardId: "c1", name: "Fix Safari login"))
        #expect(state.links["c1"]?.name == "Fix Safari login")

        _ = Reducer.reduce(state: state, action: .createManualTask(
            Link(id: "c2", name: "fix it", column: .backlog, source: .manual, promptBody: "fix it")))
        _ = Reducer.reduce(state: state, action: .renameCard(cardId: "c2", name: "Mine"))
        _ = Reducer.reduce(state: state, action: .titleGenerated(cardId: "c2", name: "Generated"))
        #expect(state.links["c2"]?.name == "Mine")
    }
}
