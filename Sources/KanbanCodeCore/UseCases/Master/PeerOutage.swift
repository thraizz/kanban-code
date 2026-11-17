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
        guard !status.online else { return nil }
        return PeerOutage(name: peerDisplayName(status), url: status.url, error: status.lastError)
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

    /// Whether the terminal of the card that owns `ownerMachine` waits.
    public func ownerWait(ownerMachine owner: String?) -> OwnerWait {
        guard let owner else { return .none }
        if localMachineId.isEmpty { return .loading }
        if owner == localMachineId { return .none }
        if peerStatuses.values.contains(where: { $0.machine?.id == owner }) { return .none }
        if peerStatuses.isEmpty { return .loading }
        return silentPeers.isEmpty ? .none : .peerSilent
    }
}
