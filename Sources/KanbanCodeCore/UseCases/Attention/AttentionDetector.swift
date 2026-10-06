import Foundation
import KanbanCodeRemoteKit

/// A decision a session waits on, as its transcript shows it: a question
/// (AskUserQuestion) or a plan to approve (ExitPlanMode) with no answer yet.
public struct PendingDecision: Sendable, Equatable {
    public var toolUseId: String
    public var kind: AttentionRequest.Kind
    /// Short line: the question header, or "Plan ready for review".
    public var title: String
    public var body: String
    public var options: [String]
    public var askedAt: Date?

    public init(toolUseId: String, kind: AttentionRequest.Kind, title: String, body: String, options: [String], askedAt: Date?) {
        self.toolUseId = toolUseId
        self.kind = kind
        self.title = title
        self.body = body
        self.options = options
        self.askedAt = askedAt
    }

    /// Request id: stable for the same tool call on every master.
    public var requestId: String { "att_\(toolUseId)" }
}

/// Finds the decision a Claude session waits on in the tail of its
/// transcript. Pure: tests feed it lines.
public enum AttentionDetector {
    /// Bytes read from the end of a transcript. A pending question is one of
    /// the last lines written; a plan can be long, so the window is generous.
    public static let tailBytes = 768 * 1024

    public static let planOptions = ["Yes, approve the plan", "No, keep planning"]
    public static let permissionOptions = ["Allow", "Deny"]

    /// The newest question or plan approval in `lines` (JSONL, oldest first)
    /// that has no tool result and no later prompt from the user.
    public static func pendingDecision(inLines lines: [String]) -> PendingDecision? {
        var pending: [String: PendingDecision] = [:]
        var order: [String] = []
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for line in lines {
            guard line.contains("\"message\""),
                  let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if obj["isSidechain"] as? Bool == true { continue }
            guard let message = obj["message"] as? [String: Any] else { continue }
            let type = obj["type"] as? String
            let timestamp = (obj["timestamp"] as? String).flatMap { iso.date(from: $0) }

            if type == "user" {
                if let text = message["content"] as? String {
                    // A typed prompt moves the session on: whatever was asked
                    // before is no longer waited on.
                    if !isMetaPrompt(text, obj) {
                        pending.removeAll()
                        order.removeAll()
                    }
                    continue
                }
                guard let blocks = message["content"] as? [[String: Any]] else { continue }
                var sawTypedText = false
                for block in blocks {
                    if block["type"] as? String == "tool_result", let id = block["tool_use_id"] as? String {
                        pending.removeValue(forKey: id)
                    } else if block["type"] as? String == "text", obj["isMeta"] as? Bool != true,
                              let text = block["text"] as? String, !isMetaPrompt(text, obj) {
                        sawTypedText = true
                    }
                }
                if sawTypedText {
                    pending.removeAll()
                    order.removeAll()
                }
                continue
            }

            guard type == "assistant", let blocks = message["content"] as? [[String: Any]] else { continue }
            for block in blocks where block["type"] as? String == "tool_use" {
                guard let id = block["id"] as? String, let name = block["name"] as? String else { continue }
                let input = block["input"] as? [String: Any] ?? [:]
                switch name {
                case "AskUserQuestion":
                    pending[id] = question(id: id, input: input, at: timestamp)
                    order.append(id)
                case "ExitPlanMode":
                    let plan = (input["plan"] as? String) ?? ""
                    pending[id] = PendingDecision(
                        toolUseId: id, kind: .planApproval, title: "Plan ready for review",
                        body: clipped(plan, 1500), options: planOptions, askedAt: timestamp)
                    order.append(id)
                default:
                    break
                }
            }
        }
        for id in order.reversed() {
            if let decision = pending[id] { return decision }
        }
        return nil
    }

    static func question(id: String, input: [String: Any], at timestamp: Date?) -> PendingDecision {
        let questions = TranscriptReader.parseAskQuestions(input)
        let first = questions.first
        let title = first?.header.flatMap { $0.isEmpty ? nil : $0 } ?? "Question"
        let body: String
        if questions.count <= 1 {
            body = first?.question ?? ""
        } else {
            body = questions.enumerated().map { "\($0.offset + 1). \($0.element.question)" }.joined(separator: "\n")
        }
        // Options are offered only when one pick answers everything.
        let options = (questions.count == 1 && first?.multiSelect == false) ? (first?.options.map(\.label) ?? []) : []
        return PendingDecision(
            toolUseId: id, kind: .question, title: title, body: clipped(body, 1500),
            options: options, askedAt: timestamp)
    }

