import Foundation

/// What the assistant tab shows over a live session whose boxd machine is
/// not connected.
public enum RemoteMachineOverlayState: Equatable, Sendable {
    /// The machine is connected, or the card has no machine: the terminal shows.
    case none
    /// The machine is in standby or stopped. A person brings it back.
    case paused(RemotePausedReason)
    /// The last resume did not reach the machine. A person tries again.
    case unreachable
    /// A resume is in flight.
    case resuming
    /// The bridge dropped while the machine keeps running. The terminal
    /// stays, with a banner that counts the tries, and reattaches by itself.
    case reconnecting(attempt: Int)

    /// Whether the overlay offers a resume.
    public var canResume: Bool {
        switch self {
        case .paused, .unreachable: true
        case .none, .resuming, .reconnecting: false
        }
    }

    /// Whether the terminal stays on screen under a banner instead of
    /// giving way to the transcript.
    public var keepsTerminal: Bool {
        if case .reconnecting = self { return true }
        return false
    }
}

/// What follows once "Resume machine" brought the machine of a card back.
public enum MachineResumeFollowUp: Equatable {
    /// The tmux session survived the pause: the terminal attaches to it.
    case attach
    /// The session is gone, as after a stopped machine boots: the assistant
    /// is resumed on the machine with the transcript of the card.
    case resumeAssistant(sessionName: String)
    /// Nothing to resume, or a resume is already running.
    case nothing

    public static func decide(link: Link, sessionAlive: Bool) -> MachineResumeFollowUp {
        if sessionAlive { return .attach }
        guard link.sessionLink != nil, link.isLaunching != true else { return .nothing }
        return .resumeAssistant(sessionName: sessionName(for: link))
    }

    /// The tmux session a resume of the card creates on its machine.
    public static func sessionName(for link: Link) -> String {
        let sessionId = link.sessionLink?.sessionId ?? link.id
        return link.effectiveAssistant.resumeSessionName(sessionId: sessionId)
    }
}

public enum RemoteMachineOverlay {
    /// The overlay for a card, from what the app knows about its machine.
    /// The supervisor state wins; the pause reason stored on the link stands
    /// in for it when the supervisor has not reported yet, right after start.
    public static func state(
        remote: RemoteLink?,
        machineState: RemoteMachineState?,
        hasLiveSession: Bool,
        isRemote: Bool
    ) -> RemoteMachineOverlayState {
        // A card that owns a machine but runs its session locally (boxd was
        // deselected on resume) gets its terminal, not the machine banner.
        guard hasLiveSession, isRemote, let remote, remote.mode == .boxd else { return .none }
        switch machineState {
        case .paused(let reason): return .paused(reason)
        case .unreachable: return .unreachable
        case .reconnecting(let attempt): return .reconnecting(attempt: attempt)
        case .connecting: return .resuming
        case .connected, .destroyed: return .none
        case nil: return remote.pausedReason.map { .paused($0) } ?? .none
        }
    }

    /// The line shown next to the resume button.
    public static func text(
        for state: RemoteMachineOverlayState,
        remote: RemoteLink,
        lastActivity: Date?
    ) -> String {
        let machine = remote.machineName
        switch state {
        case .none:
            return ""
        case .resuming:
            return "Resuming machine \(machine)…"
        case .unreachable:
            return "Machine \(machine) did not answer. Resume tries again."
        case .reconnecting(let attempt):
            return "Connection to \(machine) lost · Reconnecting… · attempt \(attempt)"
        case .paused(let reason):
            switch reason {
            case .inactivity:
                // How long the machine sat idle: from the last activity of the
                // card to the moment it was paused.
                var minutes = 60
                if let pausedAt = remote.pausedAt, let lastActivity, pausedAt > lastActivity {
                    minutes = max(1, Int(pausedAt.timeIntervalSince(lastActivity) / 60))
                }
                return "Machine \(machine) was stopped after \(durationText(minutes: minutes)) without activity"
            case .sessionStopped:
                return "Machine \(machine) paused after the session stopped"
            case .stopped:
                return "Machine \(machine) was stopped. Resume starts it again."
            case .appQuit:
                return "Machine \(machine) paused when the app quit"
            case .systemSleep:
                return "Machine \(machine) paused when the Mac went to sleep"
            case .manual:
                return "Machine \(machine) paused"
            }
        }
    }

    public static func durationText(minutes: Int) -> String {
        if minutes % 60 == 0 {
            let hours = minutes / 60
            return hours == 1 ? "1h" : "\(hours)h"
        }
        return "\(minutes) min"
    }
}
