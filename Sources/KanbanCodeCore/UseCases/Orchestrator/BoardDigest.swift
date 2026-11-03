import Foundation
import KanbanCodeRemoteKit

/// Where a card stands, from the point of view of the human who runs the
/// board: does it need them, is it moving, or is it parked.
public enum CardStanding: String, Sendable, Equatable, CaseIterable {
    /// The agent waits on the human: a question, a plan, a permission.
    case needsYou = "needs_you"
    /// The session failed to start, move or run.
    case failed
    /// The agent is in a turn right now.
    case working
    /// The agent finished its turn; nobody asked it for more yet.
    case idle
    /// A pull request is open and waits on review or CI.
    case inReview = "in_review"
    /// Planned, not started.
    case notStarted = "not_started"
    case done

    /// Display order: what wants the human first.
    public var rank: Int {
        switch self {
        case .needsYou: 0
        case .failed: 1
        case .working: 2
        case .idle: 3
        case .inReview: 4
        case .notStarted: 5
        case .done: 6
        }
    }

    public var label: String {
        switch self {
        case .needsYou: "Needs you"
        case .failed: "Failed"
        case .working: "Working"
        case .idle: "Idle"
        case .inReview: "In review"
        case .notStarted: "Not started"
        case .done: "Done"
        }
    }
}

/// One card, reduced to what an overview of the whole board needs.
public struct BoardDigestRow: Sendable, Equatable, Identifiable {
    public var id: String { cardId }
    public var cardId: String
    public var title: String
    public var project: String?
    public var column: KanbanCodeColumn
    public var standing: CardStanding
    /// Why the card stands where it does, e.g. the question it asks.
    public var reason: String?
    /// The start of the agent's last message.
    public var lastMessage: String?
    public var lastActivity: Date?
    public var queuedPrompts: Int
    /// e.g. "#42 failing", one per pull request.
    public var pullRequests: [String]
    public var parentTitle: String?
    public var isLive: Bool

    public init(cardId: String, title: String, project: String? = nil, column: KanbanCodeColumn,
                standing: CardStanding, reason: String? = nil, lastMessage: String? = nil,
                lastActivity: Date? = nil, queuedPrompts: Int = 0, pullRequests: [String] = [],
                parentTitle: String? = nil, isLive: Bool = false) {
        self.cardId = cardId
        self.title = title
        self.project = project
        self.column = column
        self.standing = standing
        self.reason = reason
        self.lastMessage = lastMessage
        self.lastActivity = lastActivity
        self.queuedPrompts = queuedPrompts
        self.pullRequests = pullRequests
        self.parentTitle = parentTitle
        self.isLive = isLive
    }
}

/// A one-screen view of every card on the board: where it stands and why.
/// Built from state the app already holds, so it costs no model call; the
/// orchestrator panel shows it and hands it to the model as context.
public enum BoardDigest {
    /// How much of the agent's last message a row keeps.
    public static let messageLimit = 240

    /// Whether a card belongs in the overview: on the board, not archived,
    /// not a bare discovered session.
    public static func includes(_ card: KanbanCodeCard) -> Bool {
        card.column != .allSessions && !card.link.manuallyArchived
            && card.link.deletedAt == nil && !card.isHiddenWorktree
    }

    /// Rows for `cards`, ordered by standing then by most recent activity.
    /// `lastMessages` maps a card id to the agent's last message.
    public static func rows(cards: [KanbanCodeCard], attention: [AttentionRequest],
                            lastMessages: [String: String] = [:]) -> [BoardDigestRow] {
        let openByCard = Dictionary(grouping: attention.filter(\.isOpen), by: { $0.cardId ?? "" })
        let titles = Dictionary(cards.map { ($0.id, $0.displayTitle) }, uniquingKeysWith: { a, _ in a })
        return cards.filter(includes).map { card in
            let message = lastMessages[card.id].map { trim($0, to: messageLimit) }
            let (standing, reason) = classify(card, attention: openByCard[card.id] ?? [], lastMessage: lastMessages[card.id])
            return BoardDigestRow(
                cardId: card.id,
                title: trim(card.displayTitle, to: 90),
                project: card.projectName,
                column: card.column,
                standing: standing,
                reason: reason,
                lastMessage: standing == .done ? nil : message,
                lastActivity: card.link.lastActivity ?? card.link.updatedAt,
                queuedPrompts: card.link.queuedPrompts?.count ?? 0,
                pullRequests: card.link.prLinks.map { pr in
                    pr.status.map { "#\(pr.number) \($0.rawValue)" } ?? "#\(pr.number)"
                },
                parentTitle: card.link.parentCardId.flatMap { titles[$0] },
                isLive: card.hasRunningSession)
        }
        .sorted { a, b in
            if a.standing.rank != b.standing.rank { return a.standing.rank < b.standing.rank }
            return (a.lastActivity ?? .distantPast) > (b.lastActivity ?? .distantPast)
        }
    }

