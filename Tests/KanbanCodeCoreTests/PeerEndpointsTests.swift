import Foundation
import Testing
@testable import KanbanCodeCore

/// Answers every pull with one page, the way a peer at any address would.
private final class OnePageTransport: PeerLinksTransport, @unchecked Sendable {
    let page: LinksPage
    let lock = NSLock()
    var asked: [String] = []

    init(page: LinksPage) { self.page = page }

    func fetchLinks(from peer: PeerEndpoint, since: Int?, epoch: String?, machineId: String?) async throws -> LinksPage {
        lock.withLock { asked.append(peer.baseURL.absoluteString) }
        return page
    }

    func notifyChanged(peer: PeerEndpoint, machineId: String) async {}
}

@Suite("Peer endpoints")
struct PeerEndpointsTests {
    /// A settings file as builds before the address hints wrote it.
    let before = #"""
    {
      "projects" : [],
      "peers" : [
        {
          "enabled" : true,
          "id" : "peer_osaka",
          "name" : "osaka",
          "terminalToken" : "kc_term",
          "token" : "kc_peer",
          "url" : "http://192.168.178.230:7780/"
        },
        {
          "enabled" : false,
          "id" : "peer_studio",
          "name" : "studio",
          "token" : "kc_studio",
          "url" : "http://192.168.178.59:7780"
        }
      ]
    }
    """#

    @Test("a settings file from before decodes unchanged: its url is the first hint, and reading does not rewrite it")
    func oldSettingsFile() async throws {
        let home = NSTemporaryDirectory() + "peer-endpoints-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: home) }
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let path = home + "/settings.json"
        try Data(before.utf8).write(to: URL(fileURLWithPath: path))

        let store = SettingsStore(basePath: home)
        let peers = try await store.read().peers
        #expect(peers == [
            PeerConfig(id: "peer_osaka", name: "osaka", url: "http://192.168.178.230:7780/", token: "kc_peer",
                       terminalToken: "kc_term", enabled: true),
            PeerConfig(id: "peer_studio", name: "studio", url: "http://192.168.178.59:7780", token: "kc_studio",
                       enabled: false),
        ])
        #expect(peers.map(\.addressHints) == [["http://192.168.178.230:7780/"], ["http://192.168.178.59:7780"]])
        #expect(peers.allSatisfy { $0.machineId == nil })
        #expect(try String(contentsOfFile: path, encoding: .utf8) == before)

        let endpoints = PeerEndpoints(peers: peers)
        #expect(endpoints.baseURL(forPeer: "peer_osaka")?.absoluteString == "http://192.168.178.230:7780")
        #expect(endpoints.baseURL(forPeer: "peer_studio")?.absoluteString == "http://192.168.178.59:7780")
    }

    @Test("the next edit writes the hints, and the first as url, so an older build still finds the peer")
    func nextEditWritesHints() async throws {
        let home = NSTemporaryDirectory() + "peer-endpoints-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: home) }
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        try Data(before.utf8).write(to: URL(fileURLWithPath: home + "/settings.json"))
        let store = SettingsStore(basePath: home)
        var settings = try await store.read()
        settings.peers[1].enabled = true
        try await store.write(settings)

        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: home + "/settings.json")))
        let written = try #require((raw as? [String: Any])?["peers"] as? [[String: Any]])
        #expect(written[0]["url"] as? String == "http://192.168.178.230:7780/")
        #expect(written[0]["addressHints"] as? [String] == ["http://192.168.178.230:7780/"])
        #expect(written[0]["machineId"] == nil)

        await store.invalidateCache()
        #expect(try await store.read().peers == settings.peers)
    }

    @Test("hints and the machine id survive a round trip; hints win over a stale url")
    func roundTrip() throws {
        let peer = PeerConfig(id: "peer_mac", machineId: "machine_mac", name: "mac",
                              addressHints: ["http://192.168.178.59:7780", "http://192.168.178.202:7780"], token: "t")
        let back = try JSONDecoder().decode(PeerConfig.self, from: JSONEncoder().encode(peer))
        #expect(back == peer)

        let mixed = #"{"id":"p","name":"n","token":"t","url":"http://old:1","addressHints":["http://new:1","http://old:1"]}"#
        #expect(try JSONDecoder().decode(PeerConfig.self, from: Data(mixed.utf8)).addressHints == ["http://new:1", "http://old:1"])
    }

    @Test("an address that answered moves to the front; the others stay behind it")
    func promote() {
        var peer = PeerConfig(name: "mac", addressHints: ["http://a:1", "http://b:1"], token: "t")
        let movedB = peer.promoteHint("http://b:1")
        #expect(movedB)
        #expect(peer.addressHints == ["http://b:1", "http://a:1"])
        let movedBAgain = peer.promoteHint("http://b:1")
        #expect(!movedBAgain)
        let addedC = peer.promoteHint("http://c:1")
        #expect(addedC)
        #expect(peer.addressHints == ["http://c:1", "http://b:1", "http://a:1"])
        let addedEmpty = peer.promoteHint("")
        #expect(!addedEmpty)
    }

    @Test("the base URL is the first hint, trimmed; an entry without a usable one has none")
    func baseURLs() {
        let endpoints = PeerEndpoints(peers: [
            PeerConfig(id: "a", name: "a", addressHints: [" http://box:7780// ", "http://other:7780"], token: "t"),
            PeerConfig(id: "b", name: "b", url: "box:7780", token: "t"),
            PeerConfig(id: "c", name: "c", url: "", token: "t"),
        ])
        #expect(endpoints.baseURL(forPeer: "a")?.absoluteString == "http://box:7780")
        #expect(endpoints.endpoint(forPeer: "a")?.apiURL("/v1/vault/audit/mirror?machine=x")?.absoluteString
            == "http://box:7780/v1/vault/audit/mirror?machine=x")
        #expect(endpoints.baseURL(forPeer: "b") == nil)
        #expect(endpoints.baseURL(forPeer: "c") == nil)
        #expect(endpoints.baseURL(forPeer: "gone") == nil)
        #expect(endpoints.all().map(\.id) == ["a"])
    }

    @Test("a machine resolves once its peer answered as it, and not after the peer is removed")
    func byMachine() {
        let box = PeerConfig(id: "peer_box", name: "box", url: "http://box:7780", token: "kc_b")
        let endpoints = PeerEndpoints(peers: [box])
        #expect(endpoints.baseURL(forMachine: "BOX") == nil)
        endpoints.noteMachine("BOX", forPeer: "peer_box")
        #expect(endpoints.baseURL(forMachine: "BOX")?.absoluteString == "http://box:7780")
        #expect(endpoints.endpoint(forMachine: "BOX")?.token == "kc_b")

        var moved = box
        moved.addressHints = ["http://box-wifi:7780"]
        endpoints.setPeers([moved])
        #expect(endpoints.baseURL(forMachine: "BOX")?.absoluteString == "http://box-wifi:7780")
        endpoints.setPeers([])
        #expect(endpoints.baseURL(forMachine: "BOX") == nil)
        endpoints.setPeers([box])
        #expect(endpoints.baseURL(forMachine: "BOX") == nil)
    }

    @Test("PeerSync keeps its endpoints current: the machine a pull met, and the entries Settings set")
    func peerSyncFeedsEndpoints() async {
        let me = MachineIdentity(id: "MAC", name: "mac")
        let box = MachineIdentity(id: "BOX", name: "box")
        let transport = OnePageTransport(page: LinksPage(machine: box, epoch: "e", seq: 1, full: true, links: []))
        let peer = PeerConfig(id: "peer_box", name: "box", url: "http://box:7780", token: "kc_b")
        let sync = PeerSync(identity: me, peers: [peer], transport: transport) { _ in }
        #expect(sync.endpoints.baseURL(forPeer: "peer_box")?.absoluteString == "http://box:7780")
        #expect(sync.endpoints.baseURL(forMachine: "BOX") == nil)

        #expect(await sync.pull(peerId: "peer_box"))
        #expect(sync.endpoints.baseURL(forMachine: "BOX")?.absoluteString == "http://box:7780")
        #expect(await sync.syncPeers().map(\.baseURL.absoluteString) == ["http://box:7780"])

        var moved = peer
        moved.addressHints = ["http://box-wifi:7780"]
        await sync.setPeers([moved])
        #expect(sync.endpoints.baseURL(forMachine: "BOX")?.absoluteString == "http://box-wifi:7780")
        #expect(await sync.pull(peerId: "peer_box"))
        #expect(transport.lock.withLock { transport.asked } == ["http://box:7780", "http://box-wifi:7780"])

        await sync.setPeers([])
        #expect(sync.endpoints.baseURL(forMachine: "BOX") == nil)
    }

    @Test("a peer without a usable address is offline with that reason")
    func noAddress() async {
        let transport = OnePageTransport(page: LinksPage(machine: MachineIdentity(id: "BOX", name: "box"),
                                                         epoch: "e", seq: 1, full: true, links: []))
        let sync = PeerSync(identity: MachineIdentity(id: "MAC", name: "mac"),
                            peers: [PeerConfig(id: "p", name: "box", url: "box", token: "t")], transport: transport) { _ in }
        #expect(await sync.pull(peerId: "p") == false)
        #expect(await sync.status(of: "p")?.lastError == "no usable address for box")
        #expect(transport.lock.withLock { transport.asked }.isEmpty)
    }
}
