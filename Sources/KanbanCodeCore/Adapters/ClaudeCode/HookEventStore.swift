import Foundation

/// Reads and manages hook events from ~/.kanban-code/hook-events.jsonl.
public actor HookEventStore {
    private let filePath: String
    private var lastReadOffset: UInt64 = 0
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
    public func readNewEvents() throws -> [HookEvent] {
        guard FileManager.default.fileExists(atPath: filePath) else { return [] }

        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: filePath))
        defer { try? handle.close() }

        handle.seek(toFileOffset: lastReadOffset)
        let data = handle.readDataToEndOfFile()
        lastReadOffset = handle.offsetInFile

        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return [] }

        var events: [HookEvent] = []
        events.reserveCapacity(max(8, data.count / 160))
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard !line.isEmpty,
                  let lineData = String(line).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let sessionId = obj["sessionId"] as? String else {
                continue
            }

            let eventName = obj["event"] as? String ?? "unknown"
            let transcriptPath = obj["transcriptPath"] as? String
            let timestampStr = obj["timestamp"] as? String
            let timestamp = timestampStr.flatMap { self.parseTimestamp($0) } ?? Date()

            events.append(HookEvent(
                sessionId: sessionId,
                eventName: eventName,
                transcriptPath: transcriptPath,
                notificationType: obj["notificationType"] as? String,
                source: obj["source"] as? String,
                timestamp: timestamp
            ))
        }
        return events
    }

    /// Read all events (for initial load).
    public func readAllEvents() throws -> [HookEvent] {
        lastReadOffset = 0
        return try readNewEvents()
    }

    /// The file path.
    public var path: String { filePath }

    private func parseTimestamp(_ value: String) -> Date? {
        isoFormatter.date(from: value) ?? isoFormatterNoFractional.date(from: value)
    }
}
