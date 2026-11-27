import Foundation
import Testing

@testable import KanbanCodeCore

@Suite("A peer master that does not answer is named, and its terminals wait for it")
struct PeerOutageTests {
    private let osaka = MachineIdentity(id: "machine_osaka", name: "osaka-box")
    private let url = "http://192.168.178.230:7780"

    private func state(peers: [PeerStatus]) -> AppState {
        var state = AppState()
        state.localMachineId = "machine_mac"
        state.boxdSettings = BoxdSettings(sshMachines: [SshMachine(name: "osaka", target: "aron@192.168.178.230")])
        for peer in peers { state.peerStatuses[peer.peerId] = peer }
        return state
    }

    @Test("a peer that never answered is the owner when it is the only one, named after its ssh machine")
    func silentPeerIsOwner() {
        let s = state(peers: [PeerStatus(peerId: "peer_osaka", online: false, lastError: "The request timed out.", url: url)])
        let outage = s.peerOutage(ownerMachine: "machine_osaka")
        #expect(outage == PeerOutage(name: "osaka", url: url, error: "The request timed out."))
        #expect(outage?.line == "osaka's Kanban Code does not answer at \(url): The request timed out.")
        #expect(s.peerOutage(sshMachine: "osaka") == outage)
        #expect(s.ownerWait(ownerMachine: "machine_osaka") == .peerSilent)
    }

    @Test("a known peer that went offline is the outage; online, there is none")
    func knownPeer() {
        var s = state(peers: [PeerStatus(peerId: "peer_osaka", machine: osaka, online: false, lastError: "offline", url: url)])
        #expect(s.peerOutage(ownerMachine: "machine_osaka")?.name == "osaka")
        // Its machine id is known, so the terminal starts and its attach loop retries.
        #expect(s.ownerWait(ownerMachine: "machine_osaka") == .none)
        s.peerStatuses["peer_osaka"]?.online = true
        #expect(s.peerOutage(ownerMachine: "machine_osaka") == nil)
        #expect(s.peerOutage(sshMachine: "osaka") == nil)
    }

    @Test("nothing to say for this master's own cards or before the peers were tried")
    func nothingYet() {
        let s = state(peers: [])
        #expect(s.peerOutage(ownerMachine: "machine_osaka") == nil)
        #expect(s.peerOutage(ownerMachine: "machine_mac") == nil)
        #expect(s.ownerWait(ownerMachine: "machine_osaka") == .loading)
        #expect(s.ownerWait(ownerMachine: "machine_mac") == .none)
        #expect(s.ownerWait(ownerMachine: nil) == .none)
        #expect(AppState().ownerWait(ownerMachine: "machine_osaka") == .loading)
    }

    @Test("an owner no peer answers as, with every peer known, starts and says so")
    func unknownOwner() {
        let s = state(peers: [PeerStatus(peerId: "peer_osaka", machine: osaka, online: true, url: url)])
        #expect(s.ownerWait(ownerMachine: "machine_gone") == .none)
        #expect(s.peerOutage(ownerMachine: "machine_gone")?.error == "no peer in Settings › Peers answers as this machine")
    }

    @Test("the card shows the outage and the peer's name in place of its machine id")
    func cardOwner() {
        var s = state(peers: [PeerStatus(peerId: "peer_osaka", online: false, lastError: "The request timed out.", url: url)])
        s.links["card_1"] = Link(id: "card_1", name: "remote card", ownerMachine: "machine_osaka")
        s.rebuildCards()
        let owner = s.cards.first { $0.id == "card_1" }?.owner
        #expect(owner?.name == "osaka")
        #expect(owner?.online == false)
        #expect(owner?.outage?.error == "The request timed out.")
    }
}

