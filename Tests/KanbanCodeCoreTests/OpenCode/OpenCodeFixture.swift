import Foundation
import SQLite3
@testable import KanbanCodeCore

/// Builds a throwaway OpenCode database with the schema of OpenCode 1.18
/// (the tables and columns Kanban reads), for adapter tests.
final class OpenCodeFixture {
    let directory: String
    let path: String
    private var db: OpaquePointer?
    private var clock: Int64 = 1_790_000_000_000

    init() throws {
        directory = NSTemporaryDirectory() + "kanban-opencode-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        path = directory + "/opencode.db"
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw FixtureError.open }
        try exec("PRAGMA journal_mode=WAL")
        try exec("""
            CREATE TABLE session (
              id text PRIMARY KEY, project_id text NOT NULL, parent_id text, slug text NOT NULL,
              directory text NOT NULL, title text NOT NULL, version text NOT NULL,
              time_created integer NOT NULL, time_updated integer NOT NULL, time_archived integer
            );
            CREATE TABLE message (
              id text PRIMARY KEY, session_id text NOT NULL,
              time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL
            );
            CREATE TABLE part (
              id text PRIMARY KEY, message_id text NOT NULL, session_id text NOT NULL,
              time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL
            );
            """)
    }

    deinit {
        sqlite3_close(db)
        try? FileManager.default.removeItem(atPath: directory)
    }

    var database: OpenCodeDatabase { OpenCodeDatabase(path: path) }

    enum FixtureError: Error { case open, exec(String) }

    /// Milliseconds for "now minus `ago` seconds".
    static func millis(ago: TimeInterval) -> Int64 {
        Int64((Date.now.addingTimeInterval(-ago).timeIntervalSince1970 * 1000).rounded())
    }

    func tick() -> Int64 {
        clock += 1000
        return clock
    }

    @discardableResult
    func addSession(
        id: String,
        directory: String = "/work/project",
        title: String = "A session",
        parentId: String? = nil,
        created: Int64? = nil,
        updated: Int64? = nil,
        archived: Int64? = nil
    ) throws -> String {
        let created = created ?? tick()
        try exec("""
            INSERT INTO session (id, project_id, parent_id, slug, directory, title, version, time_created, time_updated, time_archived)
            VALUES (\(q(id)), 'global', \(parentId.map(q) ?? "NULL"), 'slug', \(q(directory)), \(q(title)), '1.18.33',
                    \(created), \(updated ?? created), \(archived.map(String.init) ?? "NULL"))
            """)
        return id
    }

    @discardableResult
    func addMessage(sessionId: String, role: String, extra: String = "", time: Int64? = nil) throws -> String {
        let id = "msg_\(UUID().uuidString.prefix(12))"
        let time = time ?? tick()
        let data = #"{"role":"\#(role)"\#(extra.isEmpty ? "" : "," + extra)}"#
        try exec("INSERT INTO message VALUES (\(q(id)), \(q(sessionId)), \(time), \(time), \(q(data)))")
        return id
    }

    func addPart(messageId: String, sessionId: String, json: String, time: Int64? = nil, updated: Int64? = nil) throws {
        let id = "prt_\(UUID().uuidString.prefix(12))"
        let time = time ?? tick()
        try exec("INSERT INTO part VALUES (\(q(id)), \(q(messageId)), \(q(sessionId)), \(time), \(updated ?? time), \(q(json)))")
    }

    func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw FixtureError.exec(message)
        }
    }

    private func q(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }
}
