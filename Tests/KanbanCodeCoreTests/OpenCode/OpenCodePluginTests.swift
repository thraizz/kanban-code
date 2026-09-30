import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("OpenCodePlugin")
struct OpenCodePluginTests {
    private func tempPath() -> String {
        NSTemporaryDirectory() + "kanban-opencode-plugin-\(UUID().uuidString)/plugins/kanban-code.js"
    }

    @Test("Install, detect and uninstall through HookManager")
    func lifecycle() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: ((path as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent) }

        #expect(!HookManager.isInstalled(for: .opencode, settingsPath: path))
        try HookManager.install(for: .opencode, settingsPath: path)
        #expect(HookManager.isInstalled(for: .opencode, settingsPath: path))

        try HookManager.uninstall(for: .opencode, settingsPath: path)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test("An outdated plugin is refreshed; a missing one is left alone")
    func refresh() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: ((path as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent) }

        #expect(!HookManager.addMissingHooks(for: .opencode, settingsPath: path))
        #expect(!FileManager.default.fileExists(atPath: path))

        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try "// kanban-code-opencode-plugin v0\n".write(toFile: path, atomically: true, encoding: .utf8)
        #expect(HookManager.addMissingHooks(for: .opencode, settingsPath: path))
        #expect(OpenCodePlugin.isInstalled(at: path))
    }

    @Test("Uninstall leaves a file that is not Kanban's")
    func uninstallOnlyOwnFile() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: ((path as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent) }
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try "export const Mine = async () => ({})\n".write(toFile: path, atomically: true, encoding: .utf8)

        try OpenCodePlugin.uninstall(at: path)
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test("The plugin writes the hook-event lines Kanban reads, for top-level sessions")
    func contentContract() {
        let source = OpenCodePlugin.content
        #expect(source.hasPrefix("// \(OpenCodePlugin.marker) v"))
        #expect(source.contains(#"join(EVENTS_DIR, "hook-events.jsonl")"#))
        #expect(source.contains(#""opencode", "session", id"#))
        for event in HookManager.requiredHooks(for: .opencode) {
            #expect(source.contains("\"\(event)\""), "plugin emits \(event)")
        }
        #expect(source.contains("parentID"), "subagent sessions are skipped")
    }

    @Test("The plugin goes to OpenCode's global plugins directory")
    func defaultPath() {
        #expect(OpenCodePlugin.defaultPath(home: "/Users/me", environment: [:])
            == "/Users/me/.config/opencode/plugins/kanban-code.js")
        #expect(OpenCodePlugin.defaultPath(home: "/Users/me", environment: ["XDG_CONFIG_HOME": "/cfg"])
            == "/cfg/opencode/plugins/kanban-code.js")
    }
}
