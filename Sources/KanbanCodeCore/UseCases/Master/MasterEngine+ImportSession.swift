import Foundation

/// What importing a Claude Code session did.
public enum SessionImportOutcome: Sendable, Equatable {
    /// The session resumes in a Kanban Code terminal.
    case resumed
    /// The session still runs in another terminal. It resumes here once
    /// that process exits.
    case waitingForExit(ClaudeLiveSession)
    /// The session already runs in Kanban Code (or on a machine of it).
    case alreadyRunning

    /// The word `kanban import` gets back.
    public var commandStatus: String {
        switch self {
        case .resumed: "resumed"
        case .waitingForExit: "waiting"
        case .alreadyRunning: "running"
        }
    }
}

public struct SessionImport: Sendable, Equatable {
    public let cardId: String
    public let sessionId: String
    public let outcome: SessionImportOutcome
}

public enum SessionImportError: LocalizedError, Equatable {
    case noSessionId(String)
    case transcriptNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .noSessionId(let text):
            text.isEmpty
                ? "Enter a Claude Code session id, like 854054b6-24ff-45e2-bdb9-8feb1f70caf1."
                : "“\(text)” holds no Claude Code session id. It looks like 854054b6-24ff-45e2-bdb9-8feb1f70caf1."
        case .transcriptNotFound(let id):
            "There is no Claude Code session \(id) on this machine."
        }
    }
}

// MARK: - Import a Claude Code session

/// A Claude Code session started in a terminal of its own (`claude` in
/// Ghostty or Terminal) moves onto the board and continues in a Kanban Code
/// terminal. File › Import Claude Code Session and `kanban import` both come
/// here.
extension MasterEngine {
    /// How long a session still open in another terminal is waited for.
    nonisolated static let importExitWaitLimit: TimeInterval = 2 * 3600

    /// The session id in what was pasted: a bare id, a `claude --resume <id>`
    /// line, or the path of a transcript.
    public nonisolated static func claudeSessionId(in text: String) -> String? {
        let pattern = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        return text[range].lowercased()
    }

    /// The transcript of Claude Code session `sessionId`. Claude keeps it in
    /// the folder of the directory it was started in, so every project
    /// folder is looked in.
    public nonisolated static func claudeTranscript(sessionId: String, projectsDirectory: String) -> String? {
        let fileManager = FileManager.default
        guard let folders = try? fileManager.contentsOfDirectory(atPath: projectsDirectory) else { return nil }
        for folder in folders.sorted() {
            let path = "\(projectsDirectory)/\(folder)/\(sessionId).jsonl"
            if fileManager.fileExists(atPath: path) { return path }
        }
        return nil
    }

    /// Puts the card of the Claude Code session named in `input` on the
    /// board, selects it and continues the session in a Kanban Code
    /// terminal. A session still open in another terminal continues here
    /// once it is quit there: two processes on one transcript would both
    /// write it.
    public func importClaudeSession(_ input: String) async throws -> SessionImport {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sessionId = Self.claudeSessionId(in: text) else {
            throw SessionImportError.noSessionId(text)
        }
        let existing = importedCard(sessionId: sessionId)
        var link: Link
        if let existing {
            link = existing
        } else {
            link = try await makeImportedCard(sessionId: sessionId)
        }

        // An archived card, a hidden headless one, or one only listed under
        // All Sessions comes onto the board. The column holds until the
        // resume (or the session's own activity) moves the card on.
        if link.manuallyArchived || link.headless == true || link.column == .allSessions {
            link.manuallyArchived = false
            if link.headless == true { link.headless = false }
            if link.column == .allSessions {
                link.column = .waiting
                link.manualOverrides.column = true
            }
            link.updatedAt = .now
        }
        if existing != link { store.dispatch(.createManualTask(link)) }
        store.dispatch(.selectCard(cardId: link.id))
        if link.name?.isEmpty ?? true, !link.manualOverrides.name,
           let path = link.sessionLink?.sessionPath {
            nameImportedCard(link.id, transcriptPath: path)
        }

        // The last scan of the Claude processes can be two seconds old, and
        // the session may have been quit in the meantime.
        await scanClaudeProcesses()
        let status = store.state.cards.first { $0.id == link.id }?.sessionStatus ?? .ended
        let outcome: SessionImportOutcome
        switch status {
        case .live, .starting, .moving, .machine:
            outcome = .alreadyRunning
        case .elsewhere(let process):
            continueAfterExit(cardId: link.id, process: process)
            outcome = .waitingForExit(process)
            let place = process.tty.map { " (\($0))" } ?? ""
            store.dispatch(.setNotice(
                "“\(link.displayTitle)” continues here once you quit Claude in its terminal\(place).",
                kind: .success))
        case .ended, .failed, .none:
            resumeImportedCard(link.id)
            outcome = .resumed
        }
        KanbanCodeLog.info("import", "Imported session \(sessionId.prefix(8)) into card=\(link.id.prefix(12)) (\(existing == nil ? "new card" : "existing card")): \(outcome)")
        return SessionImport(cardId: link.id, sessionId: sessionId, outcome: outcome)
    }