@Suite("A peer that does not fetch from here is not handed cards")
struct PeerReachBackTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    @Test("a peer that fetched within the window reaches this master")
    func fresh() {
        let pulls = ["machine_osaka": start.addingTimeInterval(500)]
        #expect(PeerReachBack.problem(
            machineId: "machine_osaka", name: "osaka", pulls: pulls, since: start, now: start.addingTimeInterval(560)) == nil)
    }

    @Test("a peer whose last fetch is older than the window cannot take a card, and the line says since when")
    func stale() throws {
        let pulls = ["machine_osaka": start.addingTimeInterval(100)]
        let problem = try #require(PeerReachBack.problem(
            machineId: "machine_osaka", name: "osaka", pulls: pulls, since: start, now: start.addingTimeInterval(400)))
        #expect(problem.hasPrefix("osaka has not fetched cards from this machine since "))
        #expect(problem.contains("osaka's Settings › Peers"))
    }

    @Test("a peer that never fetched: no verdict while this master is new, then a refusal")
    func never() {
        #expect(PeerReachBack.problem(machineId: "m", name: "osaka", pulls: [:], since: start, now: start.addingTimeInterval(30)) == nil)
        #expect(PeerReachBack.verdict(machineId: "m", name: "osaka", pulls: [:], since: start, now: start.addingTimeInterval(30))
            == .unknown(until: start.addingTimeInterval(PeerReachBack.window)))
        let problem = PeerReachBack.problem(machineId: "m", name: "osaka", pulls: [:], since: start, now: start.addingTimeInterval(120))
        #expect(problem?.contains("since this app started") == true)
    }

    @Test("an older peer that does not say who it is gives no verdict while it fetches")
    func anonymous() {
        let pulls = ["": start.addingTimeInterval(110)]
        #expect(PeerReachBack.problem(machineId: "m", name: "osaka", pulls: pulls, since: start, now: start.addingTimeInterval(120)) == nil)
    }

    @Test("a card released to a peer that does not fetch says so instead of moving forever")
    func movingLine() {
        let state = AppState()
        state.localMachineId = "machine_mac"
        state.peerStatuses["peer_osaka"] = PeerStatus(
            peerId: "peer_osaka", machine: MachineIdentity(id: "machine_osaka", name: "osaka"), online: true)
        state.links["card_1"] = Link(id: "card_1", name: "card", ownerMachine: "machine_osaka", migrating: true)
        #expect(state.handoverLine(cardId: "card_1") == "Moving to osaka")
        state.peersNotFetching = ["machine_osaka": "osaka has not fetched cards from this machine since 13:51."]
        #expect(state.handoverLine(cardId: "card_1") == "Not picked up by osaka yet. osaka has not fetched cards from this machine since 13:51.")
    }

    @Test("the fetch names the machine asking, and the route passes it on")
    func wire() async {
        let url = HTTPPeerLinksTransport.linksURL(base: "http://h:7780", since: 3, epoch: "e", machine: "machine_mac")
        #expect(url?.absoluteString == "http://h:7780/v1/links?since=3&epoch=e&machine=machine_mac")
        let server = RecordingServer()
        _ = await RemoteLinksRoutes.handle(method: "GET", rest: ["links"], query: ["machine": "machine_mac"], server: server)
        _ = await RemoteLinksRoutes.handle(method: "GET", rest: ["links"], query: [:], server: server)
        #expect(server.machines == ["machine_mac", nil])
        #expect(server.reached.isEmpty)
    }

    @Test("the routes pass on where a peer that says who it is reached this master from")
    func reachedFrom() async {
        let server = RecordingServer()
        _ = await RemoteLinksRoutes.handle(
            method: "GET", rest: ["links"], query: ["machine": "machine_mac"], from: "192.168.178.59", server: server)
        _ = await RemoteLinksRoutes.handle(
            method: "POST", rest: ["links", "changed"], query: ["machine": "machine_mac"], from: "192.168.178.60", server: server)
        _ = await RemoteLinksRoutes.handle(method: "GET", rest: ["links"], query: [:], from: "192.168.178.61", server: server)
        _ = await RemoteLinksRoutes.handle(
            method: "GET", rest: ["peers"], query: ["machine": "machine_mac"], from: "192.168.178.62", server: server)
        #expect(server.reached.map(\.host) == ["192.168.178.59", "192.168.178.60"])
        #expect(server.reached.allSatisfy { $0.machine == "machine_mac" })
    }

    private final class RecordingServer: PeerLinksServing, @unchecked Sendable {
        var machines: [String?] = []
        var reached: [(machine: String, host: String)] = []
        func peerReached(machineId: String, host: String) async { reached.append((machineId, host)) }
        func linksPage(since: Int?, epoch: String?, machine: String?) async -> LinksPage {
            machines.append(machine)
            return LinksPage(machine: MachineIdentity(id: "m", name: "m"), epoch: "e", seq: 0, full: true, links: [])
        }
        func peerLinksChanged(machineId: String?) async {}
        func peersOverview() async -> PeersOverview { PeersOverview(machine: MachineIdentity(id: "m", name: "m"), peers: []) }
    }
}
