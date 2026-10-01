import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("MainThreadGuard")
struct MainThreadGuardTests {

    @Test("message includes label and call site")
    func messageFormat() {
        let msg = MainThreadGuard.message(label: "Foo.bar", fileID: "Mod/File.swift", line: 42)
        #expect(msg.contains("Foo.bar"))
        #expect(msg.contains("Mod/File.swift:42"))
    }

    @Test("warns on main thread, silent off main (debug only)")
    func mainVsBackground() async {
        let off = await Task.detached { MainThreadGuard.warnIfMain("bg") }.value
        #expect(off == false)
        let onMain = await MainActor.run { MainThreadGuard.warnIfMain("main") }
        #if DEBUG
        #expect(onMain == true)
        #else
        #expect(onMain == false)
        #endif
    }

    @Test("ContextUsageReader.readAsync returns the parsed result")
    func readAsync() async throws {
        let dir = NSTemporaryDirectory() + "kanban-mtg-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let json = #"{"usedPercentage":12.5,"contextWindowSize":200000,"totalInputTokens":10,"totalOutputTokens":5}"#
        try json.write(toFile: dir + "/s1.json", atomically: true, encoding: .utf8)
        let usage = await ContextUsageReader.readAsync(sessionId: "s1", basePath: dir)
        #expect(usage?.usedPercentage == 12.5)
        #expect(await ContextUsageReader.readAsync(sessionId: "missing", basePath: dir) == nil)
    }
}
