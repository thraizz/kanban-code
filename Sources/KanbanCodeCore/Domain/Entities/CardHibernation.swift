import Foundation

/// Why the app stopped a card's session to give its memory back. The card
/// keeps its session link, so a resume picks the conversation up again.
public enum HibernationReason: String, Codable, Sendable, Equatable, CaseIterable {
    /// The card sat in Done.
    case done
    /// The card waited for the user for longer than the idle limit.
    case idle
    /// More sessions ran than the configured maximum.
    case sessionLimit
    /// macOS reported critical memory pressure.
    case memoryPressure

    public var label: String {
        switch self {
        case .done: "finished"
        case .idle: "idle"
        case .sessionLimit: "over the session limit"
        case .memoryPressure: "memory pressure"
        }
    }
}

public struct CardHibernation: Codable, Sendable, Equatable {
    public var at: Date
    public var reason: HibernationReason

    public init(at: Date = .now, reason: HibernationReason) {
        self.at = at
        self.reason = reason
    }
}

/// What the processes under one card's terminals take, as last measured.
public struct CardMemory: Sendable, Equatable {
    /// Every process under the card's tmux panes, browsers included.
    public var totalBytes: Int
    /// Browsers a Playwright MCP server opened for the card.
    public var browserBytes: Int
    /// The top process of each of those browsers, which closes the rest.
    public var browserPids: [Int32]
    /// The biggest single process, for the tooltip.
    public var topCommand: String
    public var topBytes: Int
    /// Over the warning limit of Settings > Resources.
    public var exceedsWarning: Bool

    public init(totalBytes: Int, browserBytes: Int = 0, browserPids: [Int32] = [], topCommand: String = "", topBytes: Int = 0,
                exceedsWarning: Bool = false) {
        self.exceedsWarning = exceedsWarning
        self.totalBytes = totalBytes
        self.browserBytes = browserBytes
        self.browserPids = browserPids
        self.topCommand = topCommand
        self.topBytes = topBytes
    }

    /// Rounded to 64 MiB, so a scan that moves a few pages does not
    /// rebuild every card.
    public var rounded: CardMemory {
        let step = 64 * 1024 * 1024
        var copy = self
        copy.totalBytes = (totalBytes / step) * step
        copy.browserBytes = (browserBytes / step) * step
        copy.topBytes = (topBytes / step) * step
        return copy
    }

    public static func format(_ bytes: Int) -> String {
        let gib = Double(bytes) / 1_073_741_824
        if gib >= 1 { return String(format: "%.1f GB", gib) }
        return "\(bytes / 1_048_576) MB"
    }
}
