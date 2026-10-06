import Foundation

/// The recent prompts of a card's session, as the vault shows them to Jev:
/// what Rogerio typed into the card, and what other agents delivered to it.
public struct CardPrompts: Sendable, Equatable {
    /// A prompt some other sender delivered: a DM, a channel message, a
    /// parent agent, another Claude session, a Slack relay.
    public struct Delivered: Sendable, Equatable {
        /// Who sent it, e.g. "@reviewer (DM)", "Alex (Slack)".
        public var from: String
        public var text: String

        public init(from: String, text: String) {
            self.from = from
            self.text = text
        }
    }

    /// The newest prompts typed or pasted into the session with no delivery
    /// marker, nearly whole, newest last.
    public var typed: [String]
    /// Older prompts of the same session, before `typed`, each cut short so
    /// an instruction given early in the task still counts. Oldest first.
    public var earlier: [String]
    /// Prompts that carry another sender's delivery marker, newest last.
    public var delivered: [Delivered]

    public init(typed: [String], earlier: [String] = [], delivered: [Delivered] = []) {
        self.typed = typed
        self.earlier = earlier
        self.delivered = delivered
    }

    public var isEmpty: Bool { typed.isEmpty && earlier.isEmpty && delivered.isEmpty }
}

/// Reads `CardPrompts` from a Claude Code or Codex transcript.
///
/// Claude Code marks each user record with an origin: `human` (a prompt
/// entered in the session, typed or pasted) or a harness kind (task
/// notifications, messages from other Claude sessions, auto-continuations),
/// plus `isMeta` and `isCompactSummary` for text it injects itself. Kanban
/// deliveries are pasted into the session, so they arrive as `human` too;
/// they are told apart by the marker their sender prefixes:
/// `[DM from @handle]:`, `[Message from #channel @handle]:`,
/// `[Message from @handle]:` (`kanban send` from a card),
/// `[Message from DEVICE (remote agent)]:`, the self-compact follow-up
/// marker, the external share warning, `You are running as subagent card`,
/// `From NAME (Slack):`.
public enum CardPromptReader {
    public static let maxTyped = 5
    public static let maxDelivered = 3
    /// Characters kept of one typed prompt: its start and its end.
    public static let typedHead = 900
    public static let typedTail = 400
    public static let deliveredLimit = 300
    /// The typed prompts together stay under this many characters; older
    /// ones are dropped first.
    public static let typedBudget = 4000
    /// Older prompts kept after the newest ones, each cut to its start.
    public static let maxEarlier = 20
    public static let earlierLimit = 200
    public static let earlierBudget = 4000
    /// How far back from the end of the transcript to look.
    public static let scanBytes = 16 << 20

    /// What one transcript record holds for the vault.
    public enum Entry: Sendable, Equatable {
        case typed(String)
        case delivered(CardPrompts.Delivered)
    }

    /// The card's prompts, or nil when its transcript is not on this machine.
    public static func read(link: Link, kanbanHome: String?) -> CardPrompts? {
        guard let path = ConversationExportCommand.transcriptPath(for: link, kanbanHome: kanbanHome) else { return nil }
        switch link.effectiveAssistant {
        case .claude, .codex: return read(path: path)
        case .gemini, .opencode: return nil
        }
    }

