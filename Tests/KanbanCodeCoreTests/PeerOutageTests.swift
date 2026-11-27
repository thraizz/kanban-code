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
        // The terminal waits until it can be called: its attach command keeps
        // the URL it starts with, and there is no working one yet.
        #expect(s.ownerWait(ownerMachine: "machine_osaka") == .peerSilent)
        s.peerStatuses["peer_osaka"]?.online = true
        #expect(s.peerOutage(ownerMachine: "machine_osaka") == nil)
        #expect(s.peerOutage(sshMachine: "osaka") == nil)
        #expect(s.ownerWait(ownerMachine: "machine_osaka") == .none)
    }

    @Test("a peer is up by its control connection once there is one, whatever its last pull said")
    func reachableByConnection() {
        var s = state(peers: [PeerStatus(peerId: "peer_osaka", machine: osaka, online: true, url: url,
                                         controlError: "no answer for 30 s")])
        let outage = s.peerOutage(ownerMachine: "machine_osaka")
        #expect(outage?.error == "no answer for 30 s")
        #expect(s.ownerWait(ownerMachine: "machine_osaka") == .peerSilent)
        s.links["card_1"] = Link(id: "card_1", name: "remote card", ownerMachine: "machine_osaka")
        s.rebuildCards()
        #expect(s.cards.first { $0.id == "card_1" }?.owner?.online == false)

        s.peerStatuses["peer_osaka"] = PeerStatus(peerId: "peer_osaka", machine: osaka, online: false,
                                                  lastError: "timed out", url: url, connected: true, connectedVia: .accepted)
        #expect(s.peerOutage(ownerMachine: "machine_osaka") == nil)
        #expect(s.ownerWait(ownerMachine: "machine_osaka") == .none)
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

@Suite("A card handed to a peer that is not connected says so")
struct PeerHandoverLineTests {
    @Test("a card released to a peer says it moves there, and waits for it while it is not connected")
    func movingLine() {
        let state = AppState()
        state.localMachineId = "machine_mac"
        state.peerStatuses["peer_osaka"] = PeerStatus(
            peerId: "peer_osaka", machine: MachineIdentity(id: "machine_osaka", name: "osaka"), online: true,
            connected: true, connectedVia: .dialed)
        state.links["card_1"] = Link(id: "card_1", name: "card", ownerMachine: "machine_osaka", migrating: true)
        #expect(state.handoverLine(cardId: "card_1") == "Moving to osaka")
        state.peerStatuses["peer_osaka"]?.connected = false
        state.peerStatuses["peer_osaka"]?.controlError = "no answer for 30 s"
        #expect(state.handoverLine(cardId: "card_1") == "Moving to osaka, once it is connected again")
    }
}
