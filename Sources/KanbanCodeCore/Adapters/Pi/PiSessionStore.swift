import Foundation

/// Implements SessionStore for Pi's JSONL session files.
public final class PiSessionStore: SessionStore, @unchecked Sendable {
    private let sessionsRoot: String

    public init(sessionsRoot: String? = nil) {
        self.sessionsRoot = sessionsRoot ?? PiSessionFile.sessionsRoot()
    }

    public func readTranscript(sessionPath: String) async throws -> [ConversationTurn] {
        try PiSessionFile.turns(from: sessionPath)
    }

    /// Copies the session into a new file with a new id, as `pi --fork` does:
    /// the header names the original in `parentSession`, the entries are
    /// kept as they are.
    public func forkSession(sessionPath: String, targetDirectory: String? = nil) async throws -> String {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sessionPath) else {
            throw SessionStoreError.fileNotFound(sessionPath)
        }
        let content = try String(contentsOfFile: sessionPath, encoding: .utf8)
        var lines = content.components(separatedBy: "\n")
        guard let headerData = lines.first?.data(using: .utf8),
              var header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              header["type"] as? String == "session" else {
            throw SessionStoreError.fileNotFound(sessionPath)
        }

        let now = Date.now
        let newSessionId = PiSessionFile.newSessionId(at: now)
        header["id"] = newSessionId
        header["timestamp"] = PiSessionFile.timestamp(now)
        header["parentSession"] = sessionPath
        lines[0] = try Self.encode(header)

        let dir = targetDirectory ?? (sessionPath as NSString).deletingLastPathComponent
        try fileManager.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let newPath = (dir as NSString).appendingPathComponent(
            PiSessionFile.fileName(sessionId: newSessionId, createdAt: now))
        try lines.joined(separator: "\n").write(toFile: newPath, atomically: true, encoding: .utf8)

        // Keep the fork where the original sits in a list sorted by activity.
        if let attrs = try? fileManager.attributesOfItem(atPath: sessionPath),
           let originalMtime = attrs[.modificationDate] as? Date {
            try? fileManager.setAttributes([.modificationDate: originalMtime], ofItemAtPath: newPath)
        }
        return newSessionId
    }

    /// Cuts the file after the last entry of `afterTurn`. Turns carry byte
    /// offsets, so this keeps every line through that entry's.
    public func truncateSession(sessionPath: String, afterTurn: ConversationTurn) async throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sessionPath) else {
            throw SessionStoreError.fileNotFound(sessionPath)
        }

        let backupPath = sessionPath + ".bkp"
        try? fileManager.removeItem(atPath: backupPath)
        try fileManager.copyItem(atPath: sessionPath, toPath: backupPath)

        let url = URL(fileURLWithPath: sessionPath)
        let data = try Data(contentsOf: url)
        let targetOffset = max(afterTurn.lineNumber, afterTurn.endLineNumber)
        guard targetOffset >= 0, targetOffset < data.count else {
            throw SessionStoreError.fileNotFound("Invalid byte offset \(targetOffset)")
        }
        var endOffset = targetOffset
        while endOffset < data.count && data[endOffset] != UInt8(ascii: "\n") {
            endOffset += 1
        }
        if endOffset < data.count { endOffset += 1 }
        try data[0..<endOffset].write(to: url)
    }

    public func searchSessions(query: String, paths: [String]) async throws -> [SearchResult] {
        let box = ResultBox()
        try await searchSessionsStreaming(query: query, paths: paths) { results in
            box.results = results
        }
        return box.results
    }

    public func searchSessionsStreaming(
        query: String,
        paths: [String],
        onResult: @MainActor @Sendable ([SearchResult]) -> Void
    ) async throws {
        try await TranscriptSearch.searchStreaming(
            query: query,
            paths: paths,
            assistantLabel: "Pi",
            readTurns: { try PiSessionFile.turns(from: $0) },
            onResult: onResult
        )
    }

    /// Writes another assistant's conversation as a Pi session in the
    /// project's session directory. Tool calls and results become text:
    /// Pi would replay a structured call to the model, and a call from
    /// another tool set would not match any of Pi's tools.
    public func writeSession(
        turns: [ConversationTurn],
        sessionId: String,
        projectPath: String?
    ) async throws -> String {
        let now = Date.now
        let cwd = projectPath ?? NSHomeDirectory()
        let dir = (sessionsRoot as NSString).appendingPathComponent(PiSessionFile.directoryName(forCwd: cwd))
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let filePath = (dir as NSString).appendingPathComponent(
            PiSessionFile.fileName(sessionId: sessionId, createdAt: now))

        var lines = [try Self.encode([
            "type": "session",
            "version": 3,
            "id": sessionId,
            "timestamp": PiSessionFile.timestamp(now),
            "cwd": cwd,
        ])]
        var parentId: Any = NSNull()
        for turn in turns {
            let text = Self.plainText(of: turn)
            guard !text.isEmpty else { continue }
            let date = turn.timestamp.flatMap(PiSessionFile.parseTimestamp) ?? now
            let milliseconds = Int(date.timeIntervalSince1970 * 1000)
            var message: [String: Any] = [
                "role": turn.role == "user" ? "user" : "assistant",
                "content": [["type": "text", "text": text]],
                "timestamp": milliseconds,
            ]
            if turn.role != "user" {
                message["api"] = "kanban-code-migrated"
                message["provider"] = "kanban-code"
                message["model"] = turn.modelName ?? "migrated"
                message["usage"] = [
                    "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "totalTokens": 0,
                    "cost": ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "total": 0],
                ]
                message["stopReason"] = "stop"
            }
            let id = String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(8))
            lines.append(try Self.encode([
                "type": "message",
                "id": id,
                "parentId": parentId,
                "timestamp": PiSessionFile.timestamp(date),
                "message": message,
            ]))
            parentId = id
        }

        try (lines.joined(separator: "\n") + "\n").write(toFile: filePath, atomically: true, encoding: .utf8)
        return filePath
    }

    // MARK: - Helpers

    private final class ResultBox: @unchecked Sendable {
        var results: [SearchResult] = []
    }

    private static func plainText(of turn: ConversationTurn) -> String {
        let parts = turn.contentBlocks.compactMap { block -> String? in
            switch block.kind {
            case .text:
                block.text
            case .toolUse(let name, let input, _):
                "[\(name)] \(input.map { "\($0.key): \($0.value)" }.sorted().joined(separator: ", "))"
            case .toolResult(let toolName, _):
                "[\(toolName ?? "tool") result] \(block.text)"
            case .thinking, .planModeEnter, .planModeExit, .askUserQuestion, .agentCall:
                nil
            }
        }
        let text = parts.isEmpty ? turn.textPreview : parts.joined(separator: "\n")
        return text == "(empty)" ? "" : text
    }

    private static func encode(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
