import Foundation

/// Counts which features get used, so unused ones can be found and dropped.
///
/// Only names and counts are kept, never arguments, prompts or paths. Each
/// day has one file, `~/.kanban-code/usage/<yyyy-MM-dd>.json`, mapping
/// `"<kind>:<name>"` to `{"count", "last"}`. Counts collect in memory and are
/// merged into the file every minute and on quit, so several processes can
/// share a day's file. `Scripts/usage-report.py` reads them.
public enum UsageLog {

    private struct Entry: Codable {
        var count: Int
        var last: String
    }

    private static let queue = DispatchQueue(label: "kanban-code.usage", qos: .utility)
    nonisolated(unsafe) private static var pending: [String: Entry] = [:]
    nonisolated(unsafe) private static var flushScheduled = false

    private static let usageDir: String = {
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code/usage")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Whether the last dispatch came straight from a click or a key press.
    /// The app sets it; without it every action counts as `system`.
    @MainActor public static var userInputProbe: (@MainActor () -> Bool)?

    /// Records one use of `name`. `kind` groups it: `action.user`,
    /// `action.system`, `view`, `settings`, `tab`, `card-action`, `shortcut`,
    /// `menu`, `terminal`, `api`.
    public nonisolated static func record(_ kind: String, _ name: String) {
        guard !KanbanCodeLog.isTestRun else { return }
        let key = "\(kind):\(name)"
        let now = ISO8601DateFormatter().string(from: Date())
        queue.async {
            pending[key, default: Entry(count: 0, last: now)].count += 1
            pending[key]?.last = now
            guard !flushScheduled else { return }
            flushScheduled = true
            queue.asyncAfter(deadline: .now() + 60) { flushLocked() }
        }
    }

    /// Records a reducer action, as `user` when the probe says a click or key
    /// press caused it.
    @MainActor public static func recordAction(_ name: String) {
        record(userInputProbe?() == true ? "action.user" : "action.system", name)
    }

    /// Writes what is pending now. Call on quit.
    public nonisolated static func flush() {
        queue.sync { flushLocked() }
    }

    private static func flushLocked() {
        flushScheduled = false
        guard !pending.isEmpty else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let path = (usageDir as NSString).appendingPathComponent("\(formatter.string(from: Date())).json")
        let url = URL(fileURLWithPath: path)
        var day: [String: Entry] = [:]
        if let data = try? Data(contentsOf: url) {
            day = (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
        }
        for (key, entry) in pending {
            if var existing = day[key] {
                existing.count += entry.count
                existing.last = max(existing.last, entry.last)
                day[key] = existing
            } else {
                day[key] = entry
            }
        }
        pending = [:]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(day) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// `/v1/cards/card_2x9/transcript` -> `/v1/cards/{id}/transcript`: a
    /// segment that is not a plain lowercase word is an identifier.
    public nonisolated static func routeTemplate(_ segments: [String]) -> String {
        "/" + segments.map { segment in
            segment.range(of: "^[a-z][a-z-]*$", options: .regularExpression) != nil ? segment : "{id}"
        }.joined(separator: "/")
    }
}
