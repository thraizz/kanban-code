import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("GeminiActivityDetector")
struct GeminiActivityDetectorTests {

    // MARK: - Helpers

    private func writeTempFile() throws -> String {
        let path = "/tmp/kanban-test-gemini-activity-\(UUID().uuidString).json"
        try "{}".write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func setModTime(_ path: String, secondsAgo: TimeInterval) throws {
        let date = Date.now.addingTimeInterval(-secondsAgo)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
    }

    private func cleanup(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    // MARK: - Mtime-Based Activity States

    @Test("Recently modified file → activelyWorking")
    func activelyWorking() async throws {
        let path = try writeTempFile()
        defer { cleanup(path) }
        try setModTime(path, secondsAgo: 30) // 30 seconds ago

        let detector = GeminiActivityDetector()
        let result = await detector.pollActivity(sessionPaths: ["s1": path])

        #expect(result["s1"] == .activelyWorking)
    }

    @Test("File modified 3 min ago → needsAttention")
    func needsAttention() async throws {
        let path = try writeTempFile()
        defer { cleanup(path) }
        try setModTime(path, secondsAgo: 180) // 3 minutes ago

        let detector = GeminiActivityDetector()
        let result = await detector.pollActivity(sessionPaths: ["s1": path])

        #expect(result["s1"] == .needsAttention)
    }

    @Test("File modified 30 min ago → idleWaiting")
    func idleWaiting() async throws {
        let path = try writeTempFile()
        defer { cleanup(path) }
        try setModTime(path, secondsAgo: 1800) // 30 minutes ago

        let detector = GeminiActivityDetector()
        let result = await detector.pollActivity(sessionPaths: ["s1": path])

        #expect(result["s1"] == .idleWaiting)
    }

    @Test("File modified 2 hours ago → idleWaiting (quiet is not an exit)")
    func ended() async throws {
        let path = try writeTempFile()
        defer { cleanup(path) }
        try setModTime(path, secondsAgo: 7200) // 2 hours ago

        let detector = GeminiActivityDetector()
        let result = await detector.pollActivity(sessionPaths: ["s1": path])

        #expect(result["s1"] == .idleWaiting)
    }

    @Test("File modified 2 days ago → stale")
    func stale() async throws {
        let path = try writeTempFile()
        defer { cleanup(path) }
        try setModTime(path, secondsAgo: 172800) // 2 days ago

        let detector = GeminiActivityDetector()
        let result = await detector.pollActivity(sessionPaths: ["s1": path])

        #expect(result["s1"] == .stale)
    }

    @Test("Non-existent file → ended")
    func nonExistentFile() async {
        let detector = GeminiActivityDetector()
        let result = await detector.pollActivity(sessionPaths: ["s1": "/nonexistent/path.json"])

        #expect(result["s1"] == .ended)
    }

    // MARK: - Cross-Assistant Filtering

    @Test("Ignores non-Gemini session paths during poll")
    func filtersOutNonGeminiPaths() async throws {
        // Regression: without this filter, Gemini would mtime-poll a Claude
        // transcript and tag it `.activelyWorking`, and the composite detector's
        // highest-priority merge would unarchive the card. See
        // CompositeActivityDetector / CodingAssistant.owns(sessionPath:).
        let claudeDir = "/tmp/kanban-test-cross-\(UUID().uuidString)/.claude/projects"
        try FileManager.default.createDirectory(atPath: claudeDir, withIntermediateDirectories: true)
        let claudePath = "\(claudeDir)/s1.jsonl"
        try "{}".write(toFile: claudePath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: (claudeDir as NSString).deletingLastPathComponent) }

        let detector = GeminiActivityDetector()
        let result = await detector.pollActivity(sessionPaths: ["s1": claudePath])

        #expect(result["s1"] == nil)
    }

    @Test("Ignores hook events for non-Gemini transcript paths")
    func filtersOutNonGeminiHookEvents() async {
        let detector = GeminiActivityDetector()
        let event = HookEvent(
            sessionId: "s1",
            eventName: "UserPromptSubmit",
            transcriptPath: "/Users/x/.claude/projects/foo/s1.jsonl"
        )
        await detector.handleHookEvent(event)
        let state = await detector.activityState(for: "s1")
        #expect(state == .stale)
    }

    // MARK: - Multiple Sessions

    @Test("Polls multiple sessions simultaneously")
    func multipleSessionsPoll() async throws {
        let path1 = try writeTempFile()
        let path2 = try writeTempFile()
        defer {
            cleanup(path1)
            cleanup(path2)
        }
        try setModTime(path1, secondsAgo: 10)   // active
        try setModTime(path2, secondsAgo: 7200)  // quiet

        let detector = GeminiActivityDetector()
        let result = await detector.pollActivity(sessionPaths: [
            "s1": path1,
            "s2": path2,
        ])

        #expect(result["s1"] == .activelyWorking)
        #expect(result["s2"] == .idleWaiting)
    }

    // MARK: - Cached State

    @Test("activityState returns cached state after poll")
    func cachedState() async throws {
        let path = try writeTempFile()
        defer { cleanup(path) }
        try setModTime(path, secondsAgo: 30)

        let detector = GeminiActivityDetector()
        _ = await detector.pollActivity(sessionPaths: ["s1": path])

        let state = await detector.activityState(for: "s1")
        #expect(state == .activelyWorking)
    }

    @Test("activityState returns stale for unknown session")
    func unknownSessionStale() async {
        let detector = GeminiActivityDetector()
        let state = await detector.activityState(for: "unknown")
        #expect(state == .stale)
    }

    // MARK: - Hook Events

    @Test("handleHookEvent sets state from UserPromptSubmit")
    func hookEventPromptSubmit() async {
        let detector = GeminiActivityDetector()
        let event = HookEvent(sessionId: "s1", eventName: "UserPromptSubmit")
        await detector.handleHookEvent(event)

        let state = await detector.activityState(for: "s1")
        #expect(state == .activelyWorking)
    }

    @Test("handleHookEvent sets state from Stop")
    func hookEventStop() async {
        let detector = GeminiActivityDetector()
        let event = HookEvent(sessionId: "s1", eventName: "Stop")
        await detector.handleHookEvent(event)

        let state = await detector.activityState(for: "s1")
        #expect(state == .needsAttention)
    }

    @Test("handleHookEvent normalizes Gemini event names")
    func hookEventNormalization() async {
        let detector = GeminiActivityDetector()

        // AfterAgent should be treated as Stop
        let event = HookEvent(sessionId: "s1", eventName: "AfterAgent")
        await detector.handleHookEvent(event)
        let state = await detector.activityState(for: "s1")
        #expect(state == .needsAttention)

        // BeforeAgent should be treated as UserPromptSubmit
        let event2 = HookEvent(sessionId: "s2", eventName: "BeforeAgent")
        await detector.handleHookEvent(event2)
        let state2 = await detector.activityState(for: "s2")
        #expect(state2 == .activelyWorking)
    }

    @Test("Hook state takes priority over poll state")
    func hookStatePriority() async throws {
        let path = try writeTempFile()
        defer { cleanup(path) }
        try setModTime(path, secondsAgo: 7200) // file says ended

        let detector = GeminiActivityDetector()

        // Hook says actively working
        let event = HookEvent(sessionId: "s1", eventName: "UserPromptSubmit")
        await detector.handleHookEvent(event)

        // Poll should still return hook state, not file state
        let result = await detector.pollActivity(sessionPaths: ["s1": path])
        #expect(result["s1"] == .activelyWorking)
    }

    // MARK: - Custom Thresholds

    @Test("Custom thresholds change classification")
    func customThresholds() async throws {
        let path = try writeTempFile()
        defer { cleanup(path) }
        try setModTime(path, secondsAgo: 30) // 30 seconds ago

        // With very tight thresholds: activeThreshold=10, attentionThreshold=20
        let detector = GeminiActivityDetector(activeThreshold: 10, attentionThreshold: 20)
        let result = await detector.pollActivity(sessionPaths: ["s1": path])

        // 30 seconds ago is beyond both thresholds → idleWaiting
        #expect(result["s1"] == .idleWaiting)
    }

    // MARK: - resolvePendingStops (default protocol)

    @Test("resolvePendingStops returns empty (default)")
    func resolvePendingStopsEmpty() async {
        let detector = GeminiActivityDetector()
        let resolved = await detector.resolvePendingStops()
        #expect(resolved.isEmpty)
    }
}
