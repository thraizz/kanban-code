import Foundation

/// GitHub issue/PR references (`owner/repo#123`, `repo#123`, `#123`) in
/// chat and transcript text, and the URLs they resolve to.
enum GitHubIssueRef {
    /// The reference itself, shared by every place that turns one into a link
    /// so they cannot drift apart on what counts as one.
    static let body = #"(?:[a-zA-Z0-9_.-]+/)?[a-zA-Z0-9_.-]*#\d+"#

    /// A reference in text that is about to be parsed as markdown, where one
    /// already inside a link must be left alone. The lookbehind excludes
    /// matches inside URLs, hex colors, or HTML entities.
    static let markdownPattern =
        #"(?<![&/a-zA-Z0-9\[(\]])"# + Self.body + #"(?![^\[]*\])"#

    /// Resolve a GitHub issue reference to a URL.
    /// `"langwatch/langwatch#2847"` → `"https://github.com/langwatch/langwatch/pull/2847"`
    /// `"scenario#41"` → the same owner as the card's repo
    /// `"#123"` → uses `githubBaseURL` from the card's project
    static func resolve(_ ref: String, githubBaseURL: String?) -> String? {
        guard let hashIndex = ref.firstIndex(of: "#") else { return nil }
        let numberStr = String(ref[ref.index(after: hashIndex)...])
        guard let number = Int(numberStr) else { return nil }

        let prefix = String(ref[ref.startIndex..<hashIndex])
        if prefix.isEmpty {
            guard let base = githubBaseURL else { return nil }
            return "\(base)/pull/\(number)"
        }
        if !prefix.contains("/") {
            // A repo on its own is written when it is a sibling of the one in
            // hand, so the owner comes from the card's repo.
            guard let owner = self.owner(of: githubBaseURL) else { return nil }
            return "https://github.com/\(owner)/\(prefix)/pull/\(number)"
        }
        return "https://github.com/\(prefix)/pull/\(number)"
    }

    /// The owner segment of a repo URL, whatever else is around it.
    static func owner(of githubBaseURL: String?) -> String? {
        guard let githubBaseURL else { return nil }
        let parts = githubBaseURL.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        return parts[parts.count - 2]
    }
}
