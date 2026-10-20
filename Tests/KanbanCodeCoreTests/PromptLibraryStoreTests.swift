import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("PromptLibraryStore")
struct PromptLibraryStoreTests {
    private func tmpBase() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("kanban-prompts-\(UUID().uuidString)")
            .path
    }

    @Test func missingFileLoadsEmpty() async {
        let store = PromptLibraryStore(basePath: tmpBase())
        #expect(await store.load().isEmpty)
    }

    @Test func saveAndLoadKeepsOrder() async throws {
        let base = tmpBase()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let store = PromptLibraryStore(basePath: base)
        let presets = [
            PromptPreset(title: "Review", body: "Review the diff"),
            PromptPreset(title: "", body: "Write tests\nfor everything"),
        ]
        try await store.save(presets)

        let loaded = await store.load()
        #expect(loaded.map(\.id) == presets.map(\.id))
        #expect(loaded[1].body == "Write tests\nfor everything")
    }

    @Test func displayTitleFallsBackToFirstLine() {
        #expect(PromptPreset(title: "  Named ", body: "x").displayTitle == "Named")
        #expect(PromptPreset(title: "", body: "\nFirst line\nsecond").displayTitle == "First line")
        #expect(PromptPreset(title: "", body: "  ").displayTitle == "Untitled prompt")
    }
}
