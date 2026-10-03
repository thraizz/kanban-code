import Foundation

/// A hook event received from the AI CLI's hook system.
public struct HookEvent: Sendable {
    public let sessionId: String
    public let eventName: String // UserPromptSubmit, Stop, Notification, PreToolUse, etc.
    public let transcriptPath: String?
    public let notificationType: String?
    /// Notification only: the text Claude shows, e.g. "Claude needs your
    /// permission to use Bash".
    public let message: String?
    /// SessionStart only: startup, resume, clear, or compact. Tells a real
    /// fresh start apart from a compaction of a live session.
    public let source: String?
    public let timestamp: Date

    public init(
        sessionId: String,
        eventName: String,
        transcriptPath: String? = nil,
        notificationType: String? = nil,
        message: String? = nil,
        source: String? = nil,
        timestamp: Date = .now
    ) {
        self.sessionId = sessionId
        self.eventName = eventName
        self.transcriptPath = transcriptPath
        self.notificationType = notificationType
        self.message = message
        self.source = source
        self.timestamp = timestamp
    }
}

/// Port for detecting session activity state.
public protocol ActivityDetector: Sendable {
    /// Process an incoming hook event.
    func handleHookEvent(_ event: HookEvent) async

    /// Poll activity for sessions that don't have hooks.
    func pollActivity(sessionPaths: [String: String]) async -> [String: ActivityState]

    /// Get the current activity state for a session.
    func activityState(for sessionId: String) async -> ActivityState

    /// Resolve pending stop events (returns resolved session IDs).
    func resolvePendingStops() async -> [String]
}

extension ActivityDetector {
    public func resolvePendingStops() async -> [String] { [] }
}
