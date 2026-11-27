import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import KanbanCodeRemoteKit

/// A first launch this master handed to a peer: the peer adopts the card and
/// starts it with this prompt.
struct PeerLaunch: Sendable {
    var prompt: String
    var worktree: String?
    /// The prompt's images, in the order of its `[Image #N]` markers.
    var images: [Data] = []
}

public enum MasterPeerError: Error, LocalizedError, Equatable {
    case unknownCard(String)
    case notOwner(String)
    case unknownPeer(String)
    case peerOffline(String)
    /// This master cannot call the peer now; the line names it and says why.
    case notConnected(String)
    /// The peer said no to the card's offer; the line names it and says why.
    case refused(String)
    case busy(String)
    case noProject(String)
    case notReady(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unknownCard(let id): "no card \(id)"
        case .notOwner(let id): "card \(id) runs on another master"
        case .unknownPeer(let name): "no peer master \(name)"
        case .peerOffline(let name): "\(name) is offline"
        case .notConnected(let line), .refused(let line): line
        case .busy(let id): "card \(id) is launching or moving already"
        case .noProject(let url): "no project with origin \(url) here; add it in Settings"
        case .notReady(let message): message
        case .failed(let message): message
        }
    }

    /// Whether trying the adoption again would end the same way: the card
    /// then goes back to the master that released it, with this reason.
    public var refusesAdoption: Bool {
        switch self {
        case .noProject, .failed: true
        case .unknownCard, .notOwner, .unknownPeer, .peerOffline, .notConnected, .refused, .busy, .notReady: false
        }
    }
}

// MARK: - Peers

extension MasterEngine {
    /// The peer master `target` names: its machine id, its name, or the
    /// ssh machine it runs on (any case).
    public func peerMachine(named target: String) -> MachineIdentity? {
        store.state.peerMachine(named: target)
    }

    /// Whether `target` names this master.
    public func isLocalMachine(_ target: String) -> Bool {
        let state = store.state
        return Self.isLocalTarget(target) || target == state.localMachineId
            || (!state.localMachineName.isEmpty && target.lowercased() == state.localMachineName.lowercased())
    }

    /// Whether this master can call the peer with this machine id now: its
    /// control connection is up (`PeerStatus.reachable`).
    public func isPeerOnline(_ machineId: String) -> Bool {
        store.state.peerStatuses.values.contains { $0.machine?.id == machineId && $0.reachable }
    }

    /// A client of the peer master with this machine id, at the address
    /// `PeerEndpoints` has for it now, with the token this master holds for
    /// it. Make one per use: the address can change.
    public func peerClient(machineId: String) async -> RemoteClient? {
        guard let endpoint = peerSync?.endpoints.endpoint(forMachine: machineId) else { return nil }
        return RemoteClient(baseURL: endpoint.baseURL, token: endpoint.token)
    }

    /// The owner's client when another master owns the card.
    public func ownerClient(forCard cardId: String) async -> RemoteClient? {
        guard let link = store.state.links[cardId], let owner = link.ownerMachine,
              owner != store.state.localMachineId, !store.state.localMachineId.isEmpty
        else { return nil }
        return await peerClient(machineId: owner)
    }

    /// Whether another master owns the card.
    public func isForeign(_ cardId: String) -> Bool {
        guard let owner = store.state.links[cardId]?.ownerMachine else { return false }
        let local = store.state.localMachineId
        return !local.isEmpty && owner != local
    }

    /// Whether a queued prompt is gone from the owner's `queue`. rush ids
    /// carry the message's place, which shifts as the queue sends, so a
    /// known `body` is matched by its text and only an unknown one by id.
    nonisolated static func queuedPromptLeft(promptId: String, body: String?, queue: [RemoteQueuedPrompt]) -> Bool {
        if let body { return !queue.contains { $0.text == body } }
        return !queue.contains { $0.id == promptId }
    }

    /// Sends the prompt and queue actions on cards another master owns to
    /// that master, the way a remote client does: the owner runs them.
    public func installForeignCardHandler() {
        store.foreignCardHandler = { [weak self] action in
            self?.handleForeignAction(action) ?? false
        }
    }

    func handleForeignAction(_ action: Action) -> Bool {
        switch action {
        case .addQueuedPrompt(let cardId, let prompt, _):
            guard isForeign(cardId) else { return false }
            forwardedPromptIds.insert(prompt.id)
            forwardPrompt(cardId: cardId, prompt: prompt)
            return true
        case .sendQueuedPrompt(let cardId, let promptId):
            guard isForeign(cardId) else { return false }
            if forwardedPromptIds.remove(promptId) != nil { return true }
            let body = store.state.peerCards[cardId]?.queue.first { $0.id == promptId }?.body
            forwardToOwner(cardId, "send the queued prompt") { client in
                do {
                    try await client.sendQueuedPromptNow(cardId: cardId, promptId: promptId)
                } catch {
                    // The owner's queue sends itself when the turn ends; a
                    // send that lost that race went out already.
                    guard let card = try? await client.card(id: cardId),
                          Self.queuedPromptLeft(promptId: promptId, body: body, queue: card.queuedPrompts)
                    else { throw error }
                    KanbanCodeLog.info("peers", "card \(cardId): queued prompt \(promptId) left the owner's queue; taken as sent")
                }
            }
            return true
        case .removeQueuedPrompt(let cardId, let promptId):
            guard isForeign(cardId) else { return false }
            forwardToOwner(cardId, "remove the queued prompt") { client in
                try await client.removeQueuedPrompt(cardId: cardId, promptId: promptId)
            }
            return true
        case .updateQueuedPrompt(let cardId, let promptId, let body, _):
            guard isForeign(cardId) else { return false }
            forwardToOwner(cardId, "edit the queued prompt") { client in
                try await client.editQueuedPrompt(cardId: cardId, promptId: promptId, text: body)
            }
            return true
        case .reorderQueuedPrompts(let cardId, _):
            // The owner keeps its queue in the order it was sent.
            return isForeign(cardId)
        default:
            return false
        }
    }

