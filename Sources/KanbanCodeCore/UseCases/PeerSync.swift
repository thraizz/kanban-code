import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import KanbanCodeRemoteKit

/// Fetches a peer's cards. The live one is HTTP; tests pass their own.
public protocol PeerLinksTransport: Sendable {
    /// `machineId` is this machine's, so the peer knows who reaches it.
    func fetchLinks(from peer: PeerEndpoint, since: Int?, epoch: String?, machineId: String?) async throws -> LinksPage
    /// Tells a peer this machine's cards changed, so it pulls now instead of
    /// at its next tick. Best effort.
    func notifyChanged(peer: PeerEndpoint, machineId: String) async
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

/// `GET <url>/v1/links?since=&epoch=` and `POST <url>/v1/links/changed`
/// with the peer's device token.
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

    static func linksURL(base: String, since: Int?, epoch: String?, machine: String? = nil) -> URL? {
        var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard var components = URLComponents(string: trimmed + "/v1/links"),
              components.scheme != nil, components.host != nil
        else { return nil }
        var items: [URLQueryItem] = []
        if let since { items.append(URLQueryItem(name: "since", value: String(since))) }
        if let epoch { items.append(URLQueryItem(name: "epoch", value: epoch)) }
        if let machine, !machine.isEmpty { items.append(URLQueryItem(name: "machine", value: machine)) }
        components.queryItems = items.isEmpty ? nil : items
        return components.url
    }

