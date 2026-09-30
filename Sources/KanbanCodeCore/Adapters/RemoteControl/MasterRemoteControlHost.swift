import Foundation
import KanbanCodeRemoteKit
import Observation

/// The remote control API over a master engine: reads the board from its
/// store and acts through the same actions and launch flow as the Mac UI.
/// The Mac app and `kanban-code-server` both serve it.
public final class MasterRemoteControlHost: RemoteControlHost, @unchecked Sendable {
    private let engine: MasterEngine
    private let store: BoardStore
    /// Esc to a session, as the stop button does (agtop: its interrupt).
    private let sendEscape: @Sendable (String) async throws -> Void
    /// Runs tmux commands on the server that holds the session.
    private let runTmux: @Sendable ([[String]], String) async -> Void
    /// agtop cards queue and send through agtop itself: the agtop of the
    /// machine that hosts the session.
    private let agtopFor: @Sendable (String) throws -> AgtopCliAdapter
    private let queueWatch = QueueWatchFlag()

    @MainActor
    public init(engine: MasterEngine,
                agtop: AgtopCliAdapter? = nil,
                runTmux: (@Sendable ([[String]], String) async -> Void)? = nil,
                sendEscape: (@Sendable (String) async throws -> Void)? = nil) {
        self.engine = engine
        self.store = engine.store
        let tmux = engine.tmux
        if let agtop {
            self.agtopFor = { _ in agtop }
        } else {
            self.agtopFor = { session in try tmux.agtop(forSession: session) }
        }
        self.runTmux = runTmux ?? { commands, session in
            guard let adapter = try? tmux.adapter(for: session) else { return }
            for command in commands {
                _ = try? await adapter.run(command)
            }
        }
        self.sendEscape = sendEscape ?? { session in try await tmux.sendEscape(sessionName: session) }
    }

    public func board() async -> RemoteBoard {
        let board = await MainActor.run {
            RemoteBoardMapper.board(
                cards: store.state.cards,
                projects: store.state.configuredProjects,
                liveSessions: store.state.tmuxSessions,
                agtopQueues: store.state.agtopQueues,
                machine: store.state.localMachineIdentity,
                machineNames: store.state.peerMachineNames
            )
        }
        await watchAgtopQueues()
        return board
    }

    @MainActor
    private func card(_ cardId: String) throws -> KanbanCodeCard {
        guard let card = store.state.cards.first(where: { $0.id == cardId }) else {
            throw RemoteHostError.notFound("no card \(cardId)")
        }
        return card
    }

    @MainActor
    private func remoteCard(_ cardId: String) throws -> RemoteCard {
        RemoteBoardMapper.card(try card(cardId), liveSessions: store.state.tmuxSessions, agtopQueues: store.state.agtopQueues,
                               machine: store.state.localMachineIdentity, machineNames: store.state.peerMachineNames)
    }

    public func transcript(cardId: String, limit: Int, before: String?) async throws -> RemoteTranscript {
        if let owner = await ownerClient(cardId) {
            return try await forwarded { try await owner.transcript(cardId: cardId, limit: limit, before: before) }
        }
        let (path, assistant) = try await MainActor.run { () throws -> (String?, CodingAssistant) in
            let card = try card(cardId)
            return (card.link.sessionLink?.sessionPath ?? card.session?.jsonlPath, card.link.effectiveAssistant)
        }
        guard let path,
              OpenCodeDatabase.isVirtualSessionPath(path) || FileManager.default.fileExists(atPath: path) else {
            return RemoteTranscript(cardId: cardId, messages: [])
        }
        return try await RemoteTranscriptMapper.page(cardId: cardId, limit: limit, before: before) { maxTurns in
            switch assistant {
            case .claude:
                let r = try await TranscriptReader.readTail(from: path, maxTurns: maxTurns)
                return (r.turns, r.hasMore)
            case .codex:
                let r = try await CodexSessionParser.readTail(from: path, maxTurns: maxTurns)
                return (r.turns, r.hasMore)
            case .opencode:
                let all = try await OpenCodeSessionStore().readTranscript(sessionPath: path)
                return (Array(all.suffix(maxTurns)), all.count > maxTurns)
            default:
                let all = try await GeminiSessionStore().readTranscript(sessionPath: path)
                return (Array(all.suffix(maxTurns)), all.count > maxTurns)
            }
        }
    }

