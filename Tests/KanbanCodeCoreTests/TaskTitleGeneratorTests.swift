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
}
