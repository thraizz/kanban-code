import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// The global view exclusions (`settings.globalView.excludedPaths`),
/// compiled once per settings change.
///
/// An entry is either a folder, which excludes itself and everything below
/// it, or a glob (`*`, `?`, `[`), matched against the full path and the
/// folder name.
public struct PathExclusion: Sendable, Equatable {
    public let patterns: [String]
    private let prefixes: [String]
    private let globs: [String]
    /// Prefixes a Claude Code project directory name must start with to
    /// hold an excluded path; nil when a glob can match any folder name.
    private let claudeDirPrefixes: [String]?

    public static let none = PathExclusion([])

    public init(_ patterns: [String]) {
        self.patterns = patterns
        var prefixes: [String] = []
        var globs: [String] = []
        var dirPrefixes: [String]? = []
        for raw in patterns {
            let pattern = raw.trimmingCharacters(in: .whitespaces)
            guard !pattern.isEmpty else { continue }
            if let wildcard = pattern.firstIndex(where: { $0 == "*" || $0 == "?" || $0 == "[" }) {
                globs.append(pattern)
                // A glob starting at "/" only matches full paths: the literal
                // part before the first wildcard is a prefix of every match.
                let literal = String(pattern[..<wildcard])
                if literal.hasPrefix("/") {
                    dirPrefixes?.append(Self.claudeProjectDirName(literal))
                } else {
                    dirPrefixes = nil
                }
            } else {
                let normalized = ProjectDiscovery.normalizePath(pattern)
                prefixes.append(normalized)
                dirPrefixes?.append(Self.claudeProjectDirName(normalized))
            }
        }
        self.prefixes = prefixes
        self.globs = globs
        self.claudeDirPrefixes = dirPrefixes
    }

    public var isEmpty: Bool { prefixes.isEmpty && globs.isEmpty }

    /// Whether `path` is excluded from the global view.
    public func matches(_ path: String?) -> Bool {
        guard let path, !isEmpty else { return false }
        let normalized = ProjectDiscovery.normalizePath(path)
        for prefix in prefixes {
            if normalized == prefix || normalized.hasPrefix(prefix + "/") { return true }
        }
        guard !globs.isEmpty else { return false }
        let name = (normalized as NSString).lastPathComponent
        for glob in globs {
            if fnmatch(glob, normalized, 0) == 0 || fnmatch(glob, name, 0) == 0 { return true }
        }
        return false
    }

    /// Whether sessions in the Claude Code project directory `dirName`
    /// (under ~/.claude/projects) can have an excluded working directory.
    /// A false answer is certain; a true one still needs the real path.
    public func mayMatchClaudeProjectDir(_ dirName: String) -> Bool {
        guard !isEmpty else { return false }
        guard let claudeDirPrefixes else { return true }
        return claudeDirPrefixes.contains { dirName.hasPrefix($0) }
    }

    /// Claude Code names a project directory after its path with every
    /// character other than an ASCII letter or digit turned into "-".
    static func claudeProjectDirName(_ path: String) -> String {
        String(path.unicodeScalars.map { scalar -> Character in
            scalar.isASCII && CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
        })
    }
}
