import Foundation
import Testing

@testable import KanbanCodeCore

/// A card that leaves the board on the master that runs it must leave the
/// boards of its peers too. Pages only carry cards on the board, so the
/// version that took a card off was never sent: on 2026-11-27 osaka still
/// showed 160 cards the Mac had archived days before, two of them naming
/// the same tmux session, which osaka "deduplicated" on every reconcile.
@Suite("Peer sync: cards that leave the board")
struct PeerOffBoardTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let mac = MachineIdentity(id: "MAC", name: "mac")
    private let osaka = MachineIdentity(id: "OSAKA", name: "osaka")

    private func card(_ id: String, column: KanbanCodeColumn, owner: String?, tmux: String? = nil) -> Link {
        Link(id: id, name: nil, projectPath: "/p", column: column, createdAt: now, updatedAt: now,
             source: .discovered, tmuxLink: tmux.map { TmuxLink(sessionName: $0) }, ownerMachine: owner)
    }

    private func master(_ id: String, _ links: [Link]) -> AppState {
        let s = AppState()
        s.localMachineId = id
        for link in links { s.links[link.id] = link }
        s.loadSyncState(tombstones: [])
        return s
    }

    /// `to` merges what `from` serves after `since` (everything when nil).
    @discardableResult
    private func pull(_ to: AppState, from: AppState, as machine: MachineIdentity, since: LinksPage? = nil) -> LinksPage {
        let page = from.linksPage(machine: machine, since: since?.seq, epoch: since?.epoch)
        _ = Reducer.reduce(state: to, action: .peerLinksMerged(peer: machine.id, links: page.links))
        return page
    }

    @Test("an archive on the master that runs the card reaches the peer, which drops it from its board")
    func archiveReachesPeer() {
        let m = master("MAC", [card("card_1", column: .waiting, owner: nil, tmux: "loop-health")])
        let o = master("OSAKA", [])
        let first = pull(o, from: m, as: mac)
        #expect(o.links["card_1"]?.column == .waiting)

        _ = Reducer.reduce(state: m, action: .archiveCard(cardId: "card_1"))
        #expect(m.links["card_1"].map(LinkSync.isServed) == false)
        let delta = pull(o, from: m, as: mac, since: first)
        #expect(delta.links.map(\.id) == ["card_1"])
        #expect(o.links["card_1"]?.manuallyArchived == true)
        #expect(o.links["card_1"].map(LinkSync.isServed) == false)
    }

    @Test("a peer page that still shows a card this master took off its board gets that version sent again")
    func ghostIsHealed() {
        // The Mac took the card off its board before this fix: no record of
        // it leaving, and the peer kept the version it had.
        let onBoard = card("card_1", column: .waiting, owner: nil, tmux: "loop-health")
        let m = master("MAC", [onBoard])
        let o = master("OSAKA", [])
        pull(o, from: m, as: mac)
        _ = Reducer.reduce(state: m, action: .archiveCard(cardId: "card_1"))
        m.leftBoard = []
        let cursor = m.linksPage(machine: mac, since: nil, epoch: nil)
        #expect(cursor.links.isEmpty)
        #expect(o.links["card_1"]?.tmuxLink?.sessionName == "loop-health")

        // The Mac pulls osaka's page, which still shows the card on its board.
        pull(m, from: o, as: osaka)
        #expect(m.leftBoard == ["card_1"])
        pull(o, from: m, as: mac, since: cursor)
        #expect(o.links["card_1"]?.manuallyArchived == true)
        #expect(o.links["card_1"]?.tmuxLink == nil)
        #expect(o.links["card_1"].map(LinkSync.isServed) == false)
    }

    @Test("cards of another master that name one tmux session are left alone; that session is on the other machine")
    func foreignTmuxLinksNotDeduplicated() {
        let a = card("card_a", column: .waiting, owner: "MAC", tmux: "loop-health")
        let b = card("card_b", column: .allSessions, owner: "MAC", tmux: "loop-health")
        let o = master("OSAKA", [a, b])
        let result = ReconciliationResult(links: [a, b], sessions: [], activityMap: [:], tmuxSessions: ["loop-health"])
        _ = Reducer.reduce(state: o, action: .reconciled(result))
        #expect(o.links["card_a"]?.tmuxLink?.sessionName == "loop-health")
        #expect(o.links["card_b"]?.tmuxLink?.sessionName == "loop-health")
    }
}
