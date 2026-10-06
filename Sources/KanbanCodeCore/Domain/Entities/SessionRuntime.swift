import Foundation

/// What keeps the main assistant session of a card running.
///
/// Stored as "tmux" or "agtop". The rush case keeps the value it had
/// before rush was renamed from agtop: settings and remote boards are read
/// by older builds of the app, the box server and the iOS app, which know
/// only "agtop". Reading takes "rush" too, so a later build may write it
/// once every reader understands it.
public enum SessionRuntime: String, Codable, Sendable, CaseIterable {
    /// A tmux session running the assistant's interactive CLI.
    case tmux
    /// A rush host (`rush host run <id>`) running Claude Code headless. The
    /// card's terminal shows it with `rush open <id>`.
    case rush = "agtop"

    /// The runtime a stored value names, either name of rush included.
    public init?(stored value: String) {
        switch value {
        case "tmux": self = .tmux
        case "rush", "agtop": self = .rush
        default: return nil
        }
    }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let runtime = SessionRuntime(stored: value) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: "Unknown session runtime \(value)"))
        }
        self = runtime
    }

    public var displayName: String {
        switch self {
        case .tmux: "tmux"
        case .rush: "rush"
        }
    }
}

/// The session name a card keeps in `tmuxLink.sessionName` for a rush
/// session: `rush-<id>`, or `agtop-<id>` for a host started before rush was
/// renamed from agtop. The name carries the rush id, so every layer (the
/// app, the CLI, the terminal) routes it without shared state. Extra shell
/// tabs are named `<primary>-shN` and stay on tmux.
///
/// A host keeps the name it started with: Kanban passes it as
/// `--meta kanban_session=<name>`, and a host without that meta was started
/// under the old name. `cli/src/data.ts` follows the same rules.
public enum RushSessionName {
    public static let prefix = "rush-"
    /// The prefix of hosts started before the rename.
    public static let legacyPrefix = "agtop-"
    /// The host meta key that holds the session name.
    public static let metaKey = "kanban_session"

    /// The rush id of a Claude session: the first 8 hex characters of its id.
    public static func rushId(sessionId: String) -> String {
        String(sessionId.filter { $0 != "-" }.prefix(8))
    }

    /// The name a new host of `sessionId` gets.
    public static func name(sessionId: String) -> String {
        prefix + rushId(sessionId: sessionId)
    }

    /// The name a new host with id `rushId` gets.
    public static func name(rushId: String) -> String {
        prefix + rushId
    }

    /// Both names a host with id `rushId` may have, the new one first.
    public static func names(rushId: String) -> [String] {
        [prefix + rushId, legacyPrefix + rushId]
    }

    /// The name of `host`: the one in its meta when that names this host,
    /// the old name otherwise.
    public static func name(for host: RushSessionInfo) -> String {
        if let named = host.meta?[metaKey], rushId(fromName: named) == host.id { return named }
        return legacyPrefix + host.id
    }

    /// The rush id in a session name, or nil when the name is not a rush
    /// session (a tmux session, or an extra shell of a rush card).
    public static func rushId(fromName name: String) -> String? {
        guard let used = [prefix, legacyPrefix].first(where: { name.hasPrefix($0) }) else { return nil }
        let id = name.dropFirst(used.count)
        guard id.count == 8, id.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
        return String(id)
    }

    public static func isRush(_ name: String) -> Bool {
        rushId(fromName: name) != nil
    }
}
