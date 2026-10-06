import Foundation

/// Detects Pi session activity from Kanban's Pi extension, with the session
/// file's modification time as fallback.
///
/// The extension (see `PiExtension`) writes the canonical hook events:
/// `UserPromptSubmit` when a run starts, `Stop` once Pi has settled,
/// `Notification` while an extension dialog waits for an answer. Without the
/// extension, a recent write to the session file is the signal: Pi appends
/// every message and tool result as it finishes.
public actor PiActivityDetector: ActivityDetector {
    private var polledStates: [String: ActivityState] = [:]
    private var hookStates: [String: ActivityState] = [:]
    private var lastEventTime: [String: Date] = [:]
    private let activeThreshold: TimeInterval
    private let attentionThreshold: TimeInterval

    public init(activeThreshold: TimeInterval = 120, attentionThreshold: TimeInterval = 300) {
        self.activeThreshold = activeThreshold
        self.attentionThreshold = attentionThreshold
    }

    // MARK: - ActivityDetector

    public func handleHookEvent(_ event: HookEvent) async {
        // The composite detector hands every event to every detector: only
        // Pi's own sessions may set state here.
        guard let path = event.transcriptPath, CodingAssistant.pi.owns(sessionPath: path) else { return }
        lastEventTime[event.sessionId] = event.timestamp

        switch HookManager.normalizeEventName(event.eventName) {
        case "UserPromptSubmit":
            hookStates[event.sessionId] = .activelyWorking
        case "SessionStart":
            hookStates[event.sessionId] = .idleWaiting
        case "Stop":
            hookStates[event.sessionId] = .needsAttention
        case "Notification":
            // Pi never asks on its own; this is an extension's dialog, and
            // the run waits until the user answers it.
            hookStates[event.sessionId] = .awaitingPermission
        case "SessionEnd":
            hookStates[event.sessionId] = .ended
        default:
            break
        }
    }

    public func pollActivity(sessionPaths: [String: String]) async -> [String: ActivityState] {
        let owned = sessionPaths.filter { CodingAssistant.pi.owns(sessionPath: $0.value) }
        guard !owned.isEmpty else { return [:] }

        var states: [String: ActivityState] = [:]
        for (sessionId, path) in owned {
            let lastWrite = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            if let hookState = hookStates[sessionId] {
                // A long tool run sends no events: stay "working" while the
                // file is still being written, downgrade once both the
                // extension and the file have gone quiet.
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
            states[sessionId] = OpenCodeActivityDetector.state(
                sinceLastWrite: Date.now.timeIntervalSince(lastWrite),
                active: activeThreshold, attention: attentionThreshold)
        }

        for (id, state) in states { polledStates[id] = state }
        return states
    }

    public func activityState(for sessionId: String) async -> ActivityState {
        hookStates[sessionId] ?? polledStates[sessionId] ?? .stale
    }
}
