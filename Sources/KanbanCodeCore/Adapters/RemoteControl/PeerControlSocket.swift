import Foundation
import KanbanCodeRemoteKit
import Synchronization

// MARK: - Wire format

/// One message on a control connection (`GET /v1/peer/control`, see
/// `docs/peer-connections.md`). Exactly one field is set. Unknown fields are
/// ignored, so a later version can add messages.
public struct PeerControlMessage: Codable, Sendable, Equatable {
    /// Who this side is and where it listens. The dialer sends it first;
    /// the listener answers with its own once it took the connection. A
    /// dialer whose Remote Control server started after it dialed sends it
    /// again, so the listener learns its port.
    public var hello: PeerHello?
    /// Something on the sending master changed: the receiver pulls it now.
    public var changed: PeerChange?
    /// Liveness, both ways, every few seconds; answered with `pong`.
    public var ping: Int?
    public var pong: Int?
    /// The listener asks the dialer for stream `open`: a local client
    /// connected to its forward port for the dialer's API. The dialer dials
    /// `GET /v1/peer/stream?id=<open>` back and serves its API on it.
    public var open: Int?
    /// The dialer cannot serve stream `id`: the listener drops the local
    /// connection at once instead of when the wait for it runs out.
    public var refused: PeerStreamRefusal?
    /// The dialer's answer to a hello with `needsToken`: a peer-scope token
    /// it issued for the listener ("Pairing on one side").
    public var token: String?

    public init(hello: PeerHello? = nil, changed: PeerChange? = nil, ping: Int? = nil, pong: Int? = nil,
                open: Int? = nil, refused: PeerStreamRefusal? = nil, token: String? = nil) {
        self.hello = hello
        self.changed = changed
        self.ping = ping
        self.pong = pong
        self.open = open
        self.refused = refused
        self.token = token
    }
}

public struct PeerStreamRefusal: Codable, Sendable, Equatable {
    public var id: Int
    public var reason: String

    public init(id: Int, reason: String) {
        self.id = id
        self.reason = reason
    }
}

public struct PeerHello: Codable, Sendable, Equatable {
    public var machine: MachineIdentity
    public var version: String
    /// The addresses the sender's Remote Control server listens on (not
    /// loopback), with `port`: where the receiver can dial it.
    public var addresses: [String]
    public var port: Int?
    /// The dialer's: the machine id its entry for the listener is saved
    /// with. A listener that is another machine refuses the connection.
    public var expect: String?
    /// The listener's: it has no entry for the dialer. The dialer answers
    /// with a `token` it issued for the listener, and the listener saves an
    /// entry for the dialer with it (`docs/peer-connections.md`, "Pairing on
    /// one side").
    public var needsToken: Bool?

    public init(machine: MachineIdentity, version: String, addresses: [String], port: Int?, expect: String? = nil,
                needsToken: Bool? = nil) {
        self.machine = machine
        self.version = version
        self.addresses = addresses
        self.port = port
        self.expect = expect
        self.needsToken = needsToken
    }

    /// The base URLs `addresses` and `port` make, as address hints.
    public var hintURLs: [String] {
        guard let port, (1...65535).contains(port) else { return [] }
        return addresses.compactMap { PeerAddress.usableHost($0) }.map { host in
            host.contains(":") ? "http://[\(host)]:\(port)" : "http://\(host):\(port)"
        }
    }
}

public struct PeerChange: Codable, Sendable, Equatable {
    public enum What: String, Codable, Sendable {
        /// Cards: pull `GET /v1/links`.
        case links
        /// The agent setup (Settings › Sync): `detail` is what the sync
        /// says changed (`config`, `mirror`, `git:<entry>`, ...).
        case sync
        /// Open attention requests: pull `GET /v1/attention`.
        case attention
    }

    public var what: What
    public var detail: String?

    public init(what: What, detail: String? = nil) {
        self.what = what
        self.detail = detail
    }
}

// MARK: - Socket

/// One end of a control connection: the WebSocket a master dialed, or the
/// one its server accepted. Sends and receives `PeerControlMessage`s.
public final class PeerControlSocket: Sendable {
    let ws: RemoteWebSocket

    init(_ ws: RemoteWebSocket) {
        self.ws = ws
    }

