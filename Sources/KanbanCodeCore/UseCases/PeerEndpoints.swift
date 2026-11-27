import Foundation
import Synchronization

/// A peer master and the base URL to reach it at now, from
/// `PeerEndpoints`. Resolve one per use and do not keep it: where a peer
/// answers can change while this master runs.
public struct PeerEndpoint: Sendable, Equatable {
    public let peer: PeerConfig
    /// The peer's Remote Control server, without a trailing slash. While
    /// the peer dialed this master it is the loopback forward port of that
    /// connection (`docs/peer-connections.md`, "Reverse streams").
    public let baseURL: URL
    /// A real address of the peer, never a forward port: to show, to tell
    /// an ssh machine on the same host, and to write into files other
    /// programs read. The hint a connection was dialed to, else where the
    /// peer's connection came from (at the port its hello announced); nil
    /// when neither is known (it dialed in before its server listened).
    public let address: URL?

    /// The peer called at `baseURL`, an address of its own.
    public init(peer: PeerConfig, baseURL: URL) {
        self.peer = peer
        self.baseURL = baseURL
        self.address = baseURL
    }

    /// The peer called at `baseURL`, a real address of it `address`.
    public init(peer: PeerConfig, baseURL: URL, address: URL?) {
        self.peer = peer
        self.baseURL = baseURL
        self.address = address
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
/// While a control connection to the peer is up, `PeerControl` sets the
/// route: the hint it dialed, or the loopback forward port when the peer
/// dialed this master. Without one there is no answer: a peer this master
/// is not connected to cannot be called. Only a sync whose control loop
/// does not run (tests, tools) calls the entry's first address hint.
/// `PeerSync` keeps the entries and the machine id each peer answered as up
/// to date here.
///
/// A lock, not an actor: the terminal of a card on a peer builds its attach
/// command synchronously on the main actor.
public final class PeerEndpoints: Sendable {
    private struct State {
        var peers: [PeerConfig] = []
        /// The machine id each peer answered as, by peer id.
        var machines: [String: String] = [:]
        /// Where each peer with a control connection is called, by peer id.
        var routes: [String: Route] = [:]
        /// The control loop runs: a peer without a route has no address.
        var controlRuns = false
    }

    private struct Route {
        var base: URL
        var address: URL?
    }

    private let state: Mutex<State>

    public init(peers: [PeerConfig] = []) {
        state = Mutex(State(peers: peers))
    }

    /// Replaces the peer entries. A removed peer's machine id and route go
    /// with it.
    public func setPeers(_ peers: [PeerConfig]) {
        state.withLock { state in
            state.peers = peers
            let ids = Set(peers.map(\.id))
            state.machines = state.machines.filter { ids.contains($0.key) }
            state.routes = state.routes.filter { ids.contains($0.key) }
        }
    }

    /// Adds (or replaces) an entry `PeerControl` made for a peer that paired
    /// over its control connection, before `PeerSync` takes it into its list.
    func addPeer(_ peer: PeerConfig) {
        state.withLock { state in
            if let index = state.peers.firstIndex(where: { $0.id == peer.id }) {
                state.peers[index] = peer
            } else {
                state.peers.append(peer)
            }
        }
    }

    /// Calls to the peer `peerId` go to `base` while its control connection
    /// is up (nil: it went down). `address` is a real address of it.
    func setRoute(_ base: URL?, address: URL?, forPeer peerId: String) {
        state.withLock { state in
            state.routes[peerId] = base.map { Route(base: $0, address: address) }
        }
    }

    /// The real address of the peer `peerId`'s connection changed (its
    /// server started after it dialed in, and its hello said where).
    func setRouteAddress(_ address: URL?, forPeer peerId: String) {
        state.withLock { state in
            state.routes[peerId]?.address = address
        }
    }

    /// The control loop started: from now on a peer is called only through
    /// its control connection.
    func setControlRunning() {
        state.withLock { $0.controlRuns = true }
    }

    /// Whether the control loop runs, so a peer without a connection has no
    /// address.
    public var controlRuns: Bool {
        state.withLock { $0.controlRuns }
    }

    /// The base URL of a loopback forward port.
    static func forwardURL(port: Int) -> URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }

    /// The peer `peerId` answered as the machine `machineId`.
    public func noteMachine(_ machineId: String, forPeer peerId: String) {
        state.withLock { $0.machines[peerId] = machineId }
    }

    /// Every peer entry that can be called now (connected), in settings
    /// order, disabled ones included.
    public func all() -> [PeerEndpoint] {
        state.withLock { state in
            state.peers.compactMap { Self.endpoint($0, in: state) }
        }
    }

    public func endpoint(forPeer peerId: String) -> PeerEndpoint? {
        state.withLock { state in
            guard let peer = state.peers.first(where: { $0.id == peerId }) else { return nil }
            return Self.endpoint(peer, in: state)
        }
    }

    /// The first entry that answered as the machine `machineId` (or names
    /// it as its machine id), as `PeerSync.peer(forMachine:)` finds it.
    public func endpoint(forMachine machineId: String) -> PeerEndpoint? {
        guard !machineId.isEmpty else { return nil }
        return state.withLock { state in
            guard let peer = state.peers.first(where: { (state.machines[$0.id] ?? $0.machineId) == machineId })
            else { return nil }
            return Self.endpoint(peer, in: state)
        }
    }

    public func baseURL(forPeer peerId: String) -> URL? {
        endpoint(forPeer: peerId)?.baseURL
    }

    public func baseURL(forMachine machineId: String) -> URL? {
        endpoint(forMachine: machineId)?.baseURL
    }

    /// Every peer entry, with or without an address.
    public func peers() -> [PeerConfig] {
        state.withLock { $0.peers }
    }

    public func peer(_ peerId: String) -> PeerConfig? {
        state.withLock { $0.peers.first { $0.id == peerId } }
    }

    /// The entry that is the machine `machineId`: the one that answered as
    /// it, or that names it as its machine id. With or without an address.
    public func peer(forMachine machineId: String) -> PeerConfig? {
        guard !machineId.isEmpty else { return nil }
        return state.withLock { state in
            state.peers.first { (state.machines[$0.id] ?? $0.machineId) == machineId }
        }
    }

    /// The machine the entry is, once known: the one it answered as, else
    /// the one it names.
    public func machineId(forPeer peerId: String) -> String? {
        state.withLock { state in
            state.machines[peerId] ?? state.peers.first { $0.id == peerId }?.machineId
        }
    }

    /// The entry's route while it has a control connection; without one,
    /// nothing, or its first address hint for a sync that runs no control
    /// loop.
    private static func endpoint(_ peer: PeerConfig, in state: State) -> PeerEndpoint? {
        if let route = state.routes[peer.id] {
            return PeerEndpoint(peer: peer, baseURL: route.base, address: route.address)
        }
        guard !state.controlRuns else { return nil }
        return configuredURL(peer).map { PeerEndpoint(peer: peer, baseURL: $0) }
    }

    /// The entry's first address hint as a base URL: trimmed, without a
    /// trailing slash, nil unless it names a scheme and a host.
    static func configuredURL(_ peer: PeerConfig) -> URL? {
        peer.addressHints.first.flatMap(baseURL(fromHint:))
    }

    /// An address hint as a base URL: trimmed, without a trailing slash,
    /// nil unless it names a scheme and a host.
    public static func baseURL(fromHint hint: String) -> URL? {
        let raw = normalizedHint(hint)
        guard let components = URLComponents(string: raw),
              components.scheme != nil, components.host?.isEmpty == false
        else { return nil }
        return components.url
    }

    /// A hint trimmed and without trailing slashes, to compare two hints.
    public static func normalizedHint(_ hint: String) -> String {
        var raw = hint.trimmingCharacters(in: .whitespacesAndNewlines)
        while raw.hasSuffix("/") { raw.removeLast() }
        return raw
    }
}