    /// Where a card stands and why.
    static func classify(_ card: KanbanCodeCard, attention: [AttentionRequest],
                         lastMessage: String?) -> (CardStanding, String?) {
        if let request = attention.sorted(by: { $0.createdAt < $1.createdAt }).first {
            return (.needsYou, "\(kindLabel(request.kind)): \(trim(request.title, to: 160))")
        }
        if card.activityState == .awaitingPermission {
            return (.needsYou, "permission prompt in the terminal")
        }
        if case .failed(let message) = card.sessionStatus {
            return (.failed, trim(message, to: 160))
        }
        if card.isActivelyWorking || card.showSpinner {
            return (.working, nil)
        }
        switch card.column {
        case .backlog:
            return (.notStarted, nil)
        case .done:
            return (.done, nil)
        case .inReview:
            if let pr = card.link.prLinks.first(where: { $0.status == .failing || $0.status == .changesRequested || $0.status == .unresolved }) {
                return (.needsYou, "PR #\(pr.number) \(pr.status?.rawValue ?? "")")
            }
            return (.inReview, nil)
        case .inProgress, .waiting, .allSessions:
            if let lastMessage, endsWithQuestion(lastMessage) {
                return (.needsYou, "asked: \(trim(lastQuestion(lastMessage), to: 160))")
            }
            return (.idle, nil)
        }
    }

    /// True when the message hands the turn back with a question: its last
    /// non-empty line ends with a question mark.
    public static func endsWithQuestion(_ text: String) -> Bool {
        let line = lastQuestion(text).trimmingCharacters(in: CharacterSet(charactersIn: "*_` \t"))
        return line.hasSuffix("?")
    }

    private static func lastQuestion(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { !$0.isEmpty }) ?? ""
    }

    private static func kindLabel(_ kind: AttentionRequest.Kind) -> String {
        switch kind {
        case .question: "question"
        case .planApproval: "plan to approve"
        case .permission: "permission"
        case .vaultApproval: "secret approval"
        }
    }

    /// Collapses whitespace and cuts `text` to `limit` characters.
    static func trim(_ text: String, to limit: Int) -> String {
        let flat = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit - 1)) + "…"
    }

    /// The digest as text for a model: one line per card, grouped by standing.
    /// Done cards are counted, not listed, unless `includeDone`.
    public static func render(_ rows: [BoardDigestRow], now: Date = .now, includeDone: Bool = false) -> String {
        var out: [String] = []
        let counts = CardStanding.allCases.compactMap { standing -> String? in
            let n = rows.filter { $0.standing == standing }.count
            return n == 0 ? nil : "\(n) \(standing.label.lowercased())"
        }
        out.append("Board: \(rows.count) cards (\(counts.joined(separator: ", "))). Now: \(iso(now)).")
        for standing in CardStanding.allCases {
            let group = rows.filter { $0.standing == standing }
            guard !group.isEmpty else { continue }
            out.append("")
            out.append("## \(standing.label) (\(group.count))")
            if standing == .done && !includeDone {
                out.append(group.prefix(10).map { "- \($0.title)" }.joined(separator: "\n"))
                if group.count > 10 { out.append("- … \(group.count - 10) more") }
                continue
            }
            for row in group {
                var line = "- [\(row.cardId)] \(row.title)"
                var facts: [String] = []
                if let project = row.project { facts.append("project \(project)") }
                facts.append("column \(row.column.rawValue)")
                if let at = row.lastActivity { facts.append("active \(ago(at, now: now))") }
                facts.append(row.isLive ? "session live" : "no live session")
                if row.queuedPrompts > 0 { facts.append("\(row.queuedPrompts) queued") }
                if !row.pullRequests.isEmpty { facts.append("PR " + row.pullRequests.joined(separator: ", ")) }
                if let parent = row.parentTitle { facts.append("subagent of \"\(parent)\"") }
                line += " (" + facts.joined(separator: "; ") + ")"
                if let reason = row.reason { line += "\n  why: \(reason)" }
                if let message = row.lastMessage { line += "\n  last: \(message)" }
                out.append(line)
            }
        }
        return out.joined(separator: "\n")
    }

    static func ago(_ date: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86400 { return "\(s / 3600)h ago" }
        return "\(s / 86400)d ago"
    }

    private static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f.string(from: date)
    }
}