    public func createTask(_ request: RemoteTaskRequest) async throws -> RemoteCard {
        var projectPath = await MainActor.run {
            RemoteBoardMapper.resolveProject(request.project, in: store.state.configuredProjects)?.path
        }
        if projectPath == nil, Self.isRepositoryURL(request.project) {
            // A peer launching here names the repository by its origin.
            do {
                projectPath = try await engine.localRepository(repoUrl: request.project, fallback: nil)
            } catch let error as MasterPeerError {
                throw Self.hostError(error)
            }
        }
        let cardId = try await MainActor.run { () throws -> String in
            guard let projectPath else {
                let names = store.state.configuredProjects.map(\.name).sorted().joined(separator: ", ")
                throw RemoteHostError.badRequest("unknown project \(request.project); known: \(names)")
            }
            let assistant: CodingAssistant
            if let raw = request.assistant {
                guard let parsed = CodingAssistant(rawValue: raw.lowercased()) else {
                    throw RemoteHostError.badRequest("unknown assistant \(raw); use claude, codex or gemini")
                }
                assistant = parsed
            } else {
                assistant = engine.platform.defaultAssistant()
            }
            let title = request.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let imagePaths = try RemotePromptImages.write(
                RemotePromptImages.decode(request.images), to: RemotePromptImages.taskDirectory, prefix: "remote")
            return engine.createRemoteTask(RemoteLaunchRequest(
                projectPath: projectPath,
                prompt: request.prompt,
                title: title?.isEmpty == false ? title : nil,
                worktree: request.worktree,
                assistant: assistant,
                model: request.model,
                launch: request.launch ?? true,
                imagePaths: imagePaths,
                machine: request.machine?.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        }
        for _ in 0..<30 {
            if let card = try? await MainActor.run(body: { try remoteCard(cardId) }) { return card }
            try? await Task.sleep(for: .milliseconds(100))
        }
        throw RemoteHostError.notFound("card \(cardId) was created but is not on the board yet")
    }

    /// The card's live session and whether a turn runs in it.
    @MainActor
    private func liveSession(_ cardId: String) throws -> (session: String, busy: Bool) {
        let card = try card(cardId)
        guard let session = RemoteBoardMapper.liveAssistantSession(card.link, liveSessions: store.state.tmuxSessions) else {
            throw RemoteHostError.conflict("card \(cardId) has no live session; resume it first")
        }
        return (session, card.activityState == .activelyWorking)
    }

    /// Stops the running turn so a prompt can go out now.
    private func interruptForPrompt(session: String) async throws {
        try await sendEscape(session)
        // The composer takes input again once the turn has stopped.
        try? await Task.sleep(for: .milliseconds(600))
    }

    public func sendPrompt(cardId: String, _ request: RemotePromptRequest, images: [RemotePromptImages.Decoded]) async throws {
        if let owner = await ownerClient(cardId) {
            let encoded = images.map { RemoteImage(mediaType: Self.mediaType(ofExtension: $0.fileExtension), data: $0.bytes.base64EncodedString()) }
            return try await forwarded { try await owner.sendPrompt(cardId: cardId, text: request.text, mode: request.mode ?? .queue, images: encoded) }
        }
        let (session, busy) = try await MainActor.run { try liveSession(cardId) }
        let imagePaths = try RemotePromptImages.write(images, to: RemotePromptImages.promptDirectory)
        let mode = request.mode ?? .queue
        if let agtopId = AgtopSessionName.agtopId(fromName: session) {
            // agtop queues a message sent mid-turn itself, and `now` hands it
            // to Claude mid-turn; the card's own queue is not used. agtop
            // puts each image right after its [Image #N] marker.
            try await agtopFor(session).send(id: agtopId, text: request.text, imagePaths: imagePaths, now: mode == .now)
            await readAgtopQueue(session: session, agtopId: agtopId)
            return
        }
        if mode == .now && busy {
            try await interruptForPrompt(session: session)
        }
        await MainActor.run {
            let prompt = QueuedPrompt(body: request.text, sendAutomatically: true,
                                      imagePaths: imagePaths.isEmpty ? nil : imagePaths)
            store.dispatch(.addQueuedPrompt(cardId: cardId, prompt: prompt, placement: .back))
            // A queued prompt on a busy card goes out when the turn ends; the
            // rest goes out now, as the chat's send button does.
            if mode == .now || !busy {
                store.dispatch(.sendQueuedPrompt(cardId: cardId, promptId: prompt.id))
            }
        }
    }

    public func sendQueuedPromptNow(cardId: String, promptId: String) async throws {
        if let owner = await ownerClient(cardId) {
            return try await forwarded { try await owner.sendQueuedPromptNow(cardId: cardId, promptId: promptId) }
        }
        if promptId.hasPrefix("agtop-") {
            try await agtopQueueAction(cardId: cardId, promptId: promptId, send: true)
            return
        }
        let (session, busy) = try await MainActor.run { () throws -> (String, Bool) in
            try queuedPrompt(cardId, promptId)
            return try liveSession(cardId)
        }
        if busy { try await interruptForPrompt(session: session) }
        await MainActor.run {
            // Once the turn stops the queue may send it on its own.
            guard (try? queuedPrompt(cardId, promptId)) != nil else { return }
            store.dispatch(.sendQueuedPrompt(cardId: cardId, promptId: promptId))
        }
    }

    public func removeQueuedPrompt(cardId: String, promptId: String) async throws {
        if let owner = await ownerClient(cardId) {
            return try await forwarded { try await owner.removeQueuedPrompt(cardId: cardId, promptId: promptId) }
        }
        if promptId.hasPrefix("agtop-") {
            try await agtopQueueAction(cardId: cardId, promptId: promptId, send: false)
            return
        }
        try await MainActor.run {
            try queuedPrompt(cardId, promptId)
            store.dispatch(.removeQueuedPrompt(cardId: cardId, promptId: promptId))
        }
    }

    public func editQueuedPrompt(cardId: String, promptId: String, text: String) async throws {
        if let owner = await ownerClient(cardId) {
            return try await forwarded { try await owner.editQueuedPrompt(cardId: cardId, promptId: promptId, text: text) }
        }
        if promptId.hasPrefix("agtop-") {
            // agtop has no edit: the old message leaves the queue and the new
            // text joins it (a busy host queues what it is sent).
            try await agtopQueueAction(cardId: cardId, promptId: promptId, send: false)
            let session = try await MainActor.run { try liveSession(cardId).session }
            guard let agtopId = AgtopSessionName.agtopId(fromName: session) else { return }
            try await agtopFor(session).send(id: agtopId, text: text)
            await readAgtopQueue(session: session, agtopId: agtopId)
            return
        }
        try await MainActor.run {
            let prompt = try queuedPrompt(cardId, promptId)
            store.dispatch(.updateQueuedPrompt(cardId: cardId, promptId: promptId, body: text,
                                               sendAutomatically: prompt.sendAutomatically))
        }
    }

    // MARK: Channels home

    public func runCLI(_ request: RemoteCLIRequest) async throws -> RemoteCLIResult {
        await engine.runCLI(request)
    }

    public func channelFiles() async throws -> [RemoteChannelFile] {
        let home = await MainActor.run { engine.platform.kanbanHome }
        return MasterEngine.listChannelFiles(home: home)
    }

    public func channelFile(path: String, offset: Int) async throws -> Data {
        let home = await MainActor.run { engine.platform.kanbanHome }
        return try MasterEngine.readChannelFile(home: home, relative: path, offset: offset)
    }

    public func seedChannelFile(path: String, data: Data) async throws -> Bool {
        let home = await MainActor.run { engine.platform.kanbanHome }
        let created = try MasterEngine.seedChannelFile(home: home, relative: path, data: data)
        if created { await MainActor.run { store.dispatch(.refreshChannels) } }
        return created
    }

    @MainActor
    @discardableResult
    private func queuedPrompt(_ cardId: String, _ promptId: String) throws -> QueuedPrompt {
        guard let prompt = try card(cardId).link.queuedPrompts?.first(where: { $0.id == promptId }) else {
            throw RemoteHostError.notFound("card \(cardId) has no queued prompt \(promptId); it may have been sent already")
        }
        return prompt
    }

    // MARK: agtop queue

    /// Sends now, or drops, a message queued in the card's agtop host.
    private func agtopQueueAction(cardId: String, promptId: String, send: Bool) async throws {
        let (session, queue) = try await MainActor.run { () throws -> (String, [String]) in
            let (session, _) = try liveSession(cardId)
            return (session, store.state.agtopQueues[session] ?? [])
        }
        guard let agtopId = AgtopSessionName.agtopId(fromName: session) else {
            throw RemoteHostError.notFound("card \(cardId) has no queued prompt \(promptId)")
        }
        // The queue as the phone saw it may be older than agtop's.
        var current = queue
        if RemoteBoardMapper.agtopQueueIndex(of: promptId, in: current) == nil,
           let info = try? await agtopFor(session).info(id: agtopId) {
            current = info.queue
        }
        guard let index = RemoteBoardMapper.agtopQueueIndex(of: promptId, in: current) else {
            await readAgtopQueue(session: session, agtopId: agtopId)
            throw RemoteHostError.notFound("card \(cardId) has no queued prompt \(promptId); it may have been sent already")
        }
        do {
            if send {
                try await agtopFor(session).sendQueued(id: agtopId, index: index, was: current[index])
            } else {
                try await agtopFor(session).removeQueued(id: agtopId, index: index, was: current[index])
            }
        } catch let error as AgtopCommandFailed where error.message.contains("already been sent") {
            await readAgtopQueue(session: session, agtopId: agtopId)
            throw RemoteHostError.notFound("card \(cardId) has no queued prompt \(promptId); it was sent already")
        }
        await readAgtopQueue(session: session, agtopId: agtopId)
    }

    /// Reads one agtop host's queue into the store, then keeps watching
    /// while any host has something queued.
    private func readAgtopQueue(session: String, agtopId: String) async {
        guard let info = try? await agtopFor(session).info(id: agtopId) else { return }
        await MainActor.run { store.dispatch(.agtopQueueRead(sessionName: session, queue: info.queue)) }
        await watchAgtopQueues()
    }

    /// While an agtop host has messages queued, reads its queue every two
    /// seconds, so they leave the phone when agtop sends them. The session
    /// scan also reads them, but only as often as the board reconciles.
    private func watchAgtopQueues() async {
        let queued = await MainActor.run { !store.state.agtopQueues.isEmpty }
        guard queued, queueWatch.claim() else { return }
        Task { [weak self] in
            defer { self?.queueWatch.release() }
            while let self, !Task.isCancelled {
                let sessions = await MainActor.run { Array(self.store.state.agtopQueues.keys) }
                if sessions.isEmpty { return }
                try? await Task.sleep(for: .seconds(2))
                for session in sessions {
                    guard let id = AgtopSessionName.agtopId(fromName: session) else { continue }
                    let queue = (try? await self.agtopFor(session).info(id: id))?.queue ?? []
                    await MainActor.run { self.store.dispatch(.agtopQueueRead(sessionName: session, queue: queue)) }
                }
            }
        }
    }

    public func scrollTerminal(sessionName: String, lines: Int) async {
        guard !AgtopSessionName.isAgtop(sessionName) else { return }
        await runTmux(RemoteTerminalScroll.tmuxCommands(session: sessionName, lines: lines), sessionName)
    }

    public func interrupt(cardId: String) async throws {
        if let owner = await ownerClient(cardId) {
            return try await forwarded { try await owner.interrupt(cardId: cardId) }
        }
        let session = try await MainActor.run { () throws -> String in
            let card = try card(cardId)
            guard let session = RemoteBoardMapper.liveAssistantSession(card.link, liveSessions: store.state.tmuxSessions) else {
                throw RemoteHostError.conflict("card \(cardId) has no live session")
            }
            return session
        }
        try await sendEscape(session)
    }

    public func resume(cardId: String) async throws -> RemoteCard {
        if let owner = await ownerClient(cardId) {
            return try await forwarded { try await owner.resume(cardId: cardId) }
        }
        let current = try await MainActor.run { try remoteCard(cardId) }
        if current.isLive { return current }
        await MainActor.run { engine.resumeRemoteCard(cardId) }
        try? await Task.sleep(for: .milliseconds(200))
        return try await MainActor.run { try remoteCard(cardId) }
    }

    public func terminalCommand(cardId: String, sessionName: String) async throws -> [String] {
        try await MainActor.run { () throws -> [String] in
            let card = try card(cardId)
            if let owner = card.link.ownerMachine, owner != store.state.localMachineId, !store.state.localMachineId.isEmpty {
                if let command = engine.platform.peerTerminalCommand(owner, cardId, sessionName) { return command }
                throw RemoteHostError.conflict("card \(cardId) runs on \(engine.peerName(owner)); open its terminal there")
            }
            let names = card.link.tmuxLink?.allSessionNames ?? []
            guard names.contains(sessionName) else {
                throw RemoteHostError.notFound("card \(cardId) has no terminal \(sessionName)")
            }
            guard store.state.tmuxSessions.contains(sessionName) || engine.platform.machineForSession(sessionName) != nil else {
                throw RemoteHostError.conflict("terminal \(sessionName) is not running; resume the card first")
            }
            return engine.platform.terminalCommand(sessionName) ?? Self.localCommand(forSession: sessionName)
        }
    }

    // MARK: Moves and handovers

    public func rawTranscript(cardId: String, offset: Int, limit: Int) async throws -> RemoteRawTranscript {
        try await MainActor.run {
            do {
                return try engine.rawTranscript(cardId: cardId, offset: offset, limit: limit)
            } catch let error as MasterPeerError {
                throw Self.hostError(error)
            }
        }
    }

    public func handoverInfo(cardId: String) async throws -> RemoteHandoverInfo {
        do {
            return try await engine.handoverInfo(cardId: cardId)
        } catch let error as MasterPeerError {
            throw Self.hostError(error)
        }
    }

    public func updateCard(cardId: String, _ update: RemoteCardUpdate) async throws -> RemoteCard {
        try await MainActor.run { () throws -> RemoteCard in
            _ = try card(cardId)
            if let name = update.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                store.dispatch(.renameCard(cardId: cardId, name: name))
            }
            if let column = update.column, let target = KanbanCodeColumn(rawValue: column.rawValue) {
                store.dispatch(.moveCard(cardId: cardId, to: target))
            }
            if update.archived == true {
                store.dispatch(.archiveCard(cardId: cardId))
            }
            return try remoteCard(cardId)
        }
    }

    public func moveCard(cardId: String, to target: String) async throws -> RemoteCard {
        do {
            try await engine.moveCard(cardId, to: target)
        } catch let error as MasterPeerError {
            throw Self.hostError(error)
        } catch let error as RemoteClientError {
            throw Self.hostError(error)
        }
        try? await Task.sleep(for: .milliseconds(200))
        return try await MainActor.run { try remoteCard(cardId) }
    }

    // MARK: Cards another master owns

    /// The owner's client when another master owns the card: calls about
    /// the card go there.
    private func ownerClient(_ cardId: String) async -> RemoteClient? {
        await engine.ownerClient(forCard: cardId)
    }

    /// Runs a call on the owner, turning its answer into this server's.
    private func forwarded<T>(_ call: () async throws -> T) async throws -> T {
        do {
            return try await call()
        } catch let error as RemoteClientError {
            throw Self.hostError(error)
        }
    }

    static func hostError(_ error: RemoteClientError) -> RemoteHostError {
        switch error {
        case .notFound(let m): .notFound(m)
        case .conflict(let m): .conflict(m)
        default: .conflict("the owning master answered: \(error.localizedDescription)")
        }
    }

    static func hostError(_ error: MasterPeerError) -> RemoteHostError {
        switch error {
        case .unknownCard, .unknownPeer: .notFound(error.localizedDescription)
        case .noProject: .badRequest(error.localizedDescription)
        default: .conflict(error.localizedDescription)
        }
    }

    /// `git@host:owner/repo(.git)` or `https://host/owner/repo(.git)`.
    static func isRepositoryURL(_ value: String) -> Bool {
        let v = value.trimmingCharacters(in: .whitespaces)
        return v.hasPrefix("git@") || v.hasPrefix("ssh://") || ((v.hasPrefix("https://") || v.hasPrefix("http://")) && v.contains("/"))
    }

    static func mediaType(ofExtension ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        default: "image/png"
        }
    }

