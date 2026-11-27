import Foundation
import KanbanCodeRemoteKit

/// What the peer sync routes need from the master that serves them.
public protocol PeerLinksServing: AnyObject, Sendable {
    /// `GET /v1/links`: served cards and tombstones changed after `since`
    /// (all of them when `epoch` is not the current one).
    func linksPage(since: Int?, epoch: String?) async -> LinksPage
    /// `POST /v1/links/changed?machine=`: a peer of an older build says its
    /// cards changed (newer ones say so on the control connection).
    func peerLinksChanged(machineId: String?) async
    /// `GET /v1/peers`: this machine and the peers it syncs with.
    func peersOverview() async -> PeersOverview
    /// `GET /v1/peer/control`: serves a peer's control connection until it
    /// ends. `device` is the token it came with; a peer-scope one may pair
    /// a peer that has no entry here.
    func servePeerControl(_ socket: PeerControlSocket, device: RemoteDevice) async
    /// Where the Remote Control server listens now, while it runs: the
    /// control connections announce it.
    func serverListening(_ provider: @escaping @Sendable () -> (addresses: [String], port: Int)?)
    /// `GET /v1/peer/stream?id=`: serves the stream `id` the dialer of a
    /// control connection dialed back, until it ends.
    func servePeerStream(_ socket: PeerStreamSocket, id: Int, device: RemoteDevice) async
    /// Where the Remote Control server takes the streams this master dials
    /// back for its control connections.
    func serverTunnels(_ acceptor: PeerTunnelAcceptor)
}

extension PeerLinksServing {
    public func servePeerControl(_ socket: PeerControlSocket, device: RemoteDevice) async {
        socket.close(reason: "this master does not sync with peers", code: 1008)
    }
    public func serverListening(_ provider: @escaping @Sendable () -> (addresses: [String], port: Int)?) {}
    public func servePeerStream(_ socket: PeerStreamSocket, id: Int, device: RemoteDevice) async {
        socket.ws.close(code: 1008, reason: "this master does not sync with peers")
    }
    public func serverTunnels(_ acceptor: PeerTunnelAcceptor) {}
}

/// Body of `GET /v1/peers`.
public struct PeersOverview: Codable, Sendable, Equatable {
    public var machine: MachineIdentity
    public var peers: [PeerOverview]

    public init(machine: MachineIdentity, peers: [PeerOverview]) {
        self.machine = machine
        self.peers = peers
    }
}

/// A configured peer as `GET /v1/peers` shows it: never the token.
public struct PeerOverview: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    /// A real address of the peer (never the forward port its calls may go
    /// to): the one of its connection, else the last one known, else its
    /// first hint; empty when there is none (a peer that dials this master
    /// and has not yet).
    public var url: String
    public var enabled: Bool
    public var status: PeerStatus?

    public init(peer: PeerConfig, baseURL: URL?, status: PeerStatus?) {
        id = peer.id
        name = peer.name
        url = baseURL?.absoluteString ?? ""
        enabled = peer.enabled
        self.status = status
    }
}

/// The peer sync routes of the Remote Control server, as a plain function
/// the server calls after it authenticated the device.
enum RemoteLinksRoutes {
    /// Answers `method` on `rest` (the path after `/v1/`), or nil when the
    /// path is not a peer sync route.
    static func handle(
        method: String,
        rest: [String],
        query: [String: String],
        server: any PeerLinksServing
    ) async -> RemoteHTTPResponse? {
        switch rest {
        case ["links"]:
            guard method == "GET" else { return .error(405, "use GET") }
            var since: Int?
            if let raw = query["since"], !raw.isEmpty {
                guard let value = Int(raw), value >= 0 else {
                    return .error(400, "since must be a non-negative integer")
                }
                since = value
            }
            let epoch = query["epoch"].flatMap { $0.isEmpty ? nil : $0 }
            return .json(await server.linksPage(since: since, epoch: epoch))

        case ["links", "changed"]:
            guard method == "POST" else { return .error(405, "use POST") }
            await server.peerLinksChanged(machineId: query["machine"])
            return .noContent

        case ["peers"]:
            guard method == "GET" else { return .error(405, "use GET") }
            return .json(await server.peersOverview())

        default:
            return nil
        }
    }
}

/// Serves the peer sync routes from a board and its sync loop.
public final class BoardPeerLinksServer: PeerLinksServing {
    private let store: BoardStore
    private let peerSync: PeerSync?

    public init(store: BoardStore, peerSync: PeerSync?) {
        self.store = store
        self.peerSync = peerSync
    }

    /// A peer is served this master's links only once they are loaded: an
    /// earlier page would be a full page of nothing, with a cursor past it.
    public func linksPage(since: Int?, epoch: String?) async -> LinksPage {
        await store.loadLocalLinks()
        return await MainActor.run { store.peerLinksPage(since: since, epoch: epoch) }
    }

    public func peerLinksChanged(machineId: String?) async {
        await peerSync?.poke(machineId: machineId)
    }

    public func servePeerControl(_ socket: PeerControlSocket, device: RemoteDevice) async {
        guard let peerSync else {
            socket.close(reason: "this master does not sync with peers", code: 1008)
            return
        }
        await peerSync.control.serveAccepted(socket, device: device.name, deviceId: device.id, pairs: device.scope == .peer)
    }

    public func serverListening(_ provider: @escaping @Sendable () -> (addresses: [String], port: Int)?) {
        peerSync?.control.setListening(provider)
    }

    public func servePeerStream(_ socket: PeerStreamSocket, id: Int, device: RemoteDevice) async {
        guard let peerSync else {
            socket.ws.close(code: 1008, reason: "this master does not sync with peers")
            return
        }
        await peerSync.control.serveStream(socket, id: id, deviceId: device.id)
    }

    public func serverTunnels(_ acceptor: PeerTunnelAcceptor) {
        peerSync?.control.setTunnels(acceptor)
    }

    public func peersOverview() async -> PeersOverview {
        let machine = await MainActor.run { store.localMachine }
        guard let peerSync else { return PeersOverview(machine: machine, peers: []) }
        let peers = await peerSync.configuredPeers()
        var overview: [PeerOverview] = []
        for peer in peers {
            // A real address, never a forward port.
            let status = await peerSync.status(of: peer.id)
            let address = peerSync.endpoints.endpoint(forPeer: peer.id)?.address
                ?? status?.url.flatMap(URL.init(string:))
                ?? PeerEndpoints.configuredURL(peer)
            overview.append(PeerOverview(peer: peer, baseURL: address, status: status))
        }
        return PeersOverview(machine: machine, peers: overview)
    }
}
