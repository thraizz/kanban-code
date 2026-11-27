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
/// The master that accepted a connection cannot dial its peer, so it gets
/// the peer's API on a loopback forward port instead ("Reverse streams"):
/// each local connection to that port is announced with `open`, the dialer
/// dials `GET /v1/peer/stream?id=` back, and the two are piped together. The
/// dialer serves that stream in-process (`PeerTunnelStream`).
///
/// A listener with no entry for the dialer asks it for a token in its hello;
/// the dialer issues one and the listener saves an entry for it ("Pairing on
/// one side"). A dialer whose own addresses changed (a laptop on another
/// network) redials at once instead of waiting for the ping timeout.
///
/// What happens goes out on `events`, which `PeerSync` follows: connection
/// state, changes the peer announced, entries made by pairing, and what the
/// hellos taught about a peer (its machine id, its addresses).
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
        /// How long a local connection to a forward port waits for the
        /// dialer to answer its `open`.
        public var streamTimeout: Duration
        /// How often this machine's own addresses are compared with the last
        /// ones: one that went away ends the connections this master dialed,
        /// which are redialed at once.
        public var addressCheck: Duration

        public init(
            pingInterval: Duration = .seconds(10),
            timeout: Duration = .seconds(30),
            helloTimeout: Duration = .seconds(10),
            dialTimeout: TimeInterval = 5,
            firstRetry: Duration = .seconds(1),
            maxRetry: Duration = .seconds(30),
            hintExpiry: TimeInterval = 7 * 24 * 3600,
            maxHints: Int = 8,
            streamTimeout: Duration = .seconds(10),
            addressCheck: Duration = .seconds(2)
        ) {
            self.streamTimeout = streamTimeout
            self.addressCheck = addressCheck
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
        /// A peer with no entry here dialed in and gave this master a token
        /// for it: the entry made for it, saved to the settings.
        case paired(PeerConfig)
    }

    /// A live control connection, as `links()` shows it.
    public struct Link: Sendable, Equatable {
        public var peerId: String
        public var machine: MachineIdentity
        public var via: PeerConnectionDirection
        /// Machine id of the master that dialed it.
        public var dialer: String
        public var url: String?
        /// The loopback port the peer's API is forwarded to, for one this
        /// master accepted.
        public var forwardPort: Int?
        /// When the connection's hellos went through.
        public var since: ContinuousClock.Instant
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
        /// The token a dialed connection was dialed with: its streams are
        /// dialed back with it.
        let token: String?
        /// The device whose token an accepted connection came with: its
        /// streams must come with the same one.
        let deviceId: String?
        let openedAt = ContinuousClock.now
        private let state: Mutex<(heard: ContinuousClock.Instant, endReason: String?, address: URL?)>

        init(peerId: String, machine: MachineIdentity, dialer: String, direction: PeerConnectionDirection,
             url: String?, socket: PeerControlSocket, token: String? = nil, deviceId: String? = nil, address: URL? = nil) {
            self.peerId = peerId
            self.machine = machine
            self.dialer = dialer
            self.direction = direction
            self.url = url
            self.socket = socket
            self.token = token
            self.deviceId = deviceId
            state = Mutex((ContinuousClock.now, nil, address))
        }

        /// Where an accepted connection's peer listens: the host it came
        /// from and the port its last hello announced.
        var address: URL? {
            get { state.withLock { $0.address } }
            set { state.withLock { $0.address = newValue } }
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
            Link(peerId: peerId, machine: machine, via: direction, dialer: dialer, url: url, since: openedAt)
        }
    }

    private enum ControlError: Error, LocalizedError {
        case failed(String)
        var errorDescription: String? {
            switch self { case .failed(let reason): reason }
        }
    }

    public static let path = "/v1/peer/control"
    public static let streamPath = "/v1/peer/stream"

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
    /// Why this master closed every connection, once it stopped. From then
    /// on it dials nothing and takes nothing: a stopping server that
    /// redialed its peer would leave it a connection that dies with the
    /// process a moment later.
    private nonisolated let stopped = Mutex<String?>(nil)
    private nonisolated let listening = Mutex<(@Sendable () -> (addresses: [String], port: Int)?)?>(nil)
    /// Set by tests: this end goes silent (sends nothing, answers nothing)
    /// with its connections left open, as a machine that went to sleep.
    private nonisolated let silent = Mutex(false)
    /// Set by tests: an accepted connection waits this long before it
    /// reads the hello, so two masters surely dial each other at once.
    private var acceptDelay: Duration = .zero
    /// Issues the peer-scope token a listener with no entry for this master
    /// asks for (the peer entry, the listener's machine); nil while this
    /// master cannot issue one.
    private nonisolated let tokenIssuer = Mutex<(@Sendable (PeerConfig, MachineIdentity) async -> String?)?>(nil)
    /// This machine's own addresses, as the address check reads them.
    private nonisolated let localAddresses = Mutex<@Sendable () -> [String]>({ RemoteNetworkAddresses.local() })
    /// Peers whose connection ended because this machine's network changed:
    /// they are redialed at once.
    private var redialAtOnce: Set<String> = []

    /// A loopback listener that forwards to a peer's API.
    private struct Forward {
        let listener: any RemoteListener
        let port: Int
    }

    /// A local connection to a forward port, waiting for the dialer to dial
    /// its stream back.
    private struct PendingStream {
        let connectionId: UUID
        let peerId: String
        let local: any RemoteByteStream
        let timer: Task<Void, Never>
    }

    /// The forward listener of each peer whose control connection this
    /// master accepted, by peer id. It lives while the peer's connection is
    /// one this master accepted: a connection that replaces another keeps it.
    private var forwards: [String: Forward] = [:]
    /// The port each peer's forward listener last had: a reconnect binds it
    /// again when it is free, so a terminal's attach command that holds the
    /// URL keeps working.
    private var forwardPorts: [String: Int] = [:]
    private var nextStreamId = 1
    private var pendingStreams: [Int: PendingStream] = [:]
    /// What closes each open stream, by connection and stream id: a stream
    /// ends with the control connection it was opened for.
    private var liveStreams: [UUID: [Int: @Sendable () -> Void]] = [:]
    /// The last stream failure logged per peer, to log a change, not every one.
    private var loggedStreamFailure: [String: (reason: String, at: Date)] = [:]
    /// Where this master's Remote Control server takes the streams it
    /// dials back; nil while it does not run.
    private nonisolated let tunnels = Mutex<PeerTunnelAcceptor?>(nil)
    private nonisolated let forwardQueue = DispatchQueue(label: "kanban.peer.forward")

    public init(identity: MachineIdentity, endpoints: PeerEndpoints, version: String, options: Options = Options()) {
        self.identity = identity
        self.endpoints = endpoints
        self.version = version
        self.options = options
        (events, sink) = AsyncStream<Event>.makeStream(bufferingPolicy: .unbounded)
    }

    // MARK: - Configuration

    /// Sets what issues the peer-scope token a listener with no entry for
    /// this master asks for on a connection this master dialed ("Pairing on
    /// one side"). It gets this master's entry for the listener and the
    /// machine the listener's hello said it is; nil when it cannot.
    public nonisolated func setTokenIssuer(_ issue: (@Sendable (PeerConfig, MachineIdentity) async -> String?)?) {
        tokenIssuer.withLock { $0 = issue }
    }

    /// Sets where this master's Remote Control server listens, for the
    /// hello: the server calls it when it starts.
    public nonisolated func setListening(_ provider: (@Sendable () -> (addresses: [String], port: Int)?)?) {
        listening.withLock { $0 = provider }
    }

    /// Sets where the streams this master dials back for its peers are
    /// served: the Remote Control server, when it starts.
    public nonisolated func setTunnels(_ acceptor: PeerTunnelAcceptor?) {
        let started = tunnels.withLock { current -> Bool in
            defer { current = acceptor }
            return current == nil && acceptor != nil
        }
        if started { Task { await self.serverStarted() } }
    }

    /// The Remote Control server started after connections were dialed (the
    /// app dials while its server still starts): what their peers called
    /// through them was refused, so they are told to call again now. The
    /// hello goes again too: the first one had no port, so the peer did not
    /// know where this master listens.
    private func serverStarted() async {
        for connection in connections.values where connection.direction == .dialed && !isSilent {
            var hello = ownHello()
            hello.expect = connection.machine.id
            try? await connection.socket.send(PeerControlMessage(hello: hello))
            for what in [PeerChange.What.links, .sync, .attention] {
                try? await connection.socket.send(PeerControlMessage(changed: PeerChange(what: what)))
            }
        }
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
        connections.values.map { connection in
            var link = connection.link
            if connection.direction == .accepted { link.forwardPort = forwards[connection.peerId]?.port }
            return link
        }.sorted { $0.peerId < $1.peerId }
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
    /// connection. From its start a peer is called only through its
    /// control connection (`PeerEndpoints`).
    public func run() async {
        endpoints.setControlRunning()
        var addresses = Set(localAddresses.withLock { $0 }())
        var lastCheck = ContinuousClock.now
        await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                while !Task.isCancelled {
                    let now = ContinuousClock.now
                    if now - lastCheck >= options.addressCheck {
                        lastCheck = now
                        let current = Set(localAddresses.withLock { $0 }())
                        let gone = addresses.subtracting(current)
                        addresses = current
                        if !gone.isEmpty { networkChanged(gone: gone, now: current) }
                    }
                    for peer in endpoints.peers() where !isSilent && !isStopping && peer.enabled && !peer.addressHints.isEmpty
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

    /// An address of this machine went away (a laptop that changed
    /// networks, or went to sleep on one and woke on another): the
    /// connections this master dialed went out from it and are dead, but
    /// would only show it once the ping timeout ran out. They close now and
    /// are redialed at once; the peer takes the new connection in place of
    /// the old one. Peers not connected are tried again at once too.
    private func networkChanged(gone: Set<String>, now current: Set<String>) {
        let dialed = connections.values.filter { $0.direction == .dialed }
        KanbanCodeLog.info("peer", "this machine's addresses changed (gone: \(gone.sorted().joined(separator: ", ")); now: "
            + "\(current.sorted().joined(separator: ", "))): redialing \(dialed.count) control connection(s)")
        for connection in dialed {
            redialAtOnce.insert(connection.peerId)
            connection.close("\(identity.name)'s network changed", code: 1001)
            // On a dead path the close frame may never leave, and the
            // connection would wait for it.
            let socket = connection.socket
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                socket.abort()
            }
        }
        for peer in endpoints.peers() where connections[peer.id] == nil {
            nextDial[peer.id] = nil
            retry[peer.id] = nil
        }
    }

    /// Makes the address check read `addresses` instead of this machine's
    /// interfaces, for tests.
    nonisolated func setLocalAddressesForTesting(_ addresses: @escaping @Sendable () -> [String]) {
        localAddresses.withLock { $0 = addresses }
    }

    /// Closes every connection, as a master that stops, and dials or takes
    /// none after that. Each connection ends with `reason` on both ends.
    public nonisolated func stop(reason: String = "stopping") {
        stopped.withLock { if $0 == nil { $0 = reason } }
        let sockets = open.withLock { Array($0.values) }
        for socket in sockets { socket.close(reason: reason, code: 1001) }
    }

    /// Whether this master stopped (`stop`): it is shutting down.
    public nonisolated var isStopping: Bool { stopped.withLock { $0 != nil } }

    private nonisolated var stopReason: String? { stopped.withLock { $0 } }

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
            learn(peerId: peer.id, machineId: hello.machine.id, promote: hint, announced: hello.hintURLs)
            let connection = Connection(peerId: peer.id, machine: hello.machine, dialer: identity.id,
                                        direction: .dialed, url: PeerEndpoints.normalizedHint(hint), socket: socket,
                                        token: peer.token)
            guard register(connection) else { return }
            announce(connection)
            let reason = await serve(connection)
            unregister(connection, reason: reason)
            connectionEnded(connection)
            if redialAtOnce.remove(peer.id) != nil {
                // This machine's network changed: the peer is there still.
                retry[peer.id] = nil
                nextDial[peer.id] = nil
                return
            }
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
    /// says. A peer that has no entry for this master gets a token for it
    /// here, after its hello showed which machine it is.
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
        if answer.needsToken == true {
            try await issueToken(on: socket, peer: peer, listener: answer.machine)
        }
        return answer
    }

    /// The listener has no entry for this master: issues it a peer-scope
    /// token and sends it on the connection this master dialed, to the
    /// machine its entry expects. Closes and throws when it cannot.
    private func issueToken(on socket: PeerControlSocket, peer: PeerConfig, listener: MachineIdentity) async throws {
        guard let issue = tokenIssuer.withLock({ $0 }) else {
            socket.close(reason: "\(identity.name) cannot issue \(listener.name) a token", code: 1008)
            throw ControlError.failed("\(listener.name) has no entry for this master, and this master cannot issue it a token")
        }
        guard let token = await issue(peer, listener), !token.isEmpty else {
            socket.close(reason: "\(identity.name) could not issue \(listener.name) a token", code: 1008)
            throw ControlError.failed("\(listener.name) has no entry for this master, and issuing it a token failed")
        }
        try await socket.send(PeerControlMessage(token: token))
        KanbanCodeLog.info("peer", "\(listener.name) (\(listener.id)) had no entry for this master: issued it a peer token over the connection")
    }

    // MARK: - Accepting

    /// Serves a connection this master's server accepted, until it ends.
    /// `device` is the name of the token it came with, `deviceId` its id:
    /// the streams of the connection must come with the same token. With
    /// `pairs` (a peer-scope token, one this master issued to a peer
    /// master), a dialer with no entry here is asked for a token and gets
    /// an entry made for it, else it is refused.
    public func serveAccepted(_ socket: PeerControlSocket, device: String, deviceId: String? = nil, pairs: Bool = false) async {
        track(socket)
        defer { untrack(socket) }
        if let reason = stopReason {
            socket.close(reason: reason, code: 1001)
            return
        }
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
        var answered = false
        let peer: PeerConfig
        if let matched = match(hello, from: socket.remoteHost) {
            peer = matched
        } else {
            guard pairs else {
                let reason = "\(identity.name) has no peer entry for \(hello.machine.name) (\(hello.machine.id))"
                logRefusal(hello, from: from, "no peer entry")
                socket.close(reason: reason, code: 1008)
                return
            }
            guard let paired = await pair(socket, hello: hello, from: from) else { return }
            peer = paired
            answered = true
        }
        guard peer.enabled else {
            socket.close(reason: "\(identity.name) turned sync with \(peer.name) off", code: 1008)
            logRefusal(hello, from: from, "sync with \(peer.name) is off")
            return
        }
        loggedRefusal[hello.machine.id] = nil
        if !answered {
            do {
                try await socket.send(PeerControlMessage(hello: ownHello()))
            } catch {
                return
            }
        }
        // The machine id only: the addresses of a peer that dials in are
        // not kept. It reaches this master on its own, and they are the
        // ones that change (a laptop's).
        learn(peerId: peer.id, machineId: hello.machine.id, promote: nil, announced: [])
        let connection = Connection(peerId: peer.id, machine: hello.machine, dialer: hello.machine.id,
                                    direction: .accepted, url: nil, socket: socket, deviceId: deviceId,
                                    address: Self.origin(host: socket.remoteHost, hello: hello))
        guard register(connection) else { return }
        // The peer's API is reached through this connection from now on.
        await openForward(for: connection)
        announce(connection)
        let reason = await serve(connection)
        unregister(connection, reason: reason)
        connectionEnded(connection)
    }

    /// Pairing on one side: the dialer has a token this master issued, but
    /// no entry here. The answer hello asks it for a token; with it, this
    /// master makes an entry for the dialer (its machine id and name, the
    /// token, no address) and saves it. Nil, the connection closed, when no
    /// token came.
    private func pair(_ socket: PeerControlSocket, hello: PeerHello, from: String) async -> PeerConfig? {
        var answer = ownHello()
        answer.needsToken = true
        do {
            try await socket.send(PeerControlMessage(hello: answer))
        } catch {
            return nil
        }
        guard let token = try? await receiveToken(socket), !token.isEmpty else {
            let why = socket.closeReason ?? "no token within \(Self.seconds(options.helloTimeout)) s"
            socket.close(reason: "\(identity.name) has no peer entry for \(hello.machine.name) and got no token for one", code: 1008)
            logRefusal(hello, from: from, "no peer entry, and no token for one: \(why)")
            return nil
        }
        var entry = PeerConfig(machineId: hello.machine.id, name: hello.machine.name, addressHints: [], token: token)
        if let existing = endpoints.peers().first(where: { $0.machineId == hello.machine.id }) {
            // Made meanwhile by another connection of the same dialer: the
            // token issued last is the one that works.
            entry = existing
            entry.token = token
        }
        endpoints.addPeer(entry)
        sink.yield(.paired(entry))
        KanbanCodeLog.info("peer", "paired with \(hello.machine.name) (\(hello.machine.id)) from \(from): "
            + "it issued this master a token on its control connection; no address is kept for it")
        return entry
    }

    /// Where a peer that dialed in from `host` listens: that host, at the
    /// port its hello announced. Nil when either is unusable.
    static func origin(host: String?, hello: PeerHello) -> URL? {
        guard let host = host.flatMap(PeerAddress.usableHost), let port = hello.port, (1...65535).contains(port)
        else { return nil }
        return URL(string: host.contains(":") ? "http://[\(host)]:\(port)" : "http://\(host):\(port)")
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
        if let reason = stopReason {
            connection.close(reason, code: 1001)
            return false
        }
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
        liveStreams[connection.id] = [:]
        // A forward port is for a connection this master accepted.
        settleForward(connection.peerId)
        return true
    }

    /// Calls to the peer take the connection from now on (when it is still
    /// the peer's): its dialed hint, or the forward port of one accepted.
    private func announce(_ connection: Connection) {
        guard connections[connection.peerId]?.id == connection.id else { return }
        let name = endpoints.peer(connection.peerId)?.name ?? connection.machine.name
        let via: String
        switch connection.direction {
        case .dialed:
            let url = connection.url.flatMap(PeerEndpoints.baseURL(fromHint:))
            endpoints.setRoute(url, address: url, forPeer: connection.peerId)
            via = "dialed \(connection.url ?? "")"
        case .accepted:
            let forward = forwards[connection.peerId]
            endpoints.setRoute(forward.map { PeerEndpoints.forwardURL(port: $0.port) }, address: connection.address,
                               forPeer: connection.peerId)
            via = "accepted from \(connection.socket.remoteHost ?? "?")"
                + (forward.map { ", its API on 127.0.0.1:\($0.port)" } ?? ", no forward port")
        }
        KanbanCodeLog.info("peer", "control connection to \(name) (\(connection.machine.name), \(connection.machine.id)) up, \(via)")
        sink.yield(.connected(peerId: connection.peerId, machine: connection.machine, via: connection.direction,
                              url: connection.url, remoteHost: connection.socket.remoteHost))
    }

    private func unregister(_ connection: Connection, reason: String) {
        guard connections[connection.peerId]?.id == connection.id else { return }
        connections[connection.peerId] = nil
        endpoints.setRoute(nil, address: nil, forPeer: connection.peerId)
        settleForward(connection.peerId)
        let lasted = Self.seconds(ContinuousClock.now - connection.openedAt)
        KanbanCodeLog.info("peer", "control connection to \(connection.machine.name) (\(connection.direction.rawValue)) closed after \(lasted) s: \(reason)")
        sink.yield(.disconnected(peerId: connection.peerId, reason: reason))
    }

    /// A connection's serving ended, whether or not it was the peer's
    /// current one: its streams close, and local connections still waiting
    /// for one fail.
    private func connectionEnded(_ connection: Connection) {
        for close in (liveStreams.removeValue(forKey: connection.id) ?? [:]).values { close() }
        for (id, pending) in pendingStreams where pending.connectionId == connection.id {
            dropStream(id, reason: "the control connection closed")
        }
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
                // This end closed it (a stop included): its own reason, not
                // how the socket ended.
                if let reason = connection.endReason ?? stopReason { return reason }
                connection.close("connection lost")
                return "connection lost: \(Self.describe(error))"
            }
            guard let message else {
                // A stop's close frame comes back as the peer's answer; the
                // peer did not close it.
                if let reason = connection.endReason ?? stopReason { return reason }
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
            if let id = message.open, connection.direction == .dialed {
                Task { await self.answerOpen(id, on: connection) }
            }
            if let refusal = message.refused, connection.direction == .accepted {
                await streamRefused(refusal, on: connection)
            }
            if let hello = message.hello, connection.direction == .accepted, hello.machine.id == connection.machine.id {
                await helloAgain(hello, on: connection)
            }
        }
    }

    /// A dialer's later hello (its server started after it dialed): where it
    /// listens is known now.
    private func helloAgain(_ hello: PeerHello, on connection: Connection) {
        let address = Self.origin(host: connection.socket.remoteHost, hello: hello)
        guard address != nil, address != connection.address else { return }
        connection.address = address
        guard connections[connection.peerId]?.id == connection.id else { return }
        endpoints.setRouteAddress(address, forPeer: connection.peerId)
    }

    /// The peer's hello: the first hello message within `helloTimeout`, nil
    /// when the socket closed first or the time ran out (then it is closed).
    private nonisolated func receiveHello(_ socket: PeerControlSocket) async throws -> PeerHello? {
        try await receiveFirst(socket, what: "hello") { $0.hello }
    }

    /// The dialer's token, after a hello that asked for one; nil like
    /// `receiveHello`.
    private nonisolated func receiveToken(_ socket: PeerControlSocket) async throws -> String? {
        try await receiveFirst(socket, what: "token") { $0.token }
    }

    private nonisolated func receiveFirst<T: Sendable>(
        _ socket: PeerControlSocket, what: String, _ pick: (PeerControlMessage) -> T?
    ) async throws -> T? {
        let timeout = options.helloTimeout
        let timer = Task {
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { socket.close(reason: "no \(what) within \(Self.seconds(timeout)) s", code: 1008) }
        }
        defer { timer.cancel() }
        while let message = try await socket.receive() {
            if let value = pick(message) { return value }
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

    // MARK: - Reverse streams

    /// Makes sure the peer of `connection`, which this master accepted, has
    /// its loopback forward port: the same port as before when it is free.
    private func openForward(for connection: Connection) async {
        let peerId = connection.peerId
        if forwards[peerId] == nil {
            let wanted = forwardPorts[peerId]
            var bound: (any RemoteListener)?
            var failure = ""
            for port in [wanted, 0].compactMap({ $0 }) {
                do {
                    bound = try await RemoteTransport.listen(
                        address: RemoteNetworkAddresses.loopback, port: port, queue: forwardQueue,
                        onAccept: Self.forwardHandler(control: self, peerId: peerId))
                    break
                } catch {
                    failure = "\(error)"
                }
            }
            if let bound {
                if forwards[peerId] == nil {
                    forwards[peerId] = Forward(listener: bound, port: bound.port)
                    forwardPorts[peerId] = bound.port
                } else {
                    bound.cancel()
                }
            } else {
                KanbanCodeLog.warn("peer", "no forward port for \(connection.machine.name): \(failure)")
            }
        }
        // Another connection may have taken the peer's place meanwhile.
        settleForward(peerId)
    }

    /// What a forward listener does with a local connection: it waits for
    /// the dialer's stream. Not isolated: it runs on the listener's queue.
    private nonisolated static func forwardHandler(
        control: PeerControl, peerId: String
    ) -> @Sendable (any RemoteByteStream) -> Void {
        { [weak control] stream in
            guard let control else {
                stream.cancel()
                return
            }
            stream.start(onClose: {})
            Task { await control.forward(stream, peerId: peerId) }
        }
    }

    /// Closes the forward listener of `peerId` unless an accepted control
    /// connection is the peer's now.
    private func settleForward(_ peerId: String) {
        guard connections[peerId]?.direction != .accepted, let forward = forwards.removeValue(forKey: peerId) else { return }
        forward.listener.cancel()
    }

    /// A local client connected to the forward port of `peerId`: asks the
    /// dialer for a stream to carry it, and drops it when none comes within
    /// `streamTimeout`.
    private func forward(_ local: any RemoteByteStream, peerId: String) async {
        guard let connection = connections[peerId], connection.direction == .accepted, !isSilent else {
            local.cancel()
            return
        }
        let id = nextStreamId
        nextStreamId += 1
        let timeout = options.streamTimeout
        let name = connection.machine.name
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.dropStream(id, reason: "\(name) did not answer within \(Self.seconds(timeout)) s")
        }
        pendingStreams[id] = PendingStream(connectionId: connection.id, peerId: peerId, local: local, timer: timer)
        do {
            try await connection.socket.send(PeerControlMessage(open: id))
        } catch {
            dropStream(id, reason: "the control connection to \(name) failed: \(Self.describe(error))")
        }
    }

    /// Fails the local connection waiting for stream `id`.
    private func dropStream(_ id: Int, reason: String) {
        guard let pending = pendingStreams.removeValue(forKey: id) else { return }
        pending.timer.cancel()
        pending.local.cancel()
        let name = endpoints.peer(pending.peerId)?.name ?? pending.peerId
        let last = loggedStreamFailure[pending.peerId]
        guard last?.reason != reason || Date().timeIntervalSince(last?.at ?? .distantPast) > 600 else { return }
        loggedStreamFailure[pending.peerId] = (reason, Date())
        KanbanCodeLog.info("peer", "a call to \(name) through its control connection failed: \(reason)")
    }

    private func streamRefused(_ refusal: PeerStreamRefusal, on connection: Connection) {
        guard pendingStreams[refusal.id]?.connectionId == connection.id else { return }
        dropStream(refusal.id, reason: "\(connection.machine.name) refused it: \(refusal.reason)")
    }

    /// `GET /v1/peer/stream?id=`: the dialer of a control connection this
    /// master accepted dialed stream `id` back, with the token of
    /// `deviceId`. Pipes it to the local client waiting for it until either
    /// end closes.
    public func serveStream(_ socket: PeerStreamSocket, id: Int, deviceId: String) async {
        let ws = socket.ws
        guard let pending = pendingStreams[id] else {
            ws.close(code: 1008, reason: "no stream \(id) waits here")
            return
        }
        guard let connection = connections[pending.peerId], connection.id == pending.connectionId,
              connection.deviceId == deviceId, liveStreams[connection.id] != nil
        else {
            ws.close(code: 1008, reason: "stream \(id) belongs to another connection")
            return
        }
        pendingStreams[id] = nil
        pending.timer.cancel()
        let local = pending.local
        liveStreams[connection.id]?[id] = {
            ws.close(code: 1001, reason: "the control connection closed")
            local.cancel()
        }
        loggedStreamFailure[pending.peerId] = nil
        await Self.pipe(local: local, ws: ws)
        liveStreams[connection.id]?[id] = nil
    }

    /// The listener asked for stream `id` on `connection`, which this master
    /// dialed: dials it back and hands it to this master's Remote Control
    /// server, or says why not.
    private nonisolated func answerOpen(_ id: Int, on connection: Connection) async {
        func refuse(_ reason: String) async {
            try? await connection.socket.send(PeerControlMessage(refused: PeerStreamRefusal(id: id, reason: reason)))
        }
        if let reason = stopReason { return await refuse(reason) }
        guard let acceptor = tunnels.withLock({ $0 }) else {
            return await refuse("\(identity.name) runs no Remote Control server")
        }
        guard let base = connection.url.flatMap(PeerEndpoints.baseURL(fromHint:)), let token = connection.token else {
            return await refuse("no address to dial the stream back to")
        }
        let ws: RemoteWebSocket
        do {
            ws = try await RemoteWebSocketClient.connect(
                baseURL: base, path: Self.streamPath, query: [URLQueryItem(name: "id", value: String(id))],
                token: token, timeout: options.dialTimeout)
        } catch {
            return await refuse(Self.describe(error))
        }
        let stream = PeerTunnelStream(ws, peer: .tunnel(connection.machine.id))
        guard await trackDialedStream(stream, id: id, on: connection) else {
            stream.close(reason: "the control connection closed", code: 1001)
            return
        }
        acceptor.accept(stream)
    }

    /// Notes a stream this master dialed back for `connection`, to close it
    /// with the connection. False when the connection ended already.
    private func trackDialedStream(_ stream: PeerTunnelStream, id: Int, on connection: Connection) -> Bool {
        guard liveStreams[connection.id] != nil else { return false }
        liveStreams[connection.id]?[id] = { stream.close(reason: "the control connection closed", code: 1001) }
        let connectionId = connection.id
        stream.addCloseHandler { [weak self] in
            Task { await self?.untrackStream(id, connectionId: connectionId) }
        }
        return true
    }

    private func untrackStream(_ id: Int, connectionId: UUID) {
        liveStreams[connectionId]?[id] = nil
    }

    /// Pipes a local connection and a stream's WebSocket into each other:
    /// the local bytes go out as binary messages, the messages that come in
    /// go to the local connection. Waits for each send, so a slow end slows
    /// the other instead of filling memory. Ends once both directions did.
    static func pipe(local: any RemoteByteStream, ws: RemoteWebSocket) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                while let data = try? await local.receive() {
                    if data.isEmpty { continue }
                    do { try await ws.sendBinary(data) } catch { break }
                }
                // The close travels after the data sent before it.
                ws.close()
            }
            group.addTask {
                while let message = try? await ws.receive() {
                    guard case .binary(let data) = message else { continue }
                    guard await send(data, to: local) else { break }
                }
                local.cancel()
            }
        }
    }

    private static func send(_ data: Data, to stream: any RemoteByteStream) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            stream.send(data) { error in cont.resume(returning: error == nil) }
        }
    }

    // MARK: - Hints

    /// Notes what a connection taught about the entry: its machine id, the
    /// hint that worked (first from now on) and the addresses the hello of a
    /// peer this master dialed announced (tried after the known ones).
    private func learn(peerId: String, machineId: String, promote: String?, announced: [String]) {
        guard let peer = endpoints.peer(peerId) else { return }
        let hints = Self.mergedHints(peer.addressHints, promote: promote, announced: announced, limit: options.maxHints)
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

    /// Notes an open socket, so a stop closes it; one opened after the stop
    /// (a dial that was under way) closes at once.
    private func track(_ socket: PeerControlSocket) {
        open.withLock { $0[ObjectIdentifier(socket)] = socket }
        if let reason = stopReason { socket.close(reason: reason, code: 1001) }
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
