import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Settings

/// When the app stops card sessions to give memory back
/// (Settings > Resources). Every limit can be switched off with nil.
public struct SessionResourceSettings: Codable, Sendable, Equatable {
    /// A card in Done that has been quiet this long loses its session.
    public var hibernateDoneAfterMinutes: Int?
    /// A card in Waiting or In Review that has been quiet this long loses
    /// its session.
    public var hibernateIdleAfterHours: Int?
    /// At most this many cards keep a running session; the quietest go first.
    public var maxLiveSessions: Int?
    /// A card whose processes take more than this is flagged on the board.
    public var memoryWarningMB: Int
    /// A Playwright browser of a card quiet this long is closed. The MCP
    /// server stays and opens a new one on its next browser call.
    public var closeIdleBrowserAfterMinutes: Int?
    /// Under critical memory pressure the biggest quiet cards lose their
    /// sessions; under a warning their browsers close.
    public var relieveMemoryPressure: Bool

    public init(
        hibernateDoneAfterMinutes: Int? = 60,
        hibernateIdleAfterHours: Int? = 24,
        maxLiveSessions: Int? = nil,
        memoryWarningMB: Int = 2048,
        closeIdleBrowserAfterMinutes: Int? = 30,
        relieveMemoryPressure: Bool = true
    ) {
        self.hibernateDoneAfterMinutes = hibernateDoneAfterMinutes
        self.hibernateIdleAfterHours = hibernateIdleAfterHours
        self.maxLiveSessions = maxLiveSessions
        self.memoryWarningMB = memoryWarningMB
        self.closeIdleBrowserAfterMinutes = closeIdleBrowserAfterMinutes
        self.relieveMemoryPressure = relieveMemoryPressure
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SessionResourceSettings()
        // An absent key keeps the default; an explicit null switches it off.
        func optional(_ key: CodingKeys, _ fallback: Int?) -> Int? {
            guard c.contains(key) else { return fallback }
            return (try? c.decodeNil(forKey: key)) == true ? nil : (try? c.decode(Int.self, forKey: key)) ?? fallback
        }
        hibernateDoneAfterMinutes = optional(.hibernateDoneAfterMinutes, defaults.hibernateDoneAfterMinutes)
        hibernateIdleAfterHours = optional(.hibernateIdleAfterHours, defaults.hibernateIdleAfterHours)
        maxLiveSessions = optional(.maxLiveSessions, defaults.maxLiveSessions)
        memoryWarningMB = (try? c.decodeIfPresent(Int.self, forKey: .memoryWarningMB)) ?? defaults.memoryWarningMB
        closeIdleBrowserAfterMinutes = optional(.closeIdleBrowserAfterMinutes, defaults.closeIdleBrowserAfterMinutes)
        relieveMemoryPressure = (try? c.decodeIfPresent(Bool.self, forKey: .relieveMemoryPressure)) ?? defaults.relieveMemoryPressure
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(hibernateDoneAfterMinutes, forKey: .hibernateDoneAfterMinutes)
        try c.encode(hibernateIdleAfterHours, forKey: .hibernateIdleAfterHours)
        try c.encode(maxLiveSessions, forKey: .maxLiveSessions)
        try c.encode(memoryWarningMB, forKey: .memoryWarningMB)
        try c.encode(closeIdleBrowserAfterMinutes, forKey: .closeIdleBrowserAfterMinutes)
        try c.encode(relieveMemoryPressure, forKey: .relieveMemoryPressure)
    }

    private enum CodingKeys: String, CodingKey {
        case hibernateDoneAfterMinutes, hibernateIdleAfterHours, maxLiveSessions
        case memoryWarningMB, closeIdleBrowserAfterMinutes, relieveMemoryPressure
    }

    public var memoryWarningBytes: Int { memoryWarningMB * 1024 * 1024 }
}

// MARK: - Measuring

/// Adds up the processes under each tmux pane. Everything a card starts
/// (the assistant, its MCP servers, the browsers those open, dev servers)
/// runs below one of its panes.
public enum SessionProcessTree {
    public struct Process: Sendable, Equatable {
        public let pid: Int32
        public let ppid: Int32
        public let bytes: Int
        public let command: String

        public init(pid: Int32, ppid: Int32, bytes: Int, command: String) {
            self.pid = pid
            self.ppid = ppid
            self.bytes = bytes
            self.command = command
        }
    }

