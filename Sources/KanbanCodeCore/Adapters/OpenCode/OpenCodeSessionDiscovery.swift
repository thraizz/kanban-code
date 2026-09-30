import Foundation

/// Discovers OpenCode sessions from its SQLite database.
///
/// Only top-level, unarchived sessions become cards; subagent runs (sessions
/// with a parent) belong to the session that started them.
public final class OpenCodeSessionDiscovery: SessionDiscovery, @unchecked Sendable {
    private let database: OpenCodeDatabase
    private let home: String
    /// A session's first prompt never changes once it is there.
    private var promptCache: [String: String] = [:]
    private let lock = NSLock()

    public init(database: OpenCodeDatabase = OpenCodeDatabase(), home: String = NSHomeDirectory()) {
        self.database = database
        self.home = home
    }

    public func discoverSessions() async throws -> [Session] {
        try sessions(updatedAfter: nil)
    }

    public func discoverNewOrModified(since: Date) async throws -> [Session] {
        try sessions(updatedAfter: since)
    }

    private func sessions(updatedAfter: Date?) throws -> [Session] {
        let rows = try database.sessions(updatedAfter: updatedAfter)
        guard !rows.isEmpty else { return [] }
        let ids = rows.map(\.id)
        let counts = try database.messageCounts(sessionIds: ids)
        let prompts = try firstPrompts(ids)
        let activity = try database.lastActivity(sessionIds: ids)

        return rows.map { row in
            Session(
                id: row.id,
                name: Self.displayName(fromTitle: row.title),
                firstPrompt: prompts[row.id],
                projectPath: row.directory.isEmpty ? nil : row.directory,
                messageCount: counts[row.id] ?? 0,
                modifiedTime: activity[row.id] ?? row.updated,
                jsonlPath: OpenCodeDatabase.virtualSessionPath(sessionId: row.id, home: home),
                assistant: .opencode
            )
        }
    }

    private func firstPrompts(_ ids: [String]) throws -> [String: String] {
        let missing = lock.withLock { ids.filter { promptCache[$0] == nil } }
        let fetched = try database.firstUserPrompts(sessionIds: missing)
        return lock.withLock {
            promptCache.merge(fetched) { _, new in new }
            let wanted = Set(ids)
            return promptCache.filter { wanted.contains($0.key) }
        }
    }

    /// OpenCode names a session "New session - <ISO date>" until its title
    /// model has run; that placeholder is not a name.
    static func displayName(fromTitle title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.hasPrefix("New session - ") || trimmed.hasPrefix("Child session - ") {
            return nil
        }
        return trimmed
    }
}
