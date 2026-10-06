import Foundation
import KanbanCodeRemoteKit
import Testing

@testable import KanbanCodeCore

/// The one status every surface renders for a card's session: starting,
/// moving, failed, live, ended, and the machine under a live session.
@Suite("Card session status")
struct CardSessionStatusTests {
    private func link(
        tmux: TmuxLink? = nil, launching: Bool = false, updatedAt: Date = .now,
        session: Bool = true, remote: RemoteLink? = nil
    ) -> Link {
        var link = Link(
            id: "card_1", name: "Fix it", projectPath: "/repo", column: .waiting,
            sessionLink: session ? SessionLink(sessionId: "0f1e2d3c-aaaa", sessionPath: "/t.jsonl") : nil,
            tmuxLink: tmux)
        link.isLaunching = launching ? true : nil
        link.remote = remote
        link.isRemote = remote != nil
        link.updatedAt = updatedAt
        return link
    }

    @Test("a start in flight shows its last step, and a stale one stops spinning")
    func starting() {
        let fresh = link(tmux: TmuxLink(sessionName: "rush-0f1e2d3c"), launching: true)
        #expect(CardSessionStatus.of(link: fresh, moving: nil, report: .step("Copying files"), machineState: nil)
            == .starting("Starting session… Copying files"))
        #expect(CardSessionStatus.of(link: fresh, moving: nil, report: nil, machineState: nil) == .starting("Starting session…"))
        #expect(CardSessionStatus.of(link: fresh, moving: nil, report: nil, machineState: nil).isWorking)