    /// The card whose own session is `sessionId`. A card that only absorbed
    /// it (a shell tab's session) would resume its own session instead, so
    /// it does not count.
    func importedCard(sessionId: String) -> Link? {
        let candidates = store.state.links.values
            .filter { $0.sessionLink?.sessionId == sessionId }
            .sorted { $0.updatedAt > $1.updatedAt }
        return candidates.first { !$0.manuallyArchived } ?? candidates.first
    }

    /// A card for a session discovery has not turned into one yet.
    private func makeImportedCard(sessionId: String) async throws -> Link {
        let directory = platform.claudeProjectsDirectory
        let found = await Task.detached(priority: .userInitiated) {
            Self.claudeTranscript(sessionId: sessionId, projectsDirectory: directory)
        }.value
        guard let path = found else { throw SessionImportError.transcriptNotFound(sessionId) }
        let metadata = try? await JsonlParser.extractMetadata(from: path)
        let folder = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        return Link(
            projectPath: metadata?.projectPath ?? JsonlParser.decodeDirectoryName(folder),
            column: .waiting,
            lastActivity: modified ?? .now,
            manualOverrides: ManualOverrides(column: true),
            source: .discovered,
            sessionLink: SessionLink(sessionId: sessionId, sessionPath: path)
        )
    }

    /// Names a card that has no name of its own from its conversation
    /// (`ConversationTitle.name`). The title model takes seconds, so the
    /// name lands after the import answered.
    private func nameImportedCard(_ cardId: String, transcriptPath: String) {
        let titler = platform.titleConversation
        Task {
            guard let name = await ConversationTitle.name(transcriptPath: transcriptPath, titler: titler) else {
                return
            }
            // Named by hand in the meantime: that name stays.
            guard let link = store.state.links[cardId], link.name?.isEmpty ?? true,
                  !link.manualOverrides.name else { return }
            KanbanCodeLog.info("import", "Named card=\(cardId.prefix(12)) “\(name)”")
            store.dispatch(.renameCard(cardId: cardId, name: name))
        }
    }

    @discardableResult
    private func resumeImportedCard(_ cardId: String) -> Bool {
        guard let link = store.state.links[cardId] else { return false }
        return resume(
            cardId: cardId,
            runRemotely: link.isRemote,
            skipPermissions: platform.skipPermissions(),
            commandOverride: nil,
            assistant: link.effectiveAssistant,
            serviceIdOverride: link.apiServiceId,
            modelOverride: link.modelOverride,
            modelVariantOverride: link.modelVariantOverride,
            machineChoice: link.remote.map { .existing($0.machineName) }
        )
    }

    /// Resumes the card once the Claude process that holds its session in
    /// another terminal exits, and brings the window up on it. Stops waiting
    /// when the card leaves the board or starts some other way, and after
    /// `importExitWaitLimit`.
    private func continueAfterExit(cardId: String, process: ClaudeLiveSession) {
        let sessionId = process.sessionId
        guard importsWaitingForExit.insert(sessionId).inserted else { return }
        let started = ClaudeLiveSessions.systemProcessInfo(process.pid)?.started
        KanbanCodeLog.info("import", "Session \(sessionId.prefix(8)) runs as pid \(process.pid); card=\(cardId.prefix(12)) resumes once it exits")
        Task {
            defer { importsWaitingForExit.remove(sessionId) }
            let deadline = Date().addingTimeInterval(Self.importExitWaitLimit)
            while Self.processRuns(pid: process.pid, started: started) {
                guard Date() < deadline else {
                    KanbanCodeLog.info("import", "Session \(sessionId.prefix(8)) still runs as pid \(process.pid); stopped waiting for card=\(cardId.prefix(12))")
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, importStillWaits(cardId: cardId, sessionId: sessionId) else { return }
            }
            await scanClaudeProcesses()
            guard importStillWaits(cardId: cardId, sessionId: sessionId) else { return }
            KanbanCodeLog.info("import", "pid \(process.pid) exited; resuming session \(sessionId.prefix(8)) in card=\(cardId.prefix(12))")
            if resumeImportedCard(cardId) { platform.revealCard(cardId) }
        }
    }

    /// Whether the card still waits for its session to be quit elsewhere:
    /// it is on the board, still on that session, and not started here.
    private func importStillWaits(cardId: String, sessionId: String) -> Bool {
        guard let card = store.state.cards.first(where: { $0.id == cardId }),
              !card.link.manuallyArchived,
              card.link.sessionLink?.sessionId == sessionId else { return false }
        switch card.sessionStatus {
        case .elsewhere, .ended, .failed: return true
        case .none, .live, .starting, .moving, .machine: return false
        }
    }

    /// Whether `pid` still runs and is the process that started at
    /// `started` (a pid is reused once its process is gone).
    nonisolated static func processRuns(pid: Int32, started: Date?) -> Bool {
        guard let info = ClaudeLiveSessions.systemProcessInfo(pid) else { return false }
        guard let started, let now = info.started else { return true }
        return abs(now.timeIntervalSince(started)) < 2
    }
}
