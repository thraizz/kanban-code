import Foundation

/// Detects Codex CLI activity from session file modification times.
///
/// Codex does not currently expose the same settings-hook contract that Claude
/// Code and Gemini CLI use, so polling is the source of truth.
public actor CodexActivityDetector: ActivityDetector {
    private var polledStates: [String: ActivityState] = [:]
    private let activeThreshold: TimeInterval
    private let attentionThreshold: TimeInterval

    public init(activeThreshold: TimeInterval = 120, attentionThreshold: TimeInterval = 300) {
        self.activeThreshold = activeThreshold
        self.attentionThreshold = attentionThreshold
    }

    public func handleHookEvent(_ event: HookEvent) async {
        // Hooks are unsupported for Codex; activity comes from file polling.
    }

    public func pollActivity(sessionPaths: [String: String]) async -> [String: ActivityState] {
        // Drop session paths clearly owned by another assistant. Codex has no
        // hooks, so every recently-modified file it sees looks `.activelyWorking`.
        // Without this filter a just-archived Claude session's transcript
        // (mtime a few seconds ago from the SessionEnd flush) tags
        // `.activelyWorking` here, then the composite-detector priority merge
        // picks it over Claude's correct `.ended` and auto-unarchives the card.
        let filtered = sessionPaths.filter { !CodingAssistant.codex.ownedByOther(sessionPath: $0.value) }

        let fileManager = FileManager.default
        var states: [String: ActivityState] = [:]

        for (sessionId, path) in filtered {
            guard let attrs = try? fileManager.attributesOfItem(atPath: path),
                  let mtime = attrs[.modificationDate] as? Date else {
                states[sessionId] = .ended
                continue
            }

            let timeSinceModified = Date.now.timeIntervalSince(mtime)
            if timeSinceModified < activeThreshold {
                states[sessionId] = .activelyWorking
            } else if timeSinceModified < attentionThreshold {
                states[sessionId] = .needsAttention
            } else if timeSinceModified < 86400 {
                // Quiet is not an exit: the process may still be open in a
                // terminal. `.ended` (which moves a card to Done) is kept for
                // a real end signal.
                states[sessionId] = .idleWaiting
            } else {
                states[sessionId] = .stale
            }
        }

        for (id, state) in states {
            polledStates[id] = state
        }

        return states
    }

    public func activityState(for sessionId: String) async -> ActivityState {
        polledStates[sessionId] ?? .stale
    }
}
