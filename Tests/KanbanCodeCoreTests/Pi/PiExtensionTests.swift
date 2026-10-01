import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("PiExtension")
struct PiExtensionTests {
    private func tempPath() -> String {
        NSTemporaryDirectory() + "kanban-pi-extension-\(UUID().uuidString)/extensions/kanban-code.js"
    }

    private func cleanup(_ path: String) {
        try? FileManager.default.removeItem(atPath: ((path as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent)
    }

    @Test("Installs into Pi's global extensions directory")
    func defaultPath() {
        #expect(PiExtension.defaultPath(home: "/Users/me") == "/Users/me/.pi/agent/extensions/kanban-code.js")
        #expect(HookManager.defaultSettingsPath(for: .pi) == PiExtension.defaultPath())
    }

    @Test("Install, detect and uninstall through HookManager")
    func lifecycle() throws {
        let path = tempPath()
        defer { cleanup(path) }

        #expect(!HookManager.isInstalled(for: .pi, settingsPath: path))
        try HookManager.install(for: .pi, settingsPath: path)
        #expect(HookManager.isInstalled(for: .pi, settingsPath: path))

        try HookManager.uninstall(for: .pi, settingsPath: path)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test("An outdated extension is refreshed; a missing one is left alone")
    func refresh() throws {
        let path = tempPath()
        defer { cleanup(path) }

        #expect(!HookManager.addMissingHooks(for: .pi, settingsPath: path))
        #expect(!FileManager.default.fileExists(atPath: path))

        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try "// kanban-code-pi-extension v0\n".write(toFile: path, atomically: true, encoding: .utf8)
        #expect(HookManager.addMissingHooks(for: .pi, settingsPath: path))
        #expect(PiExtension.isInstalled(at: path))
    }

    @Test("Uninstall leaves a file that is not Kanban's")
    func uninstallOnlyOwnFile() throws {
        let path = tempPath()
        defer { cleanup(path) }
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try "export default function (pi) {}\n".write(toFile: path, atomically: true, encoding: .utf8)

        try PiExtension.uninstall(at: path)
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test("The extension writes the hook-event lines Kanban reads")
    func contentContract() {
        let content = PiExtension.content
        #expect(content.hasPrefix("// \(PiExtension.marker) v"))
        #expect(content.contains(".kanban-code"))
        #expect(content.contains("hook-events.jsonl"))
        #expect(content.contains("getSessionFile()"))
        for event in ["session_start", "agent_start", "agent_settled", "ui_prompt_start", "ui_prompt_end", "session_shutdown"] {
            #expect(content.contains("pi.on(\"\(event)\""))
        }
        for hook in HookManager.requiredHooks(for: .pi) {
            #expect(content.contains("\"\(hook)\""))
        }
    }
}

@Suite("PiActivityDetector")
struct PiActivityDetectorTests {
    static let path = "/Users/me/.pi/agent/sessions/--Users-me-project--/2026-09-30T18-12-57-981Z_\(PiFixture.sessionId).jsonl"

    private func event(_ name: String, path: String = PiActivityDetectorTests.path) -> HookEvent {
        HookEvent(sessionId: PiFixture.sessionId, eventName: name, transcriptPath: path)
    }

    @Test("Extension events set the state")
    func hookStates() async {
        let detector = PiActivityDetector()
        await detector.handleHookEvent(event("SessionStart"))
        #expect(await detector.activityState(for: PiFixture.sessionId) == .idleWaiting)
        await detector.handleHookEvent(event("UserPromptSubmit"))
        #expect(await detector.activityState(for: PiFixture.sessionId) == .activelyWorking)
        await detector.handleHookEvent(event("Notification"))
        #expect(await detector.activityState(for: PiFixture.sessionId) == .awaitingPermission)
        await detector.handleHookEvent(event("Stop"))
        #expect(await detector.activityState(for: PiFixture.sessionId) == .needsAttention)
        await detector.handleHookEvent(event("SessionEnd"))
        #expect(await detector.activityState(for: PiFixture.sessionId) == .ended)
    }

    @Test("Events of another assistant's sessions are ignored")
    func otherAssistant() async {
        let detector = PiActivityDetector()
        await detector.handleHookEvent(event("UserPromptSubmit", path: "/Users/me/.claude/projects/x/abc.jsonl"))
        #expect(await detector.activityState(for: PiFixture.sessionId) == .stale)
    }

    @Test("Without the extension, a fresh write means working")
    func pollsFileWrites() async throws {
        let fixture = try PiFixture()
        defer { fixture.cleanup() }
        let path = try fixture.write(PiFixture.branchedSession)
        let foreign = "/Users/me/.codex/sessions/2026/09/30/rollout-x.jsonl"

        let states = await PiActivityDetector().pollActivity(sessionPaths: [
            PiFixture.sessionId: path,
            "codex": foreign,
        ])
        // The fixture lives under a temp `.pi/agent` directory, so it is Pi's.
        #expect(states[PiFixture.sessionId] == .activelyWorking)
        #expect(states["codex"] == nil)
    }
}
