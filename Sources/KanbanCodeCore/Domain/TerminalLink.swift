import Foundation

/// What to do with a link clicked in a terminal. The target comes from
/// terminal output, so it must not reach Launch Services unchecked: a crafted
/// link could otherwise run an app bundle, a script or a custom-scheme handler.
/// (Follows the policy of Ghostty's own macOS app.)
public enum TerminalLink: Equatable, Sendable {
    /// Open directly (web, mail, and local files that cannot run code).
    case open(URL)
    /// A custom scheme: open only after the user confirms.
    case confirm(URL)
    /// Never open.
    case deny

    /// Classifies `value`, a URL or an absolute path (Ghostty resolves
    /// relative paths before handing them over).
    public static func classify(_ value: String) -> TerminalLink {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !containsUnsafeCharacters(trimmed) else { return .deny }

        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), !scheme.isEmpty {
            switch scheme {
            case "http", "https":
                guard let host = url.host, !host.isEmpty else { return .deny }
                return .open(url)
            case "mailto":
                guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), !c.path.isEmpty else { return .deny }
                return .open(url)
            case "file":
                return fileDecision(url)
            default:
                return .confirm(url)
            }
        }

        // A path: absolute or ~-relative.
        let expanded = NSString(string: trimmed).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return .deny }
        return fileDecision(URL(filePath: expanded))
    }

    private static func fileDecision(_ url: URL) -> TerminalLink {
        guard url.isFileURL, url.query == nil, url.fragment == nil else { return .deny }
        if let host = url.host, !host.isEmpty, host.caseInsensitiveCompare("localhost") != .orderedSame {
            return .deny
        }
        let target = url.standardizedFileURL.resolvingSymlinksInPath()
        guard let values = try? target.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isExecutableKey]) else {
            return .deny
        }
        let isDirectory = values.isDirectory == true
        guard isDirectory || values.isRegularFile == true else { return .deny }
        if unsafeExtensions.contains(target.pathExtension.lowercased()) { return .deny }
        if !isDirectory, values.isExecutable == true { return .deny }
        return .open(target)
    }

    /// Bundles, installers and scripts that Launch Services would run.
    static let unsafeExtensions: Set<String> = [
        "app", "appex", "action", "workflow", "command", "tool", "terminal", "sh", "zsh", "bash",
        "csh", "ksh", "tcsh", "fish", "py", "rb", "pl", "php", "js", "jxa", "scpt", "scptd",
        "applescript", "pkg", "mpkg", "dmg", "jar", "prefpane", "saver", "kext", "plugin",
        "bundle", "framework", "dylib", "webloc", "fileloc", "inetloc", "url", "mobileconfig",
        "osax", "qlgenerator", "mdimporter", "xpc", "service",
    ]

    /// Control, invisible and text-reversing characters, which could make the
    /// shown link differ from the opened one.
    static func containsUnsafeCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: return true
            default: return false
            }
        }
    }
}
