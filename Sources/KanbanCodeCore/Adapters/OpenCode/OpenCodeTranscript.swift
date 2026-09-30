import Foundation

/// Turns OpenCode's message and part rows into conversation turns.
///
/// A message is one user prompt or one assistant step; its parts carry the
/// content (`text`, `reasoning`, `tool`, `file`, …). Consecutive assistant
/// messages are one bubble, as they are for the other assistants. A turn's
/// `lineNumber` is the ordinal of its first message, which is stable while
/// the session grows.
public enum OpenCodeTranscript {
    public static func turns(
        messages: [OpenCodeDatabase.MessageRow],
        parts: [OpenCodeDatabase.PartRow]
    ) -> [ConversationTurn] {
        let partsByMessage = Dictionary(grouping: parts, by: \.messageId)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var turns: [ConversationTurn] = []
        for (ordinal, message) in messages.enumerated() {
            let info = jsonObject(message.data) ?? [:]
            guard let role = info["role"] as? String, role == "user" || role == "assistant" else { continue }
            let messageParts = (partsByMessage[message.id] ?? []).compactMap { jsonObject($0.data) }

            var blocks: [ContentBlock] = []
            var imageCount = 0
            for part in messageParts {
                switch part["type"] as? String {
                case "text":
                    // Synthetic text is context OpenCode injects (file
                    // contents, reminders), not something anyone typed or said.
                    if part["synthetic"] as? Bool == true { continue }
                    let text = (part["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { blocks.append(ContentBlock(kind: .text, text: text)) }
                case "reasoning":
                    let text = (part["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { blocks.append(ContentBlock(kind: .thinking, text: String(text.prefix(500)))) }
                case "tool":
                    blocks.append(contentsOf: toolBlocks(part))
                case "file":
                    if (part["mime"] as? String)?.hasPrefix("image/") == true {
                        imageCount += 1
                    } else if let name = part["filename"] as? String ?? part["url"] as? String {
                        blocks.append(ContentBlock(kind: .text, text: "[file: \(name)]"))
                    }
                case "compaction":
                    blocks.append(ContentBlock(kind: .text, text: "[conversation compacted]"))
                default:
                    // step-start, step-finish, patch, snapshot, agent, retry:
                    // bookkeeping with nothing to read in a chat.
                    continue
                }
            }
            guard !blocks.isEmpty || imageCount > 0 else { continue }

            let timestamp = iso.string(from: message.created)
            let model = info["modelID"] as? String
            append(
                role: role, ordinal: ordinal, timestamp: timestamp, blocks: blocks,
                imageCount: imageCount, model: model, to: &turns
            )
        }
        return turns
    }

    // MARK: - Tools

    /// A tool part is the call and, once it ran, its result.
    static func toolBlocks(_ part: [String: Any]) -> [ContentBlock] {
        let rawName = part["tool"] as? String ?? "tool"
        let name = displayToolName(rawName)
        let callId = part["callID"] as? String
        let state = part["state"] as? [String: Any] ?? [:]
        let rawInput = state["input"] as? [String: Any] ?? [:]

        var input: [String: String] = [:]
        for (key, value) in rawInput {
            input[key] = stringify(value)
            // Chat rendering reads Claude's snake_case keys (file_path, …).
            let snake = snakeCase(key)
            if snake != key, input[snake] == nil { input[snake] = stringify(value) }
        }
        let rawInputJSON = JSONSerialization.isValidJSONObject(rawInput)
            ? try? JSONSerialization.data(withJSONObject: rawInput, options: [.sortedKeys])
            : nil
        let description = input.isEmpty
            ? name
            : "\(name)(\(rawInput.keys.sorted().map { "\($0): \(input[$0] ?? "")" }.joined(separator: ", ")))"

        var blocks = [ContentBlock(kind: .toolUse(name: name, input: input, id: callId), text: description, rawInputJSON: rawInputJSON)]
        switch state["status"] as? String {
        case "completed":
            blocks.append(ContentBlock(kind: .toolResult(toolName: name, toolUseId: callId), text: state["output"] as? String ?? ""))
        case "error":
            blocks.append(ContentBlock(kind: .toolResult(toolName: name, toolUseId: callId), text: "Error: \(state["error"] as? String ?? "failed")"))
        default:
            break // pending or running: the call is shown, the result is not in yet
        }
        return blocks
    }

    /// OpenCode's tool ids in the names the chat view knows.
    static func displayToolName(_ name: String) -> String {
        switch name.lowercased() {
        case "bash": "Bash"
        case "read": "Read"
        case "write": "Write"
        case "edit", "multiedit", "patch", "apply_patch": "Edit"
        case "glob", "list": "Glob"
        case "grep": "Grep"
        case "webfetch": "WebFetch"
        case "websearch": "WebSearch"
        case "todowrite": "TodoWrite"
        case "todoread": "TodoRead"
        case "task": "Task"
        default: name
        }
    }

    // MARK: - Helpers

    private static func append(
        role: String, ordinal: Int, timestamp: String, blocks: [ContentBlock],
        imageCount: Int, model: String?, to turns: inout [ConversationTurn]
    ) {
        if role == "assistant", let last = turns.last, last.role == "assistant" {
            let merged = last.contentBlocks + blocks
            turns[turns.count - 1] = ConversationTurn(
                index: last.index,
                lineNumber: last.lineNumber,
                role: last.role,
                textPreview: preview(blocks: merged, role: role),
                timestamp: last.timestamp ?? timestamp,
                contentBlocks: merged,
                imageCount: last.imageCount + imageCount,
                modelName: last.modelName ?? model,
                endLineNumber: ordinal
            )
            return
        }
        turns.append(ConversationTurn(
            index: turns.count,
            lineNumber: ordinal,
            role: role,
            textPreview: preview(blocks: blocks, role: role),
            timestamp: timestamp,
            contentBlocks: blocks,
            imageCount: imageCount,
            modelName: role == "assistant" ? model : nil
        ))
    }

    static func preview(blocks: [ContentBlock], role: String) -> String {
        let text = blocks.filter { if case .text = $0.kind { true } else { false } }
            .map(\.text).joined(separator: "\n")
        if !text.isEmpty { return String(text.prefix(500)) }
        let tools = blocks.compactMap { block -> String? in
            if case .toolUse(let name, _, _) = block.kind { return name }
            return nil
        }
        if !tools.isEmpty {
            var seen = Set<String>()
            return "[tool: \(tools.filter { seen.insert($0).inserted }.joined(separator: ", "))]"
        }
        if blocks.contains(where: { if case .thinking = $0.kind { true } else { false } }) {
            return "[reasoning]"
        }
        return "(empty)"
    }

    static func jsonObject(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
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

    private static func snakeCase(_ key: String) -> String {
        var result = ""
        for character in key {
            if character.isUppercase {
                result += "_" + character.lowercased()
            } else {
                result.append(character)
            }
        }
        return result
    }
}
