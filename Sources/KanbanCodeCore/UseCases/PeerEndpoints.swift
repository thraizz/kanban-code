import Foundation
import Synchronization

/// A peer master and the base URL to reach it at now, from
/// `PeerEndpoints`. Resolve one per use and do not keep it: where a peer
/// answers can change while this master runs.
public struct PeerEndpoint: Sendable, Equatable {
    public let peer: PeerConfig
    /// The peer's Remote Control server, without a trailing slash.
    public let baseURL: URL

    public init(peer: PeerConfig, baseURL: URL) {
        self.peer = peer
        self.baseURL = baseURL
    }

    public var id: String { peer.id }
    public var name: String { peer.name }
    public var token: String { peer.token }
    public var enabled: Bool { peer.enabled }

    /// `baseURL` followed by `path` (which may carry a query), e.g.
    /// `/v1/vault/replica`.
    public func apiURL(_ path: String) -> URL? {
        URL(string: baseURL.absoluteString + path)
    }
}

/// The one place that knows where a peer master answers
/// (`docs/peer-connections.md`, "One place that knows a peer's URL").
/// Everything that calls a peer asks here, per call, instead of reading an
/// address from its `PeerConfig`.
///
/// For now the answer is the entry's first address hint (the URL from
/// Settings › Peers). `PeerSync` keeps the entries and the machine id each
/// peer answered as up to date here.
///
/// A lock, not an actor: the terminal of a card on a peer builds its attach
/// command synchronously on the main actor.
public final class PeerEndpoints: Sendable {
    private struct State {
        var peers: [PeerConfig] = []
        /// The machine id each peer answered as, by peer id.
        var machines: [String: String] = [:]
    }

    private let state: Mutex<State>

    public init(peers: [PeerConfig] = []) {
        state = Mutex(State(peers: peers))
    }

    /// Replaces the peer entries. A removed peer's machine id goes with it.
    public func setPeers(_ peers: [PeerConfig]) {
        state.withLock { state in
            state.peers = peers
            let ids = Set(peers.map(\.id))
            state.machines = state.machines.filter { ids.contains($0.key) }
        }
    }

    /// The peer `peerId` answered as the machine `machineId`.
    public func noteMachine(_ machineId: String, forPeer peerId: String) {
        state.withLock { $0.machines[peerId] = machineId }
    }

    /// Every peer entry that has a base URL now, in settings order,
    /// disabled ones included.
    public func all() -> [PeerEndpoint] {
        state.withLock { state in
            state.peers.compactMap { peer in Self.configuredURL(peer).map { PeerEndpoint(peer: peer, baseURL: $0) } }
        }
    }

    public func endpoint(forPeer peerId: String) -> PeerEndpoint? {
        state.withLock { state in
            guard let peer = state.peers.first(where: { $0.id == peerId }) else { return nil }
            return Self.configuredURL(peer).map { PeerEndpoint(peer: peer, baseURL: $0) }
        }
    }

    /// The first entry that answered as the machine `machineId` (or names
    /// it as its machine id), as `PeerSync.peer(forMachine:)` finds it.
    public func endpoint(forMachine machineId: String) -> PeerEndpoint? {
        guard !machineId.isEmpty else { return nil }
        return state.withLock { state in
            guard let peer = state.peers.first(where: { (state.machines[$0.id] ?? $0.machineId) == machineId })
            else { return nil }
            return Self.configuredURL(peer).map { PeerEndpoint(peer: peer, baseURL: $0) }
        }
    }

    public func baseURL(forPeer peerId: String) -> URL? {
        endpoint(forPeer: peerId)?.baseURL
    }

    public func baseURL(forMachine machineId: String) -> URL? {
        endpoint(forMachine: machineId)?.baseURL
    }

    /// The entry's first address hint as a base URL: trimmed, without a
    /// trailing slash, nil unless it names a scheme and a host.
    static func configuredURL(_ peer: PeerConfig) -> URL? {
        guard var raw = peer.addressHints.first?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        while raw.hasSuffix("/") { raw.removeLast() }
        guard let components = URLComponents(string: raw),
              components.scheme != nil, components.host?.isEmpty == false
        else { return nil }
        return components.url
    }
}
