import Foundation

/// What keeps the main assistant session of a card running.
public enum SessionRuntime: String, Codable, Sendable, CaseIterable {
    /// A tmux session running the assistant's interactive CLI.
    case tmux
    /// A rush host (`rush host run <id>`) running Claude Code headless. The
    /// card's terminal shows it with `rush open <id>`. The stored value stays
    /// "agtop", the name rush had before it was renamed.
    case agtop

    public var displayName: String {
        switch self {
        case .tmux: "tmux"
        case .agtop: "rush"
        }
    }
}

/// The session name a card keeps in `tmuxLink.sessionName` for an agtop
/// session. The name carries the agtop id, so every layer (the app, the
/// CLI, the terminal) routes it without shared state. Extra shell tabs are
/// named `<primary>-shN` and stay on tmux.
public enum AgtopSessionName {
    public static let prefix = "agtop-"

    /// The agtop id of a Claude session: the first 8 hex characters of its id.
    public static func agtopId(sessionId: String) -> String {
        String(sessionId.filter { $0 != "-" }.prefix(8))
    }

    public static func name(sessionId: String) -> String {
        prefix + agtopId(sessionId: sessionId)
    }

    public static func name(agtopId: String) -> String {
        prefix + agtopId
    }

    /// The agtop id in a session name, or nil when the name is not an agtop
    /// session (a tmux session, or an extra shell of an agtop card).
    public static func agtopId(fromName name: String) -> String? {
        guard name.hasPrefix(prefix) else { return nil }
        let id = name.dropFirst(prefix.count)
        guard id.count == 8, id.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
        return String(id)
    }

    public static func isAgtop(_ name: String) -> Bool {
        agtopId(fromName: name) != nil
    }
}
