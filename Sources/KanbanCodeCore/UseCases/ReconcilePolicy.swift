import Foundation

/// How often the full reconcile pass runs.
///
/// Hook events, the tmux watch and explicit reconciles after user actions
/// carry the real-time updates. When those event sources are known to work,
/// the full pass is only a slow safety net for missed events; otherwise it is
/// the main way the board learns about changes and stays fast.
public enum ReconcilePolicy {
    public static let activeFallback: Duration = .seconds(3)
    public static let backgroundFallback: Duration = .seconds(10)
    public static let eventDriven: Duration = .seconds(30)

    public static func interval(appIsActive: Bool, eventSourcesHealthy: Bool) -> Duration {
        if eventSourcesHealthy { return eventDriven }
        return appIsActive ? activeFallback : backgroundFallback
    }

    /// Whether hook events can be relied on.
    ///
    /// - The hook file watcher must be running.
    /// - At least one enabled assistant must have its hooks installed.
    /// - Every enabled assistant that has sessions on the board must report
    ///   through hooks; one that is only followed by polling its session
    ///   files (Codex, or an assistant whose hooks are missing) needs the
    ///   fast poll.
    public static func eventSourcesHealthy(
        hookWatcherRunning: Bool,
        enabledAssistants: [CodingAssistant],
        hooksInstalled: Set<CodingAssistant>,
        assistantsWithSessions: Set<CodingAssistant>
    ) -> Bool {
        guard hookWatcherRunning else { return false }
        let enabled = Set(enabledAssistants)
        guard !enabled.isDisjoint(with: hooksInstalled) else { return false }
        for assistant in assistantsWithSessions.intersection(enabled) {
            guard assistant.supportsHooks, hooksInstalled.contains(assistant) else { return false }
        }
        return true
    }
}
