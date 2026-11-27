import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import KanbanCodeRemoteKit

/// Fetches a peer's cards. The live one is HTTP; tests pass their own.
/// That a peer's cards changed comes on its control connection.
public protocol PeerLinksTransport: Sendable {
    func fetchLinks(from peer: PeerEndpoint, since: Int?, epoch: String?) async throws -> LinksPage
}

public enum PeerSyncError: Error, Equatable, LocalizedError {
    case badURL(String)
    /// The peer has no address to reach it at: its name.
    case noAddress(String)
    case http(Int, String)
    case selfPeer
    /// The address answered as another machine than the entry is saved as:
    /// the machine it answered as (name, id) and the one expected.
    case otherMachine(String, String, expected: String)

    public var errorDescription: String? {
        switch self {
        case .badURL(let url): "bad peer URL \(url)"
        case .noAddress(let name): "no usable address for \(name)"
        case .http(let status, let body): "HTTP \(status): \(body)"
        case .selfPeer: "this peer is the local machine"
        case .otherMachine(let name, let id, let expected): "answered as \(name) (\(id)), not \(expected)"
        }
    }
}

/// `GET <url>/v1/links?since=&epoch=` with the peer's device token.
public struct HTTPPeerLinksTransport: PeerLinksTransport {
    private let session: URLSession
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 20) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 6
        self.session = URLSession(configuration: config)
        self.timeout = timeout
    }

    static func linksURL(base: String, since: Int?, epoch: String?) -> URL? {
        var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard var components = URLComponents(string: trimmed + "/v1/links"),
              components.scheme != nil, components.host != nil
        else { return nil }
        var items: [URLQueryItem] = []
        if let since { items.append(URLQueryItem(name: "since", value: String(since))) }
        if let epoch { items.append(URLQueryItem(name: "epoch", value: epoch)) }
        components.queryItems = items.isEmpty ? nil : items
        return components.url
    }

    public func fetchLinks(from peer: PeerEndpoint, since: Int?, epoch: String?) async throws -> LinksPage {
        guard let url = Self.linksURL(base: peer.baseURL.absoluteString, since: since, epoch: epoch) else {
            throw PeerSyncError.badURL(peer.baseURL.absoluteString)
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("Bearer \(peer.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw PeerSyncError.http(status, String(decoding: data.prefix(300), as: UTF8.self))
        }
        return try JSONDecoder.remote.decode(LinksPage.self, from: data)
    }
}

