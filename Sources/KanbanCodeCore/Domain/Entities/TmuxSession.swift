import Foundation

/// A tmux session discovered via `tmux list-sessions`.
public struct TmuxSession: Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let path: String // session_path
    public let attached: Bool
    /// A rush host's queued messages; nil for tmux sessions.
    public let rushQueue: [String]?
    /// What a blocked rush host waits on (see `RushSessionInfo.needs`).
    public let rushNeeds: String?

    public init(name: String, path: String, attached: Bool = false, rushQueue: [String]? = nil, rushNeeds: String? = nil) {
        self.name = name
        self.path = path
        self.attached = attached
        self.rushQueue = rushQueue
        self.rushNeeds = rushNeeds
    }
}
