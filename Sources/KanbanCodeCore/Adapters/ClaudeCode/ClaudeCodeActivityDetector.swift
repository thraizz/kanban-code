import Foundation

/// Detects Claude Code session activity from hook events and .jsonl file polling.
public actor ClaudeCodeActivityDetector: ActivityDetector {
    /// Stores the last known event per session.
    private var lastEvents: [String: HookEvent] = [:]
    /// Stores the last known mtime per session (for polling fallback).
    private var lastMtimes: [String: Date] = [:]
    /// Stores the last polled activity state per session.
    private var polledStates: [String: ActivityState] = [:]
    /// Session transcript paths (populated by pollActivity, used for direct mtime checks).
    private var sessionPaths: [String: String] = [:]
    /// Sessions that received a Stop but might get a follow-up prompt.
    private var pendingStops: [String: Date] = [:]
    /// Last time UserPromptSubmit was seen per session — survives later Stop/Notification events.
    /// Used by Stop/Notification handlers to tell "mid-conversation" from "dormant session".
    private var lastUserPromptTimes: [String: Date] = [:]
    /// Delay before treating a Stop as final (seconds).
    private let stopDelay: TimeInterval
    /// When each subagent still running under a session was started.
    ///
    /// A subagent sent to the background outlives the turn that started it:
    /// the main agent goes back to the prompt, Stop fires, and the work
    /// carries on. Nothing else reports it, because the transcript gets no
    /// lines while a subagent works.
    private var runningSubagents: [String: [Date]] = [:]
    /// How long a subagent counts as running without its stop event.
    ///
    /// A session killed while its subagents work never sends them, and the
    /// card would show work that nothing is doing.
    private let subagentTimeout: TimeInterval

    public init(
        stopDelay: TimeInterval = 3.0,
        activeTimeout: TimeInterval = 300,
        toolCallTimeout: TimeInterval = 30 * 60,
        subagentTimeout: TimeInterval = 2 * 60 * 60
    ) {
        self.stopDelay = stopDelay
        self.activeTimeout = activeTimeout
        self.toolCallTimeout = toolCallTimeout
        self.subagentTimeout = subagentTimeout
    }

    public func handleHookEvent(_ event: HookEvent) async {
        // Drop events whose transcriptPath is clearly owned by another assistant.
        // The composite detector forwards every event to every detector, and
        // without this check a Gemini UserPromptSubmit would stamp
        // `.activelyWorking` into Claude's lastEvents for a non-Claude session.
        // Paths that aren't under any known assistant dir (e.g. test fixtures)
        // still pass through, so tests don't need to mirror the real layout.
        if let path = event.transcriptPath,
           !path.isEmpty,
           CodingAssistant.claude.ownedByOther(sessionPath: path) {
            return
        }

        // Subagent events say what runs under the session, not what the
        // session itself is doing, so they must not become its last event.
        if event.eventName == "SubagentStart" {
            runningSubagents[event.sessionId, default: []].append(event.timestamp)
            return
        }
        if event.eventName == "SubagentStop" {
            var running = runningSubagents[event.sessionId] ?? []
            if !running.isEmpty { running.removeFirst() }
            runningSubagents[event.sessionId] = running.isEmpty ? nil : running
            return
        }

        // A compaction fires SessionStart inside the same living process:
        // the turn, its pending stop, and its background subagents all carry
        // on through it, so it must not touch any of the session's state.
        if event.eventName == "SessionStart", event.source == "compact" {
            return
        }

        lastEvents[event.sessionId] = event

        if event.eventName == "Stop" {
            // Record stop — will be resolved after stopDelay if no follow-up prompt
            pendingStops[event.sessionId] = event.timestamp
        } else if event.eventName == "UserPromptSubmit" {
            // Clear pending stops on any new activity
            pendingStops.removeValue(forKey: event.sessionId)
            lastUserPromptTimes[event.sessionId] = event.timestamp
        } else if event.eventName == "SessionStart" {
            pendingStops.removeValue(forKey: event.sessionId)
            runningSubagents.removeValue(forKey: event.sessionId)
        } else if event.eventName == "SessionEnd" {
            runningSubagents.removeValue(forKey: event.sessionId)
        }
    }

    /// Whether the session still has subagents working under it.
    private func hasRunningSubagents(_ sessionId: String) -> Bool {
        guard let started = runningSubagents[sessionId], !started.isEmpty else { return false }
        let cutoff = Date.now.addingTimeInterval(-subagentTimeout)
        let live = started.filter { $0 > cutoff }
        if live.count != started.count {
            runningSubagents[sessionId] = live.isEmpty ? nil : live
        }
        return !live.isEmpty
    }

    /// Timeout (seconds) before treating a hook-active session as timed out.
    /// Matches Claude Code's own ~5-minute timeout for long-running tool calls.
    private let activeTimeout: TimeInterval
    /// How long a quiet transcript still counts as working while its last
    /// entry is a tool call with no result yet: a long build or test run
    /// writes nothing until it finishes. Capped so a session killed
    /// mid-tool doesn't show work forever.
    private let toolCallTimeout: TimeInterval

    public func pollActivity(sessionPaths: [String: String]) async -> [String: ActivityState] {
        // Drop session paths clearly owned by another assistant (Gemini, Codex).
        // See handleHookEvent for rationale. Unowned paths (test fixtures) pass
        // through so existing tests don't need to mirror the real directory layout.
        let filtered = sessionPaths.filter { !CodingAssistant.claude.ownedByOther(sessionPath: $0.value) }

        // Cache paths for direct mtime checks in activityState()
        for (id, path) in filtered {
            self.sessionPaths[id] = path
        }

        let fileManager = FileManager.default
        var states: [String: ActivityState] = [:]

        for (sessionId, path) in filtered {
            guard let attrs = try? fileManager.attributesOfItem(atPath: path),
                  let mtime = attrs[.modificationDate] as? Date else {
                states[sessionId] = .ended
                continue
            }

            lastMtimes[sessionId] = mtime

            let timeSinceModified = Date.now.timeIntervalSince(mtime)

            // Polling NEVER returns .activelyWorking — only hooks can confirm active work.
            // This prevents false "In Progress" cards for sessions started externally.
            if timeSinceModified < activeTimeout {
                // Modified within timeout window — session might be active but unconfirmed by hooks
                states[sessionId] = .idleWaiting
            } else if timeSinceModified < 3600 {
                // No activity for 5min-1hr — likely needs attention
                states[sessionId] = .needsAttention
            } else if timeSinceModified < 86400 {
                states[sessionId] = .ended
            } else {
                states[sessionId] = .stale
            }
        }

        // Store poll results for use by activityState(for:)
        for (id, state) in states {
            polledStates[id] = state
        }

        return states
    }

    public func activityState(for sessionId: String) async -> ActivityState {
        // A permission prompt blocks the main agent until the user answers,
        // whatever its subagents are doing.
        if isAwaitingPermission(sessionId) {
            return .awaitingPermission
        }

        // Subagents still running keep the session at work, whatever its own
        // last event says. The main agent can be back at the prompt with the
        // Stop hook already fired while they carry on.
        if hasRunningSubagents(sessionId), lastEvents[sessionId]?.eventName != "SessionEnd" {
            return .activelyWorking
        }

        // Check hook-based detection first
        guard let lastEvent = lastEvents[sessionId] else {
            // No hook events — use polled state if available.
            // Polling never returns .activelyWorking, so sessions without hooks
            // never appear in "In Progress".
            return polledStates[sessionId] ?? .stale
        }

        switch lastEvent.eventName {
        case "UserPromptSubmit":
            // After a prompt, Claude is actively working. Stay in this state until:
            // 1. A Stop hook fires (handled by the "Stop" case below)
            // 2. File stale >3s AND last jsonl line is "[Request interrupted by user]"
            //    → Ctrl+C detected instantly without waiting for 5-minute timeout
            // 3. File hasn't been modified for >5 minutes (safety net timeout)
            //    Handles: killed process, Claude's own tool timeout, abandoned sessions
            // 4. No file path cached (shouldn't happen) — fall back to hook age
            guard let path = sessionPaths[sessionId] else {
                let timeSince = Date.now.timeIntervalSince(lastEvent.timestamp)
                if timeSince > activeTimeout {
                    return polledStates[sessionId] ?? .needsAttention
                }
                return .activelyWorking
            }

            guard let fileAge = Self.fileAge(path) else {
                return .activelyWorking
            }

            // Safety net: 5-minute timeout for killed processes / abandoned sessions,
            // unless a tool call is still running
            if fileAge > activeTimeout {
                return isRunningToolCall(path: path, fileAge: fileAge) ? .activelyWorking : .needsAttention
            }

            // Fast Ctrl+C detection: file stopped changing >3s ago, check last line
            if fileAge > 3, Self.lastLineContainsInterrupt(path) {
                return .needsAttention
            }

            return .activelyWorking

        case "SessionStart":
            // Session opened or resumed — Claude is at the prompt waiting for input.
            // NOT actively working yet (that requires UserPromptSubmit).
            return .idleWaiting

        case "Stop":
            // Stop is the authoritative "turn ended" signal from Claude Code.
            // BUT: ralph loops and fast human replies fire a new UserPromptSubmit
            // within 1-2 seconds of Stop, and demoting for a few hundred ms
            // before the next prompt causes a visible Waiting ↔ In Progress
            // flicker. Use a short grace period (`stopDelay`) where we keep
            // showing activelyWorking; after that, snap to needsAttention.
            let sinceStop = Date.now.timeIntervalSince(lastEvent.timestamp)
            if sinceStop < stopDelay {
                return .activelyWorking
            }
            // Continuation detection: ralph-loop (and similar stop-hook
            // continuation frameworks) inject `additionalContext` on Stop,
            // so Claude runs another turn WITHOUT firing a new UserPromptSubmit.
            // The only signal we have is the transcript file being written to
            // after the Stop event. If mtime advanced past the Stop timestamp,
            // Claude is still working.
            if let path = sessionPaths[sessionId],
               let fileAge = Self.fileAge(path),
               fileAge < activeTimeout {
                let fileMtime = Date.now.addingTimeInterval(-fileAge)
                if fileMtime.timeIntervalSince(lastEvent.timestamp) > 1.0 {
                    return .activelyWorking
                }
            }
            return .needsAttention
        case "SessionEnd":
            return .ended
        case "Notification":
            // Notification fires when Claude wants user attention (tool
            // approval, bash permission prompt, etc). Default to
            // needsAttention unless the transcript is still being written to
            // very recently — which indicates the user just auto-approved and
            // Claude is already resuming work.
            if let path = sessionPaths[sessionId],
               let fileAge = Self.fileAge(path) {
                if fileAge < 5 {
                    return .activelyWorking
                }
                // Answering the prompt (a permission, an AskUserQuestion)
                // fires no UserPromptSubmit, so this Notification stays the
                // last event for the rest of the turn. A transcript written
                // after it means the prompt was answered and Claude went on;
                // without this, every tool call longer than 5s read as
                // Waiting. The margin covers the hook timestamp's
                // whole-second resolution.
                let fileMtime = Date.now.addingTimeInterval(-fileAge)
                if fileMtime.timeIntervalSince(lastEvent.timestamp) > 2.0,
                   fileAge < activeTimeout || isRunningToolCall(path: path, fileAge: fileAge) {
                    return .activelyWorking
                }
            }
            return .needsAttention
        default:
            // Unknown hook events — use polled state, never promote to activelyWorking
            return polledStates[sessionId] ?? .idleWaiting
        }
    }

    /// Whether a quiet transcript is waiting on a tool call that is still
    /// running, within `toolCallTimeout`.
    private func isRunningToolCall(path: String, fileAge: TimeInterval) -> Bool {
        fileAge < toolCallTimeout && Self.lastEntryIsPendingToolUse(path)
    }

    /// Whether the transcript's last conversation entry is an assistant
    /// message calling a tool, i.e. no tool result has come back yet.
    /// Bookkeeping lines (attachments, mode, titles) are skipped; a user
    /// entry, whether a tool result, a prompt or an interrupt, means no.
    static func lastEntryIsPendingToolUse(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }

        // A tool call carries its input (a whole file for Write), so read
        // more than one short line's worth.
        let fileSize = handle.seekToEndOfFile()
        let readSize: UInt64 = min(256 * 1024, fileSize)
        handle.seek(toFileOffset: fileSize - readSize)
        let data = handle.availableData
        guard let tail = String(data: data, encoding: .utf8) else { return false }

        for line in tail.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard line.contains("\"type\":\"assistant\"") || line.contains("\"type\":\"user\""),
                  let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = obj["type"] as? String else { continue }
            if type == "user" { return false }
            guard type == "assistant" else { continue }
            let content = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            return content.contains { $0["type"] as? String == "tool_use" }
        }
        return false
    }

    /// Whether the session's last event is a permission prompt nobody has answered yet.
    ///
    /// Answering it, either way, writes the tool result to the transcript, so a
    /// transcript untouched since the prompt means the prompt is still up. The
    /// hook timestamp has whole-second resolution and the tool call is written
    /// just before the prompt shows, hence the tolerance.
    private func isAwaitingPermission(_ sessionId: String) -> Bool {
        guard let event = lastEvents[sessionId],
              event.eventName == "Notification",
              event.notificationType == "permission_prompt" else { return false }
        guard let path = sessionPaths[sessionId] ?? event.transcriptPath,
              let fileAge = Self.fileAge(path) else { return true }
        let fileMtime = Date.now.addingTimeInterval(-fileAge)
        return fileMtime.timeIntervalSince(event.timestamp) < 2.0
    }

    /// Quick mtime check — returns seconds since file was last modified, or nil on error.
    private static func fileAge(_ path: String) -> TimeInterval? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        return Date.now.timeIntervalSince(mtime)
    }

    /// Check if the last line of a .jsonl file contains "[Request interrupted by user]".
    /// Claude Code writes this synthetic user message on Ctrl+C.
    /// Reads from the end of the file for efficiency (avoids reading entire file).
    private static func lastLineContainsInterrupt(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }

        // Read the last 4KB — enough for the last jsonl line
        let fileSize = handle.seekToEndOfFile()
        let readSize: UInt64 = min(4096, fileSize)
        handle.seek(toFileOffset: fileSize - readSize)
        let data = handle.availableData
        guard let tail = String(data: data, encoding: .utf8) else { return false }

        // Find the last non-empty line
        let lines = tail.split(separator: "\n", omittingEmptySubsequences: true)
        guard let lastLine = lines.last else { return false }

        return lastLine.contains("Request interrupted by user")
    }

    /// Resolve all pending stops (call periodically from background orchestrator).
    public func resolvePendingStops() -> [String] {
        let now = Date.now
        var resolved: [String] = []
        for (sessionId, stopTime) in pendingStops {
            if now.timeIntervalSince(stopTime) >= stopDelay {
                resolved.append(sessionId)
            }
        }
        for id in resolved {
            pendingStops.removeValue(forKey: id)
        }
        return resolved
    }
}
