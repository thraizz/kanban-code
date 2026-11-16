import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("RemotePTY")
struct RemotePTYTests {
    /// Spawns a shell that appends each SIGWINCH and SIGHUP it gets to a file,
    /// with the time, and exits on SIGHUP.
    private func spawnSignalRecorder() throws -> (RemotePTYProcess, String, AsyncStream<Void>) {
        let log = NSTemporaryDirectory() + "kanban-code-pty-\(UUID().uuidString).log"
        // Perl, not sh: a shell cannot trap a signal ignored when it started,
        // and the test runner's threads may hand the child a blocked mask.
        let script = """
        use POSIX;
        sub note { open(my $f, '>>', $ARGV[0]); print $f "@_\\n"; close $f }
        $SIG{WINCH} = sub { note('WINCH') };
        $SIG{HUP} = sub { note('HUP'); exit 0 };
        sigprocmask(SIG_SETMASK, POSIX::SigSet->new);
        note('ready');
        select(undef, undef, undef, 0.02) while 1;
        """
        let process = try RemotePTYProcess.spawn(argv: ["/usr/bin/perl", "-e", script, log], cols: 80, rows: 24)
        let (exited, cont) = AsyncStream<Void>.makeStream()
        process.startReading(onData: { _ in }, onExit: { cont.yield(); cont.finish() })
        return (process, log, exited)
    }

    private func waitFor(_ log: String, toContain text: String) async throws {
        for _ in 0..<1000 {
            if let s = try? String(contentsOfFile: log, encoding: .utf8), s.contains(text) { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("\(log) never contained \(text)")
    }

    @Test("A hang-up right after a resize waits until the resize has settled")
    func hangUpWaitsForResize() async throws {
        let (process, log, exited) = try spawnSignalRecorder()
        defer { try? FileManager.default.removeItem(atPath: log) }
        try await waitFor(log, toContain: "ready")

        // Timed from the resize: the hang-up may not come sooner than half a
        // second after it, however slow the machine is.
        let start = Date()
        process.resize(cols: 100, rows: 30)
        // A resize still queued when the hang-up starts is dropped instead;
        // this is the case of one the child has already seen.
        try await waitFor(log, toContain: "WINCH")
        process.terminate()
        for await _ in exited { break }
        let elapsed = Date().timeIntervalSince(start)

        let lines = try String(contentsOfFile: log, encoding: .utf8).split(separator: "\n")
        let winch = lines.firstIndex { $0.hasPrefix("WINCH") }
        let hup = lines.firstIndex { $0.hasPrefix("HUP") }
        #expect(winch != nil && hup != nil)
        if let winch, let hup { #expect(winch < hup) }
        #expect(elapsed >= 0.45, "hung up \(elapsed)s after a resize")
    }

    @Test("A resize after the hang-up started is dropped")
    func resizeAfterTerminateIsDropped() async throws {
        let (process, log, exited) = try spawnSignalRecorder()
        defer { try? FileManager.default.removeItem(atPath: log) }
        try await waitFor(log, toContain: "ready")

        process.terminate()
        process.resize(cols: 100, rows: 30)
        for await _ in exited { break }

        let text = try String(contentsOfFile: log, encoding: .utf8)
        #expect(!text.contains("WINCH"))
        #expect(text.contains("HUP"))
    }
}
