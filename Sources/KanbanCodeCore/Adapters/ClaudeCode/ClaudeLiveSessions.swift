#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// A Claude Code process running on this Mac, as it registers itself in
/// `~/.claude/sessions/<pid>.json`.
///
/// Claude Code writes that file for every interactive session, wherever it
/// runs: in a card's tmux session, and just as well in a Ghostty or Terminal
/// window outside Kanban Code. It is the one place that says a session
/// without a Kanban tmux session is still running.
public struct ClaudeLiveSession: Sendable, Equatable {
    public let pid: Int32
    public let sessionId: String
    /// The terminal the process runs on, e.g. "ttys001".
    public let tty: String?

    public init(pid: Int32, sessionId: String, tty: String?) {
        self.pid = pid
        self.sessionId = sessionId
        self.tty = tty
    }
}

public enum ClaudeLiveSessions {
    /// What the system says about a process: when it started and its
    /// terminal, or nil when no process has that pid.
    public struct ProcessInfo: Sendable {
        /// Nil where the system does not say (Linux).
        public let started: Date?
        public let tty: String?

        public init(started: Date?, tty: String?) {
            self.started = started
            self.tty = tty
        }
    }

    /// `~/.claude/sessions`, or the one under `CLAUDE_CONFIG_DIR`.
    public static var defaultDirectory: String {
        let env = Foundation.ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
        let root = env.flatMap { $0.isEmpty ? nil : $0 }
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".claude")
        return (root as NSString).appendingPathComponent("sessions")
    }

    /// The live sessions registered in `directory`, by session id.
    ///
    /// A file stays behind when its process is killed, and its pid can be
    /// taken by another process later. So a file counts only while a process
    /// with its pid runs and started when the file says (`procStart`).
    public static func scan(
        directory: String = defaultDirectory,
        processInfo: (Int32) -> ProcessInfo? = systemProcessInfo
    ) -> [String: ClaudeLiveSession] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [:] }
        var live: [String: ClaudeLiveSession] = [:]
        for name in names where name.hasSuffix(".json") {
            let path = (directory as NSString).appendingPathComponent(name)
            guard let data = FileManager.default.contents(atPath: path),
                  let entry = try? JSONDecoder().decode(Entry.self, from: data),
                  entry.kind == nil || entry.kind == "interactive",
                  !entry.sessionId.isEmpty,
                  let process = processInfo(entry.pid)
            else { continue }
            if let started = process.started,
               let procStart = entry.procStart.flatMap(parseProcStart),
               abs(started.timeIntervalSince(procStart)) > 2 {
                continue  // The pid belongs to another process now.
            }
            live[entry.sessionId] = ClaudeLiveSession(pid: entry.pid, sessionId: entry.sessionId, tty: process.tty)
        }
        return live
    }

    private struct Entry: Decodable {
        let pid: Int32
        let sessionId: String
        let procStart: String?
        let kind: String?
    }

    /// "Mon Nov 16 09:15:22 2026", in UTC.
    static func parseProcStart(_ text: String) -> Date? {
        let normalized = text.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter.date(from: normalized)
    }

    /// The start time and terminal of `pid`, from the kernel.
    public static func systemProcessInfo(_ pid: Int32) -> ProcessInfo? {
        guard pid > 0 else { return nil }
        #if os(macOS)
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let started = Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec)
            + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
        var tty: String?
        if info.e_tdev != UInt32.max, let name = devname(dev_t(bitPattern: info.e_tdev), S_IFCHR) {
            let text = String(cString: name)
            tty = text.hasPrefix("??") ? nil : text
        }
        return ProcessInfo(started: started, tty: tty)
        #else
        guard kill(pid, 0) == 0 || errno == EPERM else { return nil }
        return ProcessInfo(started: nil, tty: nil)
        #endif
    }
}