    /// Reads a Claude Code or Codex transcript from its end.
    public static func read(path: String, scanBytes: Int = scanBytes) -> CardPrompts? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int) ?? 0
        var typed: [String] = []
        var delivered: [CardPrompts.Delivered] = []
        do {
            try TranscriptReader.scanRecordsBackwards(filePath: path) { offset, line in
                if size - offset > scanBytes { return true }
                guard line.contains("\"user\"") || line.contains("user_message"),
                      let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let entry = entry(record: obj)
                else { return false }
                switch entry {
                case .typed(let text):
                    // Claude Code can write the same prompt twice in a row.
                    if typed.last != text { typed.append(text) }
                case .delivered(let d):
                    if delivered.count < maxDelivered { delivered.append(d) }
                }
                return typed.count >= maxTyped + maxEarlier
            }
        } catch {
            return nil
        }
        let recent = budgeted(Array(typed.prefix(maxTyped)))
        let older = shortened(Array(typed.dropFirst(recent.count)))
        return CardPrompts(typed: recent.reversed(), earlier: older.reversed(), delivered: delivered.reversed())
    }

    /// Keeps the newest prompts (first in `newestFirst`) that fit the budget,
    /// each clipped to its head and tail.
    static func budgeted(_ newestFirst: [String]) -> [String] {
        var out: [String] = []
        var used = 0
        for text in newestFirst {
            let clipped = clip(text, head: typedHead, tail: typedTail)
            if !out.isEmpty && used + clipped.count > typedBudget { break }
            out.append(clipped)
            used += clipped.count
        }
        return out
    }

    /// The older prompts (newest first) cut to their start, as many as fit
    /// `earlierBudget`.
    static func shortened(_ newestFirst: [String]) -> [String] {
        var out: [String] = []
        var used = 0
        for text in newestFirst.prefix(maxEarlier) {
            let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            let cut = flat.count > earlierLimit ? String(flat.prefix(earlierLimit)) + " [...]" : flat
            if used + cut.count > earlierBudget { break }
            out.append(cut)
            used += cut.count
        }
        return out
    }

    static func clip(_ text: String, head: Int, tail: Int) -> String {
        guard text.count > head + tail + 5 else { return text }
        return String(text.prefix(head)) + " [...] " + String(text.suffix(tail))
    }

    /// The vault's reading of one transcript record; nil for anything that
    /// is not a prompt entered in the session.
    public static func entry(record obj: [String: Any]) -> Entry? {
        let type = obj["type"] as? String
        if type == "event_msg" {
            guard let payload = obj["payload"] as? [String: Any],
                  payload["type"] as? String == "user_message",
                  let message = payload["message"] as? String
            else { return nil }
            return entry(text: message)
        }
        guard type == "user" else { return nil }
        if obj["isMeta"] as? Bool == true || obj["isCompactSummary"] as? Bool == true
            || obj["isSidechain"] as? Bool == true || obj["isVisibleInTranscriptOnly"] as? Bool == true {
            return nil
        }
        if obj["promptSource"] as? String == "system" { return nil }
        if let origin = obj["origin"] as? [String: Any], let kind = origin["kind"] as? String, kind != "human" {
            return nil
        }
        guard let message = obj["message"] as? [String: Any] else { return nil }
        let text: String
        if let s = message["content"] as? String {
            text = s
        } else if let blocks = message["content"] as? [[String: Any]] {
            if blocks.contains(where: { $0["type"] as? String == "tool_result" }) { return nil }
            text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .joined(separator: "\n")
        } else {
            return nil
        }
        return entry(text: text)
    }

    static let harnessPrefixes = [
        "<local-command", "<command-name>", "<command-message>", "<command-args>", "<task-notification>",
        "<system-reminder>", "<bash-input>", "<bash-stdout>", "<bash-stderr>", "<user-prompt-submit-hook>",
        "[Request interrupted", "Caveat: The messages below", "Another Claude session sent a message:",
        "This session is being continued from a previous conversation",
    ]

    /// Kept in step with `cli/src/delivery-marker.ts`.
    public static let selfCompactFollowUpMarker = "[Self-compact follow-up from this card]:"

    /// A prompt an agent-scope remote device (an OpenClaw agent) sends a
    /// card. Assistant commands such as `/compact` pass as typed.
    public static func markRemoteAgentMessage(_ text: String, device: String) -> String {
        if text.trimmingCharacters(in: .whitespaces).hasPrefix("/") { return text }
        return "[Message from \(device) (remote agent)]: \(text)"
    }

    static let externalWarning = "The message below was sent by an unverified user via a public share link."

    /// Classifies the text of a prompt by its delivery marker.
    public static func entry(text raw: String) -> Entry? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if harnessPrefixes.contains(where: { text.hasPrefix($0) }) { return nil }
        func delivered(_ from: String, _ body: Substring) -> Entry {
            .delivered(.init(from: from, text: clip(body.trimmingCharacters(in: .whitespacesAndNewlines),
                                                    head: deliveredLimit, tail: 0)))
        }
        if text.hasPrefix(externalWarning) {
            let body = text.drop(while: { $0 != "\n" })
            return delivered("an unverified user through a public share link", body)
        }
        if text.hasPrefix("[DM from "), let close = text.range(of: "]:") {
            let who = text[text.index(text.startIndex, offsetBy: 9)..<close.lowerBound]
            return delivered("\(who) (DM)", text[close.upperBound...])
        }
        if text.hasPrefix("[Message from "), let close = text.range(of: "]:") {
            let who = text[text.index(text.startIndex, offsetBy: 14)..<close.lowerBound]
            let parts = who.split(separator: " ", maxSplits: 1)
            let from = who.hasPrefix("#") && parts.count == 2 ? "\(parts[1]) in \(parts[0])" : String(who)
            return delivered(from, text[close.upperBound...])
        }
        if text.hasPrefix(selfCompactFollowUpMarker) {
            return delivered("this card's own agent (self-compact follow-up)", text.dropFirst(selfCompactFollowUpMarker.count))
        }
        if text.hasPrefix("You are running as subagent card ") {
            return delivered("the parent agent that started this subagent", text.drop(while: { $0 != "\n" }))
        }
        if text.hasPrefix("From "), let newline = text.firstIndex(of: "\n") {
            let header = text[..<newline]
            if header.hasSuffix(" (Slack):") {
                let name = header.dropFirst(5).dropLast(" (Slack):".count)
                return delivered("\(name) (Slack)", text[text.index(after: newline)...])
            }
        }
        return .typed(text)
    }
}
