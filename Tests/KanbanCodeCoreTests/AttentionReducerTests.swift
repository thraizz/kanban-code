import Foundation
import Testing

@testable import KanbanCodeCore

@Suite("Attention requests in the reducer")
struct AttentionReducerTests {
    func request(_ id: String = "att_1", kind: AttentionRequest.Kind = .question) -> AttentionRequest {
        AttentionRequest(
            id: id, cardId: "card_1", kind: kind, title: "Pick one", body: "Which database?",
            options: ["Postgres", "SQLite"], createdAt: Date(timeIntervalSince1970: 100))
    }

    @Test("raising a request stores it open and delivers it")
    func raise() {
        var state = AppState()
        let effects = Reducer.reduce(state: &state, action: .attentionRaised(request()))
        #expect(state.openAttentionRequests.map(\.id) == ["att_1"])
        guard case .deliverAttention(let delivered) = effects.first else {
            Issue.record("expected deliverAttention, got \(effects)")
            return
        }
        #expect(delivered.id == "att_1")
    }

    @Test("raising the same id again updates it without a second delivery")
    func raiseAgainUpdates() {
        var state = AppState()
        _ = Reducer.reduce(state: &state, action: .attentionRaised(request()))
        var changed = request()
        changed.body = "Which database, really?"
        let effects = Reducer.reduce(state: &state, action: .attentionRaised(changed))
        #expect(state.attentionRequests["att_1"]?.body == "Which database, really?")
        guard case .updateAttention = effects.first else {
            Issue.record("expected updateAttention, got \(effects)")
            return
        }
    }

    @Test("resolving closes it, records who acted, and withdraws it everywhere")
    func resolve() {
        var state = AppState()
        _ = Reducer.reduce(state: &state, action: .attentionRaised(request()))
        let effects = Reducer.reduce(
            state: &state, action: .attentionResolved(id: "att_1", resolution: "SQLite", by: "phone"))
        let resolved = state.attentionRequests["att_1"]
        #expect(resolved?.isOpen == false)
        #expect(resolved?.resolution == "SQLite")
        #expect(resolved?.resolvedBy == "phone")
        #expect(state.openAttentionRequests.isEmpty)
        guard case .withdrawAttention(let withdrawn) = effects.first else {
            Issue.record("expected withdrawAttention, got \(effects)")
            return
        }
        #expect(withdrawn.resolution == "SQLite")
    }

    @Test("a second resolution of the same request is ignored")
    func resolveTwice() {
        var state = AppState()
        _ = Reducer.reduce(state: &state, action: .attentionRaised(request()))
        _ = Reducer.reduce(state: &state, action: .attentionResolved(id: "att_1", resolution: "SQLite", by: "phone"))
        let effects = Reducer.reduce(
            state: &state, action: .attentionResolved(id: "att_1", resolution: "Postgres", by: "mac"))
        #expect(effects.isEmpty)
        #expect(state.attentionRequests["att_1"]?.resolution == "SQLite")
    }

    @Test("a resolved request is not reopened by a late raise")
    func lateRaiseIgnored() {
        var state = AppState()
        _ = Reducer.reduce(state: &state, action: .attentionRaised(request()))
        _ = Reducer.reduce(state: &state, action: .attentionResolved(id: "att_1", resolution: nil, by: "session"))
        let effects = Reducer.reduce(state: &state, action: .attentionRaised(request()))
        #expect(effects.isEmpty)
        #expect(state.openAttentionRequests.isEmpty)
    }

    @Test("pruning drops old resolved requests and keeps open ones")
    func prune() {
        var state = AppState()
        _ = Reducer.reduce(state: &state, action: .attentionRaised(request("a")))
        _ = Reducer.reduce(state: &state, action: .attentionRaised(request("b")))
        _ = Reducer.reduce(state: &state, action: .attentionResolved(id: "a", resolution: nil, by: "mac"))
        _ = Reducer.reduce(state: &state, action: .attentionPruned(before: Date().addingTimeInterval(60)))
        #expect(state.attentionRequests.keys.sorted() == ["b"])
    }

    @Test("the vault approval options are fixed")
    func vaultOptions() {
        #expect(AttentionRequest.vaultApprovalOptions.count == 3)
        #expect(AttentionRequest.vaultApprovalOptions.last == "Deny")
    }
}
