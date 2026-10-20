import Foundation
import KanbanCodeRemoteKit
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Executes side effects produced by the Reducer.
/// All async operations (disk, network, tmux) go through here.
public actor EffectHandler {
    private let coordinationStore: CoordinationStore
    private let tmuxAdapter: TmuxManagerPort?
    private let setClipboardImage: (@Sendable (Data) -> Void)?
    private let notifier: NotifierPort?
    private let queuedPromptJournal: QueuedPromptJournal
    private let humanMessageLog: HumanMessageLog
    private let remoteMachines: (any RemoteMachineControl)?
    /// Delivers attention requests to the Mac and the phone.
    private var attentionDelivery: (any AttentionDelivering)?

    public func setAttentionDelivery(_ delivery: (any AttentionDelivering)?) {
        attentionDelivery = delivery
    }

    /// Creates a session on a machine, and reconnects the machine once when
    /// it answers no longer: the app can hold a machine as paused while it
    /// runs again, and the shell of the user must not fail for that.
    private func createRemoteSession(machineName: String, name: String, path: String) async throws {
        do {
            try await tmuxAdapter?.createSession(name: name, path: path, command: nil)
        } catch {
            guard await remoteMachines?.reconnectIfRunning(machineName: machineName) == true else { throw error }
            try await tmuxAdapter?.createSession(name: name, path: path, command: nil)
        }
    }

    /// A shell that fails takes only its own tab. A session of a card that
    /// fails takes the tmux link with it, so the card can be launched again.
    static func terminalFailure(cardId: String, sessionName: String, isExtra: Bool, error: any Error) -> Action {
        isExtra
            ? .extraTerminalFailed(cardId: cardId, sessionName: sessionName, error: error.localizedDescription)
            : .terminalFailed(cardId: cardId, error: error.localizedDescription)
    }

    /// Writes a card title from a prompt.
    private let titleGenerator: @Sendable (String) async throws -> String

    public init(
        coordinationStore: CoordinationStore,
        tmuxAdapter: TmuxManagerPort? = nil,
        setClipboardImage: (@Sendable (Data) -> Void)? = nil,
        notifier: NotifierPort? = nil,
        queuedPromptJournal: QueuedPromptJournal? = nil,
        remoteMachines: (any RemoteMachineControl)? = nil,
        humanMessageLog: HumanMessageLog? = nil,
        titleGenerator: (@Sendable (String) async throws -> String)? = nil
    ) {
        self.titleGenerator = titleGenerator ?? { try await TaskTitleGenerator.generate(prompt: $0) }
        self.coordinationStore = coordinationStore
        self.tmuxAdapter = tmuxAdapter
        self.setClipboardImage = setClipboardImage
        self.notifier = notifier
        self.queuedPromptJournal = queuedPromptJournal ?? QueuedPromptJournal()
        self.humanMessageLog = humanMessageLog ?? HumanMessageLog()
        self.remoteMachines = remoteMachines
    }

    public func execute(_ effect: Effect, dispatch: @MainActor @Sendable (Action) -> Void) async {
        switch effect {
        case .persistLinks(let links):
            do {
                try await coordinationStore.writeLinks(links)
            } catch {
                KanbanCodeLog.warn("effect", "persistLinks failed: \(error)")
            }

        case .upsertLink(let link):
            do {
                try await coordinationStore.upsertLink(link)
            } catch {
                KanbanCodeLog.warn("effect", "upsertLink failed: \(error)")
            }

        case .removeLink(let id):
            do {
                try await coordinationStore.removeLink(id: id)
            } catch {
                KanbanCodeLog.warn("effect", "removeLink failed: \(error)")
            }

        case .persistTombstones(let tombstones):
            do {
                try await coordinationStore.writeTombstones(tombstones)
            } catch {
                KanbanCodeLog.warn("effect", "persistTombstones failed: \(error)")
            }

        case .createTmuxSession(let cardId, let name, let path, let isExtra):
            do {
                try await tmuxAdapter?.createSession(name: name, path: path, command: nil)
                await dispatch(.terminalCreated(cardId: cardId, tmuxName: name))
            } catch {
                await dispatch(Self.terminalFailure(
                    cardId: cardId, sessionName: name, isExtra: isExtra, error: error))
            }

        case .createRemoteTmuxSession(let cardId, let machineName, let name, let path, let isExtra):
            await remoteMachines?.assignSession(name, to: machineName)
            do {
                try await createRemoteSession(machineName: machineName, name: name, path: path)
                // The terminal waits for this marker before it attaches, the
                // same way it does for the session of the card.
                await remoteMachines?.markSessionReady(name, on: machineName)
                await dispatch(.terminalCreated(cardId: cardId, tmuxName: name))
            } catch {
                await dispatch(Self.terminalFailure(
                    cardId: cardId, sessionName: name, isExtra: isExtra, error: error))
            }

        case .killTmuxSession(let name):
            try? await tmuxAdapter?.killSession(name: name)

        case .killTmuxSessions(let names):
            for name in names {
                try? await tmuxAdapter?.killSession(name: name)
            }

        case .stopRemoteMachine(let machineName, let reason):
            await remoteMachines?.stop(machineName: machineName, reason: reason)

        case .destroyRemoteMachine(let machineName):
            do {
                try await remoteMachines?.destroy(machineName: machineName)
                await dispatch(.remoteMachineDestroyed(machineName: machineName))
            } catch {
                KanbanCodeLog.warn("effect", "destroyRemoteMachine \(machineName) failed: \(error)")
                await dispatch(.setError("Could not destroy machine \(machineName): \(error.localizedDescription)"))
            }

        case .deleteSessionFile(let path):
            try? FileManager.default.removeItem(atPath: path)

        case .cleanupTerminalCache(let sessionNames):
            await MainActor.run {
                for name in sessionNames {
                    TerminalCacheRelay.remove(name)
                }
            }

        case .cleanupBrowserCache(let cardId):
            await MainActor.run {
                BrowserTabCacheRelay.removeAll(cardId: cardId)
            }

        case .refreshDiscovery:
            // This is handled by the orchestrator, not here
            break

        case .updateSessionIndex(let sessionId, let name):
            try? SessionIndexReader.updateSummary(sessionId: sessionId, summary: name)

        case .generateTitle(let cardId, let prompt):
            do {
                let title = try await titleGenerator(prompt)
                await dispatch(.titleGenerated(cardId: cardId, name: title))
            } catch {
                // The card keeps the first line of its prompt as its name.
                KanbanCodeLog.warn("title", "card \(cardId.prefix(12)): \(error.localizedDescription)")
            }

        case .moveSessionFile(let cardId, let sessionId, let oldPath, let newProjectPath):
            do {
                let newPath = try SessionFileMover.moveSession(
                    sessionId: sessionId,
                    fromPath: oldPath,
                    toProjectPath: newProjectPath
                )
                // Update the link's sessionPath to the new location
                try await coordinationStore.updateLink(id: cardId) { link in
                    link.sessionLink?.sessionPath = newPath
                }
                KanbanCodeLog.info("effect", "Moved session \(sessionId.prefix(8)) → \(newPath)")
            } catch {
                KanbanCodeLog.warn("effect", "moveSessionFile failed: \(error)")
                await dispatch(.setError("Move failed: \(error.localizedDescription)"))
            }
        case .journalQueuedPrompt(let cardId, let prompt, let reason):
            await queuedPromptJournal.append(
                QueuedPromptJournalEntry(
                    cardId: cardId,
                    promptId: prompt.id,
                    reason: reason,
                    body: prompt.body,
                    imagePaths: prompt.imagePaths,
                    sendAutomatically: prompt.sendAutomatically
                )
            )

        case .recordHumanMessage(let cardId, let text, let at, let sessionId):
            humanMessageLog.append(cardId: cardId, HumanMessageRecord(at: at, text: text, sessionId: sessionId))

        case .sendPromptToTmux(let sessionName, let promptBody, let assistant, let human):
            do {
                // A prompt to a session on a paused machine brings the
                // machine back first; the prompt itself never wakes it.
                guard await remoteMachines?.resumeMachine(forSession: sessionName) != false else {
                    KanbanCodeLog.warn("effect", "sendPromptToTmux: the machine of \(sessionName) did not come back")
                    return
                }
                if human, let rushId = RushSessionName.rushId(fromName: sessionName),
                   let rush = try (tmuxAdapter as? RoutingTmuxAdapter)?.rush(forSession: sessionName) {
                    // rush keeps its own record of what the human typed.
                    try await rush.send(id: rushId, text: promptBody, human: true)
                    return
                }
                if assistant.submitsPromptWithPaste {
                    try await tmuxAdapter?.pastePrompt(to: sessionName, text: promptBody)
                } else {
                    try await tmuxAdapter?.sendPrompt(to: sessionName, text: promptBody)
                }
            } catch {
                KanbanCodeLog.warn("effect", "sendPromptToTmux failed: \(error)")
            }

        case .sendPromptWithImagesToTmux(let sessionName, let promptBody, let imagePaths, let assistant, let human):
            do {
                guard let tmux = tmuxAdapter else { return }
                guard await remoteMachines?.resumeMachine(forSession: sessionName) != false else {
                    KanbanCodeLog.warn("effect", "sendPromptWithImagesToTmux: the machine of \(sessionName) did not come back")
                    return
                }
                if let rushId = RushSessionName.rushId(fromName: sessionName),
                   let rush = try (tmux as? RoutingTmuxAdapter)?.rush(forSession: sessionName) {
                    // rush takes the images as files and puts each right
                    // after its [Image #N] marker in the text.
                    try await rush.send(id: rushId, text: promptBody, imagePaths: imagePaths, human: human)
                    return
                }
                let images = assistant.supportsImageUpload
                    ? imagePaths.compactMap { ImageAttachment.fromPath($0) }
                    : []
                if !images.isEmpty,
                   let remotePaths = try await remoteMachines?.uploadImages(sessionName: sessionName, imagePaths: imagePaths) {
                    // The clipboard does not reach the machine: the images go
                    // over the bridge and the prompt points at them by path.
                    let body = PromptImageLayout.replacingMarkersWithMarkdown(in: promptBody, imagePaths: remotePaths)
                    if assistant.submitsPromptWithPaste {
                        try await tmux.pastePrompt(to: sessionName, text: body)
                    } else {
                        try await tmux.sendPrompt(to: sessionName, text: body)
                    }
                } else if !images.isEmpty {
                    guard let setClipboard = setClipboardImage else { return }
                    let sender = ImageSender(tmux: tmux)
                    try await sender.waitForReady(sessionName: sessionName, assistant: assistant)
                    try await sender.sendPromptWithImages(
                        sessionName: sessionName,
                        prompt: promptBody,
                        images: images,
                        assistant: assistant,
                        setClipboard: setClipboard
                    )
                } else if assistant.submitsPromptWithPaste {
                    let body = PromptImageLayout.replacingMarkersWithMarkdown(in: promptBody, imagePaths: imagePaths)
                    try await tmux.pastePrompt(to: sessionName, text: body)
                } else {
                    let body = PromptImageLayout.replacingMarkersWithMarkdown(in: promptBody, imagePaths: imagePaths)
                    try await tmux.sendPrompt(to: sessionName, text: body)
                }
                if assistant.supportsImageUpload {
                    for path in imagePaths {
                        try? FileManager.default.removeItem(atPath: path)
                    }
                }
            } catch {
                KanbanCodeLog.warn("effect", "sendPromptWithImagesToTmux failed: \(error)")
            }

        case .deleteFiles(let paths):
            for path in paths {
                try? FileManager.default.removeItem(atPath: path)
            }

        case .deliverAttention(let request):
            await attentionDelivery?.deliver(request)

        case .updateAttention(let request):
            await attentionDelivery?.update(request)

        case .withdrawAttention(let request):
            await attentionDelivery?.withdraw(request)
        }
    }
}

/// Relay to avoid importing Kanban (UI) target from KanbanCodeCore.
/// The actual TerminalCache is in the Kanban target and registers itself on app launch.
@MainActor
public enum TerminalCacheRelay {
    public static var removeHandler: ((String) -> Void)?

    public static func remove(_ sessionName: String) {
        removeHandler?(sessionName)
    }
}

/// Relay for BrowserTabCache cleanup from KanbanCodeCore (same pattern as TerminalCacheRelay).
@MainActor
public enum BrowserTabCacheRelay {
    public static var removeAllHandler: ((String) -> Void)?

    public static func removeAll(cardId: String) {
        removeAllHandler?(cardId)
    }
}
