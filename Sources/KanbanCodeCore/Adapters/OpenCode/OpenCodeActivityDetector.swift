import Foundation

/// Detects OpenCode session activity from Kanban's OpenCode plugin, with the
/// session database as fallback.
///
/// The plugin (see `OpenCodePlugin`) writes the canonical hook events:
/// `UserPromptSubmit` when a session turns busy or a permission was answered,
/// `Notification` when OpenCode asks for a permission, `Stop` when the
/// session goes idle. Without the plugin, the last write to the session in
/// the database is the signal; it is weaker, because nothing is written while
/// a permission prompt waits.
public actor OpenCodeActivityDetector: ActivityDetector {
    private let database: OpenCodeDatabase
    private var polledStates: [String: ActivityState] = [:]
    private var hookStates: [String: ActivityState] = [:]
    private var lastEventTime: [String: Date] = [:]
    private let activeThreshold: TimeInterval
    private let attentionThreshold: TimeInterval

    public init(
        database: OpenCodeDatabase = OpenCodeDatabase(),
        activeThreshold: TimeInterval = 120,
        attentionThreshold: TimeInterval = 300
    ) {
        self.database = database
        self.activeThreshold = activeThreshold
        self.attentionThreshold = attentionThreshold
    }

    // MARK: - ActivityDetector

    public func handleHookEvent(_ event: HookEvent) async {
        // The composite detector hands every event to every detector: only
        // OpenCode's own sessions may set state here.
        guard Self.isOpenCodeEvent(event) else { return }
        lastEventTime[event.sessionId] = event.timestamp

        switch HookManager.normalizeEventName(event.eventName) {
        case "UserPromptSubmit":
            hookStates[event.sessionId] = .activelyWorking
        case "SessionStart":
            hookStates[event.sessionId] = .idleWaiting
        case "Stop", "Notification":
            hookStates[event.sessionId] = .needsAttention
        case "SessionEnd":
            hookStates[event.sessionId] = .ended
        default:
            break
        }
    }

    public func pollActivity(sessionPaths: [String: String]) async -> [String: ActivityState] {
        let owned = sessionPaths.filter { OpenCodeDatabase.isVirtualSessionPath($0.value) }
        guard !owned.isEmpty else { return [:] }
        let activity = (try? database.lastActivity(sessionIds: Array(owned.keys))) ?? [:]

        var states: [String: ActivityState] = [:]
        for sessionId in owned.keys {
            let lastWrite = activity[sessionId]
            if let hookState = hookStates[sessionId] {
                // A long tool run sends no events: stay "working" while the
                // session is still being written, downgrade once both the
                // plugin and the database have gone quiet.
                if hookState == .activelyWorking,
                   let lastTime = lastEventTime[sessionId],
                   Date.now.timeIntervalSince(max(lastTime, lastWrite ?? .distantPast)) > attentionThreshold {
                    hookStates[sessionId] = .needsAttention
                    states[sessionId] = .needsAttention
                } else {
                    states[sessionId] = hookState
                }
                continue
            }

            guard let lastWrite else {
                states[sessionId] = .ended
                continue
            }
            states[sessionId] = Self.state(sinceLastWrite: Date.now.timeIntervalSince(lastWrite),
                                           active: activeThreshold, attention: attentionThreshold)
        }

        for (id, state) in states { polledStates[id] = state }
        return states
    }

    public func activityState(for sessionId: String) async -> ActivityState {
        hookStates[sessionId] ?? polledStates[sessionId] ?? .stale
    }

    // MARK: - Helpers

    static func isOpenCodeEvent(_ event: HookEvent) -> Bool {
        if let path = event.transcriptPath, !path.isEmpty {
            return OpenCodeDatabase.isVirtualSessionPath(path)
        }
        return false
    }

    static func state(sinceLastWrite elapsed: TimeInterval, active: TimeInterval, attention: TimeInterval) -> ActivityState {
        if elapsed < active { return .activelyWorking }
        if elapsed < attention { return .needsAttention }
        if elapsed < 3600 { return .idleWaiting }
        if elapsed < 86400 { return .ended }
        return .stale
    }
}