    /// The command a viewer runs for a session of this master: agtop's own
    /// UI for agtop, a tmux attach otherwise.
    public static func localCommand(forSession sessionName: String) -> [String] {
        if let agtopId = AgtopSessionName.agtopId(fromName: sessionName) {
            return [AgtopCliAdapter.findExecutable() ?? "agtop", "open", agtopId, "--solo"]
        }
        return [ShellCommand.findExecutable("tmux") ?? "tmux", "attach-session", "-t", sessionName]
    }

    public func boardChanges() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let store = self.store
        let alive = BoardChangeFlag()
        continuation.onTermination = { _ in alive.stop() }
        Task { @MainActor in
            Self.observe(store: store, continuation: continuation, alive: alive)
        }
        return stream
    }

    /// Yields once per change of the cards, the live sessions or the
    /// projects, re-arming the observation each time.
    @MainActor
    private static func observe(store: BoardStore, continuation: AsyncStream<Void>.Continuation, alive: BoardChangeFlag) {
        guard alive.isAlive else { return }
        withObservationTracking {
            _ = store.state.cards
            _ = store.state.tmuxSessions
            _ = store.state.agtopQueues
            _ = store.state.configuredProjects
            _ = store.state.peerStatuses
        } onChange: {
            continuation.yield()
            Task { @MainActor in observe(store: store, continuation: continuation, alive: alive) }
        }
    }
}

private final class BoardChangeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var alive = true

    var isAlive: Bool { lock.withLock { alive } }
    func stop() { lock.withLock { alive = false } }
}

/// One agtop queue watcher at a time.
private final class QueueWatchFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false

    /// True when the caller should start the watcher.
    func claim() -> Bool {
        lock.withLock {
            if running { return false }
            running = true
            return true
        }
    }

    func release() { lock.withLock { running = false } }
}