    /// Sends a prompt typed here to the master that owns the card. It is
    /// journalled before it leaves, and a send the owner does not take comes
    /// back to the card's chat as a failed prompt, text and images kept.
    func forwardPrompt(cardId: String, prompt: QueuedPrompt) {
        let journal = promptJournal
        let store = self.store
        let ownerName = peerName(store.state.links[cardId]?.ownerMachine ?? "")
        Task {
            await journal.append(QueuedPromptJournalEntry(
                cardId: cardId, promptId: prompt.id, reason: .sent, body: prompt.body,
                imagePaths: prompt.imagePaths, sendAutomatically: prompt.sendAutomatically))
            @MainActor func fail(_ message: String) {
                KanbanCodeLog.warn("peers", "prompt \(prompt.id) to \(cardId) not sent: \(message)")
                store.dispatch(.promptSendFailed(cardId: cardId, prompt: prompt, message: message))
                store.dispatch(.setError("Could not send the prompt on \(ownerName): \(message)"))
            }
            var images: [RemoteImage] = []
            for path in prompt.imagePaths ?? [] {
                guard let data = FileManager.default.contents(atPath: path) else {
                    return fail("the image \((path as NSString).lastPathComponent) is gone")
                }
                images.append(RemoteImage(mediaType: MasterRemoteControlHost.mediaType(ofExtension: (path as NSString).pathExtension),
                                          data: data.base64EncodedString()))
            }
            guard let client = await ownerClient(forCard: cardId) else {
                return fail("\(ownerName) is not a configured peer")
            }
            do {
                try await client.sendPrompt(cardId: cardId, text: prompt.body, mode: .queue, images: images,
                                            human: prompt.isHuman, conversation: prompt.conversation)
                if prompt.conversation != nil { await self.mirrorConversations(cardId: cardId) }
                if let card = try? await client.card(id: cardId) {
                    store.dispatch(.peerCardRead(cardId: cardId, state: PeerTranscriptMirror.state(of: card)))
                }
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    /// Runs `call` on the card's owner, reporting a failure on the board.
    /// A start (`isStart`) reports on the card itself: its status bar shows
    /// the owner's answer, the way a start here shows its own.
    func forwardToOwner(_ cardId: String, _ what: String, isStart: Bool = false,
                        _ call: @escaping @Sendable (RemoteClient) async throws -> Void) {
        if isStart { store.dispatch(.cardStartReported(cardId: cardId, report: nil)) }
        Task {
            let owner = peerName(store.state.links[cardId]?.ownerMachine ?? "")
            guard let client = await ownerClient(forCard: cardId) else {
                report("Could not \(what): \(owner) is not a configured peer")
                return
            }
            do {
                try await call(client)
                // Show the owner's answer (queue, busy) without waiting for the next scan.
                if let card = try? await client.card(id: cardId) {
                    store.dispatch(.peerCardRead(cardId: cardId, state: PeerTranscriptMirror.state(of: card)))
                }
            } catch {
                // The owner's queue as it is now, so the bar does not keep
                // offering a prompt the owner no longer holds.
                if let card = try? await client.card(id: cardId) {
                    store.dispatch(.peerCardRead(cardId: cardId, state: PeerTranscriptMirror.state(of: card)))
                }
                report("Could not \(what) on \(owner): \(error.localizedDescription)")
            }
        }
        func report(_ message: String) {
            KanbanCodeLog.warn("peers", "card \(cardId): \(message)")
            if isStart {
                store.dispatch(.cardStartReported(cardId: cardId, report: .failed(message)))
            } else {
                store.dispatch(.setError(message))
            }
        }
    }

    /// Stops the running turn of a card, here or on its owner.
    public func interrupt(cardId: String) {
        if isForeign(cardId) {
            forwardToOwner(cardId, "interrupt") { client in try await client.interrupt(cardId: cardId) }
            return
        }
        guard let session = store.state.links[cardId]?.tmuxLink?.sessionName else { return }
        let tmux = self.tmux
        Task { try? await tmux.sendEscape(sessionName: session) }
    }

    /// Keeps an image on the master that owns the card and returns its path
    /// there, for a paste into the card's terminal here to type.
    public func uploadPastedImage(cardId: String, data: Data) async throws -> String {
        guard let client = await ownerClient(forCard: cardId) else {
            throw MasterPeerError.unknownPeer(peerName(store.state.links[cardId]?.ownerMachine ?? "the owner"))
        }
        return try await client.uploadPastedImage(cardId: cardId, data: data).path
    }

    /// Sends an image dropped on a card another master owns to its session
    /// there, as a message of its own. False when this master owns the card.
    @discardableResult
    public func sendDroppedImage(cardId: String, png: Data) -> Bool {
        guard isForeign(cardId) else { return false }
        let image = RemoteImage(mediaType: "image/png", data: png.base64EncodedString())
        forwardToOwner(cardId, "send the image") { client in
            try await client.sendPrompt(cardId: cardId, text: "", images: [image])
        }
        return true
    }

    /// Asks the peers to pull now.
    public func notifyPeers() {
        guard let peerSync else { return }
        Task.detached { await peerSync.notifyPeers() }
    }

    // MARK: Moves

    /// Where a resume picked in the resume dialog sends a card another
    /// master owns: nil when the pick is that owner, which resumes the card
    /// where it is; "mac" or the picked machine otherwise, where the card
    /// moves and continues.
    public func movePick(forForeignCard cardId: String, runRemotely: Bool, machineChoice: BoxdMachineChoice?) -> String? {
        guard isForeign(cardId), let owner = store.state.links[cardId]?.ownerMachine else { return nil }
        guard runRemotely else { return "mac" }
        guard let name = machineChoice?.machineName, peerMachine(named: name)?.id != owner else { return nil }
        return name
    }

    /// Moves a card to `target` and reports a refusal on the card, the way
    /// a failed start is.
    public func moveCardReporting(_ cardId: String, to target: String) {
        store.dispatch(.cardStartReported(cardId: cardId, report: nil))
        Task {
            do {
                try await moveCard(cardId, to: target)
            } catch {
                let place = isLocalMachine(target) ? "this Mac" : target
                store.dispatch(.cardStartReported(
                    cardId: cardId, report: .failed("Could not move the card to \(place): \(error.localizedDescription)")))
            }
        }
    }

    /// Continues a card somewhere else. `target` is a peer master (by id or
    /// name: the card's ownership moves there), "mac"/"local" or this
    /// master's name (the card comes back here from a machine this master
    /// drives), or a boxd/ssh machine this master drives. A card another
    /// master owns is moved by its owner.
    public func moveCard(_ cardId: String, to target: String) async throws {
        guard let link = store.state.links[cardId] else { throw MasterPeerError.unknownCard(cardId) }
        if let client = await ownerClient(forCard: cardId) {
            let forwarded = isLocalMachine(target) ? store.state.localMachineId : target
            _ = try await client.move(cardId: cardId, to: forwarded)
            return
        }
        guard store.state.isOwnedLocally(link) else { throw MasterPeerError.notOwner(cardId) }
        if isLocalMachine(target) {
            if link.remote != nil, link.isRemote { moveCardToMachine(cardId, to: "local") }
            return
        }
        if let peer = peerMachine(named: target) {
            try await handover(cardId: cardId, to: peer.id)
            return
        }
        guard link.sessionLink != nil else { throw MasterPeerError.failed("card \(cardId) has no conversation to move") }
        moveCardToMachine(cardId, to: target)
    }

    /// Hands a card this master owns to a peer. The peer is offered the
    /// card first (`offerCard`); only once it said yes does the session
    /// here end, the worktree branch go to origin, and the card get
    /// released with `migrating` set. The peer adopts it once the release
    /// reaches it: it pulls the transcript (and uncommitted changes) from
    /// here and resumes the conversation. A peer that is not connected, or
    /// says no, leaves the card here as it was, and the error says why.
    public func handover(cardId: String, to machineId: String) async throws {
        guard let link = store.state.links[cardId] else { throw MasterPeerError.unknownCard(cardId) }
        guard store.state.isOwnedLocally(link) else { throw MasterPeerError.notOwner(cardId) }
        guard link.isLaunching != true, !handoversInFlight.contains(cardId) else { throw MasterPeerError.busy(cardId) }
        guard await peerClient(machineId: machineId) != nil else { throw MasterPeerError.unknownPeer(machineId) }
        if let problem = peerNotConnected(machineId) { throw MasterPeerError.notConnected(problem) }
        if let problem = peerReachBackProblem(machineId) { throw MasterPeerError.failed(problem) }
        handoversInFlight.insert(cardId)
        defer { handoversInFlight.remove(cardId) }

        // The peer says yes before anything here ends: refused, the card
        // stays as it is, its session still running.
        let name = peerName(machineId)
        let offering = CardStartReport.handingOver("Handing over to \(name)…")
        store.dispatch(.cardStartReported(cardId: cardId, report: offering))
        defer {
            if store.state.cardStarts[cardId] == offering { store.dispatch(.cardStartReported(cardId: cardId, report: nil)) }
        }
        if let refusal = await offerCard(cardId, to: machineId) { throw MasterPeerError.refused(refusal) }
        guard let link = store.state.links[cardId], store.state.isOwnedLocally(link), link.isLaunching != true else {
            throw MasterPeerError.busy(cardId)
        }
        KanbanCodeLog.info("handover", "Releasing card=\(cardId.prefix(12)) to \(name)")

        // A card on a machine this master drives comes back first, so its
        // transcript here is complete.
        if let remote = link.remote, link.isRemote, let boxdSupervisor {
            let sid = link.sessionLink?.sessionId ?? link.id
            let names = (link.tmuxLink?.allSessionNames ?? []) + [link.effectiveAssistant.resumeSessionName(sessionId: sid)]
            await boxdSupervisor.leave(
                machineName: remote.machineName,
                sessionNames: Array(Set(names)),
                localTranscript: link.sessionLink?.sessionPath,
                remoteCwd: remote.remoteCwd)
        }
        // The conversation runs in one place only.
        for name in link.tmuxLink?.allSessionNames ?? [] {
            try? await tmux.killSession(name: name)
        }
        if link.tmuxLink != nil { try? await Task.sleep(for: .seconds(1)) }

        if let worktree = link.worktreeLink, let branch = worktree.branch, !branch.isEmpty,
           FileManager.default.fileExists(atPath: worktree.path) {
            let pushed = await Self.git(["push", "-u", "origin", "HEAD:refs/heads/\(branch)"], in: worktree.path)
            if pushed?.succeeded == true {
                KanbanCodeLog.info("handover", "Pushed \(branch) from \(worktree.path)")
            } else {
                KanbanCodeLog.warn("handover", "Push of \(branch) failed: \(pushed?.stderr.prefix(300) ?? "no git")")
            }
        }
        releasedCards[cardId] = store.state.links[cardId]
        store.dispatch(.releaseCardOwnership(cardId: cardId, to: machineId))
        guard store.state.links[cardId]?.ownerMachine == machineId else {
            throw MasterPeerError.failed("card \(cardId) could not be released")
        }
        notifyPeers()
    }

    /// Why the card cannot start here yet: it is moving here from a peer
    /// and its transcript is still on the way. The adoption starts it once
    /// the copy is done. Nil when the card can start.
    public func stillMovingHere(_ cardId: String) -> String? {
        guard let link = store.state.links[cardId], link.migrating == true, store.state.isOwnedLocally(link) else { return nil }
        let line = store.state.handoverLine(cardId: cardId) ?? "Moving here"
        return "\(line). It resumes by itself once it is here."
    }

    /// Whether the peer `machineId` would pick up a card released to it
    /// (`PeerReachBack`).
    func peerReachBack(_ machineId: String) -> PeerReachBack.Verdict {
        let name = store.state.peerStatuses.values.first { $0.machine?.id == machineId }
            .map { store.state.peerDisplayName($0) } ?? peerName(machineId)
        return PeerReachBack.verdict(
            machineId: machineId, name: name, pulls: store.peerPulls, since: store.peerPullsSince)
    }

    /// Why the peer `machineId` would not pick up a card released to it;
    /// nil when it would, or when that cannot be told yet.
    func peerReachBackProblem(_ machineId: String) -> String? {
        if case .problem(let line) = peerReachBack(machineId) { return line }
        return nil
    }

    /// Notes which peers have not fetched from here lately, for the line of
    /// a card that waits for one of them. Dispatched only when it changes.
    func refreshPeersNotFetching() {
        var problems: [String: String] = [:]
        for status in store.state.peerStatuses.values {
            guard let id = status.machine?.id, let problem = peerReachBackProblem(id) else { continue }
            problems[id] = problem
        }
        if problems != store.state.peersNotFetching {
            store.dispatch(.peersNotFetchingChanged(problems))
        }
    }

    /// The name of the peer master with this machine id, as Settings shows it.
    public func peerDisplayName(_ machineId: String) -> String { peerName(machineId) }

    func peerName(_ machineId: String) -> String {
        store.state.peerStatuses.values.first { $0.machine?.id == machineId }?.machine?.name ?? machineId
    }

    /// Hands a card that never ran to a peer, which launches it there. The
    /// peer is offered the card first; the card is released only once it
    /// said yes. A peer that is not connected is refused at once, and one
    /// that says no or does not answer leaves the card here, not started,
    /// with the reason.
    func launchOnPeer(cardId: String, prompt: String, worktree: String?, peer: MachineIdentity, images: [ImageAttachment] = []) {
        guard !peerLaunchesWaiting.contains(cardId), !handoversInFlight.contains(cardId) else { return }
        if let problem = peerNotConnected(peer.id) {
            KanbanCodeLog.warn("handover", "Not launching card=\(cardId.prefix(12)) on \(peer.name): \(problem)")
            store.dispatch(.cardStartReported(cardId: cardId, report: .failed("Could not start it on \(peer.name): \(problem)")))
            return
        }
        switch peerReachBack(peer.id) {
        case .reaches:
            break
        case .problem(let problem):
            // Released, the card would wait there for a pickup that never
            // comes; it stays here, not started, with the reason.
            KanbanCodeLog.warn("handover", "Not launching card=\(cardId.prefix(12)) on \(peer.name): \(problem)")
            store.dispatch(.cardStartReported(cardId: cardId, report: .failed("Could not start it on \(peer.name): \(problem)")))
            return
        case .unknown(let until):
            // This master just started, and the peer has not fetched from
            // it yet. Released now, a card to a peer that cannot fetch from
            // here would wait there forever, so it waits here until the
            // peer fetches once, or the window says it cannot.
            KanbanCodeLog.info("handover", "Waiting for \(peer.name) to fetch from here before launching card=\(cardId.prefix(12)) there")
            peerLaunchesWaiting.insert(cardId)
            store.dispatch(.cardStartReported(cardId: cardId, report: .handingOver("Waiting for \(peer.name) to answer before it starts there")))
            Task { [weak self] in
                while Date() < until, let self, case .unknown = self.peerReachBack(peer.id) {
                    try? await Task.sleep(for: .milliseconds(500))
                }
                guard let self else { return }
                self.peerLaunchesWaiting.remove(cardId)
                guard self.store.state.links[cardId] != nil else { return }
                self.launchOnPeer(cardId: cardId, prompt: prompt, worktree: worktree, peer: peer, images: images)
            }
            return
        }
        // The images of the launch, else those the card keeps (a card
        // started from the backlog or by the remote API).
        let imageData = images.isEmpty
            ? (store.state.links[cardId]?.promptImagePaths ?? []).compactMap { FileManager.default.contents(atPath: $0) }
            : images.map(\.data)
        // The offer carries the prompt; the adoption fetches it with the images.
        pendingPeerLaunches[cardId] = PeerLaunch(prompt: prompt, worktree: worktree, images: imageData)
        KanbanCodeLog.info("handover", "Launching card=\(cardId.prefix(12)) on \(peer.name)")
        handoversInFlight.insert(cardId)
        store.dispatch(.cardStartReported(cardId: cardId, report: .handingOver("Handing over to \(peer.name)…")))
        Task {
            defer { handoversInFlight.remove(cardId) }
            let refusal = await offerCard(cardId, to: peer.id)
            guard let link = store.state.links[cardId], store.state.isOwnedLocally(link), link.isLaunching != true,
                  link.sessionLink == nil
            else {
                // Deleted, started here or handed elsewhere meanwhile.
                pendingPeerLaunches[cardId] = nil
                if case .handingOver = store.state.cardStarts[cardId] {
                    store.dispatch(.cardStartReported(cardId: cardId, report: nil))
                }
                return
            }
            if let refusal {
                pendingPeerLaunches[cardId] = nil
                KanbanCodeLog.warn("handover", "Card=\(cardId.prefix(12)) stays here: \(refusal)")
                store.dispatch(.cardStartReported(cardId: cardId, report: .failed("Could not start it on \(peer.name): \(refusal)")))
                return
            }
            store.dispatch(.cardStartReported(cardId: cardId, report: nil))
            if link.column == .backlog {
                store.dispatch(.moveCard(cardId: cardId, to: .inProgress))
            }
            releasedCards[cardId] = store.state.links[cardId]
            store.dispatch(.releaseCardOwnership(cardId: cardId, to: peer.id))
            notifyPeers()
        }
    }

    /// Why this master cannot call the peer `machineId` now, e.g. "osaka is
    /// not connected: osaka is stopping"; nil when it can.
    func peerNotConnected(_ machineId: String) -> String? {
        guard !isPeerOnline(machineId) else { return nil }
        let status = store.state.peerStatuses.values.first { $0.machine?.id == machineId }
        let name = status.map { store.state.peerDisplayName($0) } ?? peerName(machineId)
        let reason = status?.unreachableReason?.trimmingCharacters(in: CharacterSet(charactersIn: ". \n"))
        guard let reason, !reason.isEmpty else { return "\(name) is not connected" }
        return "\(name) is not connected: \(reason)"
    }

    // MARK: Offers

    /// How long a peer has to answer an offer.
    static let offerTimeout: TimeInterval = 10

    /// Offers the card to the peer `machineId` before this master releases
    /// it (`POST /v1/cards/{id}/offer`): nil when the peer takes it, else
    /// why not. Nothing here changes either way.
    func offerCard(_ cardId: String, to machineId: String) async -> String? {
        let name = peerName(machineId)
        guard let client = await peerClient(machineId: machineId) else { return "\(name) is not a configured peer" }
        let info: RemoteHandoverInfo
        do {
            info = try await handoverInfo(cardId: cardId, forOffer: true)
        } catch {
            return error.localizedDescription
        }
        let offer = RemoteCardOffer(from: store.state.localMachineId, handover: info)
        do {
            let answer = try await client.offer(cardId: cardId, offer, timeout: Self.offerTimeout)
            if answer.accepted == true {
                KanbanCodeLog.info("handover", "\(name) takes card=\(cardId.prefix(12))")
                return nil
            }
            let reason = answer.refused.flatMap { $0.isEmpty ? nil : $0 } ?? "no reason given"
            KanbanCodeLog.info("handover", "\(name) refused card=\(cardId.prefix(12)): \(reason)")
            return "\(name) does not take it: \(reason)"
        } catch {
            let reason = (error as? URLError)?.code == .timedOut
                ? "\(name) did not answer within \(Int(Self.offerTimeout)) s"
                : "\(name) did not answer: \(error.localizedDescription)"
            KanbanCodeLog.warn("handover", "Offer of card=\(cardId.prefix(12)): \(reason)")
            return reason
        }
    }

    /// Why this master would not take the card a peer offers it, nil when it
    /// would. It checks what it can without the card: it is not stopping,
    /// it reaches the master that offers it (to fetch the card once it is
    /// released), it has the assistant, and it finds the project or may
    /// clone it. What only the adoption finds (a clone that fails, a
    /// transcript that is not there) still hands the card back.
    public func offerProblem(cardId: String, _ offer: RemoteCardOffer) async -> String? {
        let problem = await offerCheck(offer)
        let from = peerName(offer.from)
        if let problem {
            KanbanCodeLog.info("handover", "Refusing card=\(cardId.prefix(12)) from \(from): \(problem)")
        } else {
            KanbanCodeLog.info("handover", "Taking card=\(cardId.prefix(12)) from \(from) once it is released")
        }
        return problem
    }

    private func offerCheck(_ offer: RemoteCardOffer) async -> String? {
        let here = store.state.localMachineName.isEmpty ? "this master" : store.state.localMachineName
        if peerSync?.control.isStopping == true { return "\(here) is shutting down" }
        guard !offer.from.isEmpty, offer.from != store.state.localMachineId else {
            return "the offer does not say which master it comes from"
        }
        guard isPeerOnline(offer.from) else {
            return "\(here) cannot reach \(peerName(offer.from)) to fetch the card"
        }
        let info = offer.handover
        guard let assistant = CodingAssistant(rawValue: info.assistant) else {
            return "\(here) does not know the assistant \(info.assistant)"
        }
        if info.sessionId != nil, assistant != .claude { return "only Claude conversations move between masters" }
        guard platform.assistantInstalled(assistant) else { return "\(assistant.displayName) is not installed on \(here)" }
        do {
            _ = try await repositoryPlan(repoUrl: info.repoUrl, fallback: info.projectPath, hasCommits: info.repoHasCommits ?? true)
        } catch {
            return error.localizedDescription
        }
        return nil
    }

    // MARK: Serving a handover

    /// What a master adopting `cardId` needs from this one. `forOffer`
    /// leaves out what only the adoption needs and is not final while the
    /// card still runs here: the uncommitted changes and the images.
    public func handoverInfo(cardId: String, forOffer: Bool = false) async throws -> RemoteHandoverInfo {
        // The card as it was when this master released it: the new owner's
        // edits may already have landed here.
        guard let link = releasedCards[cardId] ?? store.state.links[cardId] else { throw MasterPeerError.unknownCard(cardId) }
        let transcript = link.sessionLink?.sessionPath
        let size = transcript.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0))?[.size] as? Int } ?? 0
        let repoRoot = link.projectPath
        let worktree = link.worktreeLink.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        var repoUrl: String?
        if let dir = worktree?.path ?? repoRoot, FileManager.default.fileExists(atPath: dir) {
            repoUrl = await Self.git(["remote", "get-url", "origin"], in: dir)
                .flatMap { $0.succeeded ? $0.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil }
        }
        var patch: String?
        if let worktree, !forOffer {
            if let diff = await Self.uncommittedDiff(in: worktree.path), diff.succeeded,
               !diff.stdout.isEmpty, diff.stdout.utf8.count < 20 << 20 {
                // The command runner trims the last newline, which git apply needs.
                let text = diff.stdout.hasSuffix("\n") ? diff.stdout : diff.stdout + "\n"
                patch = Data(text.utf8).base64EncodedString()
            }
        }
        if !forOffer {
            KanbanCodeLog.info("handover", "Serving card=\(cardId.prefix(12)) transcript=\(transcript ?? "none") (\(size) bytes)")
        }
        var launch = pendingPeerLaunches[cardId]
        if launch == nil, link.sessionLink == nil, link.migrating == true,
           let prompt = link.promptBody ?? link.name, !prompt.isEmpty {
            // A first launch released before this app restarted: the prompt
            // it held in memory is gone, the card's own is not.
            KanbanCodeLog.info("handover", "Serving card=\(cardId.prefix(12)) with its saved prompt")
            launch = PeerLaunch(prompt: prompt, worktree: nil)
        }
        var info = RemoteHandoverInfo(
            cardId: cardId,
            sessionId: link.sessionLink?.sessionId,
            assistant: link.effectiveAssistant.rawValue,
            projectPath: repoRoot,
            cwd: worktree?.path ?? repoRoot,
            repoUrl: repoUrl,
            branch: worktree?.branch ?? link.worktreeLink?.branch,
            worktreeName: (worktree?.path ?? link.worktreeLink?.path).map { ($0 as NSString).lastPathComponent }
                .flatMap { $0.isEmpty ? nil : $0 },
            patch: patch,
            transcriptSize: size
        )
        if repoUrl == nil, let repoRoot, FileManager.default.fileExists(atPath: repoRoot) {
            info.repoHasCommits = await Self.git(["rev-parse", "--verify", "-q", "HEAD"], in: repoRoot)?.succeeded == true
        }
        info.refusal = refusedHandovers[cardId]
        if let launch, forOffer {
            info.launchPrompt = launch.prompt
            info.launchWorktree = launch.worktree
        } else if let launch {
            info.launchPrompt = launch.prompt
            info.launchWorktree = launch.worktree
            info.launchImages = launch.images.isEmpty
                ? Self.remoteImages(atPaths: link.promptImagePaths ?? [])
                : launch.images.map { RemoteImage(mediaType: RemotePromptImages.mimeType(of: $0), data: $0.base64EncodedString()) }
            KanbanCodeLog.info("handover", "Serving card=\(cardId.prefix(12)) first prompt with \(info.launchImages?.count ?? 0) image(s)")
        }
        if let remote = link.remote, link.isRemote,
           let target = store.state.links[cardId]?.ownerMachine,
           store.state.sshMachine(named: remote.machineName, runningMaster: target) != nil {
            info.machineCwd = remote.remoteCwd
        }
        return info
    }

