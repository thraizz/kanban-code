import Foundation

/// Reads Pi's session files.
///
/// Pi writes one JSONL file per session at
/// `~/.pi/agent/sessions/--<cwd>--/<timestamp>_<uuid>.jsonl`. The first line
/// is a `session` header (id, cwd, `parentSession` for a fork); every other
/// line is an entry with an `id` and a `parentId`. The entries form a tree:
/// `/tree` in Pi continues from an earlier entry without deleting the later
/// ones. The conversation on screen is the branch from the last entry back to
/// the root, so that is the one read here.
public enum PiSessionFile {
    /// One parsed line with the byte offset it starts at.
    struct Entry {
        let offset: Int
        let object: [String: Any]

        var type: String? { object["type"] as? String }
        var id: String? { object["id"] as? String }
        var parentId: String? { object["parentId"] as? String }
        var message: [String: Any]? { object["message"] as? [String: Any] }
    }

    public struct Metadata: Sendable, Equatable {
        public let sessionId: String
        public let projectPath: String?
        public let firstPrompt: String?
        /// Set with `/name` or `--name`.
        public let name: String?
        public let messageCount: Int
        /// The file this session was forked from.
        public let parentSession: String?
    }

    // MARK: - Locations

    /// `~/.pi/agent/sessions`.
    public static func sessionsRoot(home: String = NSHomeDirectory()) -> String {
        (home as NSString).appendingPathComponent("\(CodingAssistant.pi.configDirName)/sessions")
    }

    /// The directory Pi keeps a working directory's sessions in: the path
    /// without its leading separator, `/`, `\` and `:` replaced by `-`,
    /// wrapped in `--`.
    public static func directoryName(forCwd cwd: String) -> String {
        var trimmed = Substring(cwd)
        if trimmed.hasPrefix("/") { trimmed = trimmed.dropFirst() }
        let encoded = String(trimmed.map { "/\\:".contains($0) ? "-" : $0 })
        return "--\(encoded)--"
    }

    /// Every session file, one directory level below the root.
    public static func sessionFiles(root: String? = nil) -> [String] {
        let root = root ?? sessionsRoot()
        let fileManager = FileManager.default
        guard let dirs = try? fileManager.contentsOfDirectory(atPath: root) else { return [] }
        var files: [String] = []
        for dir in dirs {
            let dirPath = (root as NSString).appendingPathComponent(dir)
            guard let names = try? fileManager.contentsOfDirectory(atPath: dirPath) else { continue }
            for name in names where name.hasSuffix(".jsonl") {
                files.append((dirPath as NSString).appendingPathComponent(name))
            }
        }
        return files
    }

    /// The session id in a file name: what follows the timestamp's `_`.
    public static func sessionId(fromFileName path: String) -> String? {
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        guard let separator = name.lastIndex(of: "_") else { return nil }
        let id = name[name.index(after: separator)...]
        return id.isEmpty ? nil : String(id)
    }

