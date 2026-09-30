import Foundation

/// Rules that keep discovered sessions off the board by what their prompt
/// says: recurring scheduled tasks, bots, scripts. A card someone claimed
/// (created, launched, named, pinned, gave work to) is never hidden.
public struct SessionExclusion: Codable, Sendable, Equatable {
    /// Hide sessions Claude Desktop starts from a scheduled task
    /// (the prompt starts with `<scheduled-task name="...">`).
    public var hideScheduledTasks: Bool
    /// Patterns matched case-insensitively against the session's prompt and
    /// title. A pattern with `*`, `?` or `[` is a glob over the whole text;
    /// any other pattern matches when the text contains it.
    public var titlePatterns: [String]

    public init(hideScheduledTasks: Bool = false, titlePatterns: [String] = []) {
        self.hideScheduledTasks = hideScheduledTasks
        self.titlePatterns = titlePatterns
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hideScheduledTasks = (try? c.decodeIfPresent(Bool.self, forKey: .hideScheduledTasks)) ?? false
        titlePatterns = (try? c.decodeIfPresent([String].self, forKey: .titlePatterns)) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case hideScheduledTasks, titlePatterns
    }

    public var isEmpty: Bool {
        !hideScheduledTasks && !titlePatterns.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// True when the card is an unclaimed session these rules hide.
    public func excludes(link: Link, session: Session?) -> Bool {
        guard !isEmpty, !link.isClaimed else { return false }
        let texts = [link.promptBody, session?.firstPrompt, link.displayTitle]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if hideScheduledTasks, texts.contains(where: Self.isScheduledTask) { return true }
        for pattern in titlePatterns {
            let pattern = pattern.trimmingCharacters(in: .whitespaces)
            guard !pattern.isEmpty else { continue }
            if texts.contains(where: { Self.matches(pattern: pattern, text: $0) }) { return true }
        }
        return false
    }

    /// True when the prompt is one Claude Desktop sends for a scheduled task.
    public static func isScheduledTask(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<scheduled-task")
    }

    public static func matches(pattern: String, text: String) -> Bool {
        if pattern.contains(where: { "*?[".contains($0) }) {
            return fnmatch(pattern, text, FNM_CASEFOLD) == 0
        }
        return text.range(of: pattern, options: .caseInsensitive) != nil
    }
}
