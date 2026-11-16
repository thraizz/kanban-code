import Foundation
import Testing

@testable import KanbanCodeCore

/// Claude Code sessions that run outside Kanban Code's tmux, e.g. in a
/// Ghostty window: read from `~/.claude/sessions/<pid>.json`.
@Suite("Claude live sessions")
struct ClaudeLiveSessionsTests {
    private func directory(_ files: [String: String]) throws -> String {
        let dir = NSTemporaryDirectory() + "claude-sessions-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for (name, body) in files {
            try body.write(toFile: dir + "/" + name, atomically: true, encoding: .utf8)
        }
        return dir
    }

    private func entry(pid: Int32, session: String, procStart: String = "Mon Nov 16 09:15:22 2026",
                       kind: String = "interactive") -> String {
        #"{"pid":\#(pid),"sessionId":"\#(session)","cwd":"/repo","procStart":"\#(procStart)","kind":"\#(kind)","status":"waiting"}"#
    }

    private let started = ClaudeLiveSessions.parseProcStart("Mon Nov 16 09:15:22 2026")!

    @Test("a running process counts, with its terminal; a dead one does not")
    func liveAndDead() throws {
        let dir = try directory([
            "100.json": entry(pid: 100, session: "live-session"),
            "200.json": entry(pid: 200, session: "dead-session"),
        ])
        let live = ClaudeLiveSessions.scan(directory: dir) { pid in
            pid == 100 ? .init(started: started, tty: "ttys001") : nil
        }
        #expect(live == ["live-session": ClaudeLiveSession(pid: 100, sessionId: "live-session", tty: "ttys001")])
    }

    @Test("a pid taken by a later process does not keep the old session alive")
    func reusedPid() throws {
        let dir = try directory(["100.json": entry(pid: 100, session: "old-session")])
        let live = ClaudeLiveSessions.scan(directory: dir) { _ in
            .init(started: started.addingTimeInterval(3600), tty: "ttys004")
        }
        #expect(live.isEmpty)
    }

    @Test("headless runs and unreadable files are left out")
    func skipped() throws {
        let dir = try directory([
            "100.json": entry(pid: 100, session: "print-run", kind: "print"),
            "101.json": "not json",
            "102.key": "secret",
        ])
        #expect(ClaudeLiveSessions.scan(directory: dir) { _ in .init(started: started, tty: nil) }.isEmpty)
        #expect(ClaudeLiveSessions.scan(directory: dir + "-missing").isEmpty)
    }

    @Test("procStart parses in UTC, with a space-padded day too")
    func parsing() {
        #expect(ClaudeLiveSessions.parseProcStart("Mon Nov 16 09:15:22 2026")
            == Date(timeIntervalSince1970: 1_794_820_522))
        #expect(ClaudeLiveSessions.parseProcStart("Fri Nov  6 09:15:22 2026") != nil)
    }

    #if os(macOS)
    @Test("this test process reads as running, with its real start time")
    func systemInfo() throws {
        let info = try #require(ClaudeLiveSessions.systemProcessInfo(getpid()))
        let started = try #require(info.started)
        #expect(started < .now && started > .now.addingTimeInterval(-3600))
        #expect(ClaudeLiveSessions.systemProcessInfo(-1) == nil)
    }
    #endif
}
