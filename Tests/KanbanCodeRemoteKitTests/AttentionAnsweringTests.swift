import Foundation
import Testing
@testable import KanbanCodeRemoteKit

private func request(_ id: String, owner: String? = nil, at seconds: TimeInterval = 0, open: Bool = true) -> AttentionRequest {
    AttentionRequest(id: id, cardId: "card_1", kind: .vaultApproval, title: "A card wants AWS lw-dev access", body: "",
                     options: ["Approve once", "Deny"], createdAt: Date(timeIntervalSince1970: 1_800_000_000 + seconds),
                     resolvedAt: open ? nil : Date(timeIntervalSince1970: 1_800_000_100), machineId: owner)
}

@Suite("Attention list across masters")
struct AttentionFleetTests {
    @Test func aRequestTwoMastersListShowsOnceOnItsOwner() {
        let sources = [
            AttentionFleet.Source(machineId: "mac", isLive: true, requests: [request("a", owner: "box")]),
            AttentionFleet.Source(machineId: "box", isLive: true, requests: [request("a")]),
        ]
        let visible = AttentionFleet.visible(sources)
        #expect(visible.map(\.request.id) == ["a"])
        #expect(visible.first?.source == 1)
    }

    @Test func aMirrorCopyTheOwnerNoLongerListsIsGone() {
        // The box settled it; the Mac's mirror is a few seconds behind.
        let sources = [
            AttentionFleet.Source(machineId: "mac", isLive: true, requests: [request("a", owner: "box"), request("m", at: 5)]),
            AttentionFleet.Source(machineId: "box", isLive: true, requests: []),
        ]
        #expect(AttentionFleet.visible(sources).map(\.request.id) == ["m"])
    }

    @Test func aMirrorCopyShowsWhileItsOwnerIsNotReachable() {
        let sources = [
            AttentionFleet.Source(machineId: "mac", isLive: true, requests: [request("a", owner: "box")]),
            AttentionFleet.Source(machineId: "box", isLive: false, requests: []),
        ]
        let visible = AttentionFleet.visible(sources)
        #expect(visible.map(\.request.id) == ["a"])
        #expect(visible.first?.source == 0)
        // A master that is not paired at all: the mirror is all there is.
        #expect(AttentionFleet.visible([sources[0]]).map(\.request.id) == ["a"])
    }

    @Test func answeredAndResolvedRequestsAreNotShownOldestFirst() {
        let sources = [
            AttentionFleet.Source(machineId: "box", isLive: true,
                                  requests: [request("late", at: 30), request("done", open: false), request("early"), request("mine", at: 10)]),
        ]
        #expect(AttentionFleet.visible(sources, hidden: ["mine"]).map(\.request.id) == ["early", "late"])
    }
}

@Suite("Answering an attention request")
struct AttentionAnswerStateTests {
    @Test func aTapShowsProgressAndASecondTapDoesNothing() {
        var state = AttentionAnswerState()
        let began1 = state.begin("a", option: "Approve once")
        #expect(began1)
        #expect(state.isSending("a") && state.sending["a"] == "Approve once")
        let began2 = state.begin("a", option: "Deny")
        #expect(!began2)
        #expect(state.sending["a"] == "Approve once")
        // Another request is answered on its own.
        let began3 = state.begin("b", option: "Deny")
        #expect(began3)
    }

    @Test func anAcceptedAnswerHidesTheRequestForGood() {
        var state = AttentionAnswerState()
        _ = state.begin("a", option: "Approve once")
        state.succeeded("a")
        #expect(!state.isSending("a") && state.settled == ["a"])
        let began4 = state.begin("a", option: "Approve once")
        #expect(!began4)
        // Still listed by a mirror: stays hidden. No longer listed: forgotten.
        state.prune(listed: ["a"])
        #expect(state.settled == ["a"])
        state.prune(listed: [])
        #expect(state.settled.isEmpty)
    }

    @Test func aFailedCallKeepsTheRowWithTheErrorAndWorkingButtons() {
        var state = AttentionAnswerState()
        _ = state.begin("a", option: "Approve once")
        state.failed("a", error: RemoteClientError.transport("The network connection was lost."))
        #expect(!state.isSending("a") && state.settled.isEmpty)
        #expect(state.errors["a"] == "The network connection was lost.")
        #expect(state.note == nil)
        // The retry clears the error while it runs.
        let began5 = state.begin("a", option: "Approve once")
        #expect(began5)
        #expect(state.errors["a"] == nil)
    }

    @Test func aRequestSettledElsewhereLeavesQuietly() {
        var state = AttentionAnswerState()
        _ = state.begin("a", option: "Approve once")
        let message = AttentionAnswerCopy.alreadyAnswered(by: "phone", resolution: "Approve for this card (2 days)")
        #expect(message == "This was already answered on the phone: Approve for this card (2 days).")
        state.failed("a", error: RemoteClientError.conflict(message))
        #expect(state.settled == ["a"] && state.errors.isEmpty)
        #expect(state.note == message)

        _ = state.begin("b", option: "Deny")
        #expect(state.note == nil)
        state.failed("b", error: RemoteClientError.notFound("This request is no longer open."))
        #expect(state.settled == ["a", "b"] && state.note == AttentionAnswerCopy.gone)

        // A conflict about something else is a real error.
        _ = state.begin("c", option: "Yes")
        state.failed("c", error: RemoteClientError.conflict(AttentionAnswerCopy.sessionGone))
        #expect(!state.settled.contains("c") && state.errors["c"] == AttentionAnswerCopy.sessionGone)
    }

    @Test func backingOutOfFaceIDLeavesTheRowAsItWas() {
        var state = AttentionAnswerState()
        _ = state.begin("a", option: "Approve once")
        state.cancelled("a")
        #expect(!state.isSending("a") && state.settled.isEmpty && state.errors.isEmpty)
        let began6 = state.begin("a", option: "Approve once")
        #expect(began6)
    }

    @Test func noAnswerTextNamesARequestId() {
        for text in [AttentionAnswerCopy.gone, AttentionAnswerCopy.ownerUnreachable, AttentionAnswerCopy.sessionGone,
                     AttentionAnswerCopy.alreadyAnswered(by: nil, resolution: nil),
                     AttentionAnswerCopy.alreadyAnswered(by: "iPhone", resolution: "Deny")] {
            #expect(!text.contains("vault_") && !text.contains("att_"))
        }
        #expect(AttentionAnswerCopy.alreadyAnswered(by: "peer", resolution: nil) == "This was already answered.")
    }
}