    func send(_ message: PeerControlMessage) async throws {
        let data = try JSONEncoder.remote.encode(message)
        try await ws.sendText(String(decoding: data, as: UTF8.self))
    }

    /// The next message; nil once the connection closed. Frames that are no
    /// message (a newer kind, binary) are skipped.
    func receive() async throws -> PeerControlMessage? {
        while let frame = try await ws.receive() {
            guard case .text(let text) = frame,
                  let message = try? JSONDecoder.remote.decode(PeerControlMessage.self, from: Data(text.utf8))
            else { continue }
            return message
        }
        return nil
    }

    /// Closes with `reason`, which the other side logs and shows.
    func close(reason: String, code: UInt16 = 1000) {
        ws.close(code: code, reason: reason)
    }

    /// Drops the connection without waiting for the close frame to leave:
    /// for one whose network is gone, where that send may never finish.
    func abort() {
        ws.connection.cancel()
    }

    /// The reason the other side gave when it closed, if it did.
    var closeReason: String? {
        guard let close = ws.peerClose else { return nil }
        if !close.reason.isEmpty { return close.reason }
        return close.code == 1001 ? "going away" : "closed (code \(close.code))"
    }

    /// Where the other end connects from, when the transport knows.
    var remoteHost: String? {
        ws.connection.stream.peer?.host
    }
}

// MARK: - Streams

/// The WebSocket of one stream (`GET /v1/peer/stream?id=`), as the server
/// that accepted it hands it to the control connections: the dialer's end of
/// a local client's connection to the forward port.
public final class PeerStreamSocket: Sendable {
    let ws: RemoteWebSocket

    init(_ ws: RemoteWebSocket) {
        self.ws = ws
    }
}

/// Where the Remote Control server takes the streams this master dialed
/// back for its control connections: each is served like a TCP connection,
/// from the tunnel marker (`RemotePeerAddress.tunnel`), never from loopback.
public struct PeerTunnelAcceptor: Sendable {
    let accept: @Sendable (any RemoteByteStream) -> Void

    init(_ accept: @escaping @Sendable (any RemoteByteStream) -> Void) {
        self.accept = accept
    }
}

/// A stream this master dialed back to the peer it holds a control
/// connection with, as the byte stream of one connection to its own Remote
/// Control server: what the peer's local client sends arrives in binary
/// messages, and what the server answers goes back the same way. It never
/// touches a TCP port here, and its peer is the tunnel marker.
final class PeerTunnelStream: RemoteByteStream, @unchecked Sendable {
    private let ws: RemoteWebSocket
    let peer: RemotePeerAddress?
    private let state = Mutex<(closed: Bool, handlers: [@Sendable () -> Void])>((false, []))

    init(_ ws: RemoteWebSocket, peer: RemotePeerAddress) {
        self.ws = ws
        self.peer = peer
    }

    func start(onClose: @escaping @Sendable () -> Void) {
        addCloseHandler(onClose)
    }

    /// Runs `handler` once the stream ended (at once when it did already).
    func addCloseHandler(_ handler: @escaping @Sendable () -> Void) {
        let closed = state.withLock { s -> Bool in
            if !s.closed { s.handlers.append(handler) }
            return s.closed
        }
        if closed { handler() }
    }

    func receive() async throws -> Data? {
        do {
            while let message = try await ws.receive() {
                if case .binary(let data) = message { return data }
            }
        } catch {
            finish()
            throw error
        }
        finish()
        return nil
    }

    func send(_ data: Data, completion: @escaping @Sendable (Error?) -> Void) {
        ws.connection.send(RemoteWebSocket.frames(opcode: .binary, payload: data, masked: ws.role == .client),
                           completion: completion)
    }

    func cancel() {
        ws.close()
        finish()
    }

    /// Closes it with `reason`, which the other side logs.
    func close(reason: String, code: UInt16 = 1000) {
        ws.close(code: code, reason: reason)
        finish()
    }

    private func finish() {
        let handlers = state.withLock { s -> [@Sendable () -> Void] in
            guard !s.closed else { return [] }
            s.closed = true
            defer { s.handlers = [] }
            return s.handlers
        }
        handlers.forEach { $0() }
    }
}
