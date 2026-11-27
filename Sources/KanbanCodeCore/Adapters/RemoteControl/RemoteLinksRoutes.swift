import Foundation
import KanbanCodeRemoteKit

/// What the peer sync routes need from the master that serves them.
public protocol PeerLinksServing: AnyObject, Sendable {
    /// `GET /v1/links`: served cards and tombstones changed after `since`
    /// (all of them when `epoch` is not the current one). `machine` is the
    /// machine id of the peer asking, when it says.
    func linksPage(since: Int?, epoch: String?, machine: String?) async -> LinksPage
    /// `POST /v1/links/changed?machine=`: a peer says its cards changed.
    func peerLinksChanged(machineId: String?) async
    /// `GET /v1/peers`: this machine and the peers it syncs with.
    func peersOverview() async -> PeersOverview
    /// The peer master `machineId` reached this one from `host`, on one of
    /// the routes above.
    func peerReached(machineId: String, host: String) async
    /// `GET /v1/peer/control`: serves a peer's control connection until it
    /// ends. `device` is the token it came with.
    func servePeerControl(_ socket: PeerControlSocket, device: RemoteDevice) async
    /// Where the Remote Control server listens now, while it runs: the
    /// control connections announce it.
    func serverListening(_ provider: @escaping @Sendable () -> (addresses: [String], port: Int)?)
}

extension PeerLinksServing {
    public func peerReached(machineId: String, host: String) async {}
    public func servePeerControl(_ socket: PeerControlSocket, device: RemoteDevice) async {
        socket.close(reason: "this master does not sync with peers", code: 1008)
    }
    public func serverListening(_ provider: @escaping @Sendable () -> (addresses: [String], port: Int)?) {}
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
    /// Where this master reaches the peer now, from `PeerEndpoints`; empty
    /// when it has no address.
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
    /// path is not a peer sync route. `host` is where the request came from.
    static func handle(
        method: String,
        rest: [String],
        query: [String: String],
        from host: String? = nil,
        server: any PeerLinksServing
    ) async -> RemoteHTTPResponse? {
        if rest.first == "links", let host, let machine = query["machine"], !machine.isEmpty {
            await server.peerReached(machineId: machine, host: host)
        }
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
            let machine = query["machine"].flatMap { $0.isEmpty ? nil : $0 }
            return .json(await server.linksPage(since: since, epoch: epoch, machine: machine))

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
    public func linksPage(since: Int?, epoch: String?, machine: String?) async -> LinksPage {
        await store.loadLocalLinks()
        return await MainActor.run { store.peerLinksPage(machine: machine, since: since, epoch: epoch) }
    }

    public func peerLinksChanged(machineId: String?) async {
        await peerSync?.poke(machineId: machineId)
    }

    public func peerReached(machineId: String, host: String) async {
        await peerSync?.noteContact(machineId: machineId, host: host)
    }

    public func servePeerControl(_ socket: PeerControlSocket, device: RemoteDevice) async {
        guard let peerSync else {
            socket.close(reason: "this master does not sync with peers", code: 1008)
            return
        }
        await peerSync.control.serveAccepted(socket, device: device.name)
    }

    public func serverListening(_ provider: @escaping @Sendable () -> (addresses: [String], port: Int)?) {
        peerSync?.control.setListening(provider)
    }

    public func peersOverview() async -> PeersOverview {
        let machine = await MainActor.run { store.localMachine }
        guard let peerSync else { return PeersOverview(machine: machine, peers: []) }
        let peers = await peerSync.configuredPeers()
        var overview: [PeerOverview] = []
        for peer in peers {
            overview.append(PeerOverview(peer: peer, baseURL: peerSync.endpoints.baseURL(forPeer: peer.id),
                                         status: await peerSync.status(of: peer.id)))
        }
        return PeersOverview(machine: machine, peers: overview)
    }
}