    public func fetchLinks(from peer: PeerEndpoint, since: Int?, epoch: String?, machineId: String?) async throws -> LinksPage {
        guard let url = Self.linksURL(base: peer.baseURL.absoluteString, since: since, epoch: epoch, machine: machineId) else {
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

    public func notifyChanged(peer: PeerEndpoint, machineId: String) async {
        guard let links = Self.linksURL(base: peer.baseURL.absoluteString, since: nil, epoch: nil),
              var components = URLComponents(url: links.appendingPathComponent("changed"), resolvingAgainstBaseURL: false)
        else { return }
        components.queryItems = [URLQueryItem(name: "machine", value: machineId)]
        guard let url = components.url else { return }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("Bearer \(peer.token)", forHTTPHeaderField: "Authorization")
        _ = try? await session.data(for: request)
    }
}

/// Pulls every configured peer's cards into this board.
///
/// Each peer is pulled on a timer (and at once after `poke`), asking only
/// for what changed since the last page (`since` + `epoch`); every page goes
/// to the board as `.peerLinksMerged`. Peer status (online, last seen,
/// machine identity, control connection) goes out as `.peerStatusChanged`
/// when it changes.
///
/// A peer with a control connection (`control`) says when its cards
/// changed, so it is pulled then, plus a safety pull every minute; one
/// without is pulled every few seconds.
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
    private var wake: AsyncStream<Void>.Continuation?
    /// Failed pulls since each peer last answered: an online peer turns
    /// offline only once they span `offlineGrace`.
    private var reachability: [String: RemoteReachability] = [:]
    private let offlineGrace: TimeInterval
    /// Where each peer master last reached this one from, by machine id: a
    /// peer that moved to another address keeps fetching from here, from
    /// the new one (`PeerAddress`).
    private var contacts: [String: (host: String, at: Date)] = [:]
    /// When a pull last tried a peer at an address learned from its
    /// requests, by peer id and URL, so a wrong one is not tried every tick.
    private var relocationsTried: [String: Date] = [:]
    /// Saves a peer's new address (peer id, address), so Settings › Peers
    /// shows it and the next start reaches the peer at once.
    private var addressLearned: (@Sendable (String, String) async -> Void)?
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

    /// A contact older than this says nothing about where the peer is now.
    static let contactWindow: TimeInterval = 120
    /// How long before a learned address that did not answer is tried again.
    static let relocationRetry: TimeInterval = 30

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
        wake?.yield()
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

    /// Sets what saves a peer's address once a pull learned a new one: it
    /// gets the peer id and the address.
    public func onAddressLearned(_ handler: @escaping @Sendable (_ peerId: String, _ address: String) async -> Void) {
        addressLearned = handler
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

    /// Notes that the peer master `machineId` reached this one from `host`
    /// (it fetched this master's cards, or said its own changed).
    public func noteContact(machineId: String, host: String, at date: Date = .now) {
        guard !machineId.isEmpty, machineId != identity.id, let host = PeerAddress.usableHost(host) else { return }
        contacts[machineId] = (host, date)
    }

    // MARK: - Pulling

    /// Pulls one peer now. Returns whether it answered. A peer that was
    /// online stays online through failed pulls until they span
    /// `offlineGrace`: a loaded host that answers late is not offline.
    /// A peer that does not answer at its address but reached this master
    /// lately from another one is tried there; when it answers there as the
    /// same machine, that is its address from then on.
    @discardableResult
    public func pull(peerId: String) async -> Bool {
        guard let peer = peers.first(where: { $0.id == peerId }), peer.enabled else { return false }
        let cursor = cursors[peer.id]
        let endpoint = endpoints.endpoint(forPeer: peer.id)
        do {
            guard let endpoint else { throw PeerSyncError.noAddress(peer.name) }
            let page = try await transport.fetchLinks(from: endpoint, since: cursor?.seq, epoch: cursor?.epoch, machineId: identity.id)
            try await accept(page, from: endpoint)
            return true
        } catch {
            // A connected peer is called through its connection; an address
            // learned from its requests says nothing about that.
            if (error as? PeerSyncError) != .selfPeer, controlStates[peer.id]?.connected != true,
               let endpoint, !endpoint.isForwarded, await relocate(endpoint, cursor: cursor) {
                return true
            }
            var reach = reachability[peer.id] ?? RemoteReachability(grace: offlineGrace)
            reach.failed()
            reachability[peer.id] = reach
            var status = statuses[peer.id] ?? PeerStatus(peerId: peer.id)
            status.online = status.online && !reach.isOffline()
            status.lastError = error.localizedDescription
            status.url = endpoint?.address.absoluteString
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
        // The address shown is a real one, never a forward port.
        await report(PeerStatus(peerId: peer.id, machine: page.machine, online: true, lastSeen: .now,
                                url: peer.address.absoluteString))
    }

    /// Tries `peer`, which did not answer at its address, at the one it
    /// reached this master from lately. The machine it is: the one it
    /// answered as before, else one that reached this master and is no
    /// other peer. It moves there only when it answers there, with its
    /// token, as that machine. Whether it answered there.
    private func relocate(_ peer: PeerEndpoint, cursor: Cursor?) async -> Bool {
        let now = Date()
        let current = peer.baseURL.absoluteString
        let known = statuses[peer.id]?.machine?.id
        let others = Set(peers.filter { $0.id != peer.id }.compactMap { statuses[$0.id]?.machine?.id })
        let candidates = contacts
            .filter { id, contact in
                now.timeIntervalSince(contact.at) < Self.contactWindow
                    && (known.map { $0 == id } ?? !others.contains(id))
            }
            .sorted { $0.value.at > $1.value.at }
        let oldHost = PeerAddress.host(of: current)
        for (machineId, contact) in candidates where contact.host != oldHost {
            guard let url = PeerAddress.replacingHost(of: current, with: contact.host),
                  let base = URL(string: url)
            else { continue }
            let key = peer.id + " " + url
            if let last = relocationsTried[key], now.timeIntervalSince(last) < Self.relocationRetry { continue }
            relocationsTried[key] = now
            let moved = PeerEndpoint(peer: peer.peer, baseURL: base)
            guard let page = try? await transport.fetchLinks(
                      from: moved, since: cursor?.seq, epoch: cursor?.epoch, machineId: identity.id),
                  page.machine.id == machineId,
                  // Settings › Peers may have changed it meanwhile.
                  let index = peers.firstIndex(where: { $0.id == peer.id }),
                  endpoints.baseURL(forPeer: peer.id) == peer.baseURL
            else { continue }
            peers[index].promoteHint(url)
            relocationsTried[key] = nil
            KanbanCodeLog.info("sync", "\(peer.name) moved from \(current) to \(url): it reached this machine from \(contact.host)")
            try? await accept(page, from: moved)
            await addressLearned?(peer.id, url)
            return true
        }
        return false
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
    /// `machineId` (a `POST /v1/links/changed` from it), or of every peer.
    public func poke(machineId: String? = nil) {
        if let machineId, let peer = peer(forMachine: machineId) {
            pokedPeers.insert(peer.id)
            wake?.yield()
        } else {
            pokedAll = true
            wake?.yield()
        }
    }

    /// Tells every peer this machine's cards changed: on its control
    /// connection, or (a peer without one that answers pulls) with
    /// `POST /v1/links/changed`.
    public func notifyPeers() async {
        let enabled = peers.filter(\.enabled)
        let machineId = identity.id
        let transport = transport
        let control = control
        let online = Set(enabled.filter { statuses[$0.id]?.online == true }.map(\.id))
        let endpoints = enabled.map { ($0.id, self.endpoints.endpoint(forPeer: $0.id)) }
        await withTaskGroup(of: Void.self) { group in
            for (peerId, endpoint) in endpoints {
                group.addTask {
                    if await control.send(PeerChange(what: .links), toPeer: peerId) { return }
                    guard online.contains(peerId), let endpoint else { return }
                    await transport.notifyChanged(peer: endpoint, machineId: machineId)
                }
            }
        }
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
        case let .connected(peerId, machine, via, _, remoteHost):
            controlStates[peerId] = ControlState(connected: true, via: via, machine: machine)
            endpoints.noteMachine(machine.id, forPeer: peerId)
            // A peer that dialed in shows where it is now, for a pull that
            // fails at the address on file.
            if via == .accepted, let remoteHost { noteContact(machineId: machine.id, host: remoteHost) }
            // What changed while it was not connected was not pushed.
            pokedPeers.insert(peerId)
            wake?.yield()
            await reportControl(peerId)
            await changeHandler?(machine.id, PeerChange(what: .sync))
            await changeHandler?(machine.id, PeerChange(what: .attention))
        case let .disconnected(peerId, reason):
            controlStates[peerId] = ControlState(connected: false, machine: controlStates[peerId]?.machine, error: reason,
                                                 closedBecause: reason)
            await reportControl(peerId)
        case let .dialFailed(peerId, reason):
            guard controlStates[peerId]?.connected != true else { return }
            var state = controlStates[peerId] ?? ControlState()
            state.error = state.closedBecause.map { "\($0); no new connection: \(reason)" } ?? reason
            controlStates[peerId] = state
            await reportControl(peerId)
        case let .changed(peerId, machineId, change):
            if change.what == .links {
                pokedPeers.insert(peerId)
                wake?.yield()
            } else {
                await changeHandler?(machineId, change)
            }
        case let .learned(peerId, machineId, hints):
            guard let index = peers.firstIndex(where: { $0.id == peerId }) else { return }
            peers[index].machineId = machineId
            peers[index].addressHints = hints
            await entryLearned?(peerId, machineId, hints)
        }
    }

    private func reportControl(_ peerId: String) async {
        await report(statuses[peerId] ?? PeerStatus(peerId: peerId))
    }

    /// Whether the peer has a control connection, as last reported.
    public func isConnected(peerId: String) -> Bool {
        controlStates[peerId]?.connected == true
    }

    /// How often an offline peer is tried again. A master restarting for a
    /// deploy is back within seconds, and a longer wait shows it offline for
    /// that long; a failed pull to a refusing host costs next to nothing.
    public static let offlineRetry: Duration = .seconds(5)

    /// Runs until the task is cancelled: dials and serves the control
    /// connections, and pulls peers with a control connection every
    /// `connectedInterval`, other online peers every `interval`, offline
    /// ones every `offlineInterval`, poked ones at once.
    public func run(
        interval: Duration = .seconds(5),
        offlineInterval: Duration = PeerSync.offlineRetry,
        connectedInterval: Duration = PeerSync.safetyPull
    ) async {
        let control = control
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await control.run() }
            group.addTask { await self.followControl() }
            group.addTask {
                await self.pullLoop(interval: interval, offlineInterval: offlineInterval, connectedInterval: connectedInterval)
            }
            await group.next()
            group.cancelAll()
        }
    }

    private func pullLoop(interval: Duration, offlineInterval: Duration, connectedInterval: Duration) async {
        let (wakes, wake) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.wake = wake
        var nextPull: [String: ContinuousClock.Instant] = [:]
        let clock = ContinuousClock()
        while !Task.isCancelled {
            let now = clock.now
            let forceAll = pokedAll
            pokedAll = false
            let poked = pokedPeers
            pokedPeers = []
            let due = peers.filter { peer in
                peer.enabled && (forceAll || poked.contains(peer.id) || (nextPull[peer.id] ?? now) <= now)
            }
            if !due.isEmpty {
                await withTaskGroup(of: (String, Bool).self) { group in
                    for peer in due {
                        group.addTask { (peer.id, await self.pull(peerId: peer.id)) }
                    }
                    for await (id, online) in group {
                        let every = controlStates[id]?.connected == true ? connectedInterval : (online ? interval : offlineInterval)
                        nextPull[id] = clock.now + every
                    }
                }
            }
            await withTaskGroup(of: Void.self) { group in
                group.addTask { try? await Task.sleep(for: .milliseconds(250)) }
                group.addTask {
                    var next = wakes.makeAsyncIterator()
                    _ = await next.next()
                }
                await group.next()
                group.cancelAll()
            }
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

    /// The page `GET /v1/links` answers with. `machine` is the peer asking,
    /// when it says (older peers do not), noted as a sign that it reaches
    /// this master.
    public func peerLinksPage(machine: String?, since: Int?, epoch: String?) -> LinksPage {
        notePeerPull(machine: machine)
        return peerLinksPage(since: since, epoch: epoch)
    }

    /// The page `GET /v1/links` answers with.
    public func peerLinksPage(since: Int?, epoch: String?) -> LinksPage {
        var page = state.linksPage(machine: localMachine, since: since, epoch: epoch)
        page.repoSlugs = localRepoSlugs.isEmpty ? nil : localRepoSlugs
        return page
    }
}
