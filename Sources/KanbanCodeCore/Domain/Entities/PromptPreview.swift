import Foundation

/// Short copies of long prompts.
///
/// A card whose session exists does not need its whole first prompt in
/// memory or in links.json: the transcript holds it. Such cards keep the
/// first `discoveredLimit` characters (enough for names, search and
/// display), or `userLimit` for prompts a user wrote on the board, followed
/// by `marker`. Code that re-sends or shows the whole prompt reads it back
/// with `PromptPreview.fullPrompt(for:)`.
public enum PromptPreview {
    /// Characters kept for a discovered session's prompt.
    public static let discoveredLimit = 4_000
    /// Characters kept for a prompt written on the board once its session exists.
    public static let userLimit = 64_000
    /// Appended to a shortened prompt.
    public static let marker = "\n\n[prompt shortened, the full text is in the session transcript]"

    public static func isPreview(_ text: String) -> Bool {
        text.hasSuffix(marker)
    }

    /// `text` cut to `limit` characters plus `marker`, or `text` as is when
    /// it fits or is already a preview.
    public static func make(_ text: String, limit: Int) -> String {
        // UTF-8 length bounds the character count, so most prompts skip the
        // character walk.
        guard text.utf8.count > limit, !isPreview(text), text.count > limit else { return text }
        return String(text.prefix(limit)) + marker
    }

    /// `text` without `marker`.
    public static func stripMarker(_ text: String) -> String {
        isPreview(text) ? String(text.dropLast(marker.count)) : text
    }

    /// The prompt body `link` should keep: the whole body while the card has
    /// no session or sits in the backlog (it launches with it), a preview
    /// once a session holds the prompt.
    public static func trimmedBody(of link: Link) -> String? {
        guard let body = link.promptBody, link.sessionLink != nil, link.column != .backlog else {
            return link.promptBody
        }
        return make(body, limit: link.source == .discovered ? discoveredLimit : userLimit)
    }

    /// Whether `link.promptBody` is a preview of a longer prompt.
    public static func isPreview(_ link: Link) -> Bool {
        link.promptBody.map(isPreview) ?? false
    }

    /// The whole first prompt of `link`: its body, or when that is a
    /// preview, the first prompt read back from the Claude transcript
    /// (falling back to the preview without its marker).
    public static func fullPrompt(for link: Link, transcriptPath: String? = nil) async -> String? {
        guard let body = link.promptBody else { return nil }
        guard isPreview(body) else { return body }
        if let path = transcriptPath ?? link.sessionLink?.sessionPath,
           let full = try? await JsonlParser.extractMetadata(from: path, firstPromptLimit: nil)?.firstPrompt,
           !full.isEmpty {
            return full
        }
        return stripMarker(body)
    }
}

/// Counts links whose prompt body was shortened while decoding, so the
/// store that read them can write the shorter file back once.
public final class PromptTrimReport: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0

    public init() {}

    public var count: Int { lock.withLock { _count } }

    func record() { lock.withLock { _count += 1 } }

    public static let userInfoKey = CodingUserInfoKey(rawValue: "kanban.promptTrimReport")!
}
