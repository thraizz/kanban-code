import Foundation

/// What the Mac knows about whether Rogerio is at it, reported by the Mac
/// master to itself and to its peers (`POST /v1/attention/presence`).
public struct MacPresence: Codable, Sendable, Equatable {
    /// Kanban Code is the frontmost app and its main window is key.
    public var isKanbanFrontmost: Bool
    /// The card whose drawer is open, if any.
    public var visibleCardId: String?
    /// The tab of that card on screen: "terminal", "chat", or another tab.
    public var visibleTab: String?
    /// Seconds since the last keyboard or mouse input.
    public var idleSeconds: Double
    public var screenLocked: Bool
    public var screensaverActive: Bool
    /// Lid closed with no external display (awake or not).
    public var lidClosed: Bool
    public var displayAsleep: Bool
    public var reportedAt: Date

    public init(
        isKanbanFrontmost: Bool = false, visibleCardId: String? = nil, visibleTab: String? = nil,
        idleSeconds: Double = 0, screenLocked: Bool = false, screensaverActive: Bool = false,
        lidClosed: Bool = false, displayAsleep: Bool = false, reportedAt: Date = .now
    ) {
        self.isKanbanFrontmost = isKanbanFrontmost
        self.visibleCardId = visibleCardId
        self.visibleTab = visibleTab
        self.idleSeconds = idleSeconds
        self.screenLocked = screenLocked
        self.screensaverActive = screensaverActive
        self.lidClosed = lidClosed
        self.displayAsleep = displayAsleep
        self.reportedAt = reportedAt
    }
}