    /// A slice of the card's transcript file.
    public func rawTranscript(cardId: String, offset: Int, limit: Int) throws -> RemoteRawTranscript {
        guard let link = releasedCards[cardId] ?? store.state.links[cardId] else { throw MasterPeerError.unknownCard(cardId) }
        guard let path = link.sessionLink?.sessionPath, let handle = FileHandle(forReadingAtPath: path) else {
            return RemoteRawTranscript(data: Data(), offset: offset, size: 0)
        }
        defer { try? handle.close() }
        let size = Int((try? handle.seekToEnd()) ?? 0)
        guard offset < size else { return RemoteRawTranscript(data: Data(), offset: offset, size: size) }
        try handle.seek(toOffset: UInt64(offset))
        let data = try handle.read(upToCount: min(limit, size - offset)) ?? Data()
        if releasedCards[cardId] != nil {
            // The new owner is copying the transcript of the card it adopts.
            store.dispatch(.handoverProgress(cardId: cardId, progress: HandoverProgress(copiedBytes: offset + data.count, totalBytes: size)))
        }
        return RemoteRawTranscript(data: data, offset: offset, size: size)
    }

    // MARK: Adopting

    /// Runs until cancelled: tells the peers when cards changed here, and
    /// adopts the cards peers released to this master.
    public func runOwnershipLoop() async {
        var lastNotified = store.state.syncSeq
        var lastAttention = localAttentionSignature
        var lastAttempt: [String: Date] = [:]
        var scannedVersion = -1
        var lastScan = Date.distantPast
        var lastReachBackCheck = Date.distantPast
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))
            let seq = store.state.syncSeq
            if seq != lastNotified {
                lastNotified = seq
                notifyPeers()
            }
            let attention = localAttentionSignature
            if attention != lastAttention, let peerSync {
                lastAttention = attention
                Task.detached { await peerSync.announce(PeerChange(what: .attention)) }
            }
            let local = store.state.localMachineId
            guard !local.isEmpty else { continue }
            if Date().timeIntervalSince(lastReachBackCheck) >= 5 {
                lastReachBackCheck = Date()
                refreshPeersNotFetching()
            }
            // A released card stops being served once its new owner took it.
            // The cards only need a look when they changed, or when a
            // failed adoption is due for another try.
            let version = store.state.cardInputsVersion
            guard version != scannedVersion || Date().timeIntervalSince(lastScan) >= 30 else { continue }
            scannedVersion = version
            lastScan = Date()
            for (id, _) in releasedCards where store.state.links[id]?.migrating != true {
                releasedCards[id] = nil
                pendingPeerLaunches[id] = nil
                store.dispatch(.handoverProgress(cardId: id, progress: nil))
            }
            for (id, _) in refusedHandovers where store.state.links[id]?.migrating != true {
                refusedHandovers[id] = nil
            }
            for link in store.state.links.values where link.ownerMachine == local && link.migrating == true {
                let id = link.id
                guard !handoversInFlight.contains(id) else { continue }
                if let last = lastAttempt[id], Date().timeIntervalSince(last) < 30 { continue }
                lastAttempt[id] = Date()
                handoversInFlight.insert(id)
                Task {
                    defer { handoversInFlight.remove(id) }
                    if await adoptOrHandBack(cardId: id) { lastAttempt[id] = nil }
                }
            }
        }
    }

    /// Adopts a card a peer released to this master. A failure that
    /// another try would repeat sends the card back to that peer with the
    /// reason; any other failure leaves the card for the next try. Returns
    /// whether the card left the adoption queue.
    @discardableResult
    func adoptOrHandBack(cardId id: String) async -> Bool {
        do {
            try await adopt(cardId: id)
            return true
        } catch {
            let link = store.state.links[id]
            store.dispatch(.handoverProgress(cardId: id, progress: nil))
            KanbanCodeLog.warn("handover", "Adopting card=\(id.prefix(12)) failed: \(error.localizedDescription)")
            store.dispatch(.setError("Could not take over \(link?.name ?? id): \(error.localizedDescription)"))
            guard let refusal = error as? MasterPeerError, refusal.refusesAdoption,
                  let from = link?.ownerRev?.machine, from != store.state.localMachineId
            else { return false }
            refusedHandovers[id] = refusal.localizedDescription
            store.dispatch(.releaseCardOwnership(cardId: id, to: from))
            guard store.state.links[id]?.ownerMachine == from else {
                refusedHandovers[id] = nil
                return false
            }
            KanbanCodeLog.info("handover", "Card=\(id.prefix(12)) goes back to \(peerName(from))")
            notifyPeers()
            return true
        }
    }

    /// Keeps a card the peer could not take: it stays as it was here, with
    /// the peer's reason as the result of its start.
    private func takeBack(cardId: String, from: String, reason: String) throws {
        let before = store.state.links[cardId]
        store.dispatch(.adoptCard(cardId: cardId, sessionLink: nil, worktreeLink: nil, projectPath: nil))
        guard store.state.links[cardId]?.migrating == nil else { throw MasterPeerError.notReady("card \(cardId) could not be taken back") }
        pendingPeerLaunches[cardId] = nil
        releasedCards[cardId] = nil
        if before?.sessionLink == nil, before?.column == .inProgress {
            store.dispatch(.moveCard(cardId: cardId, to: .backlog))
        }
        let line = "\(peerName(from)) could not take it: \(reason)"
        KanbanCodeLog.warn("handover", "Card=\(cardId.prefix(12)) stays here. \(line)")
        store.dispatch(.cardStartReported(cardId: cardId, report: .failed(line)))
        store.dispatch(.setError("\(before?.name ?? cardId) stays on this machine. \(line)"))
    }

    /// Takes over a card a peer released to this master: its repository
    /// and worktree here, its transcript, then its session.
    func adopt(cardId: String) async throws {
        guard let link = store.state.links[cardId] else { throw MasterPeerError.unknownCard(cardId) }
        guard let from = link.ownerRev?.machine, from != store.state.localMachineId,
              let client = await peerClient(machineId: from)
        else { throw MasterPeerError.unknownPeer(link.ownerRev?.machine ?? "the releasing master") }
        KanbanCodeLog.info("handover", "Adopting card=\(cardId.prefix(12)) from \(peerName(from))")
        let info = try await client.handover(cardId: cardId)
        if let reason = info.refusal {
            try takeBack(cardId: cardId, from: from, reason: reason)
            return
        }
        let assistant = CodingAssistant(rawValue: info.assistant) ?? link.effectiveAssistant

        let repoRoot = try await localRepository(repoUrl: info.repoUrl, fallback: info.projectPath, hasCommits: info.repoHasCommits ?? true)
        var cwd = repoRoot
        var worktreeLink: WorktreeLink?
        // A card that ran over ssh on this very machine continues in the
        // folder it ran in, uncommitted work included.
        let machineCwd = info.machineCwd.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
        if let machineCwd, info.sessionId != nil {
            cwd = machineCwd
            if let branch = info.branch, machineCwd.contains("/.claude/worktrees/") {
                worktreeLink = WorktreeLink(path: machineCwd, branch: branch)
            }
            KanbanCodeLog.info("handover", "Card=\(cardId.prefix(12)) ran on this machine over ssh, continuing in \(machineCwd)")
        } else if info.sessionId != nil, let name = info.worktreeName, let branch = info.branch {
            worktreeLink = try await Self.checkoutWorktree(repoRoot: repoRoot, name: name, branch: branch)
            cwd = worktreeLink!.path
            if let patch = info.patch, let data = Data(base64Encoded: patch), !data.isEmpty {
                try await Self.applyPatch(data, in: cwd)
            }
        }

        var sessionLink: SessionLink?
        if let sessionId = info.sessionId {
            guard assistant == .claude else { throw MasterPeerError.failed("only Claude conversations move between masters") }
            // An empty transcript would replace the conversation with nothing.
            guard info.transcriptSize > 0 else {
                throw MasterPeerError.notReady("\(peerName(from)) has no transcript for this card yet")
            }
            let path = transcriptPath(cwd: cwd, sessionId: sessionId)
            var raw = await Self.mirroredPrefix(
                at: PeerTranscriptMirror.mirrorPath(
                    directory: (platform.kanbanHome as NSString).appendingPathComponent("peers"),
                    machineId: from, sessionId: sessionId),
                size: info.transcriptSize, cardId: cardId, client: client) ?? Data()
            if !raw.isEmpty {
                KanbanCodeLog.info("handover", "Transcript \(sessionId.prefix(8)): \(raw.count) of \(info.transcriptSize) bytes taken from the mirror here")
            }
            store.dispatch(.handoverProgress(cardId: cardId, progress: HandoverProgress(copiedBytes: raw.count, totalBytes: info.transcriptSize)))
            while raw.count < info.transcriptSize {
                let slice = try await client.rawTranscript(cardId: cardId, offset: raw.count)
                if slice.data.isEmpty { break }
                raw.append(slice.data)
                store.dispatch(.handoverProgress(cardId: cardId, progress: HandoverProgress(copiedBytes: raw.count, totalBytes: info.transcriptSize)))
            }
            var mappings: [PathMapping] = []
            if let old = info.cwd, old != cwd { mappings.append(PathMapping(from: old, to: cwd)) }
            if let old = info.projectPath, old != repoRoot, old != info.cwd { mappings.append(PathMapping(from: old, to: repoRoot)) }
            let incomingLines = raw.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
            if machineCwd != nil, BoxdLaunchPlanner.lineCount(ofFileAt: path) >= incomingLines {
                // The session wrote this file here; the releasing master's copy
                // is a mirror of it.
                KanbanCodeLog.info("handover", "Transcript \(sessionId.prefix(8)) already here at \(path), kept")
            } else {
                try Self.writeTranscript(raw, to: path, rewriter: TranscriptPathRewriter(mappings))
                KanbanCodeLog.info("handover", "Transcript \(sessionId.prefix(8)) copied (\(raw.count) bytes) to \(path)")
            }
            sessionLink = SessionLink(sessionId: sessionId, sessionPath: path)
        }

        store.dispatch(.adoptCard(cardId: cardId, sessionLink: sessionLink, worktreeLink: worktreeLink, projectPath: repoRoot))
        guard store.state.links[cardId]?.migrating == nil else { throw MasterPeerError.notReady("card \(cardId) could not be adopted") }
        notifyPeers()

        if sessionLink != nil {
            resume(
                cardId: cardId,
                runRemotely: false,
                skipPermissions: platform.skipPermissions(),
                commandOverride: nil,
                assistant: assistant,
                keepSelection: true
            )
        } else if let prompt = info.launchPrompt {
            let isGitRepo = FileManager.default.fileExists(atPath: (repoRoot as NSString).appendingPathComponent(".git"))
            // The prompt's images, kept with the card as the New Task dialog keeps them.
            // A bad image is left out rather than keeping the card from starting.
            var imagePaths: [String] = []
            do {
                imagePaths = try RemotePromptImages.write(
                    RemotePromptImages.decode(info.launchImages), to: RemotePromptImages.taskDirectory, prefix: "handover")
            } catch {
                KanbanCodeLog.warn("handover", "Images of card=\(cardId.prefix(12)) left out: \(error.localizedDescription)")
            }
            KanbanCodeLog.info("handover", "Launching card=\(cardId.prefix(12)) with \(imagePaths.count) of \(info.launchImages?.count ?? 0) image(s)")
            launch(
                cardId: cardId,
                prompt: prompt,
                projectPath: repoRoot,
                worktreeName: isGitRepo && assistant.supportsWorktree ? info.launchWorktree : nil,
                runRemotely: false,
                skipPermissions: platform.skipPermissions(),
                images: imagePaths.compactMap { ImageAttachment.fromPath($0) },
                assistant: assistant,
                modelOverride: link.modelOverride,
                keepSelection: true
            )
        }
    }

    /// The images at `paths` for the remote API; a file that is gone is left out.
    static func remoteImages(atPaths paths: [String]) -> [RemoteImage]? {
        let images = paths.compactMap { path -> RemoteImage? in
            guard let data = FileManager.default.contents(atPath: path) else { return nil }
            return RemoteImage(mediaType: RemotePromptImages.mimeType(of: data), data: data.base64EncodedString())
        }
        return images.isEmpty ? nil : images
    }

    /// Where the repository a card needs is, or would be, on this master.
    enum RepositoryPlan: Equatable {
        /// It is here; `addsProject` when it may not be a project yet.
        case here(String, addsProject: Bool)
        /// It is cloned from `url` into the folder.
        case clone(url: String, into: String)
        /// A project with no `origin` and no commits starts as a new
        /// repository in the folder.
        case create(String)
    }

    /// How this master gets the repository with origin `repoUrl` (else the
    /// project at `fallback` on the releasing master), without doing it:
    /// a configured project or an earlier clone, a clone where this master
    /// may clone, a new repository for a project with nothing to bring.
    /// Throws why it cannot.
    func repositoryPlan(repoUrl: String?, fallback: String?, hasCommits: Bool = true) async throws -> RepositoryPlan {
        guard let repoUrl, let wanted = Self.normalizedRepoURL(repoUrl) else {
            if let fallback, FileManager.default.fileExists(atPath: fallback) { return .here(fallback, addsProject: false) }
            guard let fallback else { throw MasterPeerError.noProject("unknown") }
            // The folder of the same name in the projects directory.
            let name = (fallback as NSString).lastPathComponent
            let dir = (platform.projectsDirectory as NSString).appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: dir) { return .here(dir, addsProject: true) }
            guard platform.clonesMissingProjects else { throw MasterPeerError.noProject(fallback) }
            guard !hasCommits else {
                throw MasterPeerError.failed("\(name) has no git remote, so its files cannot follow here; give it a remote, or copy it to \(dir)")
            }
            return .create(dir)
        }
        var candidates = store.state.configuredProjects.map(\.effectiveRepoRoot)
        let cloneDir = (platform.projectsDirectory as NSString).appendingPathComponent(Self.repoName(of: repoUrl))
        candidates.append(cloneDir)
        for dir in candidates where FileManager.default.fileExists(atPath: dir) {
            let origin = await Self.git(["remote", "get-url", "origin"], in: dir)
            if let out = origin?.stdout, origin?.succeeded == true, Self.normalizedRepoURL(out) == wanted {
                return .here(dir, addsProject: true)
            }
        }
        guard platform.clonesMissingProjects else { throw MasterPeerError.noProject(repoUrl) }
        guard !FileManager.default.fileExists(atPath: cloneDir) else {
            throw MasterPeerError.failed("\(cloneDir) exists and is not a clone of \(repoUrl)")
        }
        return .clone(url: repoUrl, into: cloneDir)
    }

    /// The repository with origin `repoUrl` here: a configured project, or
    /// a clone next to the others where this master may clone.
    func localRepository(repoUrl: String?, fallback: String?, hasCommits: Bool = true) async throws -> String {
        switch try await repositoryPlan(repoUrl: repoUrl, fallback: fallback, hasCommits: hasCommits) {
        case .here(let dir, let addsProject):
            if addsProject { await addProjectIfMissing(dir) }
            return dir
        case .clone(let url, let dir):
            try? FileManager.default.createDirectory(atPath: platform.projectsDirectory, withIntermediateDirectories: true)
            KanbanCodeLog.info("handover", "Cloning \(url) into \(dir)")
            let clone = await Self.git(["clone", url, dir], in: platform.projectsDirectory, timeout: 1200)
            guard clone?.succeeded == true else {
                throw MasterPeerError.failed("git clone \(url) failed: \(clone?.stderr.prefix(300) ?? "no git")")
            }
            await addProjectIfMissing(dir)
            return dir
        case .create(let dir):
            return try await newRepository(at: dir)
        }
    }

    /// Starts a project that has no `origin` and no commits on the master
    /// that released the card as a new repository in `dir`.
    private func newRepository(at dir: String) async throws -> String {
        let name = (dir as NSString).lastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        KanbanCodeLog.info("handover", "Starting \(name) as a new repository in \(dir)")
        // A worktree needs a commit to branch from.
        let identity = ["-c", "user.name=Kanban Code", "-c", "user.email=kanban-code@localhost"]
        guard await Self.git(["init"], in: dir)?.succeeded == true,
              await Self.git(identity + ["commit", "--allow-empty", "-m", "Initial commit"], in: dir)?.succeeded == true
        else { throw MasterPeerError.failed("git init in \(dir) failed") }
        await addProjectIfMissing(dir)
        return dir
    }

    private func addProjectIfMissing(_ path: String) async {
        guard !store.state.configuredProjects.contains(where: { $0.effectiveRepoRoot == path || $0.path == path }) else { return }
        try? await settingsStore.addProject(Project(path: path))
        await store.loadSettingsAndCache()
    }

    /// `github.com/owner/repo` for the ssh and https forms of a remote.
    nonisolated static func normalizedRepoURL(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix(".git") { s.removeLast(4) }
        if let range = s.range(of: "://") {
            s = String(s[range.upperBound...])
            if let at = s.firstIndex(of: "@"), at < (s.firstIndex(of: "/") ?? s.endIndex) {
                s = String(s[s.index(after: at)...])
            }
        } else if let at = s.firstIndex(of: "@"), let colon = s.firstIndex(of: ":"), at < colon {
            s = String(s[s.index(after: at)..<colon]) + "/" + String(s[s.index(after: colon)...])
        }
        return s.lowercased()
    }

    nonisolated static func repoName(of url: String) -> String {
        var name = (url.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).lastPathComponent
        if name.hasSuffix(".git") { name.removeLast(4) }
        if let colon = name.lastIndex(of: ":") { name = String(name[name.index(after: colon)...]) }
        return name.isEmpty ? "repo" : name
    }

    /// The worktree `name` of `repoRoot` on `branch`, from origin when the
    /// branch is not here yet.
    nonisolated static func checkoutWorktree(repoRoot: String, name: String, branch: String) async throws -> WorktreeLink {
        let path = "\(repoRoot)/.claude/worktrees/\(name)"
        if FileManager.default.fileExists(atPath: path) {
            // What this worktree held from an earlier stay here is older than
            // what comes now; it is stashed, not lost.
            if let dirty = await git(["status", "--porcelain"], in: path), !dirty.stdout.isEmpty {
                // Unstaged first: an intent-to-add entry makes the stash fail.
                _ = await git(["reset", "-q"], in: path)
                let stash = await git(["stash", "push", "--include-untracked", "-m", "kanban handover \(ISO8601DateFormatter().string(from: Date()))"], in: path)
                if stash?.succeeded == true {
                    KanbanCodeLog.info("handover", "Stashed earlier changes of worktree \(name)")
                } else {
                    KanbanCodeLog.warn("handover", "Could not stash earlier changes of worktree \(name): \(stash?.stderr.prefix(300) ?? "no git")")
                }
            }
            _ = await git(["fetch", "origin", branch], in: path)
            if await git(["merge", "--ff-only", "origin/\(branch)"], in: path)?.succeeded != true {
                KanbanCodeLog.warn("handover", "Worktree \(name) did not fast-forward to origin/\(branch)")
            }
            return WorktreeLink(path: path, branch: branch)
        }
        try? FileManager.default.createDirectory(atPath: "\(repoRoot)/.claude/worktrees", withIntermediateDirectories: true)
        _ = await git(["fetch", "origin", branch], in: repoRoot)
        let hasLocal = await git(["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], in: repoRoot)?.succeeded == true
        let hasRemote = await git(["show-ref", "--verify", "--quiet", "refs/remotes/origin/\(branch)"], in: repoRoot)?.succeeded == true
        let arguments: [String]
        if hasLocal {
            arguments = ["worktree", "add", path, branch]
        } else if hasRemote {
            arguments = ["worktree", "add", "--track", "-b", branch, path, "origin/\(branch)"]
        } else {
            arguments = ["worktree", "add", "-b", branch, path]
        }
        guard let result = await git(arguments, in: repoRoot), result.succeeded else {
            throw MasterPeerError.failed("git worktree add \(name) failed")
        }
        if hasLocal, hasRemote {
            _ = await git(["merge", "--ff-only", "origin/\(branch)"], in: path)
        }
        return WorktreeLink(path: path, branch: branch)
    }

    /// Everything uncommitted in a worktree, new files included, as a
    /// binary diff against HEAD. Built in a copy of the index, so the
    /// worktree's own index is left as it was.
    nonisolated static func uncommittedDiff(in dir: String) async -> ShellCommand.Result? {
        guard let indexPath = await git(["rev-parse", "--git-path", "index"], in: dir), indexPath.succeeded else { return nil }
        let source = indexPath.stdout.hasPrefix("/") ? indexPath.stdout : (dir as NSString).appendingPathComponent(indexPath.stdout)
        let temp = NSTemporaryDirectory() + "kanban-handover-index-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: temp) }
        if FileManager.default.fileExists(atPath: source) {
            try? FileManager.default.copyItem(atPath: source, toPath: temp)
        }
        var env = ShellCommand.loginEnvironment
        env["GIT_INDEX_FILE"] = temp
        _ = await git(["add", "-A"], in: dir, environment: env)
        return await git(["diff", "--cached", "--no-color", "--no-ext-diff", "--binary", "HEAD"], in: dir, environment: env)
    }

    nonisolated static func applyPatch(_ patch: Data, in dir: String) async throws {
        let file = NSTemporaryDirectory() + "kanban-handover-\(UUID().uuidString).patch"
        try patch.write(to: URL(fileURLWithPath: file))
        defer { try? FileManager.default.removeItem(atPath: file) }
        let result = await git(["apply", "--binary", "--whitespace=nowarn", file], in: dir)
        if result?.succeeded != true {
            KanbanCodeLog.warn("handover", "Uncommitted changes did not apply in \(dir): \(result?.stderr.prefix(300) ?? "no git")")
        }
    }

    /// The bytes of the local mirror of a peer's transcript, when they are
    /// the start of the transcript that peer serves now: the adoption then
    /// copies only the rest. The mirror's last bytes are compared with the
    /// peer's at the same offset.
    static func mirroredPrefix(at path: String, size: Int, cardId: String, client: RemoteClient) async -> Data? {
        guard let mirror = FileManager.default.contents(atPath: path), !mirror.isEmpty, mirror.count <= size else { return nil }
        let tail = min(mirror.count, 64 << 10)
        let offset = mirror.count - tail
        guard let slice = try? await client.rawTranscript(cardId: cardId, offset: offset, limit: tail),
              slice.data == mirror.suffix(tail) else { return nil }
        return mirror
    }

    /// Writes a transcript line by line with its paths rewritten.
    nonisolated static func writeTranscript(_ raw: Data, to path: String, rewriter: TranscriptPathRewriter) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        var out = Data()
        out.reserveCapacity(raw.count + 4096)
        for line in raw.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false) {
            if line.isEmpty { continue }
            let text = String(decoding: line, as: UTF8.self)
            out.append(contentsOf: Array(rewriter.rewriteLine(text).utf8))
            out.append(UInt8(ascii: "\n"))
        }
        try out.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    nonisolated static func git(_ arguments: [String], in dir: String, timeout: TimeInterval = 120,
                                environment: [String: String]? = nil) async -> ShellCommand.Result? {
        let git = ShellCommand.findExecutable("git") ?? "/usr/bin/git"
        return try? await ShellCommand.run(git, arguments: ["-c", "color.ui=false", "-c", "core.pager=cat"] + arguments,
                                           currentDirectory: dir, environment: environment, timeout: timeout)
    }
}
