import Foundation

/// The name of a card for a Claude Code conversation that started outside
/// Kanban Code, read from its transcript when it is imported.
public enum ConversationTitle {
    /// What a transcript records about its own name.
    public struct Titles: Sendable, Equatable {
        /// The name the user gave the session (`/rename`).
        public var custom: String?
        /// The title Claude Code wrote for the conversation itself.
        public var claude: String?

        public init(custom: String? = nil, claude: String? = nil) {
            self.custom = custom
            self.claude = claude
        }
    }

    /// Characters kept of the first prompt, which states the task.
    static let firstPromptLimit = 1500

    /// The card's name: the name the user gave the session, else a title
    /// `titler` writes from the conversation, else Claude Code's own title.
    /// Nil when the transcript gives none of them.
    public static func name(
        transcriptPath path: String,
        titler: @Sendable (String) async throws -> String
    ) async -> String? {
        let titles = await Task.detached(priority: .utility) { Self.titles(path: path) }.value
        if let custom = titles.custom { return custom }
        if let digest = await digest(path: path) {
            do {
                let title = try await titler(digest)
                if !title.isEmpty { return title }
            } catch {
                KanbanCodeLog.warn("import", "No title for \((path as NSString).lastPathComponent): \(error.localizedDescription)")
            }
        }
        return titles.claude
    }

    /// The latest `custom-title` and `ai-title` records. A custom title
    /// Claude Code gave a branched session itself ("… (Branch)") is not the
    /// user's.
    public static func titles(path: String) -> Titles {
        var titles = Titles()
        try? TranscriptReader.scanRecordsBackwards(filePath: path) { _, line in
            if titles.custom == nil, line.contains("\"custom-title\""),
               let title = string(line, type: "custom-title", key: "customTitle"),
               !title.hasSuffix("(Branch)") {
                titles.custom = title
            }
            if titles.claude == nil, line.contains("\"ai-title\""),
               let title = string(line, type: "ai-title", key: "aiTitle") {
                titles.claude = title
            }
            return titles.custom != nil
        }
        return titles
    }

    /// The digest the title model reads once a session has answered: the first
    /// request, the agent's first reply, and the latest requests, for any
    /// assistant. Nil until the session has an assistant turn, so a card is
    /// only re-titled once there is a reply to read.
    public static func refinementDigest(sessionPath path: String, assistant: CodingAssistant) async -> String? {
        let store = ConversationExportCommand.sessionStore(for: assistant)
        guard let turns = try? await store.readTranscript(sessionPath: path) else { return nil }
        return refinementDigest(turns: turns, budget: TaskTitleGenerator.maxPromptCharacters)
    }

    static func refinementDigest(turns: [ConversationTurn], budget: Int) -> String? {
        guard turns.contains(where: { $0.role == "assistant" }) else { return nil }
        let users = turns.filter { $0.role == "user" && !$0.isQueued }
        guard let firstUser = users.first else { return nil }
        let first = stripped(firstUser.textPreview)
        guard !first.isEmpty else { return nil }
        let answer = turns.first { $0.role == "assistant" }.map { stripped($0.textPreview) }
        let later = users.dropFirst()
            .map { stripped($0.textPreview) }
            .filter { !$0.isEmpty && !isSameStart($0, first) }
        return refinementDigest(firstPrompt: first, answer: answer, laterPrompts: later, budget: budget)
    }

    /// The digest of the first request, the agent's first reply and the latest
    /// requests, within `budget` characters.
    static func refinementDigest(
        firstPrompt: String, answer: String?, laterPrompts: [String], budget: Int
    ) -> String? {
        var parts: [String] = []
        var used = 0
        let head = "First request:\n" + String(firstPrompt.prefix(budget / 2))
        parts.append(head)
        used += head.count
        if let answer, !answer.isEmpty {
            let line = "First reply:\n" + flat(answer, limit: 800)
            parts.append(line)
            used += line.count
        }
        var latest: [String] = []
        for prompt in laterPrompts.reversed() {
            let line = "- " + flat(prompt, limit: 300)
            if used + line.count + 1 > budget { break }
            latest.insert(line, at: 0)
            used += line.count + 1
        }
        if !latest.isEmpty {
            parts.append("Latest requests:\n" + latest.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }

    private static func stripped(_ text: String) -> String {
        InjectedPromptText.strip(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What the title model reads: the first prompt, which states the task,
    /// and the latest prompts, which say where it went. Nil when the human
    /// wrote nothing.
    public static func digest(path: String) async -> String? {
        let budget = TaskTitleGenerator.maxPromptCharacters
        let first = (try? await JsonlParser.extractMetadata(from: path, firstPromptLimit: firstPromptLimit))?
            .firstPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompts = await Task.detached(priority: .utility) { CardPromptReader.read(path: path) }.value
        let later = ((prompts?.earlier ?? []) + (prompts?.typed ?? []))
            .filter { !$0.isEmpty && !isSameStart($0, first) }
        return digest(firstPrompt: first, laterPrompts: later, budget: budget)
    }

    /// The digest of `firstPrompt` and `laterPrompts` (oldest first), within
    /// `budget` characters: the first prompt, then as many of the latest
    /// prompts as fit, each on a line of its own.
    static func digest(firstPrompt: String?, laterPrompts: [String], budget: Int) -> String? {
        var parts: [String] = []
        var used = 0
        if let firstPrompt, !firstPrompt.isEmpty {
            let head = "First request:\n" + String(firstPrompt.prefix(budget / 2))
            parts.append(head)
            used += head.count
        }
        var latest: [String] = []
        for prompt in laterPrompts.reversed() {
            let line = "- " + flat(prompt, limit: 300)
            if used + line.count + 1 > budget { break }
            latest.insert(line, at: 0)
            used += line.count + 1
        }
        if !latest.isEmpty {
            parts.append("Latest requests:\n" + latest.joined(separator: "\n"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    private static func flat(_ text: String, limit: Int) -> String {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return line.count > limit ? String(line.prefix(limit)) + " […]" : line
    }

    /// Whether `text` is the first prompt again: the later prompts may
    /// include it, cut short.
    private static func isSameStart(_ text: String, _ first: String?) -> Bool {
        guard let first, !first.isEmpty else { return false }
        let probe = text.replacingOccurrences(of: " [...]", with: "").prefix(80)
        return first.split(whereSeparator: \.isNewline).joined(separator: " ").hasPrefix(probe)
            || first.hasPrefix(probe)
    }

    private static func string(_ line: String, type: String, key: String) -> String? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["type"] as? String == type,
              let value = (obj[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}
