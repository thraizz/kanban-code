import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

/// Read-only access to OpenCode's session database.
///
/// OpenCode keeps every session, message and message part in one SQLite
/// database (`~/.local/share/opencode/opencode.db`, WAL mode) instead of a
/// file per session. Each query opens its own read-only connection, so a
/// reader never holds a lock across OpenCode's writes and a missing or
/// half-migrated database reads as empty instead of failing the board.
///
/// Kanban identifies a session by a path, so an OpenCode session gets a
/// virtual one, `~/.local/share/opencode/session/<id>`: nothing exists at it,
/// it only routes the session to the OpenCode adapters (see
/// `CodingAssistant.owns(sessionPath:)`).
public struct OpenCodeDatabase: Sendable {
    public let path: String

    public init(path: String? = nil) {
        self.path = path ?? Self.defaultPath()
    }

    // MARK: - Paths

    /// OpenCode's data directory under the given home.
    public static func dataDirectory(home: String = NSHomeDirectory()) -> String {
        (home as NSString).appendingPathComponent(CodingAssistant.opencode.configDirName)
    }

    /// The database OpenCode itself uses: `OPENCODE_DB` when set, else the
    /// default file in its data directory.
    public static func defaultPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let override = environment["OPENCODE_DB"], !override.isEmpty {
            return (override as NSString).expandingTildeInPath
        }
        return (dataDirectory() as NSString).appendingPathComponent("opencode.db")
    }

    /// The virtual session path Kanban stores for an OpenCode session.
    public static func virtualSessionPath(sessionId: String, home: String = NSHomeDirectory()) -> String {
        (dataDirectory(home: home) as NSString).appendingPathComponent("session/\(sessionId)")
    }

    /// The session id of a virtual session path, or nil for any other path.
    public static func sessionId(fromVirtualPath path: String) -> String? {
        guard path.contains("/\(CodingAssistant.opencode.configDirName)/session/") else { return nil }
        let id = (path as NSString).lastPathComponent
        return id.hasPrefix("ses_") ? id : nil
    }

    /// True for a virtual OpenCode session path: callers that would read the
    /// session as a file use this to go through the store instead.
    public static func isVirtualSessionPath(_ path: String) -> Bool {
        sessionId(fromVirtualPath: path) != nil
    }

    // MARK: - Rows

    public struct SessionRow: Sendable, Equatable {
        public let id: String
        public let directory: String
        public let title: String
        public let parentId: String?
        public let created: Date
        public let updated: Date
        public let archived: Date?
    }

    public struct MessageRow: Sendable, Equatable {
        public let id: String
        public let sessionId: String
        public let created: Date
        /// The message's JSON (`role`, `time`, `modelID`, …).
        public let data: String
    }

    public struct PartRow: Sendable, Equatable {
        public let id: String
        public let messageId: String
        public let created: Date
        public let updated: Date
        /// The part's JSON (`type` plus the fields of that type).
        public let data: String
    }

    // MARK: - Queries

    /// Top-level sessions that are not archived, newest first. Sessions with
    /// a parent are the subagent runs of another session and never cards.
    public func sessions(updatedAfter: Date? = nil) throws -> [SessionRow] {
        var sql = """
            SELECT id, directory, title, parent_id, time_created, time_updated, time_archived
            FROM session WHERE parent_id IS NULL AND time_archived IS NULL
            """
        var bindings: [Binding] = []
        if let updatedAfter {
            sql += " AND time_updated > ?"
            bindings.append(.int(Self.millis(updatedAfter)))
        }
        sql += " ORDER BY time_updated DESC"
        return try query(sql, bindings, Self.sessionRow)
    }

    /// One session by id, archived and child sessions included.
    public func session(id: String) throws -> SessionRow? {
        try query("""
            SELECT id, directory, title, parent_id, time_created, time_updated, time_archived
            FROM session WHERE id = ?
            """, [.text(id)], Self.sessionRow).first
    }

    /// Ids of the top-level sessions whose working directory is `directory`.
    public func sessionIds(directory: String) throws -> Set<String> {
        Set(try query(
            "SELECT id FROM session WHERE directory = ? AND parent_id IS NULL",
            [.text(directory)]
        ) { Self.text($0, 0) ?? "" })
    }

    /// The newest top-level session created in `directory` since `date`: the
    /// session a launch in that directory started. Paths are compared with
    /// symlinks resolved (`/tmp` is `/private/tmp`).
    public func newSessionId(directory: String, createdSince date: Date) -> String? {
        let wanted = Self.canonicalPath(directory)
        let rows = (try? query("""
            SELECT id, directory FROM session
            WHERE parent_id IS NULL AND time_created >= ?
            ORDER BY time_created DESC
            """, [.int(Self.millis(date) - 1000)]) { (Self.text($0, 0) ?? "", Self.text($0, 1) ?? "") }) ?? []
        return rows.first { Self.canonicalPath($0.1) == wanted }?.0
    }

    static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    public func messages(sessionId: String) throws -> [MessageRow] {
        try query("""
            SELECT id, session_id, time_created, data FROM message
            WHERE session_id = ? ORDER BY time_created, id
            """, [.text(sessionId)]) { stmt in
            MessageRow(
                id: Self.text(stmt, 0) ?? "",
                sessionId: Self.text(stmt, 1) ?? "",
                created: Self.date(stmt, 2) ?? .distantPast,
                data: Self.text(stmt, 3) ?? "{}"
            )
        }
    }

    public func parts(sessionId: String) throws -> [PartRow] {
        try query("""
            SELECT id, message_id, time_created, time_updated, data FROM part
            WHERE session_id = ? ORDER BY time_created, id
            """, [.text(sessionId)]) { stmt in
            PartRow(
                id: Self.text(stmt, 0) ?? "",
                messageId: Self.text(stmt, 1) ?? "",
                created: Self.date(stmt, 2) ?? .distantPast,
                updated: Self.date(stmt, 3) ?? .distantPast,
                data: Self.text(stmt, 4) ?? "{}"
            )
        }
    }

    /// Number of messages of each given session.
    public func messageCounts(sessionIds: [String]) throws -> [String: Int] {
        var counts: [String: Int] = [:]
        for chunk in Self.chunks(sessionIds) {
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            for (id, count) in try query(
                "SELECT session_id, count(*) FROM message WHERE session_id IN (\(marks)) GROUP BY session_id",
                chunk.map { .text($0) },
                { (Self.text($0, 0) ?? "", Int(Self.int($0, 1) ?? 0)) }
            ) {
                counts[id] = count
            }
        }
        return counts
    }

    /// The text of the first non-synthetic text part of each session's first
    /// user message, for the given sessions.
    public func firstUserPrompts(sessionIds: [String]) throws -> [String: String] {
        var prompts: [String: String] = [:]
        for chunk in Self.chunks(sessionIds) {
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            // Only the parts of each session's first user message: a filter
            // over all parts reads every transcript (hundreds of MB).
            let rows = try query("""
                SELECT m.session_id, p.data FROM part p JOIN message m ON m.id = p.message_id
                WHERE m.id IN (
                    SELECT (SELECT m2.id FROM message m2
                            WHERE m2.session_id = s.id AND json_extract(m2.data, '$.role') = 'user'
                            ORDER BY m2.time_created, m2.id LIMIT 1)
                    FROM session s WHERE s.id IN (\(marks)))
                ORDER BY p.time_created, p.id
                """, chunk.map { .text($0) }) { (Self.text($0, 0) ?? "", Self.text($0, 1) ?? "") }
            for (id, data) in rows where prompts[id] == nil {
                guard let part = OpenCodeTranscript.jsonObject(data),
                      part["type"] as? String == "text",
                      part["synthetic"] as? Bool != true,
                      let text = (part["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else { continue }
                prompts[id] = text
            }
        }
        return prompts
    }

    /// Time of the latest write to each given session: the session row, its
    /// newest message, or a part of that message, which moves while a reply
    /// streams (the session row itself only moves at message boundaries).
    public func lastActivity(sessionIds: [String]) throws -> [String: Date] {
        var result: [String: Date] = [:]
        for chunk in Self.chunks(sessionIds) {
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let rows = try query("""
                SELECT s.id, max(s.time_updated, coalesce(m.time_updated, 0),
                    coalesce((SELECT max(p.time_updated) FROM part p WHERE p.message_id = m.id), 0))
                FROM session s
                LEFT JOIN message m ON m.id = (
                    SELECT id FROM message WHERE session_id = s.id ORDER BY time_created DESC, id DESC LIMIT 1)
                WHERE s.id IN (\(marks))
                """, chunk.map { .text($0) }) { (Self.text($0, 0) ?? "", Self.date($0, 1)) }
            for (id, date) in rows { if let date { result[id] = date } }
        }
        return result
    }

    /// The searchable fields of a part.
    public struct SearchPart: Sendable, Equatable {
        public let sessionId: String
        public let type: String
        public let text: String?
        public let synthetic: Bool
        public let tool: String?
        /// The tool input as JSON.
        public let input: String?
        /// The first 4000 characters of the tool output.
        public let output: String?
    }

    /// Parts whose JSON contains `needle` (case-insensitive for ASCII, as
    /// SQLite's LIKE is). The fields are pulled out in SQL so a common word
    /// does not copy every matching tool output whole.
    public func parts(containing needle: String) throws -> [SearchPart] {
        let escaped = needle
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return try query("""
            SELECT session_id, json_extract(data, '$.type'), json_extract(data, '$.text'),
                   coalesce(json_extract(data, '$.synthetic'), 0), json_extract(data, '$.tool'),
                   json_extract(data, '$.state.input'), substr(json_extract(data, '$.state.output'), 1, 4000)
            FROM part WHERE data LIKE ? ESCAPE '\\'
            """, [.text("%\(escaped)%")]) { stmt in
            SearchPart(
                sessionId: Self.text(stmt, 0) ?? "",
                type: Self.text(stmt, 1) ?? "",
                text: Self.text(stmt, 2),
                synthetic: (Self.int(stmt, 3) ?? 0) != 0,
                tool: Self.text(stmt, 4),
                input: Self.text(stmt, 5),
                output: Self.text(stmt, 6)
            )
        }
    }

    /// Sessions with a part containing `needle`.
    public func sessionIds(containing needle: String) throws -> Set<String> {
        Set(try parts(containing: needle).map(\.sessionId))
    }

    /// Splits ids into groups under SQLite's bound-parameter limit.
    static func chunks(_ ids: [String]) -> [[String]] {
        stride(from: 0, to: ids.count, by: 500).map { Array(ids[$0..<min($0 + 500, ids.count)]) }
    }

    // MARK: - SQLite

    enum Binding {
        case text(String)
        case int(Int64)
    }

    public enum DatabaseError: Error, LocalizedError {
        case unavailable
        case sqlite(code: Int32, message: String)

        public var errorDescription: String? {
            switch self {
            case .unavailable: "SQLite is not available on this platform"
            case .sqlite(let code, let message): "OpenCode database error \(code): \(message)"
            }
        }
    }

    static func millis(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    #if canImport(SQLite3)
    /// Runs one statement on a fresh read-only connection. A database that
    /// does not exist yet reads as no rows.
    func query<T>(_ sql: String, _ bindings: [Binding], _ map: (OpaquePointer) -> T) throws -> [T] {
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        var db: OpaquePointer?
        let openCode = sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        defer { sqlite3_close_v2(db) }
        guard openCode == SQLITE_OK, let db else {
            throw DatabaseError.sqlite(code: openCode, message: db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed")
        }
        sqlite3_busy_timeout(db, 250)

        var stmt: OpaquePointer?
        let prepareCode = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        guard prepareCode == SQLITE_OK, let stmt else {
            // A schema without the table or column (an older or newer
            // OpenCode) is "no data", not an error the board should surface.
            let message = String(cString: sqlite3_errmsg(db))
            if message.contains("no such table") || message.contains("no such column") { return [] }
            throw DatabaseError.sqlite(code: prepareCode, message: message)
        }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, binding) in bindings.enumerated() {
            let position = Int32(index + 1)
            switch binding {
            case .text(let value): sqlite3_bind_text(stmt, position, value, -1, transient)
            case .int(let value): sqlite3_bind_int64(stmt, position, value)
            }
        }

        var rows: [T] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_ROW {
                rows.append(map(stmt))
            } else if step == SQLITE_DONE {
                break
            } else {
                throw DatabaseError.sqlite(code: step, message: String(cString: sqlite3_errmsg(db)))
            }
        }
        return rows
    }

    static func text(_ stmt: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(stmt, column) != SQLITE_NULL,
              let cString = sqlite3_column_text(stmt, column) else { return nil }
        return String(cString: cString)
    }

    static func int(_ stmt: OpaquePointer, _ column: Int32) -> Int64? {
        guard sqlite3_column_type(stmt, column) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(stmt, column)
    }
    #else
    func query<T>(_ sql: String, _ bindings: [Binding], _ map: (OpaquePointer) -> T) throws -> [T] {
        []
    }

    static func text(_ stmt: OpaquePointer, _ column: Int32) -> String? { nil }
    static func int(_ stmt: OpaquePointer, _ column: Int32) -> Int64? { nil }
    #endif

    static func date(_ stmt: OpaquePointer, _ column: Int32) -> Date? {
        int(stmt, column).map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
    }

    static func sessionRow(_ stmt: OpaquePointer) -> SessionRow {
        SessionRow(
            id: text(stmt, 0) ?? "",
            directory: text(stmt, 1) ?? "",
            title: text(stmt, 2) ?? "",
            parentId: text(stmt, 3),
            created: date(stmt, 4) ?? .distantPast,
            updated: date(stmt, 5) ?? .distantPast,
            archived: date(stmt, 6)
        )
    }
}
