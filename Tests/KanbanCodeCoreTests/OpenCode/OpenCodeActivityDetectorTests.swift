import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("OpenCodeActivityDetector")
struct OpenCodeActivityDetectorTests {
    private func path(_ id: String) -> String {
        OpenCodeDatabase.virtualSessionPath(sessionId: id, home: "/Users/me")
    }

    private func event(_ id: String, _ name: String, at date: Date = .now) -> HookEvent {
        HookEvent(sessionId: id, eventName: name, transcriptPath: path(id), timestamp: date)
    }

    @Test("Plugin events drive the state")
    func pluginEvents() async throws {
        let fixture = try OpenCodeFixture()
        let detector = OpenCodeActivityDetector(database: fixture.database)

        await detector.handleHookEvent(event("ses_a", "SessionStart"))
        #expect(await detector.activityState(for: "ses_a") == .idleWaiting)
        await detector.handleHookEvent(event("ses_a", "UserPromptSubmit"))
        #expect(await detector.activityState(for: "ses_a") == .activelyWorking)
        await detector.handleHookEvent(event("ses_a", "Notification"))
        #expect(await detector.activityState(for: "ses_a") == .needsAttention, "a permission prompt waits on the user")
        await detector.handleHookEvent(event("ses_a", "UserPromptSubmit"))
        await detector.handleHookEvent(event("ses_a", "Stop"))
        #expect(await detector.activityState(for: "ses_a") == .needsAttention)
        await detector.handleHookEvent(event("ses_a", "SessionEnd"))
        #expect(await detector.activityState(for: "ses_a") == .ended)
    }

    @Test("Events of other assistants' sessions are ignored")
    func ignoresOtherAssistants() async throws {
        let fixture = try OpenCodeFixture()
        let detector = OpenCodeActivityDetector(database: fixture.database)
        await detector.handleHookEvent(HookEvent(
            sessionId: "claude-1", eventName: "UserPromptSubmit",
            transcriptPath: "/Users/me/.claude/projects/p/claude-1.jsonl"
        ))
        await detector.handleHookEvent(HookEvent(sessionId: "no-path", eventName: "UserPromptSubmit"))
        #expect(await detector.activityState(for: "claude-1") == .stale)
        #expect(await detector.activityState(for: "no-path") == .stale)

        let states = await detector.pollActivity(sessionPaths: ["claude-1": "/Users/me/.claude/projects/p/claude-1.jsonl"])
        #expect(states.isEmpty)
    }

    @Test("Without the plugin, the last database write is the signal")
    func pollFallback() async throws {
        let fixture = try OpenCodeFixture()
        try fixture.addSession(id: "ses_live", updated: OpenCodeFixture.millis(ago: 5))
        try fixture.addSession(id: "ses_old", updated: OpenCodeFixture.millis(ago: 90_000))
        let detector = OpenCodeActivityDetector(database: fixture.database, activeThreshold: 60, attentionThreshold: 120)

        let states = await detector.pollActivity(sessionPaths: [
            "ses_live": path("ses_live"), "ses_old": path("ses_old"), "ses_gone": path("ses_gone"),
        ])
        #expect(states["ses_live"] == .activelyWorking)
        #expect(states["ses_old"] == .stale)
        #expect(states["ses_gone"] == .ended)
    }

    @Test("A long tool run stays working while the database is written")
    func longRunStaysWorking() async throws {
        let fixture = try OpenCodeFixture()
        try fixture.addSession(id: "ses_a", updated: OpenCodeFixture.millis(ago: 1))
        let detector = OpenCodeActivityDetector(database: fixture.database, activeThreshold: 60, attentionThreshold: 120)
        await detector.handleHookEvent(event("ses_a", "UserPromptSubmit", at: .now.addingTimeInterval(-600)))

        let states = await detector.pollActivity(sessionPaths: ["ses_a": path("ses_a")])
        #expect(states["ses_a"] == .activelyWorking)
    }

    @Test("A working state with no event and no write for too long needs attention")
    func quietWorkDowngrades() async throws {
        let fixture = try OpenCodeFixture()
        try fixture.addSession(id: "ses_a", updated: OpenCodeFixture.millis(ago: 600))
        let detector = OpenCodeActivityDetector(database: fixture.database, activeThreshold: 60, attentionThreshold: 120)
        await detector.handleHookEvent(event("ses_a", "UserPromptSubmit", at: .now.addingTimeInterval(-600)))

        let states = await detector.pollActivity(sessionPaths: ["ses_a": path("ses_a")])
        #expect(states["ses_a"] == .needsAttention)
    }
}