    /// Memory per tmux session name. `paneRoots` is (session, pane pid).
    public static func measure(processes: [Process], paneRoots: [(session: String, pid: Int32)]) -> [String: CardMemory] {
        guard !processes.isEmpty, !paneRoots.isEmpty else { return [:] }
        var children: [Int32: [Int32]] = [:]
        for p in processes { children[p.ppid, default: []].append(p.pid) }
        let byPid = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })

        var result: [String: CardMemory] = [:]
        for (session, root) in paneRoots {
            var memory = result[session] ?? CardMemory(totalBytes: 0)
            // (pid, inside a Playwright server, inside a browser)
            var stack: [(Int32, Bool, Bool)] = [(root, false, false)]
            var visited = Set<Int32>()
            while let (pid, underPlaywright, underBrowser) = stack.popLast() {
                guard visited.insert(pid).inserted, let p = byPid[pid] else { continue }
                memory.totalBytes += p.bytes
                if p.bytes > memory.topBytes {
                    memory.topBytes = p.bytes
                    memory.topCommand = shortCommand(p.command)
                }
                let browser = isBrowser(p.command)
                if browser && underPlaywright {
                    memory.browserBytes += p.bytes
                    if !underBrowser { memory.browserPids.append(pid) }
                }
                let playwright = underPlaywright || isPlaywrightServer(p.command)
                for child in children[pid] ?? [] {
                    stack.append((child, playwright, underBrowser || browser))
                }
            }
            result[session] = memory
        }
        return result
    }

    static func isBrowser(_ command: String) -> Bool {
        command.contains("Google Chrome") || command.contains("Chromium")
            || command.contains("chrome-headless-shell") || command.contains("Microsoft Edge")
            || command.contains("/ms-playwright/")
    }

    /// Only browsers of `@playwright/mcp` are closed: it opens a new one on
    /// its next call. Other MCP servers may not.
    static func isPlaywrightServer(_ command: String) -> Bool {
        command.contains("playwright") && !isBrowser(command)
    }

    static func shortCommand(_ command: String) -> String {
        guard let first = command.split(separator: " ").first else { return command }
        let name = (String(first) as NSString).lastPathComponent
        return String((name + command.dropFirst(first.count)).prefix(80))
    }

    /// Every process, with its physical footprint where the system gives it
    /// (it counts swapped and compressed pages, which RSS does not), else RSS.
    public static func processTable() async -> [Process] {
        guard let result = try? await ShellCommand.run("/bin/ps", arguments: ["-axo", "pid=,ppid=,rss=,command="], timeout: 20),
              result.succeeded else { return [] }
        return result.stdout.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let pid = Int32(parts[0]), let ppid = Int32(parts[1]), let rssKB = Int(parts[2]) else { return nil }
            return Process(pid: pid, ppid: ppid, bytes: footprint(pid: pid) ?? rssKB * 1024, command: String(parts[3]))
        }
    }

    static func footprint(pid: Int32) -> Int? {
        #if canImport(Darwin)
        var info = rusage_info_v2()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        guard status == 0 else { return nil }
        return Int(info.ri_phys_footprint)
        #else
        return nil
        #endif
    }

    /// Asks each browser to quit; its helper processes go with it.
    public static func terminate(_ pids: [Int32]) {
        for pid in pids where pid > 1 {
            kill(pid, SIGTERM)
        }
    }
}

// MARK: - Policy

/// Decides which cards lose their session or their browser. Pure: the
/// monitor measures, this picks, the reducer acts.
public enum HibernationPolicy {
    public enum Decision: Sendable, Equatable {
        case hibernate(cardId: String, reason: HibernationReason)
        case closeBrowser(cardId: String, pids: [Int32])
    }

    public enum Pressure: Sendable, Equatable {
        case none, warning, critical
    }

    /// A card with a running assistant session on this machine.
    public struct LiveCard: Sendable, Equatable {
        public var cardId: String
        public var column: KanbanCodeColumn
        public var lastActive: Date
        /// Something rules the card out of hibernation (it works, it is
        /// open, its subagents run); its browser may still close.
        public var canHibernate: Bool
        public var isWorking: Bool
        public var memory: CardMemory?

        public init(cardId: String, column: KanbanCodeColumn, lastActive: Date, canHibernate: Bool,
                    isWorking: Bool, memory: CardMemory?) {
            self.cardId = cardId
            self.column = column
            self.lastActive = lastActive
            self.canHibernate = canHibernate
            self.isWorking = isWorking
            self.memory = memory
        }
    }

    /// Cards quiet for less than this are never hibernated for pressure.
    public static let pressureQuietMinimum: TimeInterval = 15 * 60
    /// Browsers quiet for less than this are not closed for a warning.
    public static let pressureBrowserQuietMinimum: TimeInterval = 5 * 60
    /// Sessions hibernated per critical pressure event.
    public static let pressureHibernateCount = 3

