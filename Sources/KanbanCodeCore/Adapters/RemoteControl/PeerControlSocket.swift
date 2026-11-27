import Foundation
import KanbanCodeRemoteKit

// MARK: - Wire format

/// One message on a control connection (`GET /v1/peer/control`, see
/// `docs/peer-connections.md`). Exactly one field is set. Unknown fields are
/// ignored, so a later version can add messages.
public struct PeerControlMessage: Codable, Sendable, Equatable {
    /// Who this side is and where it listens. The dialer sends it first;
    /// the listener answers with its own once it took the connection.
    public var hello: PeerHello?
    /// Something on the sending master changed: the receiver pulls it now.
    public var changed: PeerChange?
    /// Liveness, both ways, every few seconds; answered with `pong`.
    public var ping: Int?
    public var pong: Int?

    public init(hello: PeerHello? = nil, changed: PeerChange? = nil, ping: Int? = nil, pong: Int? = nil) {
        self.hello = hello
        self.changed = changed
        self.ping = ping
        self.pong = pong
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

    public init(machine: MachineIdentity, version: String, addresses: [String], port: Int?, expect: String? = nil) {
        self.machine = machine
        self.version = version
        self.addresses = addresses
        self.port = port
        self.expect = expect
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
