import Foundation

/// A peer master this one cannot reach: the master that runs a card, or the
/// master on an ssh machine. Its cards' terminals stream from it, so they
/// stay empty until it answers. The ssh link to the same host is separate
/// and can be up meanwhile (a firewall that lets port 22 through but not the
/// Remote Control port, say).
public struct PeerOutage: Sendable, Equatable, Hashable {
    /// The ssh machine on the same host, else the peer's machine name, else
    /// the host of its URL.
    public var name: String
    /// The peer's Remote Control URL.
    public var url: String?
    /// Why the last pull failed.
    public var error: String?

    public init(name: String, url: String? = nil, error: String? = nil) {
        self.name = name
        self.url = url
        self.error = error
    }

    /// The warning line, e.g. "osaka's Kanban Code does not answer at
    /// http://…:7780: The request timed out."
    public var line: String {
        var text = "\(name)'s Kanban Code does not answer"
        if let url { text += " at \(url)" }
        if let error, !error.isEmpty {
            text += ": " + error.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        }
        return text + "."
    }
}

/// Whether a terminal of a card must hold off before it starts.
public enum OwnerWait: Sendable, Equatable {
    /// It starts now.
    case none
    /// The identity of this master or the peers' first answers have not
    /// loaded yet: wait a little, then start as usual.
    case loading
    /// The card's owner is no peer that answered, and a peer has not
    /// answered yet that may be it: wait until it does. Started now, the
    /// terminal would look for the session on this Mac and give up.
    case peerSilent
}

extension AppState {
    /// The name a peer goes by here.
    func peerDisplayName(_ status: PeerStatus) -> String {
        if let ssh = boxdSettings?.sshMachines.first(where: { $0.isComplete && MachineDirectory.isSameMachine($0, status) }) {
            return ssh.name
        }
        return status.machine?.name ?? status.url.flatMap(MachineDirectory.host(ofURL:)) ?? status.peerId
    }

    private func outage(of status: PeerStatus) -> PeerOutage? {
        guard !status.reachable else { return nil }
        return PeerOutage(name: peerDisplayName(status), url: status.url, error: status.unreachableReason)
    }

    /// The peers that have not answered since this master started, so their
    /// machine ids are not known.
    private var silentPeers: [PeerStatus] {
        peerStatuses.values.filter { $0.machine == nil }.sorted { $0.peerId < $1.peerId }
    }

    /// Why the master that owns cards as `owner` cannot be reached; nil when
    /// it answers, is this master, or the peers have not been tried yet.
    /// A peer that never answered has no machine id here, so when one such
    /// peer is left, it is taken to be the owner.
    public func peerOutage(ownerMachine owner: String) -> PeerOutage? {
        guard !localMachineId.isEmpty, owner != localMachineId, !peerStatuses.isEmpty else { return nil }
        if let status = peerStatuses.values.first(where: { $0.machine?.id == owner }) {
            return outage(of: status)
        }
        let silent = silentPeers
        if silent.count == 1 { return outage(of: silent[0]) }
        if silent.isEmpty {
            return PeerOutage(name: owner, error: "no peer in Settings › Peers answers as this machine")
        }
        let names = silent.map(peerDisplayName).joined(separator: ", ")
        return PeerOutage(name: owner, error: "it is one of \(names), none of which answers")
    }

    /// Why the master on the ssh machine `name` cannot be reached; nil when
    /// it answers or the machine runs no paired master.
    public func peerOutage(sshMachine name: String) -> PeerOutage? {
        guard let ssh = boxdSettings?.sshMachine(named: name),
              let status = peerStatuses.values.first(where: { MachineDirectory.isSameMachine(ssh, $0) })
        else { return nil }
        return outage(of: status)
    }

    /// Whether the terminal of the card that owns `ownerMachine` waits. A
    /// known owner this master cannot call now holds it too: its attach
    /// command takes the owner's address when it starts, and while the
    /// owner is not connected there is none that works.
    public func ownerWait(ownerMachine owner: String?) -> OwnerWait {
        guard let owner else { return .none }
        if localMachineId.isEmpty { return .loading }
        if owner == localMachineId { return .none }
        if let status = peerStatuses.values.first(where: { $0.machine?.id == owner }) {
            return status.reachable ? .none : .peerSilent
        }
        if peerStatuses.isEmpty { return .loading }
        return silentPeers.isEmpty ? .none : .peerSilent
    }
}

/// Whether a peer master reaches this one. A card launched on or handed to
/// a peer is only released here: the peer picks it up when it fetches this
/// master's cards, and then asks this master for the prompt or transcript.
/// This master reaching the peer says nothing about that direction (a
/// firewall or a changed address can block only one of them), so it goes by
/// when the peer last fetched.
public enum PeerReachBack {
    /// A peer fetches every few seconds; this long without one is a peer
    /// that cannot.
    public static let window: TimeInterval = 90

    public enum Verdict: Sendable, Equatable {
        /// It fetched lately, or a peer too old to say who it is did.
        case reaches
        /// This master started less than `window` ago and the peer has not
        /// fetched yet: it is known by `until`.
        case unknown(until: Date)
        /// It does not fetch from here; the line says since when.
        case problem(String)
    }

    /// Whether the peer `machineId` would pick up a card released to it.
    public static func verdict(
        machineId: String, name: String, pulls: [String: Date], since: Date, now: Date = .now
    ) -> Verdict {
        if let last = pulls[machineId], now.timeIntervalSince(last) < window { return .reaches }
        if let anonymous = pulls[""], now.timeIntervalSince(anonymous) < window { return .reaches }
        if now.timeIntervalSince(since) < window { return .unknown(until: since.addingTimeInterval(window)) }
        let when = pulls[machineId].map { "since \(Self.clock(from: $0))" } ?? "since this app started"
        return .problem("\(name) has not fetched cards from this machine \(when), so it cannot take one over. "
            + "Check this machine's address in \(name)'s Settings › Peers, and its firewall.")
    }

    /// Why the peer `machineId` would not pick up a card released to it;
    /// nil when it would, or when that cannot be told yet.
    public static func problem(
        machineId: String, name: String, pulls: [String: Date], since: Date, now: Date = .now
    ) -> String? {
        if case .problem(let line) = verdict(machineId: machineId, name: name, pulls: pulls, since: since, now: now) {
            return line
        }
        return nil
    }

    private static func clock(from date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}