    public static func decide(cards: [LiveCard], settings: SessionResourceSettings,
                              pressure: Pressure = .none, now: Date = .now) -> [Decision] {
        var hibernated: [String: HibernationReason] = [:]
        func quiet(_ card: LiveCard) -> TimeInterval { now.timeIntervalSince(card.lastActive) }
        let candidates = cards.filter { $0.canHibernate && !$0.isWorking }

        for card in candidates {
            if card.column == .done, let minutes = settings.hibernateDoneAfterMinutes,
               quiet(card) >= TimeInterval(minutes * 60) {
                hibernated[card.cardId] = .done
            } else if card.column == .waiting || card.column == .inReview,
                      let hours = settings.hibernateIdleAfterHours,
                      quiet(card) >= TimeInterval(hours * 3600) {
                hibernated[card.cardId] = .idle
            }
        }

        if let limit = settings.maxLiveSessions, limit > 0 {
            var live = cards.count - hibernated.count
            for card in candidates.sorted(by: { $0.lastActive < $1.lastActive }) where live > limit {
                guard hibernated[card.cardId] == nil else { continue }
                hibernated[card.cardId] = .sessionLimit
                live -= 1
            }
        }

        if pressure == .critical, settings.relieveMemoryPressure {
            let biggest = candidates
                .filter { hibernated[$0.cardId] == nil && quiet($0) >= pressureQuietMinimum }
                .sorted { ($0.memory?.totalBytes ?? 0) > ($1.memory?.totalBytes ?? 0) }
                .prefix(pressureHibernateCount)
            for card in biggest { hibernated[card.cardId] = .memoryPressure }
        }

        var decisions: [Decision] = cards.compactMap { card in
            hibernated[card.cardId].map { .hibernate(cardId: card.cardId, reason: $0) }
        }

        for card in cards where hibernated[card.cardId] == nil && !card.isWorking {
            guard let pids = card.memory?.browserPids, !pids.isEmpty else { continue }
            var limit = settings.closeIdleBrowserAfterMinutes.map { TimeInterval($0 * 60) }
            if pressure != .none, settings.relieveMemoryPressure {
                limit = min(limit ?? .infinity, pressureBrowserQuietMinimum)
            }
            if let limit, quiet(card) >= limit {
                decisions.append(.closeBrowser(cardId: card.cardId, pids: pids))
            }
        }
        return decisions
    }
}

// MARK: - Reading the board

extension AppState {
    /// Memory per card: the sum over all of its tmux sessions.
    public func cardMemory(memoryBySession: [String: CardMemory]) -> [String: CardMemory] {
        var result: [String: CardMemory] = [:]
        for link in links.values {
            guard let tmux = link.tmuxLink else { continue }
            var sum: CardMemory?
            for name in tmux.allSessionNames {
                guard let m = memoryBySession[name] else { continue }
                var total = sum ?? CardMemory(totalBytes: 0)
                total.totalBytes += m.totalBytes
                total.browserBytes += m.browserBytes
                total.browserPids += m.browserPids
                if m.topBytes > total.topBytes {
                    total.topBytes = m.topBytes
                    total.topCommand = m.topCommand
                }
                sum = total
            }
            if let sum { result[link.id] = sum }
        }
        return result
    }

    /// Every local card whose assistant session runs in a tmux pane that
    /// was measured, with what keeps it from hibernating.
    public func hibernationCandidates(memoryBySession: [String: CardMemory]) -> [HibernationPolicy.LiveCard] {
        let memoryByCard = cardMemory(memoryBySession: memoryBySession)
        // Parents wait on children that report back into their terminal.
        var parentsOfLiveChildren = Set<String>()
        for link in links.values {
            guard let parent = link.parentCardId, let tmux = link.tmuxLink,
                  tmux.isShellOnly != true, tmux.isPrimaryDead != true,
                  tmuxSessions.contains(tmux.sessionName) else { continue }
            parentsOfLiveChildren.insert(parent)
        }

        return links.values.compactMap { link -> HibernationPolicy.LiveCard? in
            guard !link.isTombstone, !link.manuallyArchived, isOwnedLocally(link),
                  link.remote == nil, !link.isRemote,
                  let tmux = link.tmuxLink, tmux.isShellOnly != true, tmux.isPrimaryDead != true,
                  tmuxSessions.contains(tmux.sessionName),
                  // Only a session seen in a local tmux pane: rush and remote
                  // sessions are not ours to stop this way.
                  memoryBySession[tmux.sessionName] != nil
            else { return nil }
            let activity = link.sessionLink.flatMap { activityMap[$0.sessionId] }
            let lastActive = [link.lastActivity, link.lastOpenedAt, link.launchedAt]
                .compactMap { $0 }.max() ?? link.updatedAt
            let canHibernate = link.sessionLink != nil
                && link.isLaunching != true
                && selectedCardId != link.id
                && !(link.queuedPrompts?.contains { $0.sendAutomatically } ?? false)
                && !parentsOfLiveChildren.contains(link.id)
            return HibernationPolicy.LiveCard(
                cardId: link.id,
                column: link.column,
                lastActive: lastActive,
                canHibernate: canHibernate,
                isWorking: activity == .activelyWorking || activity == .awaitingPermission,
                memory: memoryByCard[link.id]
            )
        }
    }
}
