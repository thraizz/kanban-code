import Foundation
import Observation
import KanbanCodeRemoteKit

/// A card on the merged board and the master it belongs to.
struct FleetCard: Identifiable {
    var id: String { card.id }
    let card: RemoteCard
    /// Where the card's prompts, transcript and terminals go: the master
    /// that owns it, or the one that listed it when its owner is not paired.
    let master: BoardModel
    /// Name of the owner machine.
    let machineName: String
}

/// Every paired master at once: one live board per master, merged into one
/// board whose cards each name the machine that runs them.
@Observable
final class FleetModel {
    let store: ServerStore
    private(set) var masters: [BoardModel] = []
    /// Previews: nothing connects.
    private let isPreview: Bool

    init(store: ServerStore) {
        self.store = store
        isPreview = false
    }

    init(preview masters: [BoardModel]) {
        store = ServerStore()
        self.masters = masters
        isPreview = true
    }

    /// Adds a board for each newly paired master and drops the forgotten ones.
    func sync() {
        guard !isPreview else { return }
        let ids = Set(store.servers.map(\.id))
        for gone in masters where !ids.contains(gone.server.id) {
            gone.stop()
            BoardCache.remove(gone.server.id)
        }
        var kept: [BoardModel] = []
        for model in masters where ids.contains(model.server.id) {
            // Paired again with a new token: connect with it.
            if model.client?.token == Keychain.token(for: model.server.id) {
                kept.append(model)
            } else {
                model.stop()
            }
        }
        for server in store.servers where !kept.contains(where: { $0.server.id == server.id }) {
            let model = BoardModel(server: server, client: ServerStore.client(for: server))
            kept.append(model)
            model.start()
        }
        masters = store.servers.compactMap { server in kept.first { $0.server.id == server.id } }
    }

    func stop() {
        masters.forEach { $0.stop() }
    }

    func start() {
        masters.forEach { $0.start() }
    }

    var primary: BoardModel? {
        masters.first { $0.server.id == store.primaryID } ?? masters.first
    }

    var isMulti: Bool { masters.count > 1 }

    /// A decision and the master to answer it on.
    struct FleetAttention: Identifiable {
        var id: String { request.id }
        let request: AttentionRequest
        let master: BoardModel
        let cardName: String?
    }

    /// Open decisions on every master, oldest first. A master that mirrors
    /// another's request lists it too; the owner's copy wins.
    var attention: [FleetAttention] {
        var byId: [String: FleetAttention] = [:]
        for master in masters {
            for request in master.attention where request.isOpen {
                let owns = request.machineId == nil || request.machineId == master.machineId
                if byId[request.id] == nil || owns {
                    let name = request.cardId.flatMap { id in cards.first { $0.card.id == id }?.card.title }
                    byId[request.id] = FleetAttention(request: request, master: master, cardName: name)
                }
            }
        }
        return byId.values.sorted { $0.request.createdAt < $1.request.createdAt }
    }

    /// Cards name their machine when more than one machine runs them: several
    /// masters paired, or one master listing cards synced from its peers.
    var showsMachines: Bool {
        isMulti || Set(masters.flatMap { $0.board?.cards.compactMap(\.machineId) ?? [] }).count > 1
    }

    /// Primary first, then the order they were paired in.
    var orderedMasters: [BoardModel] {
        guard let primary else { return masters }
        return [primary] + masters.filter { $0 !== primary }
    }

    var onlineMasters: [BoardModel] { orderedMasters.filter(\.isOnline) }

    func master(machineId: String) -> BoardModel? {
        masters.first { $0.machineId == machineId }
    }

    /// Every card of every master, once. A card two masters list (a peer's
    /// synced copy) is taken from its owner when the owner's board has it.
    var cards: [FleetCard] {
        var byId: [String: (entry: FleetCard, fromOwner: Bool)] = [:]
        var order: [String] = []
        for model in orderedMasters {
            for card in model.board?.cards ?? [] {
                let owner = card.machineId.flatMap(master(machineId:)) ?? model
                let fromOwner = owner === model
                let name = card.machineId.flatMap { master(machineId: $0)?.machineName } ?? card.machineName ?? model.machineName
                let entry = FleetCard(card: card, master: owner, machineName: name)
                if let existing = byId[card.id] {
                    if fromOwner && !existing.fromOwner { byId[card.id] = (entry, true) }
                } else {
                    byId[card.id] = (entry, fromOwner)
                    order.append(card.id)
                }
            }
        }
        return order.compactMap { byId[$0]?.entry }
    }

    func entry(cardId: String) -> FleetCard? {
        cards.first { $0.id == cardId }
    }

    /// Projects of every master, once per name: the same repository sits at
    /// a different path on each machine.
    var projects: [RemoteProject] {
        var seen = Set<String>()
        var out: [RemoteProject] = []
        for model in orderedMasters {
            for project in model.board?.projects ?? [] where seen.insert(project.name).inserted {
                out.append(project)
            }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Any master has a board to show.
    var hasBoard: Bool { masters.contains { $0.board != nil } }
}