        let stale = link(tmux: TmuxLink(sessionName: "rush-0f1e2d3c"), launching: true, updatedAt: .now.addingTimeInterval(-60))
        #expect(CardSessionStatus.of(link: stale, moving: nil, report: .step("Copying files"), machineState: nil) == .live)
    }

    @Test("a move wins over everything, and offers no resume")
    func moving() {
        let status = CardSessionStatus.of(
            link: link(), moving: "Moving to box, copying the transcript (1 of 2 MB)", report: .failed("Resume failed: x"),
            machineState: nil)
        #expect(status == .moving("Moving to box, copying the transcript (1 of 2 MB)"))
        #expect(!status.canResume)
        #expect(status.isWorking)
    }

    @Test("a failed start says why and offers the resume; a live session hides it")
    func failed() {
        let status = CardSessionStatus.of(link: link(), moving: nil, report: .failed("Resume failed: no folder"), machineState: nil)
        #expect(status == .failed("Resume failed: no folder"))
        #expect(status.canResume)
        #expect(status.text(for: link()) == "Resume failed: no folder")

        let live = link(tmux: TmuxLink(sessionName: "rush-0f1e2d3c"))
        #expect(CardSessionStatus.of(link: live, moving: nil, report: .failed("Resume failed: old"), machineState: nil) == .live)
    }

    @Test("ended and never-run sessions")
    func endedAndNone() {
        #expect(CardSessionStatus.of(link: link(), moving: nil, report: nil, machineState: nil) == .ended)
        #expect(CardSessionStatus.of(link: link(), moving: nil, report: nil, machineState: nil).text(for: link())
            == "Claude Code session ended")
        #expect(CardSessionStatus.of(link: link(session: false), moving: nil, report: nil, machineState: nil) == .none)
        // A shell tab alone is no session.
        let shell = link(tmux: TmuxLink(sessionName: "sh", isShellOnly: true))
        #expect(CardSessionStatus.of(link: shell, moving: nil, report: nil, machineState: nil) == .ended)
    }

    @Test("a live session on a paused machine offers the machine")
    func machine() {
        let remote = RemoteLink(mode: .boxd, machineName: "kanban-1")
        let live = link(tmux: TmuxLink(sessionName: "claude-0f1e2d3c"), remote: remote)
        let paused = CardSessionStatus.of(link: live, moving: nil, report: nil, machineState: .paused(.inactivity))
        #expect(paused == .machine(.paused(.inactivity)))
        #expect(paused.canResume)
        #expect(!paused.showsTerminal)
        let reconnecting = CardSessionStatus.of(link: live, moving: nil, report: nil, machineState: .reconnecting(attempt: 2))
        #expect(reconnecting.showsTerminal)
        #expect(!reconnecting.canResume)
        #expect(CardSessionStatus.of(link: live, moving: nil, report: nil, machineState: .connected) == .live)
    }

    @Test("the owner's report of a card it runs reads the same here")
    func peerReport() {
        let starting = RemoteSessionStatus(kind: .starting, text: "Starting session… Copying files")
        let launching = link(tmux: TmuxLink(sessionName: "rush-0f1e2d3c"), launching: true)
        #expect(CardSessionStatus.of(link: launching, moving: nil, report: nil, peer: starting, machineState: nil)
            == .starting("Starting session… Copying files"))

        let failed = RemoteSessionStatus(kind: .failed, text: "Resume failed: no folder", canResume: true)
        #expect(CardSessionStatus.of(link: link(), moving: nil, report: nil, peer: failed, machineState: nil)
            == .failed("Resume failed: no folder"))
    }

    @Test("the wire form carries what the clients show, and nothing for a plain live or ended session")
    func wire() throws {
        let l = link()
        #expect(CardSessionStatus.live.remote(for: l) == nil)
        #expect(CardSessionStatus.ended.remote(for: l) == nil)
        #expect(CardSessionStatus.moving("Moving to box").remote(for: l) == RemoteSessionStatus(kind: .moving, text: "Moving to box"))
        #expect(CardSessionStatus.failed("Resume failed: x").remote(for: l)
            == RemoteSessionStatus(kind: .failed, text: "Resume failed: x", canResume: true))

        let card = RemoteCard(id: "c", title: "t", column: .waiting, updatedAt: Date(timeIntervalSince1970: 0),
                              sessionStatus: RemoteSessionStatus(kind: .moving, text: "Moving to box"))
        let data = try JSONEncoder.remote.encode(card)
        #expect(try JSONDecoder.remote.decode(RemoteCard.self, from: data).sessionStatus?.text == "Moving to box")
        // A kind a client does not know reads as no status, not as a broken card.
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["sessionStatus"] = ["kind": "teleporting", "text": "?", "canResume": false]
        let future = try JSONSerialization.data(withJSONObject: json)
        #expect(try JSONDecoder.remote.decode(RemoteCard.self, from: future).sessionStatus == nil)
    }

    @Test("the reducer keeps one report per card: step, move, failure, cleared by the next start")
    func reducer() {
        var state = AppState()
        var l = link(launching: true)
        state.links[l.id] = l
        _ = Reducer.reduce(state: &state, action: .launchProgress(cardId: l.id, message: "Creating machine"))
        #expect(state.cardStarts[l.id] == .step("Creating machine"))
        #expect(state.launchStep(l.id) == "Creating machine")

        _ = Reducer.reduce(state: &state, action: .resumeFailed(cardId: l.id, error: "rush start failed"))
        #expect(state.cardStarts[l.id] == .failed("Resume failed: rush start failed"))
        #expect(state.startFailure(l.id) == "Resume failed: rush start failed")

        _ = Reducer.reduce(state: &state, action: .resumeCard(cardId: l.id))
        #expect(state.cardStarts[l.id] == nil)

        let progress = HandoverProgress(copiedBytes: 1 << 20, totalBytes: 4 << 20)
        _ = Reducer.reduce(state: &state, action: .handoverProgress(cardId: l.id, progress: progress))
        #expect(state.cardStarts[l.id] == .moving(progress))
        // Clearing a move leaves any other report alone.
        _ = Reducer.reduce(state: &state, action: .cardStartReported(cardId: l.id, report: .failed("Could not move")))
        _ = Reducer.reduce(state: &state, action: .handoverProgress(cardId: l.id, progress: nil))
        #expect(state.cardStarts[l.id] == .failed("Could not move"))

        l = state.links[l.id]!
        _ = Reducer.reduce(state: &state, action: .launchCard(
            cardId: l.id, prompt: "go", projectPath: "/repo", worktreeName: nil, runRemotely: false, commandOverride: nil))
        #expect(state.cardStarts[l.id] == nil)
    }

    @Test("the move line names both ends and the copy")
    func handoverLine() {
        var state = AppState()
        state.localMachineId = "machine_mac"
        state.peerStatuses["peer_box"] = PeerStatus(peerId: "peer_box", machine: MachineIdentity(id: "machine_box", name: "box"), online: true)
        var released = link()
        released.ownerMachine = "machine_box"
        released.migrating = true
        state.links[released.id] = released
        #expect(state.handoverLine(cardId: released.id) == "Moving to box")
        state.cardStarts[released.id] = .moving(HandoverProgress(copiedBytes: 120 << 20, totalBytes: 270 << 20))
        #expect(state.handoverLine(cardId: released.id) == "Moving to box, copying the transcript (120 of 270 MB)")
        #expect(state.ownerMachineChoice(cardId: released.id) == "box")

        var incoming = released
        incoming.ownerMachine = "machine_mac"
        incoming.ownerRev = SyncStamp(counter: 3, machine: "machine_box")
        state.links[incoming.id] = incoming
        #expect(state.handoverLine(cardId: incoming.id)?.hasPrefix("Moving here from box") == true)
        #expect(state.ownerMachineChoice(cardId: incoming.id) == nil)

        state.links[incoming.id]?.migrating = nil
        #expect(state.handoverLine(cardId: incoming.id) == nil)
    }
}
