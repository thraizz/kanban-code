import Foundation
import KanbanCodeRemoteKit

/// How far the transcript copy of a card moving between masters got.
public struct HandoverProgress: Sendable, Equatable {
    public var copiedBytes: Int
    public var totalBytes: Int

    public init(copiedBytes: Int, totalBytes: Int) {
        self.copiedBytes = copiedBytes
        self.totalBytes = totalBytes
    }

    /// "120 of 270 MB".
    public var label: String {
        let mb = 1_048_576.0
        let total = Double(totalBytes) / mb
        let copied = Double(min(copiedBytes, totalBytes)) / mb
        return total < 10
            ? String(format: "%.1f of %.1f MB", copied, total)
            : String(format: "%.0f of %.0f MB", copied, total)
    }
}

/// What the last start of a card (a launch, a resume, a move to another
/// master) reported: the step it is on, how far the move copied its
/// transcript, or the line that says why it failed. One per card; the
/// latest report wins.
public enum CardStartReport: Sendable, Equatable {
    case step(String)
    case moving(HandoverProgress)
    case failed(String)
}

/// Where the assistant session of a card stands. The card detail, Cmd+Enter
/// and the remote API (the phone, the other masters) all read this one value,
/// so a start, a move and a failure look the same wherever the card runs.
public enum CardSessionStatus: Sendable, Equatable {
    /// No conversation yet, and nothing starting.
    case none
    /// The session runs.
    case live
    /// A launch or resume is in flight; the line carries its last step.
    case starting(String)
    /// The card moves between masters; the line says where and how far.
    case moving(String)
    /// The session runs on a boxd machine that is not connected.
    case machine(RemoteMachineOverlayState)
    /// The last start failed and nothing runs; the line says why.
    case failed(String)
    /// The session ended; a resume continues the conversation.
    case ended

    /// Whether the way on is a resume (of the session, or of its machine).
    public var canResume: Bool {
        switch self {
        case .ended, .failed: true
        case .machine(let state): state.canResume
        case .none, .live, .starting, .moving: false
        }
    }

    /// Whether work is in flight: a spinner goes with the line.
    public var isWorking: Bool {
        switch self {
        case .starting, .moving: true
        case .machine(let state): state == .resuming || state.keepsTerminal
        case .none, .live, .failed, .ended: false
        }
    }

    /// Whether the last start failed.
    public var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }

    /// Whether the terminal of the session stays on screen.
    public var showsTerminal: Bool {
        switch self {
        case .live: true
        case .machine(let state): state.keepsTerminal
        default: false
        }
    }

    /// The line shown where the resume button goes.
    public func text(for link: Link) -> String {
        let assistant = link.effectiveAssistant.displayName
        switch self {
        case .none: return "No agent session"
        case .live: return ""
        case .starting(let line), .moving(let line), .failed(let line): return line
        case .machine(let state):
            guard let remote = link.remote else { return "" }
            return RemoteMachineOverlay.text(for: state, remote: remote, lastActivity: link.lastActivity)
        case .ended:
            if link.isRemote, let remote = link.remote, remote.mode == .boxd, let reason = remote.pausedReason {
                return RemoteMachineOverlay.text(for: .paused(reason), remote: remote, lastActivity: link.lastActivity)
            }
            return "\(assistant) session ended"
        }
    }

    /// The same, on the wire. Nil when the session runs, ended or never ran:
    /// every client knows those from `isLive` and the session id.
    public func remote(for link: Link) -> RemoteSessionStatus? {
        switch self {
        case .none, .live, .ended: nil
        case .starting: RemoteSessionStatus(kind: .starting, text: text(for: link))
        case .moving: RemoteSessionStatus(kind: .moving, text: text(for: link))
        case .machine: RemoteSessionStatus(kind: .machine, text: text(for: link), canResume: canResume)
        case .failed: RemoteSessionStatus(kind: .failed, text: text(for: link), canResume: true)
        }
    }

    /// The status a peer master reported for a card it owns.
    public init?(remote: RemoteSessionStatus) {
        switch remote.kind {
        case .starting: self = .starting(remote.text)
        case .moving: self = .moving(remote.text)
        case .failed: self = .failed(remote.text)
        case .machine: return nil
        }
    }

    public static func startingLine(_ step: String?) -> String {
        guard let step, !step.isEmpty else { return "Starting session…" }
        return "Starting session… \(step)"
    }

    /// A launch lock older than this without news is stale: the card stops
    /// showing the spinner.
    public static let staleLaunchAfter: TimeInterval = 30

    /// The status of a card from what this master knows of it.
    ///
    /// - `moving`: the line of a move in flight (`AppState.handoverLine`).
    /// - `report`: what the last start of the card reported here.
    /// - `peer`: what the owner reported, for a card another master runs.
    public static func of(
        link: Link,
        moving: String?,
        report: CardStartReport?,
        peer: RemoteSessionStatus? = nil,
        machineState: RemoteMachineState?,
        now: Date = .now
    ) -> CardSessionStatus {
        if let moving { return .moving(moving) }
        let hasLiveSession = link.tmuxLink.map { $0.isShellOnly != true && $0.isPrimaryDead != true } ?? false
        if link.isLaunching == true, now.timeIntervalSince(link.updatedAt) <= staleLaunchAfter {
            if case .step(let step) = report, !step.isEmpty { return .starting(startingLine(step)) }
            if let peer, peer.kind == .starting { return .starting(peer.text) }
            return .starting(startingLine(nil))
        }
        if hasLiveSession {
            let machine = RemoteMachineOverlay.state(
                remote: link.remote, machineState: machineState, hasLiveSession: true, isRemote: link.isRemote)
            return machine == .none ? .live : .machine(machine)
        }
        if case .failed(let line) = report { return .failed(line) }
        if let peer, let status = CardSessionStatus(remote: peer) { return status }
        return link.sessionLink != nil ? .ended : .none
    }
}
