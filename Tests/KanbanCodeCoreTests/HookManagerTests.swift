import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("HookManager")
struct HookManagerTests {
    func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "kanban-code-hooks-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    func cleanup(_ dir: String) {
        try? FileManager.default.removeItem(atPath: dir)
    }

    @Test("Install hooks into empty settings")
    func installEmpty() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let settingsPath = (dir as NSString).appendingPathComponent("settings.json")
        let scriptPath = (dir as NSString).appendingPathComponent(".kanban-code/hook.sh")
        try "{}".write(toFile: settingsPath, atomically: true, encoding: .utf8)

        try HookManager.install(claudeSettingsPath: settingsPath, hookScriptPath: scriptPath)

        let installed = HookManager.isInstalled(claudeSettingsPath: settingsPath)
        #expect(installed)

        // Verify all hook events are present
        let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let hooks = root["hooks"] as! [String: Any]
        #expect(hooks["Stop"] != nil)
        #expect(hooks["Notification"] != nil)
        #expect(hooks["UserPromptSubmit"] != nil)
        #expect(hooks["SessionStart"] != nil)
        #expect(hooks["SessionEnd"] != nil)

        // Verify nested format: [{matcher: "", hooks: [{type, command}]}]
        let stopGroups = hooks["Stop"] as! [[String: Any]]
        #expect(stopGroups.count == 1)
        let entries = stopGroups[0]["hooks"] as! [[String: Any]]
        #expect(entries.count == 1)
        #expect((entries[0]["command"] as! String).contains(".kanban-code/hook.sh"))

        // Verify hook script was deployed
        #expect(FileManager.default.fileExists(atPath: scriptPath))
        #expect(FileManager.default.isExecutableFile(atPath: scriptPath))
    }

    @Test("Install preserves existing hooks in nested format")
    func installPreservesExisting() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let settingsPath = (dir as NSString).appendingPathComponent("settings.json")
        let scriptPath = (dir as NSString).appendingPathComponent(".kanban-code/hook.sh")
        let existing = """
        {
            "hooks": {
                "Stop": [
                    {
                        "matcher": "",
                        "hooks": [
                            {"type": "command", "command": "/usr/local/bin/other-hook.sh"}
                        ]
                    }
                ]
            }
        }
        """
        try existing.write(toFile: settingsPath, atomically: true, encoding: .utf8)

        try HookManager.install(claudeSettingsPath: settingsPath, hookScriptPath: scriptPath)

        let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let hooks = root["hooks"] as! [String: Any]
        let stopGroups = hooks["Stop"] as! [[String: Any]]

        // Should have one group with both hooks
        #expect(stopGroups.count == 1)
        let entries = stopGroups[0]["hooks"] as! [[String: Any]]
        #expect(entries.count == 2)
    }

    @Test("Install is idempotent")
    func installIdempotent() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let settingsPath = (dir as NSString).appendingPathComponent("settings.json")
        let scriptPath = (dir as NSString).appendingPathComponent(".kanban-code/hook.sh")
        try "{}".write(toFile: settingsPath, atomically: true, encoding: .utf8)

        try HookManager.install(claudeSettingsPath: settingsPath, hookScriptPath: scriptPath)
        try HookManager.install(claudeSettingsPath: settingsPath, hookScriptPath: scriptPath)

        let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let hooks = root["hooks"] as! [String: Any]
        let stopGroups = hooks["Stop"] as! [[String: Any]]
        let entries = stopGroups[0]["hooks"] as! [[String: Any]]

        // Should NOT have duplicates
        #expect(entries.count == 1)
    }

    @Test("Uninstall removes only kanban hooks")
    func uninstall() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let settingsPath = (dir as NSString).appendingPathComponent("settings.json")
        let existing = """
        {
            "hooks": {
                "Stop": [
                    {
                        "matcher": "",
                        "hooks": [
                            {"type": "command", "command": "/usr/local/bin/other-hook.sh"},
                            {"type": "command", "command": "/home/user/.kanban-code/hook.sh"}
                        ]
                    }
                ]
            }
        }
        """
        try existing.write(toFile: settingsPath, atomically: true, encoding: .utf8)

        try HookManager.uninstall(claudeSettingsPath: settingsPath)

        let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let hooks = root["hooks"] as! [String: Any]
        let stopGroups = hooks["Stop"] as! [[String: Any]]
        let entries = stopGroups[0]["hooks"] as! [[String: Any]]

        #expect(entries.count == 1)
        #expect((entries[0]["command"] as! String).contains("other-hook"))
    }

    @Test("isInstalled returns false for missing hooks")
    func notInstalled() {
        let installed = HookManager.isInstalled(claudeSettingsPath: "/nonexistent/path")
        #expect(!installed)
    }

    @Test("HookEventStore parses new events incrementally")
    func hookEventStoreParsesIncrementally() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let eventsPath = (dir as NSString).appendingPathComponent("hook-events.jsonl")
        let first = #"{"sessionId":"s1","event":"Stop","timestamp":"2026-06-03T16:12:47.001Z","transcriptPath":"/tmp/a.jsonl"}"#
        try first.write(toFile: eventsPath, atomically: true, encoding: .utf8)

        let store = HookEventStore(basePath: dir)
        let initial = try await store.readNewEvents()
        #expect(initial.count == 1)
        #expect(initial[0].sessionId == "s1")
        #expect(initial[0].eventName == "Stop")
        #expect(initial[0].transcriptPath == "/tmp/a.jsonl")

        let second = #"{"sessionId":"s2","event":"Notification","timestamp":"2026-06-03T16:12:48Z"}"#
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: eventsPath))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(("\n" + second).utf8))

        let next = try await store.readNewEvents()
        #expect(next.count == 1)
        #expect(next[0].sessionId == "s2")
        #expect(next[0].eventName == "Notification")
    }

    @Test("HookEventStore parses the SessionStart source")
    func hookEventStoreParsesSource() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let eventsPath = (dir as NSString).appendingPathComponent("hook-events.jsonl")
        let lines = """
            {"sessionId":"s1","event":"SessionStart","timestamp":"2026-06-03T16:12:47Z","transcriptPath":"/tmp/a.jsonl","source":"compact"}
            {"sessionId":"s1","event":"Stop","timestamp":"2026-06-03T16:12:48Z","transcriptPath":"/tmp/a.jsonl"}
            """
        try lines.write(toFile: eventsPath, atomically: true, encoding: .utf8)

        let events = try await HookEventStore(basePath: dir).readNewEvents()
        #expect(events.count == 2)
        #expect(events[0].source == "compact")
        #expect(events[1].source == nil)
    }

    @Test("HookEventStore parses the Notification type")
    func hookEventStoreParsesNotificationType() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let eventsPath = (dir as NSString).appendingPathComponent("hook-events.jsonl")
        let lines = """
            {"sessionId":"s1","event":"Notification","timestamp":"2026-06-03T16:12:47Z","transcriptPath":"/tmp/a.jsonl","notificationType":"permission_prompt"}
            {"sessionId":"s1","event":"Notification","timestamp":"2026-06-03T16:12:48Z","transcriptPath":"/tmp/a.jsonl"}
            """
        try lines.write(toFile: eventsPath, atomically: true, encoding: .utf8)

        let events = try await HookEventStore(basePath: dir).readNewEvents()
        #expect(events.count == 2)
        #expect(events[0].notificationType == "permission_prompt")
        #expect(events[1].notificationType == nil)
    }

    /// Runs the deployed bash script the way the CLIs do: payload on stdin,
    /// HOME pointed at the temp dir it writes its event file under.
    private func runHookScript(_ scriptPath: String, home: String, payload: String) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [scriptPath]
        proc.environment = ["HOME": home, "PATH": "/usr/bin:/bin"]
        let stdin = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        stdin.fileHandleForWriting.write(Data(payload.utf8))
        try stdin.fileHandleForWriting.close()
        proc.waitUntilExit()
    }

    @Test("deployed script records the SessionStart source, and only there")
    func scriptRecordsSessionStartSource() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let scriptPath = (dir as NSString).appendingPathComponent(".kanban-code/hook.sh")
        let settingsPath = (dir as NSString).appendingPathComponent("settings.json")
        try HookManager.install(claudeSettingsPath: settingsPath, hookScriptPath: scriptPath)

        try runHookScript(
            scriptPath, home: dir,
            payload:
                #"{"session_id":"s1","hook_event_name":"SessionStart","transcript_path":"/tmp/a.jsonl","source":"compact"}"#
        )
        // A prompt whose text mentions a source must not grow the field.
        try runHookScript(
            scriptPath, home: dir,
            payload:
                #"{"session_id":"s1","hook_event_name":"UserPromptSubmit","transcript_path":"/tmp/a.jsonl","prompt":"set \"source\":\"sneaky\" please"}"#
        )
        // A SessionStart without a source still writes its line.
        try runHookScript(
            scriptPath, home: dir,
            payload:
                #"{"session_id":"s1","hook_event_name":"SessionStart","transcript_path":"/tmp/a.jsonl"}"#
        )

        let eventsPath = (dir as NSString).appendingPathComponent(".kanban-code/hook-events.jsonl")
        let content = try String(contentsOfFile: eventsPath, encoding: .utf8)
        let lines = content.split(separator: "\n")
        #expect(lines.count == 3)
        #expect(lines[0].contains(#""source":"compact""#))
        #expect(!lines[1].contains(#""source""#))
        #expect(!lines[2].contains(#""source""#))
    }

    @Test("deployed script records the Notification type, and only there")
    func scriptRecordsNotificationType() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let scriptPath = (dir as NSString).appendingPathComponent(".kanban-code/hook.sh")
        let settingsPath = (dir as NSString).appendingPathComponent("settings.json")
        try HookManager.install(claudeSettingsPath: settingsPath, hookScriptPath: scriptPath)

        try runHookScript(
            scriptPath, home: dir,
            payload:
                #"{"session_id":"s1","hook_event_name":"Notification","transcript_path":"/tmp/a.jsonl","message":"Claude needs your permission to use Bash","notification_type":"permission_prompt"}"#
        )
        try runHookScript(
            scriptPath, home: dir,
            payload:
                #"{"session_id":"s1","hook_event_name":"UserPromptSubmit","transcript_path":"/tmp/a.jsonl","prompt":"\"notification_type\":\"sneaky\""}"#
        )

        let eventsPath = (dir as NSString).appendingPathComponent(".kanban-code/hook-events.jsonl")
        let content = try String(contentsOfFile: eventsPath, encoding: .utf8)
        let lines = content.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].contains(#""notificationType":"permission_prompt""#))
        #expect(!lines[1].contains(#""notificationType""#))
    }

    @Test("refreshHookScript rewrites a stale script and skips a missing one")
    func refreshHookScriptRewritesStale() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let scriptPath = (dir as NSString).appendingPathComponent(".kanban-code/hook.sh")
        #expect(!HookManager.refreshHookScript(at: scriptPath))
        #expect(!FileManager.default.fileExists(atPath: scriptPath))

        try FileManager.default.createDirectory(
            atPath: (scriptPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        try "#!/usr/bin/env bash\n# old release".write(
            toFile: scriptPath, atomically: true, encoding: .utf8)

        #expect(HookManager.refreshHookScript(at: scriptPath))
        let content = try String(contentsOfFile: scriptPath, encoding: .utf8)
        #expect(content.contains("hook-events.jsonl"))
        #expect(FileManager.default.isExecutableFile(atPath: scriptPath))

        // Already current: nothing to do.
        #expect(!HookManager.refreshHookScript(at: scriptPath))
    }

    @Test("Install creates settings file if missing")
    func installCreatesFile() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let settingsPath = (dir as NSString).appendingPathComponent("subdir/settings.json")
        let scriptPath = (dir as NSString).appendingPathComponent(".kanban-code/hook.sh")
        try HookManager.install(claudeSettingsPath: settingsPath, hookScriptPath: scriptPath)

        #expect(FileManager.default.fileExists(atPath: settingsPath))
        let installed = HookManager.isInstalled(claudeSettingsPath: settingsPath)
        #expect(installed)
    }

    @Test("Install deploys executable hook script")
    func installDeploysScript() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let settingsPath = (dir as NSString).appendingPathComponent("settings.json")
        let scriptPath = (dir as NSString).appendingPathComponent(".kanban-code/hook.sh")
        try "{}".write(toFile: settingsPath, atomically: true, encoding: .utf8)

        try HookManager.install(claudeSettingsPath: settingsPath, hookScriptPath: scriptPath)

        // Script should exist and be executable
        #expect(FileManager.default.fileExists(atPath: scriptPath))
        #expect(FileManager.default.isExecutableFile(atPath: scriptPath))

        // Script should contain the shebang and event writing logic
        let content = try String(contentsOfFile: scriptPath, encoding: .utf8)
        #expect(content.contains("#!/usr/bin/env bash"))
        #expect(content.contains("hook-events.jsonl"))
        #expect(content.contains("session_id"))
    }

    // MARK: - Multi-Assistant Support

    @Test("Install for Gemini uses correct event names")
    func installGemini() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let settingsPath = (dir as NSString).appendingPathComponent("settings.json")
        let scriptPath = (dir as NSString).appendingPathComponent(".kanban-code/hook.sh")
        try "{}".write(toFile: settingsPath, atomically: true, encoding: .utf8)

        try HookManager.install(for: .gemini, settingsPath: settingsPath, hookScriptPath: scriptPath)

        let installed = HookManager.isInstalled(for: .gemini, settingsPath: settingsPath)
        #expect(installed)

        let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let hooks = root["hooks"] as! [String: Any]

        // Gemini uses different event names
        #expect(hooks["AfterAgent"] != nil)
        #expect(hooks["BeforeAgent"] != nil)
        #expect(hooks["Notification"] != nil)
        #expect(hooks["SessionStart"] != nil)
        #expect(hooks["SessionEnd"] != nil)

        // Should NOT have Claude-specific events
        #expect(hooks["Stop"] == nil)
        #expect(hooks["UserPromptSubmit"] == nil)
    }

    @Test("isInstalled for Gemini checks Gemini event names")
    func isInstalledGemini() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let settingsPath = (dir as NSString).appendingPathComponent("settings.json")
        let scriptPath = (dir as NSString).appendingPathComponent(".kanban-code/hook.sh")
        try "{}".write(toFile: settingsPath, atomically: true, encoding: .utf8)

        // Install Claude hooks
        try HookManager.install(for: .claude, settingsPath: settingsPath, hookScriptPath: scriptPath)

        // Claude hooks installed but Gemini hooks are not
        #expect(HookManager.isInstalled(for: .claude, settingsPath: settingsPath))
        #expect(!HookManager.isInstalled(for: .gemini, settingsPath: settingsPath))
    }

    @Test("Uninstall for Gemini removes hooks from its own settings file")
    func uninstallGemini() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        // Claude and Gemini use separate settings files in practice
        let claudeSettings = (dir as NSString).appendingPathComponent("claude-settings.json")
        let geminiSettings = (dir as NSString).appendingPathComponent("gemini-settings.json")
        let scriptPath = (dir as NSString).appendingPathComponent(".kanban-code/hook.sh")
        try "{}".write(toFile: claudeSettings, atomically: true, encoding: .utf8)
        try "{}".write(toFile: geminiSettings, atomically: true, encoding: .utf8)

        try HookManager.install(for: .claude, settingsPath: claudeSettings, hookScriptPath: scriptPath)
        try HookManager.install(for: .gemini, settingsPath: geminiSettings, hookScriptPath: scriptPath)

        #expect(HookManager.isInstalled(for: .claude, settingsPath: claudeSettings))
        #expect(HookManager.isInstalled(for: .gemini, settingsPath: geminiSettings))

        // Uninstall Gemini
        try HookManager.uninstall(for: .gemini, settingsPath: geminiSettings)

        // Claude unaffected, Gemini removed
        #expect(HookManager.isInstalled(for: .claude, settingsPath: claudeSettings))
        #expect(!HookManager.isInstalled(for: .gemini, settingsPath: geminiSettings))
    }

    @Test("normalizeEventName maps Gemini events to canonical names")
    func normalizeEventName() {
        #expect(HookManager.normalizeEventName("AfterAgent") == "Stop")
        #expect(HookManager.normalizeEventName("BeforeAgent") == "UserPromptSubmit")
        #expect(HookManager.normalizeEventName("SessionStart") == "SessionStart")
        #expect(HookManager.normalizeEventName("SessionEnd") == "SessionEnd")
        #expect(HookManager.normalizeEventName("Notification") == "Notification")
        #expect(HookManager.normalizeEventName("Stop") == "Stop")
    }

    @Test("requiredHooks returns correct events per assistant")
    func requiredHooksPerAssistant() {
        let claude = HookManager.requiredHooks(for: .claude)
        #expect(claude.contains("Stop"))
        #expect(claude.contains("UserPromptSubmit"))
        #expect(!claude.contains("AfterAgent"))

        let gemini = HookManager.requiredHooks(for: .gemini)
        #expect(gemini.contains("AfterAgent"))
        #expect(gemini.contains("BeforeAgent"))
        #expect(!gemini.contains("Stop"))
        #expect(!gemini.contains("UserPromptSubmit"))

        let codex = HookManager.requiredHooks(for: .codex)
        #expect(codex.isEmpty)
    }

    @Test("Codex hooks are unsupported")
    func codexHooksUnsupported() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let settingsPath = (dir as NSString).appendingPathComponent("settings.json")
        let scriptPath = (dir as NSString).appendingPathComponent(".kanban-code/hook.sh")

        #expect(!HookManager.isInstalled(for: .codex, settingsPath: settingsPath))
        #expect(throws: HookManagerError.self) {
            try HookManager.install(for: .codex, settingsPath: settingsPath, hookScriptPath: scriptPath)
        }
        try HookManager.uninstall(for: .codex, settingsPath: settingsPath)
    }
}