    /// The file of `sessionId` in `directory`, whatever its timestamp.
    public static func sessionFile(sessionId: String, in directory: String) -> String? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names
            .first { $0.hasSuffix("_\(sessionId).jsonl") }
            .map { (directory as NSString).appendingPathComponent($0) }
    }

    /// The file name Pi gives a session created at `date`.
    public static func fileName(sessionId: String, createdAt date: Date) -> String {
        let stamp = timestamp(date)
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        return "\(stamp)_\(sessionId).jsonl"
    }

    /// An entry timestamp: ISO 8601 in UTC with milliseconds.
    public static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func parseTimestamp(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    /// A new session id the way Pi makes them: a version 7 UUID, the
    /// creation time in milliseconds followed by random bits.
    public static func newSessionId(at date: Date = .now) -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max) }
        let milliseconds = UInt64(max(0, (date.timeIntervalSince1970 * 1000).rounded()))
        for index in 0..<6 {
            bytes[index] = UInt8(truncatingIfNeeded: milliseconds >> (8 * (5 - index)))
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x70
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let groups = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { range in
            String(hex[hex.index(hex.startIndex, offsetBy: range.lowerBound)..<hex.index(hex.startIndex, offsetBy: range.upperBound)])
        }
        return groups.joined(separator: "-")
    }

    // MARK: - Reading

    /// The header and the entries of a session file.
    static func read(_ path: String) throws -> (header: [String: Any]?, entries: [Entry]) {
        guard FileManager.default.fileExists(atPath: path) else {
            throw SessionStoreError.fileNotFound(path)
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        var header: [String: Any]?
        var entries: [Entry] = []
        var lineStart = 0
        let newline = UInt8(ascii: "\n")
        while lineStart < data.count {
            let lineEnd = data[lineStart...].firstIndex(of: newline) ?? data.count
            if lineEnd > lineStart,
               let object = try? JSONSerialization.jsonObject(with: data[lineStart..<lineEnd]) as? [String: Any] {
                if object["type"] as? String == "session" {
                    header = header ?? object
                } else {
                    entries.append(Entry(offset: lineStart, object: object))
                }
            }
            lineStart = lineEnd + 1
        }
        return (header, entries)
    }

    /// The entries from the root to the last entry written, in order.
    static func activeBranch(_ entries: [Entry]) -> [Entry] {
        guard let leaf = entries.last(where: { $0.id != nil }) else { return entries }
        let byId = Dictionary(entries.compactMap { entry in entry.id.map { ($0, entry) } },
                              uniquingKeysWith: { _, last in last })
        var branch: [Entry] = [leaf]
        var visited: Set<String> = [leaf.id!]
        var current = leaf
        while let parentId = current.parentId, let parent = byId[parentId], visited.insert(parentId).inserted {
            branch.append(parent)
            current = parent
        }
        return branch.reversed()
    }

    public static func metadata(from path: String) throws -> Metadata? {
        let (header, entries) = try read(path)
        guard let sessionId = header?["id"] as? String ?? sessionId(fromFileName: path) else { return nil }
        let branch = activeBranch(entries)

        var firstPrompt: String?
        var messageCount = 0
        for entry in branch {
            guard entry.type == "message", let message = entry.message else { continue }
            switch message["role"] as? String {
            case "user":
                messageCount += 1
                if firstPrompt == nil {
                    let text = userText(message).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { firstPrompt = String(text.prefix(500)) }
                }
            case "assistant":
                messageCount += 1
            default:
                break
            }
        }
        // The latest name wins; an empty one clears it.
        let name = entries.last { $0.type == "session_info" }
            .flatMap { $0.object["name"] as? String }
            .flatMap { $0.isEmpty ? nil : $0 }

        return Metadata(
            sessionId: sessionId,
            projectPath: header?["cwd"] as? String,
            firstPrompt: firstPrompt,
            name: name,
            messageCount: messageCount,
            parentSession: header?["parentSession"] as? String
        )
    }

    /// A file's header line, read without the rest of the file.
    public static func header(path: String) -> [String: Any]? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 16 * 1024)
        let line = data.prefix { $0 != UInt8(ascii: "\n") }
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "session" else { return nil }
        return object
    }

    /// The session id in a file's header.
    public static func headerSessionId(path: String) -> String? {
        header(path: path)?["id"] as? String
    }

    // MARK: - Transcript

    /// Conversation turns of the active branch. A turn's `lineNumber` is the
    /// byte offset of its first entry, `endLineNumber` that of its last, so a
    /// restore can cut the file after it.
    public static func turns(from path: String) throws -> [ConversationTurn] {
        turns(entries: activeBranch(try read(path).entries))
    }

    static func turns(entries: [Entry]) -> [ConversationTurn] {
        var turns: [ConversationTurn] = []
        var toolNames: [String: String] = [:]
        for entry in entries {
            let timestamp = entry.object["timestamp"] as? String
            switch entry.type {
            case "message":
                guard let message = entry.message else { continue }
                switch message["role"] as? String {
                case "user":
                    let text = userText(message).trimmingCharacters(in: .whitespacesAndNewlines)
                    let images = imageCount(message["content"])
                    guard !text.isEmpty || images > 0 else { continue }
                    let blocks = text.isEmpty ? [] : [ContentBlock(kind: .text, text: text)]
                    append(role: "user", offset: entry.offset, timestamp: timestamp,
                           blocks: blocks, imageCount: images, model: nil, to: &turns)
                case "assistant":
                    let blocks = assistantBlocks(message, toolNames: &toolNames)
                    guard !blocks.isEmpty else { continue }
                    append(role: "assistant", offset: entry.offset, timestamp: timestamp,
                           blocks: blocks, imageCount: 0, model: message["model"] as? String, to: &turns)
                case "toolResult":
                    let callId = message["toolCallId"] as? String
                    let name = (message["toolName"] as? String).map(displayToolName)
                        ?? callId.flatMap { toolNames[$0] }
                    var text = contentText(message["content"])
                    if message["isError"] as? Bool == true { text = "Error: \(text)" }
                    append(role: "assistant", offset: entry.offset, timestamp: timestamp,
                           blocks: [ContentBlock(kind: .toolResult(toolName: name, toolUseId: callId), text: text)],
                           imageCount: 0, model: nil, to: &turns)
                case "bashExecution":
                    // A `!command` the user ran in Pi's editor.
                    let command = message["command"] as? String ?? ""
                    guard !command.isEmpty else { continue }
                    append(role: "user", offset: entry.offset, timestamp: timestamp,
                           blocks: [ContentBlock(kind: .text, text: "!\(command)")],
                           imageCount: 0, model: nil, to: &turns)
                default:
                    // system (prompt and tool loadout), custom (extension
                    // context), summaries: nothing anyone typed or said.
                    continue
                }
            case "compaction":
                append(role: "assistant", offset: entry.offset, timestamp: timestamp,
                       blocks: [ContentBlock(kind: .text, text: "[conversation compacted]")],
                       imageCount: 0, model: nil, to: &turns)
            default:
                // model_change, thinking_level_change, label, session_info,
                // usage, custom, branch_summary, context_edit: bookkeeping.
                continue
            }
        }
        return turns
    }

    static func assistantBlocks(_ message: [String: Any], toolNames: inout [String: String]) -> [ContentBlock] {
        var blocks: [ContentBlock] = []
        for part in message["content"] as? [[String: Any]] ?? [] {
            switch part["type"] as? String {
            case "text":
                let text = (part["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { blocks.append(ContentBlock(kind: .text, text: text)) }
            case "thinking":
                let text = (part["thinking"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { blocks.append(ContentBlock(kind: .thinking, text: String(text.prefix(500)))) }
            case "toolCall":
                let name = displayToolName(part["name"] as? String ?? "tool")
                let callId = part["id"] as? String
                if let callId { toolNames[callId] = name }
                blocks.append(toolUseBlock(name: name, callId: callId, arguments: part["arguments"] as? [String: Any] ?? [:]))
            default:
                continue
            }
        }
        if blocks.isEmpty, message["stopReason"] as? String == "error",
           let error = message["errorMessage"] as? String, !error.isEmpty {
            blocks.append(ContentBlock(kind: .text, text: "Error: \(error)"))
        }
        return blocks
    }

    static func toolUseBlock(name: String, callId: String?, arguments: [String: Any]) -> ContentBlock {
        // Null arguments (Pi writes `"timeout": null`) say nothing.
        let arguments = arguments.filter { !($0.value is NSNull) }
        var input: [String: String] = [:]
        for (key, value) in arguments {
            input[key] = stringify(value)
        }
        // Chat rendering reads Claude's key for the file a tool touches.
        if input["file_path"] == nil, let path = input["path"] { input["file_path"] = path }
        let rawInputJSON = JSONSerialization.isValidJSONObject(arguments)
            ? try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
            : nil
        let description = arguments.isEmpty
            ? name
            : "\(name)(\(arguments.keys.sorted().map { "\($0): \(input[$0] ?? "")" }.joined(separator: ", ")))"
        return ContentBlock(kind: .toolUse(name: name, input: input, id: callId), text: description, rawInputJSON: rawInputJSON)
    }

    /// Pi's built-in tool names in the names the chat view knows.
    static func displayToolName(_ name: String) -> String {
        switch name {
        case "bash": "Bash"
        case "read": "Read"
        case "write": "Write"
        case "edit": "Edit"
        case "grep": "Grep"
        case "find", "ls": "Glob"
        default: name
        }
    }

    // MARK: - Branches

    /// Branches the session created or pushed, from its bash tool calls.
    public static func extractPushedBranches(from path: String) throws -> [JsonlParser.DiscoveredBranch] {
        let pushRegex = /git\s+push\s+(?:-[^\s]+\s+)*[A-Za-z0-9_][A-Za-z0-9_.\-]*\s+([^\s;&|]+)/
        let checkoutBranchRegex = /git\s+checkout\s+-[bB]\s+(\S+)/
        let switchCreateRegex = /git\s+switch\s+(?:-c|--create)\s+(\S+)/
        let worktreeAddRegex = /git\s+worktree\s+add\s+(?:[^\s;|&]+\s+)*?-b\s+(\S+)/
        var branches = Set<JsonlParser.DiscoveredBranch>()

        for entry in try read(path).entries where entry.type == "message" {
            guard let message = entry.message, message["role"] as? String == "assistant" else { continue }
            for part in message["content"] as? [[String: Any]] ?? [] {
                guard part["type"] as? String == "toolCall", part["name"] as? String == "bash",
                      let command = (part["arguments"] as? [String: Any])?["command"] as? String,
                      command.contains("git") else { continue }
                func addBranch(_ branch: String) {
                    // HEAD pushes the current branch — the name isn't in the command.
                    if branch != "main" && branch != "master" && branch != "HEAD" && !branch.hasPrefix("-") {
                        branches.insert(JsonlParser.DiscoveredBranch(branch: branch, repoPath: nil))
                    }
                }
                for match in command.matches(of: pushRegex) { addBranch(String(match.output.1)) }
                for match in command.matches(of: checkoutBranchRegex) { addBranch(String(match.output.1)) }
                for match in command.matches(of: switchCreateRegex) { addBranch(String(match.output.1)) }
                for match in command.matches(of: worktreeAddRegex) { addBranch(String(match.output.1)) }
            }
        }
        return Array(branches).sorted { $0.branch < $1.branch }
    }

    // MARK: - Helpers

    private static func append(
        role: String, offset: Int, timestamp: String?, blocks: [ContentBlock],
        imageCount: Int, model: String?, to turns: inout [ConversationTurn]
    ) {
        // An assistant reply is several entries (each step, each tool
        // result); they are one bubble, as they are for the other assistants.
        if role == "assistant", let last = turns.last, last.role == "assistant" {
            let merged = last.contentBlocks + blocks
            turns[turns.count - 1] = ConversationTurn(
                index: last.index,
                lineNumber: last.lineNumber,
                role: last.role,
                textPreview: OpenCodeTranscript.preview(blocks: merged, role: role),
                timestamp: last.timestamp ?? timestamp,
                contentBlocks: merged,
                imageCount: last.imageCount + imageCount,
                modelName: last.modelName ?? model,
                endLineNumber: offset
            )
            return
        }
        turns.append(ConversationTurn(
            index: turns.count,
            lineNumber: offset,
            role: role,
            textPreview: OpenCodeTranscript.preview(blocks: blocks, role: role),
            timestamp: timestamp,
            contentBlocks: blocks,
            imageCount: imageCount,
            modelName: role == "assistant" ? model : nil
        ))
    }

    /// A user message's text: a plain string, or its text blocks.
    static func userText(_ message: [String: Any]) -> String {
        if let text = message["content"] as? String { return text }
        return contentText(message["content"])
    }

    private static func contentText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        return (content as? [[String: Any]] ?? [])
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
    }

    private static func imageCount(_ content: Any?) -> Int {
        (content as? [[String: Any]] ?? []).count { $0["type"] as? String == "image" }
    }

    private static func stringify(_ value: Any) -> String {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return String(describing: value)
    }
}
