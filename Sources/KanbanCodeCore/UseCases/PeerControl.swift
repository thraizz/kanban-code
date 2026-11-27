import Foundation
import KanbanCodeRemoteKit
import Synchronization

/// The control connections of this master: one WebSocket per peer,
/// `GET /v1/peer/control` (`docs/peer-connections.md`, "The control
/// connection").
///
/// Every master dials every enabled peer it has no connection with, trying
/// its address hints in order and backing off up to 30 s. A master that
/// accepted a connection from a peer does not dial it. When both connect at
/// once, the connection the lower machine id dialed stays. The dialer sends
/// a hello first; the listener matches it to a peer entry and answers with
/// its own. Both ping every 10 s; a connection that hears nothing for 30 s
/// closes. A `changed` message makes the receiver pull at once.
///
/// What happens goes out on `events`, which `PeerSync` follows: connection
/// state, changes the peer announced, and what the hellos taught about a
/// peer (its machine id, its addresses).
public actor PeerControl {
    public struct Options: Sendable {
        public var pingInterval: Duration
        /// A connection that heard nothing for this long closes.
        public var timeout: Duration
        /// How long a side waits for the other's hello.
        public var helloTimeout: Duration
        /// How long one dial of one hint may take, TCP and upgrade.
        public var dialTimeout: TimeInterval
        public var firstRetry: Duration
        public var maxRetry: Duration
        /// A hint that failed every dial for this long is dropped (never
        /// the last one).
        public var hintExpiry: TimeInterval
        public var maxHints: Int

        public init(
            pingInterval: Duration = .seconds(10),
            timeout: Duration = .seconds(30),
            helloTimeout: Duration = .seconds(10),
            dialTimeout: TimeInterval = 5,
            firstRetry: Duration = .seconds(1),
            maxRetry: Duration = .seconds(30),
            hintExpiry: TimeInterval = 7 * 24 * 3600,
            maxHints: Int = 8
        ) {
            self.pingInterval = pingInterval
            self.timeout = timeout
            self.helloTimeout = helloTimeout
            self.dialTimeout = dialTimeout
            self.firstRetry = firstRetry
            self.maxRetry = maxRetry
            self.hintExpiry = hintExpiry
            self.maxHints = maxHints
        }
    }

    public enum Event: Sendable, Equatable {
        /// A control connection to the peer is up. `url` is the hint this
        /// master dialed; `remoteHost` where an accepted one came from.
        case connected(peerId: String, machine: MachineIdentity, via: PeerConnectionDirection,
                       url: String?, remoteHost: String?)
        case disconnected(peerId: String, reason: String)
        /// No hint of the peer took a dial; it is tried again later.
        case dialFailed(peerId: String, reason: String)
        /// The peer says something changed on it.
        case changed(peerId: String, machineId: String, PeerChange)
        /// What the connection taught about the entry: the machine it is and
        /// its address hints, newest success first. Saved to the settings.
        case learned(peerId: String, machineId: String, hints: [String])
    }

    /// A live control connection, as `links()` shows it.
    public struct Link: Sendable, Equatable {
        public var peerId: String
        public var machine: MachineIdentity
        public var via: PeerConnectionDirection
        /// Machine id of the master that dialed it.
        public var dialer: String
        public var url: String?
    }

    /// One open control connection.
    final class Connection: Sendable {
        let id = UUID()
        let peerId: String
        let machine: MachineIdentity
        let dialer: String
        let direction: PeerConnectionDirection
        let url: String?
        let socket: PeerControlSocket
        let openedAt = ContinuousClock.now
        private let state: Mutex<(heard: ContinuousClock.Instant, endReason: String?)>

        init(peerId: String, machine: MachineIdentity, dialer: String, direction: PeerConnectionDirection,
             url: String?, socket: PeerControlSocket) {
            self.peerId = peerId
            self.machine = machine
            self.dialer = dialer
            self.direction = direction
            self.url = url
            self.socket = socket
            state = Mutex((ContinuousClock.now, nil))
        }

        func heard() { state.withLock { $0.heard = .now } }

        var silence: Duration { ContinuousClock.now - state.withLock { $0.heard } }

        /// Why this end closed it, when it did.
        var endReason: String? { state.withLock { $0.endReason } }

        /// Closes it, keeping the first reason given.
        func close(_ reason: String, code: UInt16 = 1000) {
            let first = state.withLock { s -> Bool in
                guard s.endReason == nil else { return false }
                s.endReason = reason
                return true
            }
            if first { socket.close(reason: reason, code: code) }
        }

        var link: Link {
            Link(peerId: peerId, machine: machine, via: direction, dialer: dialer, url: url)
        }
    }

    private enum ControlError: Error, LocalizedError {
        case failed(String)
        var errorDescription: String? {
            switch self { case .failed(let reason): reason }
        }
    }

    public static let path = "/v1/peer/control"

    private let identity: MachineIdentity
    private let version: String
    private let endpoints: PeerEndpoints
    public nonisolated let options: Options
    public nonisolated let events: AsyncStream<Event>
    private let sink: AsyncStream<Event>.Continuation

    private var connections: [String: Connection] = [:]
    private var dialing: Set<String> = []
    private var nextDial: [String: ContinuousClock.Instant] = [:]
    private var retry: [String: Duration] = [:]
    /// When each hint (peer id + hint) began failing, to drop one that
    /// failed for `hintExpiry`.
    private var failingSince: [String: Date] = [:]
    /// The last dial failure logged per peer, to log a change, not every try.
    private var loggedFailure: [String: (reason: String, at: Date)] = [:]
    /// The same for refused connections, by the dialer's machine id.
    private var loggedRefusal: [String: (reason: String, at: Date)] = [:]
    /// Every socket open now, connected or still in its hello, so a stop
    /// can close them from outside the actor.
    private nonisolated let open = Mutex<[ObjectIdentifier: PeerControlSocket]>([:])
    private nonisolated let listening = Mutex<(@Sendable () -> (addresses: [String], port: Int)?)?>(nil)
    /// Set by tests: this end goes silent (sends nothing, answers nothing)
    /// with its connections left open, as a machine that went to sleep.
    private nonisolated let silent = Mutex(false)
    /// Set by tests: an accepted connection waits this long before it
    /// reads the hello, so two masters surely dial each other at once.
    private var acceptDelay: Duration = .zero

    public init(identity: MachineIdentity, endpoints: PeerEndpoints, version: String, options: Options = Options()) {
        self.identity = identity
        self.endpoints = endpoints
        self.version = version
        self.options = options
        (events, sink) = AsyncStream<Event>.makeStream(bufferingPolicy: .unbounded)
    }

    // MARK: - Configuration

    /// Sets where this master's Remote Control server listens, for the
    /// hello: the server calls it when it starts.
    public nonisolated func setListening(_ provider: (@Sendable () -> (addresses: [String], port: Int)?)?) {
        listening.withLock { $0 = provider }
    }

    /// The peer entries changed (`PeerSync.setPeers`): a connection of a
    /// removed or disabled entry, or of one whose token changed, closes.
    public func peersChanged(_ peers: [PeerConfig]) {
        let byId = Dictionary(peers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (peerId, connection) in connections {
            guard let peer = byId[peerId] else {
                connection.close("\(identity.name) removed this peer")
                continue
            }
            if !peer.enabled { connection.close("\(identity.name) turned sync with \(peer.name) off") }
        }
        for id in nextDial.keys where byId[id] == nil { nextDial[id] = nil }
        // An edited entry is dialed at once.
        for peer in peers where connections[peer.id] == nil { nextDial[peer.id] = nil; retry[peer.id] = nil }
    }

    // MARK: - State

    /// The live connections.
    public func links() -> [Link] {
        connections.values.map(\.link).sorted { $0.peerId < $1.peerId }
    }

    public func isConnected(peerId: String) -> Bool {
        connections[peerId] != nil
    }

    public func isConnected(machineId: String) -> Bool {
        connections.values.contains { $0.machine.id == machineId }
    }

    // MARK: - Sending

    /// Tells the peer `peerId` that `change` happened here. False when there
    /// is no connection to send it on.
    @discardableResult
    public func send(_ change: PeerChange, toPeer peerId: String) async -> Bool {
        guard let connection = connections[peerId], !isSilent else { return false }
        do {
            try await connection.socket.send(PeerControlMessage(changed: change))
            return true
        } catch {
            return false
        }
    }

    /// Like `send(_:toPeer:)`, for the peer that is the machine `machineId`.
    @discardableResult
    public func send(_ change: PeerChange, toMachine machineId: String) async -> Bool {
        guard let peerId = connections.values.first(where: { $0.machine.id == machineId })?.peerId else { return false }
        return await send(change, toPeer: peerId)
    }

    // MARK: - Dialing

    /// Dials the peers until the task is cancelled, then closes every
    /// connection.
    public func run() async {
        await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                while !Task.isCancelled {
                    let now = ContinuousClock.now
                    for peer in endpoints.peers() where !isSilent && peer.enabled && !peer.addressHints.isEmpty
                        && connections[peer.id] == nil && !dialing.contains(peer.id)
                        && (nextDial[peer.id] ?? now) <= now {
                        dialing.insert(peer.id)
                        group.addTask { await self.dial(peer) }
                    }
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
        } onCancel: {
            self.stop(reason: "\(self.identity.name) is stopping")
        }
    }

    /// Closes every connection, as a master that stops.
    public nonisolated func stop(reason: String = "stopping") {
        let sockets = open.withLock { Array($0.values) }
        for socket in sockets { socket.close(reason: reason, code: 1001) }
    }

    /// Tries each hint of `peer` in order until one connects, then serves
    /// that connection until it ends.
    private func dial(_ peer: PeerConfig) async {
        defer { dialing.remove(peer.id) }
        var failures: [String] = []
        for hint in peer.addressHints {
            guard !Task.isCancelled, connections[peer.id] == nil else { return }
            guard let base = PeerEndpoints.baseURL(fromHint: hint) else {
                failures.append("\(hint): not a URL")
                continue
            }
            let socket: PeerControlSocket
            do {
                socket = PeerControlSocket(try await RemoteWebSocketClient.connect(
                    baseURL: base, path: Self.path, token: peer.token, timeout: options.dialTimeout))
            } catch {
                failures.append(Self.describe(error))
                noteHint(peer.id, hint, worked: false)
                continue
            }
            track(socket)
            defer { untrack(socket) }
            let hello: PeerHello
            do {
                hello = try await handshakeAsDialer(socket, peer: peer)
            } catch {
                failures.append("\(PeerEndpoints.normalizedHint(hint)): \(Self.describe(error))")
                noteHint(peer.id, hint, worked: false)
                continue
            }
            noteHint(peer.id, hint, worked: true)
            loggedFailure[peer.id] = nil
            learn(peerId: peer.id, machineId: hello.machine.id, promote: hint, hello: hello)
            let connection = Connection(peerId: peer.id, machine: hello.machine, dialer: identity.id,
                                        direction: .dialed, url: PeerEndpoints.normalizedHint(hint), socket: socket)
            guard register(connection) else { return }
            let reason = await serve(connection)
            unregister(connection, reason: reason)
            // A connection that held is redialed at once; one that keeps
            // ending right away backs off.
            if ContinuousClock.now - connection.openedAt >= .seconds(30) { retry[peer.id] = nil }
            scheduleRedial(peer.id)
            return
        }
        guard !Task.isCancelled else { return }
        dropExpiredHints(peer)
        let reason = failures.isEmpty ? "no address" : failures.joined(separator: "; ")
        let delay = scheduleRedial(peer.id)
        let last = loggedFailure[peer.id]
        if last?.reason != reason || Date().timeIntervalSince(last?.at ?? .distantPast) > 600 {
            loggedFailure[peer.id] = (reason, Date())
            KanbanCodeLog.info("peer", "no control connection to \(peer.name): \(reason); next try in \(Self.seconds(delay)) s")
        }
        sink.yield(.dialFailed(peerId: peer.id, reason: reason))
    }

    @discardableResult
    private func scheduleRedial(_ peerId: String) -> Duration {
        let delay = retry[peerId] ?? options.firstRetry
        retry[peerId] = min(delay * 2, options.maxRetry)
        nextDial[peerId] = .now + delay
        return delay
    }

    /// Sends this master's hello and waits for the peer's. Closes and
    /// throws when the peer is this machine or another one than the entry
    /// says.
    private func handshakeAsDialer(_ socket: PeerControlSocket, peer: PeerConfig) async throws -> PeerHello {
        // The machine the entry was saved as is its identity; one a pull
        // noted only counts for an entry not saved with one.
        let expected = peer.machineId ?? endpoints.machineId(forPeer: peer.id)
        var hello = ownHello()
        hello.expect = expected
        try await socket.send(PeerControlMessage(hello: hello))
        guard let answer = try await receiveHello(socket) else {
            socket.close(reason: "no hello")
            throw ControlError.failed(socket.closeReason.map { "closed: \($0)" } ?? "no hello within \(Self.seconds(options.helloTimeout)) s")
        }
        if answer.machine.id == identity.id {
            socket.close(reason: "this is the same machine")
            throw ControlError.failed("this address is this machine")
        }
        if let expected, expected != answer.machine.id {
            socket.close(reason: "expected machine \(expected)", code: 1008)
            throw ControlError.failed("answered as \(answer.machine.name) (\(answer.machine.id)), not \(expected)")
        }
        return answer
    }

    // MARK: - Accepting

    /// Serves a connection this master's server accepted, until it ends.
    /// `device` is the name of the token it came with.
    public func serveAccepted(_ socket: PeerControlSocket, device: String) async {
        track(socket)
        defer { untrack(socket) }
        let from = socket.remoteHost ?? "?"
        if acceptDelay > .zero { try? await Task.sleep(for: acceptDelay) }
        if isSilent {
            // A machine asleep: the connection opens and nothing answers.
            while (try? await socket.receive()) != nil {}
            return
        }
        guard let hello = try? await receiveHello(socket) else {
            socket.close(reason: "no hello within \(Self.seconds(options.helloTimeout)) s", code: 1008)
            KanbanCodeLog.info("peer", "control connection from \(from) (\(device)) sent no hello")
            return
        }
        guard hello.machine.id != identity.id else {
            socket.close(reason: "this is the same machine")
            return
        }
        if let expected = hello.expect, expected != identity.id {
            socket.close(reason: "this is \(identity.name) (\(identity.id)), not \(expected)", code: 1008)
            logRefusal(hello, from: from, "it expects machine \(expected)")
            return
        }
        guard let peer = match(hello, from: socket.remoteHost) else {
            let reason = "\(identity.name) has no peer entry for \(hello.machine.name) (\(hello.machine.id))"
            logRefusal(hello, from: from, "no peer entry")
            socket.close(reason: reason, code: 1008)
            return
        }
        guard peer.enabled else {
            socket.close(reason: "\(identity.name) turned sync with \(peer.name) off", code: 1008)
            logRefusal(hello, from: from, "sync with \(peer.name) is off")
            return
        }
        loggedRefusal[hello.machine.id] = nil
        do {
            try await socket.send(PeerControlMessage(hello: ownHello()))
        } catch {
            return
        }
        learn(peerId: peer.id, machineId: hello.machine.id, promote: nil, hello: hello)
        let connection = Connection(peerId: peer.id, machine: hello.machine, dialer: hello.machine.id,
                                    direction: .accepted, url: nil, socket: socket)
        guard register(connection) else { return }
        let reason = await serve(connection)
        unregister(connection, reason: reason)
    }

    /// The entry an accepted hello belongs to: the one saved as its machine,
    /// else one not saved with a machine that answered a pull as it; else,
    /// among the entries whose machine is not known at all, the one with a
    /// hint at the address it came from or announced, else the only one.
    private func match(_ hello: PeerHello, from host: String?) -> PeerConfig? {
        let peers = endpoints.peers()
        if let peer = peers.first(where: { $0.machineId == hello.machine.id }) { return peer }
        if let peer = peers.first(where: { $0.machineId == nil && endpoints.machineId(forPeer: $0.id) == hello.machine.id }) {
            return peer
        }
        let unknown = peers.filter { endpoints.machineId(forPeer: $0.id) == nil }
        let hosts = Set((hello.addresses + [host].compactMap { $0 }).compactMap { PeerAddress.usableHost($0) })
        if let peer = unknown.first(where: { peer in
            peer.addressHints.contains { PeerAddress.host(of: $0).map(hosts.contains) ?? false }
        }) {
            return peer
        }
        return unknown.count == 1 ? unknown[0] : nil
    }

    // MARK: - Connections

    /// Takes a connection whose hellos went through. When the peer has one
    /// already: one from the same dialer replaces it (the old one is a
    /// leftover of a sleep or a network change); of two dialed from both
    /// ends, the one the lower machine id dialed stays. False when this one
    /// lost and was closed.
    private func register(_ connection: Connection) -> Bool {
        guard let peer = endpoints.peer(connection.peerId), peer.enabled else {
            connection.close("\(identity.name) has no enabled entry for this peer", code: 1008)
            return false
        }
        if let old = connections[connection.peerId] {
            if old.dialer == connection.dialer {
                old.close("replaced by a new connection")
                KanbanCodeLog.info("peer", "\(peer.name) connected again; the old control connection closes")
            } else if connection.dialer < old.dialer {
                old.close("both masters dialed; the connection \(Self.dialerName(connection, local: identity)) dialed stays")
                KanbanCodeLog.info("peer", "both dialed \(peer.name); keeping the one \(Self.dialerName(connection, local: identity)) dialed")
            } else {
                connection.close("both masters dialed; the connection \(Self.dialerName(old, local: identity)) dialed stays")
                return false
            }
        }
        connections[connection.peerId] = connection
        let via = connection.direction == .dialed ? "dialed \(connection.url ?? "")" : "accepted from \(connection.socket.remoteHost ?? "?")"
        KanbanCodeLog.info("peer", "control connection to \(peer.name) (\(connection.machine.name), \(connection.machine.id)) up, \(via)")
        sink.yield(.connected(peerId: connection.peerId, machine: connection.machine, via: connection.direction,
                              url: connection.url, remoteHost: connection.socket.remoteHost))
        return true
    }

    private func unregister(_ connection: Connection, reason: String) {
        guard connections[connection.peerId]?.id == connection.id else { return }
        connections[connection.peerId] = nil
        let lasted = Self.seconds(ContinuousClock.now - connection.openedAt)
        KanbanCodeLog.info("peer", "control connection to \(connection.machine.name) (\(connection.direction.rawValue)) closed after \(lasted) s: \(reason)")
        sink.yield(.disconnected(peerId: connection.peerId, reason: reason))
    }

    /// Reads the connection until it ends, answering pings and passing on
    /// changes, and pings it; closes it once it heard nothing for
    /// `timeout`. Returns why it ended.
    private nonisolated func serve(_ connection: Connection) async -> String {
        let options = self.options
        let watchdog = Task {
            var sinceLastPing = Duration.zero
            let tick = min(options.pingInterval, .seconds(1))
            var seq = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: tick)
                if Task.isCancelled { return }
                if connection.silence > options.timeout, !self.isSilent {
                    connection.close("no answer for \(Self.seconds(options.timeout)) s", code: 1001)
                    return
                }
                sinceLastPing += tick
                if sinceLastPing >= options.pingInterval, !self.isSilent {
                    sinceLastPing = .zero
                    seq += 1
                    try? await connection.socket.send(PeerControlMessage(ping: seq))
                }
            }
        }
        defer { watchdog.cancel() }
        while true {
            let message: PeerControlMessage?
            do {
                message = try await connection.socket.receive()
            } catch {
                if let reason = connection.endReason { return reason }
                connection.close("connection lost")
                return "connection lost: \(Self.describe(error))"
            }
            guard let message else {
                if let reason = connection.endReason { return reason }
                return connection.socket.closeReason.map { "\(connection.machine.name) closed it: \($0)" }
                    ?? "\(connection.machine.name) closed it"
            }
            if isSilent { continue }
            connection.heard()
            if let seq = message.ping {
                try? await connection.socket.send(PeerControlMessage(pong: seq))
            }
            if let change = message.changed {
                sink.yield(.changed(peerId: connection.peerId, machineId: connection.machine.id, change))
            }
        }
    }

    /// The peer's hello: the first hello message within `helloTimeout`, nil
    /// when the socket closed first or the time ran out (then it is closed).
    private nonisolated func receiveHello(_ socket: PeerControlSocket) async throws -> PeerHello? {
        let timeout = options.helloTimeout
        let timer = Task {
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { socket.close(reason: "no hello within \(Self.seconds(timeout)) s", code: 1008) }
        }
        defer { timer.cancel() }
        while let message = try await socket.receive() {
            if let hello = message.hello { return hello }
        }
        return nil
    }

    private func ownHello() -> PeerHello {
        let (addresses, port) = Self.advertised(listening.withLock { $0 }?())
        return PeerHello(machine: identity, version: version, addresses: addresses, port: port)
    }

    /// The addresses to announce: those the server listens on, every
    /// interface's for a wildcard, none of loopback or link-local.
    static func advertised(_ listening: (addresses: [String], port: Int)?) -> (addresses: [String], port: Int?) {
        guard let listening else { return ([], nil) }
        var addresses = listening.addresses.filter { !RemoteNetworkAddresses.wildcards.contains($0) }
        if listening.addresses.contains(where: RemoteNetworkAddresses.wildcards.contains) {
            addresses += RemoteNetworkAddresses.local()
        }
        var seen = Set<String>()
        let usable = addresses.compactMap { PeerAddress.usableHost($0) }.filter { seen.insert($0).inserted }
        return (usable, listening.port)
    }

    // MARK: - Hints

    /// Notes what a connection taught about the entry: its machine id, the
    /// hint that worked (first from now on) and the addresses its hello
    /// announced (tried after the known ones).
    private func learn(peerId: String, machineId: String, promote: String?, hello: PeerHello) {
        guard let peer = endpoints.peer(peerId) else { return }
        let hints = Self.mergedHints(peer.addressHints, promote: promote, announced: hello.hintURLs, limit: options.maxHints)
        guard hints != peer.addressHints || peer.machineId != machineId else { return }
        sink.yield(.learned(peerId: peerId, machineId: machineId, hints: hints))
    }

    /// `hints` with `promote` first and the `announced` ones it lacks after
    /// them, at most `limit`.
    static func mergedHints(_ hints: [String], promote: String?, announced: [String], limit: Int) -> [String] {
        var out = hints
        if let promote {
            let key = PeerEndpoints.normalizedHint(promote)
            out.removeAll { PeerEndpoints.normalizedHint($0) == key }
            out.insert(key, at: 0)
        }
        for url in announced where !out.contains(where: { PeerEndpoints.normalizedHint($0) == url }) {
            out.append(url)
        }
        return Array(out.prefix(max(limit, 1)))
    }

    private func noteHint(_ peerId: String, _ hint: String, worked: Bool) {
        let key = peerId + " " + PeerEndpoints.normalizedHint(hint)
        if worked {
            failingSince[key] = nil
        } else if failingSince[key] == nil {
            failingSince[key] = Date()
        }
    }

    /// Drops the hints of `peer` that failed for `hintExpiry`, never the
    /// last one.
    private func dropExpiredHints(_ peer: PeerConfig) {
        let now = Date()
        var hints = peer.addressHints
        for hint in peer.addressHints where hints.count > 1 {
            let key = peer.id + " " + PeerEndpoints.normalizedHint(hint)
            guard let since = failingSince[key], now.timeIntervalSince(since) >= options.hintExpiry else { continue }
            hints.removeAll { $0 == hint }
            failingSince[key] = nil
            KanbanCodeLog.info("peer", "dropped the address \(hint) of \(peer.name): no answer there for \(Int(options.hintExpiry / 86400)) days")
        }
        guard hints != peer.addressHints, let machineId = endpoints.machineId(forPeer: peer.id) ?? peer.machineId else { return }
        sink.yield(.learned(peerId: peer.id, machineId: machineId, hints: hints))
    }

    // MARK: - Helpers

    /// Logs a refused connection when the reason is new, else every 10
    /// minutes: a refused peer redials every 30 s.
    private func logRefusal(_ hello: PeerHello, from host: String, _ reason: String) {
        let last = loggedRefusal[hello.machine.id]
        guard last?.reason != reason || Date().timeIntervalSince(last?.at ?? .distantPast) > 600 else { return }
        loggedRefusal[hello.machine.id] = (reason, Date())
        KanbanCodeLog.info("peer", "refused a control connection from \(hello.machine.name) (\(hello.machine.id)) at \(host): \(reason)")
    }

    private func track(_ socket: PeerControlSocket) {
        open.withLock { $0[ObjectIdentifier(socket)] = socket }
    }

    private func untrack(_ socket: PeerControlSocket) {
        _ = open.withLock { $0.removeValue(forKey: ObjectIdentifier(socket)) }
    }

    /// Makes this end silent, for tests: it stops pinging, answering and
    /// sending, and leaves its connections open.
    nonisolated func goSilentForTesting() {
        silent.withLock { $0 = true }
    }

    private nonisolated var isSilent: Bool { silent.withLock { $0 } }

    /// Makes accepted connections wait `delay` before their hello, for tests.
    func delayAcceptsForTesting(_ delay: Duration) {
        acceptDelay = delay
    }

    private static func dialerName(_ connection: Connection, local: MachineIdentity) -> String {
        connection.dialer == local.id ? local.name : connection.machine.name
    }

    static func seconds(_ duration: Duration) -> String {
        let value = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        return value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    static func describe(_ error: Error) -> String {
        if let error = error as? RemoteHTTPError {
            switch error {
            case .closed: return "the connection ended"
            case .malformed(let why): return "bad frame: \(why)"
            case .tooLarge: return "message too large"
            }
        }
        if let error = error as? LocalizedError, let text = error.errorDescription { return text }
        return "\(error)"
    }
}