/// Pulls every configured peer's cards into this board.
///
/// A peer is pulled through its control connection (`control`), asking only
/// for what changed since the last page (`since` + `epoch`); every page goes
/// to the board as `.peerLinksMerged`. Peer status (online, last seen,
/// machine identity, control connection) goes out as `.peerStatusChanged`
/// when it changes.
///
/// A connected peer says when its cards changed, so it is pulled then, when
/// it connects, and once a minute besides. A peer without a connection is
/// not pulled: there is no address to call it at.
public actor PeerSync {
    public typealias Dispatch = @Sendable (Action) async -> Void

    private struct Cursor: Equatable {
        var epoch: String
        var seq: Int
    }

    private let identity: MachineIdentity
    private let transport: any PeerLinksTransport
    private let dispatch: Dispatch
    /// Where each peer answers. Every change of `peers` goes there.
    public nonisolated let endpoints: PeerEndpoints
    private var peers: [PeerConfig] {
        didSet { endpoints.setPeers(peers) }
    }
    private var cursors: [String: Cursor] = [:]
    private var statuses: [String: PeerStatus] = [:]
    /// When each status was last dispatched, to send `lastSeen` about once a
    /// minute rather than on every pull.
    private var statusDispatchedAt: [String: Date] = [:]
    private var pokedPeers: Set<String> = []
    /// Last repository slugs each peer sent, to dispatch only changes.
    private var repoSlugs: [String: [String: String]] = [:]
    private var pokedAll = false
    /// Wakes the pull loop for a poke instead of at its next check.
    private let wake = PokeSignal()
    /// Failed pulls since each peer last answered: an online peer turns
    /// offline only once they span `offlineGrace`.
    private var reachability: [String: RemoteReachability] = [:]
    private let offlineGrace: TimeInterval
    /// Saves an entry made for a peer that paired over its control
    /// connection.
    private var entryCreated: (@Sendable (PeerConfig) async -> Void)?
    /// The control connections to the peers.
    public nonisolated let control: PeerControl
    /// The control connection of each peer, by peer id, as last reported.
    private var controlStates: [String: ControlState] = [:]
    /// Takes a change a peer announced other than its cards (machine id,
    /// change): the agent sync and attention.
    private var changeHandler: (@Sendable (String, PeerChange) async -> Void)?
    /// Saves what a control connection taught about an entry (peer id,
    /// machine id, address hints).
    private var entryLearned: (@Sendable (String, String, [String]) async -> Void)?

    private struct ControlState {
        var connected = false
        var via: PeerConnectionDirection?
        var machine: MachineIdentity?
        var error: String?
        /// Why the last connection closed, kept while redials fail: "not
        /// connected" says why it went, not only that a redial was refused.
        var closedBecause: String?
    }

    /// How often a peer with a control connection is pulled without being
    /// told to: its pushes carry the rest.
    public static let safetyPull: Duration = .seconds(60)

    public init(
        identity: MachineIdentity,
        peers: [PeerConfig] = [],
        transport: any PeerLinksTransport = HTTPPeerLinksTransport(),
        offlineGrace: TimeInterval = RemoteReachability.defaultGrace,
        version: String = RemoteControlServer.bundleVersion,
        controlOptions: PeerControl.Options = PeerControl.Options(),
        dispatch: @escaping Dispatch
    ) {
        self.identity = identity
        self.peers = peers
        let endpoints = PeerEndpoints(peers: peers)
        self.endpoints = endpoints
        self.control = PeerControl(identity: identity, endpoints: endpoints, version: version, options: controlOptions)
        self.transport = transport
        self.offlineGrace = offlineGrace
        self.dispatch = dispatch
    }

    // MARK: - Configuration

    /// Replaces the peer list (Settings > Peers changed). A peer whose
    /// address changed starts over with a full pull.
    public func setPeers(_ newPeers: [PeerConfig]) async {
        let old = Dictionary(peers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for peer in newPeers where old[peer.id]?.addressHints.first != peer.addressHints.first {
            cursors[peer.id] = nil
        }
        let ids = Set(newPeers.map(\.id))
        for id in cursors.keys where !ids.contains(id) { cursors[id] = nil }
        for id in statuses.keys where !ids.contains(id) { statuses[id] = nil }
        for id in reachability.keys where !ids.contains(id) { reachability[id] = nil }
        for id in controlStates.keys where !ids.contains(id) { controlStates[id] = nil }
        peers = newPeers
        pokedAll = true
        wake.poke()
        await control.peersChanged(newPeers)
    }

    public func configuredPeers() -> [PeerConfig] { peers }

    public func status(of peerId: String) -> PeerStatus? { statuses[peerId] }

    public func allStatuses() -> [PeerStatus] {
        peers.compactMap { statuses[$0.id] }
    }

    /// The peer config whose machine is `machineId`, once it answered.
    public func peer(forMachine machineId: String) -> PeerConfig? {
        peers.first { statuses[$0.id]?.machine?.id == machineId }
    }

    /// Sets what saves an entry made for a peer that dialed in with no
    /// entry here and gave this master a token for it ("Pairing on one
    /// side").
    public func onEntryCreated(_ handler: @escaping @Sendable (PeerConfig) async -> Void) {
        entryCreated = handler
    }

    /// Sets what takes a change a peer announced on its control connection,
    /// other than its cards: `sync` (with what the agent sync says changed)
    /// and `attention`. It gets the peer's machine id.
    public func onPeerChange(_ handler: @escaping @Sendable (_ machineId: String, _ change: PeerChange) async -> Void) {
        changeHandler = handler
    }

    /// Sets what saves what a control connection taught about an entry:
    /// the machine it is and its address hints, newest success first.
    public func onEntryLearned(_ handler: @escaping @Sendable (_ peerId: String, _ machineId: String, _ hints: [String]) async -> Void) {
        entryLearned = handler
    }

    // MARK: - Pulling

    /// Pulls one peer now. Returns whether it answered. A peer that was
    /// online stays online through failed pulls until they span
    /// `offlineGrace`: a loaded host that answers late is not offline.
    /// A peer this master is not connected to is not called (false); its
    /// control connection's state says why.
    @discardableResult
    public func pull(peerId: String) async -> Bool {
        guard let peer = peers.first(where: { $0.id == peerId }), peer.enabled else { return false }
        let cursor = cursors[peer.id]
        let endpoint = endpoints.endpoint(forPeer: peer.id)
        if endpoint == nil, endpoints.controlRuns { return false }
        do {
            guard let endpoint else { throw PeerSyncError.noAddress(peer.name) }
            let page = try await transport.fetchLinks(from: endpoint, since: cursor?.seq, epoch: cursor?.epoch)
            try await accept(page, from: endpoint)
            return true
        } catch {
            var reach = reachability[peer.id] ?? RemoteReachability(grace: offlineGrace)
            reach.failed()
            reachability[peer.id] = reach
            var status = statuses[peer.id] ?? PeerStatus(peerId: peer.id)
            status.online = status.online && !reach.isOffline()
            status.lastError = error.localizedDescription
            if let address = endpoint?.address { status.url = address.absoluteString }
            await report(status)
            return false
        }
    }

    /// Takes in a page `peer` answered with.
    private func accept(_ page: LinksPage, from peer: PeerEndpoint) async throws {
        guard page.machine.id != identity.id else { throw PeerSyncError.selfPeer }
        // An entry saved with its machine id is that machine; an address
        // that answers as another one is someone else now.
        if let expected = peers.first(where: { $0.id == peer.id })?.machineId, expected != page.machine.id {
            throw PeerSyncError.otherMachine(page.machine.name, page.machine.id, expected: expected)
        }
        endpoints.noteMachine(page.machine.id, forPeer: peer.id)
        if !page.links.isEmpty {
            await dispatch(.peerLinksMerged(peer: page.machine.id, links: page.links))
        }
        if let slugs = page.repoSlugs, slugs != repoSlugs[peer.id] {
            repoSlugs[peer.id] = slugs
            await dispatch(.peerRepoSlugsLoaded(peer: page.machine.id, slugs: slugs))
        }
        cursors[peer.id] = Cursor(epoch: page.epoch, seq: page.seq)
        reachability[peer.id] = nil
        // The address shown is a real one, never a forward port; while none
        // is known, the last one stays.
        await report(PeerStatus(peerId: peer.id, machine: page.machine, online: true, lastSeen: .now,
                                url: peer.address?.absoluteString ?? statuses[peer.id]?.url))
    }

    /// Pulls every enabled peer once, concurrently.
    public func pullAll() async {
        let ids = peers.filter(\.enabled).map(\.id)
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { await self.pull(peerId: id) }
            }
        }
    }

    /// Asks for a pull before the next tick: of the peer with machine id
    /// `machineId` (a `POST /v1/links/changed` from an older build), or of
    /// every peer.
    public func poke(machineId: String? = nil) {
        if let machineId, let peer = peer(forMachine: machineId) {
            pokedPeers.insert(peer.id)
            wake.poke()
        } else {
            pokedAll = true
            wake.poke()
        }
    }

    /// Tells every connected peer this machine's cards changed, on its
    /// control connection. A peer that connects later pulls then.
    public func notifyPeers() async {
        await announce(PeerChange(what: .links))
    }

    /// Tells the peer that is the machine `machineId` that `change` happened
    /// here (agent sync). False when it has no control connection; the
    /// caller tells it its own way.
    @discardableResult
    public func announce(_ change: PeerChange, toMachine machineId: String) async -> Bool {
        await control.send(change, toMachine: machineId)
    }

    /// Tells every connected peer that `change` happened here (attention).
    /// The others notice at their next poll.
    public func announce(_ change: PeerChange) async {
        let control = control
        let ids = peers.filter(\.enabled).map(\.id)
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { await control.send(change, toPeer: id) }
            }
        }
    }

    // MARK: - Control connection

    /// Follows the control connections until the task is cancelled.
    private func followControl() async {
        for await event in control.events {
            await handle(event)
        }
    }

    private func handle(_ event: PeerControl.Event) async {
        switch event {
        case let .connected(peerId, machine, via, _, _):
            controlStates[peerId] = ControlState(connected: true, via: via, machine: machine)
            endpoints.noteMachine(machine.id, forPeer: peerId)
            // What changed while it was not connected was not pushed.
            pokedPeers.insert(peerId)
            wake.poke()
            await reportControl(peerId)
            await changeHandler?(machine.id, PeerChange(what: .sync))
            await changeHandler?(machine.id, PeerChange(what: .attention))
        case let .disconnected(peerId, reason):
            controlStates[peerId] = ControlState(connected: false, machine: controlStates[peerId]?.machine, error: reason,
                                                 closedBecause: reason)
            // Without its connection it is not pulled, so its last pull says
            // nothing about it now.
            var status = statuses[peerId] ?? PeerStatus(peerId: peerId)
            status.online = false
            reachability[peerId] = nil
            await report(status)
        case let .dialFailed(peerId, reason):
            guard controlStates[peerId]?.connected != true else { return }
            var state = controlStates[peerId] ?? ControlState()
            state.error = state.closedBecause.map { "\($0); no new connection: \(reason)" } ?? reason
            controlStates[peerId] = state
            await reportControl(peerId)
        case let .changed(peerId, machineId, change):
            if change.what == .links {
                pokedPeers.insert(peerId)
                wake.poke()
            } else {
                await changeHandler?(machineId, change)
            }
        case let .learned(peerId, machineId, hints):
            guard let index = peers.firstIndex(where: { $0.id == peerId }) else { return }
            peers[index].machineId = machineId
            peers[index].addressHints = hints
            await entryLearned?(peerId, machineId, hints)
        case let .paired(entry):
            if let index = peers.firstIndex(where: { $0.id == entry.id }) {
                peers[index] = entry
            } else {
                peers.append(entry)
            }
            await entryCreated?(entry)
        }
    }

    private func reportControl(_ peerId: String) async {
        await report(statuses[peerId] ?? PeerStatus(peerId: peerId))
    }

    /// Whether the peer has a control connection, as last reported.
    public func isConnected(peerId: String) -> Bool {
        controlStates[peerId]?.connected == true
    }

    /// Runs until the task is cancelled: dials and serves the control
    /// connections, and pulls each connected peer when it connects, when it
    /// says its cards changed (a poke) and every `safetyPull` besides.
    public func run(safetyPull: Duration = PeerSync.safetyPull) async {
        let control = control
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await control.run() }
            group.addTask { await self.followControl() }
            group.addTask { await self.pullLoop(safetyPull: safetyPull) }
            await group.next()
            group.cancelAll()
        }
    }

    private func pullLoop(safetyPull: Duration) async {
        var nextPull: [String: ContinuousClock.Instant] = [:]
        let clock = ContinuousClock()
        while !Task.isCancelled {
            let now = clock.now
            let forceAll = pokedAll
            pokedAll = false
            let poked = pokedPeers
            pokedPeers = []
            // Only a connected peer has an address; one that connects is
            // pulled at once (`.connected` pokes it).
            for id in nextPull.keys where controlStates[id]?.connected != true { nextPull[id] = nil }
            let due = peers.filter { peer in
                peer.enabled && controlStates[peer.id]?.connected == true
                    && (forceAll || poked.contains(peer.id) || (nextPull[peer.id] ?? now) <= now)
            }
            if !due.isEmpty {
                await withTaskGroup(of: String.self) { group in
                    for peer in due {
                        group.addTask { _ = await self.pull(peerId: peer.id); return peer.id }
                    }
                    for await id in group {
                        nextPull[id] = clock.now + safetyPull
                    }
                }
            }
            await wake.wait(timeout: .milliseconds(250))
        }
    }

    /// Records and (when it changed, or about once a minute) dispatches a
    /// peer's status, with the state of its control connection laid over
    /// what the pulls found.
    private func report(_ pulled: PeerStatus) async {
        var status = pulled
        let control = controlStates[status.peerId]
        status.connected = control?.connected ?? false
        status.connectedVia = status.connected ? control?.via : nil
        status.controlError = status.connected ? nil : control?.error
        if status.machine == nil { status.machine = control?.machine }
        let previous = statuses[status.peerId]
        statuses[status.peerId] = status
        let lastSent = statusDispatchedAt[status.peerId]
        let stale = lastSent.map { Date.now.timeIntervalSince($0) > 60 } ?? true
        let changed = previous?.online != status.online
            || previous?.machine != status.machine
            || previous?.lastError != status.lastError
            || previous?.url != status.url
            || previous?.connected != status.connected
            || previous?.connectedVia != status.connectedVia
            || previous?.controlError != status.controlError
        guard changed || stale else { return }
        statusDispatchedAt[status.peerId] = .now
        await dispatch(.peerStatusChanged(status))
    }
}

// MARK: - Serving

extension BoardStore {
    /// This machine's identity as the board knows it.
    public var localMachine: MachineIdentity {
        MachineIdentity(id: state.localMachineId, name: state.localMachineName,
                        alwaysOn: state.localMachineAlwaysOn ? true : nil)
    }

    /// The page `GET /v1/links` answers with.
    public func peerLinksPage(since: Int?, epoch: String?) -> LinksPage {
        var page = state.linksPage(machine: localMachine, since: since, epoch: epoch)
        page.repoSlugs = localRepoSlugs.isEmpty ? nil : localRepoSlugs
        return page
    }
}
