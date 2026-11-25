import Foundation
import Testing

@testable import KanbanCodeCore

/// A queued prompt goes out on the card's next Stop. A card whose assistant is
/// already idle has no Stop coming, so the prompt goes out at once instead.
@Suite("Reducer — queued prompt on an idle card")
struct QueuedPromptIdleSendTests {

    private func state(activity: ActivityState?, queued: [QueuedPrompt] = [], tmuxAlive: Bool = true) -> AppState {
        let state = AppState()
        var link = Link(id: "card_1", name: "a card", projectPath: "/tmp/project")
        link.tmuxLink = TmuxLink(sessionName: "claude-abc")
        link.sessionLink = SessionLink(sessionId: "session-1")
        link.queuedPrompts = queued.isEmpty ? nil : queued
        state.links[link.id] = link
        if tmuxAlive { state.tmuxSessions = ["claude-abc"] }
        if let activity { state.activityMap["session-1"] = activity }
        return state
    }

    private func sent(_ effects: [Effect]) -> [String] {
        effects.compactMap {
            switch $0 {
            case .sendPromptToTmux(_, let body, _, _, _): return body
            case .sendPromptWithImagesToTmux(_, let body, _, _, _, _): return body
            default: return nil
            }
        }
    }

    private func queue(_ state: AppState, _ prompt: QueuedPrompt) -> [Effect] {
        Reducer.reduce(state: state, action: .addQueuedPrompt(cardId: "card_1", prompt: prompt, placement: .back))
    }

    @Test("an idle card gets the prompt right away", arguments: [ActivityState.needsAttention, .idleWaiting])
    func idleSendsNow(activity: ActivityState) {
        let state = state(activity: activity)
        let effects = queue(state, QueuedPrompt(id: "prompt_1", body: "go on"))
        #expect(sent(effects) == ["go on"])
        #expect(state.links["card_1"]?.queuedPrompts == nil)
        // A prompt queued right behind it waits for the turn it started.
        #expect(state.activityMap["session-1"] == .activelyWorking)
        let next = queue(state, QueuedPrompt(id: "prompt_2", body: "and then this"))
        #expect(sent(next).isEmpty)
        #expect(state.links["card_1"]?.queuedPrompts?.map(\.id) == ["prompt_2"])
    }

    @Test("a busy card keeps the prompt for its next Stop", arguments: [ActivityState.activelyWorking, .awaitingPermission])
    func busyKeepsQueued(activity: ActivityState) {
        let state = state(activity: activity)
        let effects = queue(state, QueuedPrompt(id: "prompt_1", body: "go on"))
        #expect(sent(effects).isEmpty)
        #expect(state.links["card_1"]?.queuedPrompts?.map(\.id) == ["prompt_1"])
    }

    @Test("a prompt with others ahead of it waits its turn")
    func waitsBehindOthers() {
        let state = state(activity: .needsAttention, queued: [QueuedPrompt(id: "prompt_0", body: "held", sendAutomatically: false)])
        let effects = queue(state, QueuedPrompt(id: "prompt_1", body: "go on"))
        #expect(sent(effects).isEmpty)
        #expect(state.links["card_1"]?.queuedPrompts?.map(\.id) == ["prompt_0", "prompt_1"])
    }

    @Test("a prompt that does not send itself stays queued")
    func manualStaysQueued() {
        let state = state(activity: .needsAttention)
        let effects = queue(state, QueuedPrompt(id: "prompt_1", body: "go on", sendAutomatically: false))
        #expect(sent(effects).isEmpty)
    }

    @Test("no live session, no unknown activity, no ended assistant: it stays queued")
    func noLiveAssistant() {
        for state in [state(activity: .needsAttention, tmuxAlive: false), state(activity: nil), state(activity: .ended)] {
            let effects = queue(state, QueuedPrompt(id: "prompt_1", body: "go on"))
            #expect(sent(effects).isEmpty)
            #expect(state.links["card_1"]?.queuedPrompts?.map(\.id) == ["prompt_1"])
        }
    }
}
