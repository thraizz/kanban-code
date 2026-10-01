import Foundation

/// Reads and manages hook events from ~/.kanban-code/hook-events.jsonl.
public actor HookEventStore {
    private let filePath: String
    private var tail = HookLogTail()
    private let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let isoFormatterNoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    public init(basePath: String? = nil) {
        let base = basePath ?? (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code")
        self.filePath = (base as NSString).appendingPathComponent("hook-events.jsonl")
    }

    /// Read new events since the last read.
    ///
    /// Only the bytes appended since the previous call are read and parsed.
    /// A line the hook script is still writing is held back until its newline
    /// arrives, and a file that shrank (truncated or replaced) is read again
    /// from the start.
    public func readNewEvents() throws -> [HookEvent] {
        guard FileManager.default.fileExists(atPath: filePath) else {
            tail.reset()
            return []
        }

        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: filePath))
        defer { try? handle.close() }

        let size = try handle.seekToEnd()
        let offset = tail.nextReadOffset(fileSize: size)
        guard offset < size else { return [] }
        try handle.seek(toOffset: offset)
        let data = handle.readDataToEndOfFile()
        let lines = tail.ingest(data)

        var events: [HookEvent] = []
        events.reserveCapacity(lines.count)
        for line in lines {
            if let event = parseLine(line) { events.append(event) }
        }
        // A last line without a newline is complete when it is valid JSON (a
        // cut-off object never is), so a writer that omits the final newline
        // is not held back forever.
        if let rest = tail.pendingLine, let event = parseLine(rest) {
            events.append(event)
            tail.discardPendingLine()
        }
        return events
    }

    private func parseLine(_ lineData: Data) -> HookEvent? {
        guard let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              let sessionId = obj["sessionId"] as? String else {
            return nil
        }
        let timestamp = (obj["timestamp"] as? String).flatMap { parseTimestamp($0) } ?? Date()
        return HookEvent(
            sessionId: sessionId,
            eventName: obj["event"] as? String ?? "unknown",
            transcriptPath: obj["transcriptPath"] as? String,
            notificationType: obj["notificationType"] as? String,
            source: obj["source"] as? String,
            timestamp: timestamp
        )
    }

    /// Read all events (for initial load).
    public func readAllEvents() throws -> [HookEvent] {
        tail.reset()
        return try readNewEvents()
    }

    /// The file path.
    public var path: String { filePath }

    private func parseTimestamp(_ value: String) -> Date? {
        isoFormatter.date(from: value) ?? isoFormatterNoFractional.date(from: value)
    }
}

/// Tracks how far an append-only JSONL file has been consumed.
///
/// Pure bookkeeping, so the edge cases (partial last line, truncation,
/// rotation) are testable without a file: the caller asks where to start
/// reading, reads from there, and hands the bytes to `ingest`.
public struct HookLogTail: Sendable {
    /// Byte offset up to which data has been read (including held-back bytes).
    public private(set) var offset: UInt64 = 0
    /// Bytes of a line that has no newline yet.
    private var partial = Data()

    public init() {}

    public mutating func reset() {
        offset = 0
        partial.removeAll()
    }

    /// Where to start reading a file that is currently `fileSize` bytes.
    /// A file smaller than what was already read was truncated or replaced,
    /// so everything starts over.
    public mutating func nextReadOffset(fileSize: UInt64) -> UInt64 {
        if fileSize < offset { reset() }
        return offset
    }

    /// The held-back bytes of a line that has no newline yet.
    public var pendingLine: Data? { partial.isEmpty ? nil : partial }

    public mutating func discardPendingLine() { partial.removeAll() }

    /// Feeds bytes read from `nextReadOffset`; returns the complete lines.
    /// A trailing line without a newline is kept for the next call.
    public mutating func ingest(_ data: Data) -> [Data] {
        offset += UInt64(data.count)
        guard !data.isEmpty else { return [] }
        var buffer = partial
        buffer.append(data)
        var lines: [Data] = []
        var lineStart = buffer.startIndex
        var index = buffer.startIndex
        while index < buffer.endIndex {
            if buffer[index] == 0x0A {
                if index > lineStart { lines.append(buffer[lineStart..<index]) }
                lineStart = buffer.index(after: index)
            }
            index = buffer.index(after: index)
        }
        partial = Data(buffer[lineStart..<buffer.endIndex])
        return lines
    }
}
