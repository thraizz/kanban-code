import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("Event-driven updates")
struct EventDrivenUpdatesTests {
    // MARK: - HookLogTail

    private func lines(_ tail: inout HookLogTail, _ text: String) -> [String] {
        tail.ingest(Data(text.utf8)).map { String(decoding: $0, as: UTF8.self) }
    }

    @Test("complete lines are returned once, offsets advance")
    func completeLines() {
        var tail = HookLogTail()
        #expect(lines(&tail, "a\nb\n") == ["a", "b"])
        #expect(tail.offset == 4)
        #expect(tail.nextReadOffset(fileSize: 4) == 4)
        #expect(lines(&tail, "c\n") == ["c"])
    }

    @Test("a partial trailing line waits for its newline")
    func partialLine() {
        var tail = HookLogTail()
        #expect(lines(&tail, "{\"a\":1}\n{\"b\"") == ["{\"a\":1}"])
        #expect(lines(&tail, ":2}") == [])
        #expect(lines(&tail, "\n") == ["{\"b\":2}"])
    }

    @Test("a truncated file is read again from the start")
    func truncation() {
        var tail = HookLogTail()
        _ = lines(&tail, "aaaa\nbbbb\n")
        #expect(tail.nextReadOffset(fileSize: 3) == 0)
        #expect(lines(&tail, "x\n") == ["x"])
    }

    @Test("truncation drops a held-back partial line")
    func truncationDropsPartial() {
        var tail = HookLogTail()
        _ = lines(&tail, "aaaa\npart")
        _ = tail.nextReadOffset(fileSize: 2)
        #expect(lines(&tail, "new\n") == ["new"])
    }

    @Test("an unterminated but complete JSON line is read without waiting")
    func unterminatedCompleteLine() async throws {
        let dir = NSTemporaryDirectory() + "hook-tail-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try Data("{\"sessionId\":\"s1\",\"event\":\"Stop\"}".utf8)
            .write(to: URL(fileURLWithPath: dir + "/hook-events.jsonl"))
        let store = HookEventStore(basePath: dir)
        #expect(try await store.readNewEvents().map(\.sessionId) == ["s1"])
        #expect(try await store.readNewEvents().isEmpty)
    }

    @Test("blank lines are skipped")
    func blankLines() {
        var tail = HookLogTail()
        #expect(lines(&tail, "\n\na\n\n") == ["a"])
    }

    @Test("HookEventStore reads only appended events, across partial writes and truncation")
    func storeReadsAppends() async throws {
        let dir = NSTemporaryDirectory() + "hook-tail-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/hook-events.jsonl"
        FileManager.default.createFile(atPath: path, contents: nil)
        let store = HookEventStore(basePath: dir)

        func append(_ text: String) throws {
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
        }

        try append("{\"sessionId\":\"s1\",\"event\":\"Stop\"}\n{\"sessionId\":\"s2\",\"ev")
        #expect(try await store.readNewEvents().map(\.sessionId) == ["s1"])
        try append("ent\":\"UserPromptSubmit\"}\n")
        let second = try await store.readNewEvents()
        #expect(second.map(\.sessionId) == ["s2"])
        #expect(second.first?.eventName == "UserPromptSubmit")
        #expect(try await store.readNewEvents().isEmpty)

        try Data("{\"sessionId\":\"s3\",\"event\":\"Stop\"}\n".utf8).write(to: URL(fileURLWithPath: path))
        #expect(try await store.readNewEvents().map(\.sessionId) == ["s3"])
    }

    // MARK: - sessionActivityChanged

    private func card(_ id: String, session: String, column: KanbanCodeColumn) -> Link {
        Link(
            id: id, name: id, projectPath: "/p", column: column, updatedAt: .now, source: .manual,
            sessionLink: SessionLink(sessionId: session)
        )
    }

    @Test("sessionActivityChanged updates only the named session's card")
    func singleCardUpdate() {
        var state = AppState()
        state.links["a"] = card("a", session: "sa", column: .waiting)
        state.links["b"] = card("b", session: "sb", column: .waiting)
        state.activityMap = ["sb": .idleWaiting]
        state.rebuildCards()

        let effects = Reducer.reduce(state: &state, action: .sessionActivityChanged(["sa": .activelyWorking]))

        #expect(state.links["a"]?.column == .inProgress)
        #expect(state.links["b"]?.column == .waiting)
        #expect(state.activityMap["sa"] == .activelyWorking)
        #expect(state.activityMap["sb"] == .idleWaiting)
        #expect(!effects.isEmpty)
    }

    @Test("sessionActivityChanged ignores cards mid-launch and removes stale entries")
    func launchingAndStale() {
        var state = AppState()
        var launching = card("a", session: "sa", column: .inProgress)
        launching.isLaunching = true
        state.links["a"] = launching
        state.activityMap = ["sa": .idleWaiting, "other": .ended]
        state.rebuildCards()

        _ = Reducer.reduce(state: &state, action: .sessionActivityChanged(["sa": .stale, "other": .stale]))

        #expect(state.links["a"]?.column == .inProgress)
        #expect(state.activityMap["sa"] == nil)
        #expect(state.activityMap["other"] == nil)
    }

    @Test("sessionActivityChanged with no change persists nothing")
    func noop() {
        var state = AppState()
        state.links["a"] = card("a", session: "sa", column: .inProgress)
        state.activityMap = ["sa": .activelyWorking]
        state.rebuildCards()
        let effects = Reducer.reduce(state: &state, action: .sessionActivityChanged(["sa": .activelyWorking]))
        #expect(effects.isEmpty)
    }

    // MARK: - ReconcilePolicy

    @Test("interval is 30s while event sources are healthy, regardless of focus")
    func healthyInterval() {
        #expect(ReconcilePolicy.interval(appIsActive: true, eventSourcesHealthy: true) == .seconds(30))
        #expect(ReconcilePolicy.interval(appIsActive: false, eventSourcesHealthy: true) == .seconds(30))
    }

    @Test("interval falls back to 3s active and 10s in background")
    func fallbackInterval() {
        #expect(ReconcilePolicy.interval(appIsActive: true, eventSourcesHealthy: false) == .seconds(3))
        #expect(ReconcilePolicy.interval(appIsActive: false, eventSourcesHealthy: false) == .seconds(10))
    }

    @Test("health needs a running watcher and installed hooks")
    func healthRequirements() {
        func healthy(watcher: Bool = true, enabled: [CodingAssistant] = [.claude],
                     hooks: Set<CodingAssistant> = [.claude], sessions: Set<CodingAssistant> = [.claude]) -> Bool {
            ReconcilePolicy.eventSourcesHealthy(
                hookWatcherRunning: watcher, enabledAssistants: enabled,
                hooksInstalled: hooks, assistantsWithSessions: sessions)
        }
        #expect(healthy())
        #expect(!healthy(watcher: false))
        #expect(!healthy(hooks: []))
        // Codex has no hooks: its sessions need the fast poll.
        #expect(!healthy(enabled: [.claude, .codex], sessions: [.claude, .codex]))
        // ... but an enabled assistant without sessions does not.
        #expect(healthy(enabled: [.claude, .codex], sessions: [.claude]))
        // A disabled assistant's sessions are not followed at all.
        #expect(healthy(enabled: [.claude], sessions: [.claude, .codex]))
        // Hooks missing for an assistant that has sessions.
        #expect(!healthy(enabled: [.claude, .gemini], hooks: [.claude], sessions: [.claude, .gemini]))
    }
}
