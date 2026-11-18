import Testing

@testable import KanbanCodeCore

@Suite("Activity of cards another master owns")
struct PeerCardActivityTests {
    private let liveIdle = PeerCardState(isLive: true, isBusy: false)
    private let liveBusy = PeerCardState(isLive: true, isBusy: true)
    private let dead = PeerCardState(isLive: false, isBusy: false)

    @Test("a question or permission prompt seen here keeps the card pulsing while the owner says it is live")
    func keepsPermissionPrompt() {
        #expect(AppState.peerOwnedActivity(local: .awaitingPermission, peer: liveIdle, hasLiveTerminal: true) == .awaitingPermission)
        #expect(AppState.peerOwnedActivity(local: .awaitingPermission, peer: liveBusy, hasLiveTerminal: true) == .awaitingPermission)
        #expect(AppState.peerOwnedActivity(local: .awaitingPermission, peer: nil, hasLiveTerminal: true) == .awaitingPermission)
    }

    @Test("a prompt on a session the owner reports gone is dropped")
    func dropsPromptOfDeadSession() {
        #expect(AppState.peerOwnedActivity(local: .awaitingPermission, peer: dead, hasLiveTerminal: true) == nil)
        #expect(AppState.peerOwnedActivity(local: .awaitingPermission, peer: nil, hasLiveTerminal: false) == nil)
    }

    @Test("otherwise the owner's busy and live flags decide")
    func ownerFlagsDecide() {
        #expect(AppState.peerOwnedActivity(local: .needsAttention, peer: liveBusy, hasLiveTerminal: true) == .activelyWorking)
        #expect(AppState.peerOwnedActivity(local: .activelyWorking, peer: liveIdle, hasLiveTerminal: true) == .idleWaiting)
        #expect(AppState.peerOwnedActivity(local: .activelyWorking, peer: dead, hasLiveTerminal: true) == nil)
        #expect(AppState.peerOwnedActivity(local: nil, peer: nil, hasLiveTerminal: true) == .idleWaiting)
        #expect(AppState.peerOwnedActivity(local: nil, peer: nil, hasLiveTerminal: false) == nil)
    }
}