    /// Text the harness writes as a user turn that is not a typed prompt:
    /// command output, interrupts, compact summaries.
    static func isMetaPrompt(_ text: String, _ obj: [String: Any]) -> Bool {
        if obj["isMeta"] as? Bool == true || obj["isCompactSummary"] as? Bool == true { return true }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("<command-") || trimmed.hasPrefix("<local-command")
            || trimmed.hasPrefix("<system-reminder>") || trimmed.hasPrefix("<task-notification>")
    }

    /// Time of the newest user or assistant message: the conversation
    /// moving, not the harness writing hook or progress lines.
    public static func lastTimestamp(inLines lines: [String]) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for line in lines.reversed() {
            guard line.contains("\"type\":\"user\"") || line.contains("\"type\":\"assistant\""),
                  !line.contains("\"isSidechain\":true"),
                  let range = line.range(of: "\"timestamp\":\"") else { continue }
            let rest = line[range.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { continue }
            if let date = iso.date(from: String(rest[..<end])) { return date }
        }
        return nil
    }

    /// A tool call waiting on a permission prompt.
    public struct ToolCall: Sendable, Equatable {
        public var name: String
        /// The command, file, URL or pattern it acts on.
        public var detail: String?
        /// The one-line description Claude gives a Bash call.
        public var description: String?

        public init(name: String, detail: String? = nil, description: String? = nil) {
            self.name = name
            self.detail = detail
            self.description = description
        }

        /// "Bash: <command>", for the detail sheet.
        public var text: String { detail.map { "\(name): \($0)" } ?? name }

        /// One plain line for a notification, never the command itself:
        /// "Claude wants to run a command: Convert the recording to mp4".
        public var summary: String {
            let said = description?.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: \.isNewline).first.map(String.init)
            switch name {
            case "Bash":
                if let said, !said.isEmpty { return "Claude wants to run a command: \(AttentionDetector.clipped(said, 120))" }
                return "Claude wants to run a Bash command"
            case "Edit", "MultiEdit", "Write", "NotebookEdit":
                let file = detail.map { ($0 as NSString).lastPathComponent } ?? ""
                return file.isEmpty ? "Claude wants to edit a file" : "Claude wants to edit \(file)"
            case "WebFetch":
                if let host = detail.flatMap({ URL(string: $0)?.host }) { return "Claude wants to fetch a page from \(host)" }
                return "Claude wants to fetch a web page"
            default:
                return "Claude wants to use \(name)"
            }
        }
    }

    /// The newest tool call with no result yet, for a permission request.
    public static func pendingToolCall(inLines lines: [String]) -> ToolCall? {
        var calls: [(id: String, call: ToolCall)] = []
        var answered = Set<String>()
        for line in lines {
            guard line.contains("tool_"), let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["isSidechain"] as? Bool != true,
                  let message = obj["message"] as? [String: Any],
                  let blocks = message["content"] as? [[String: Any]] else { continue }
            for block in blocks {
                if block["type"] as? String == "tool_use", let id = block["id"] as? String, let name = block["name"] as? String {
                    let input = block["input"] as? [String: Any] ?? [:]
                    let detail = (input["command"] as? String) ?? (input["file_path"] as? String)
                        ?? (input["url"] as? String) ?? (input["pattern"] as? String)
                    calls.append((id, ToolCall(name: name, detail: detail, description: input["description"] as? String)))
                } else if block["type"] as? String == "tool_result", let id = block["tool_use_id"] as? String {
                    answered.insert(id)
                }
            }
        }
        return calls.last(where: { !answered.contains($0.id) })?.call
    }

    static func clipped(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) + "..." : text
    }

    /// Reads the last `tailBytes` of a transcript as lines; the first,
    /// partial line of the window is dropped.
    public static func tailLines(path: String, bytes: Int = tailBytes) -> [String] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return [] }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return lines
    }
}
