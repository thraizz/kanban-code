import SwiftUI
import KanbanCodeCore
import KanbanCodeRemoteKit

/// What the Overview and the orchestrator's digest read: the agents' last
/// messages, re-read when a card's activity moves.
///
/// Kept by ContentView, so switching sidebar tabs keeps what was read.
@Observable
@MainActor
final class BoardOverviewModel {
    /// Last agent message per card, and the activity date it was read at.
    private(set) var lastMessages: [String: String] = [:]
    private var readAt: [String: Date] = [:]

    /// The cards the board shows: its filters (excluded paths, hidden
    /// sessions, the selected project) apply here too.
    func rows(_ state: AppState) -> [BoardDigestRow] {
        BoardDigest.rows(cards: state.filteredCards, attention: state.openAttentionRequests, lastMessages: lastMessages)
    }

    /// Reads the last message of every card whose activity moved since the
    /// last read. Done cards are skipped: the digest lists them by title.
    func refreshMessages(_ cards: [KanbanCodeCard]) async {
        let wanted = cards.filter { BoardDigest.includes($0) && $0.column != .done && $0.column != .backlog }
        let stale: [(id: String, path: String, assistant: CodingAssistant, at: Date)] = wanted.compactMap { card in
            guard let session = card.session, let path = session.jsonlPath else { return nil }
            let at = card.link.lastActivity ?? session.modifiedTime
            if let seen = readAt[card.id], seen >= at { return nil }
            return (card.id, path, session.assistant, at)
        }
        guard !stale.isEmpty else { return }
        let read = await withTaskGroup(of: (String, String?, Date).self) { group in
            for item in stale {
                group.addTask {
                    let text = await TranscriptNotificationReader.lastAssistantText(
                        transcriptPath: item.path, assistant: item.assistant)
                    return (item.id, text, item.at)
                }
            }
            var out: [(String, String?, Date)] = []
            for await result in group { out.append(result) }
            return out
        }
        for (id, text, at) in read {
            lastMessages[id] = text
            readAt[id] = at
        }
    }

}

/// Sidebar tab next to Sessions and Prompts: every card by where it stands.
/// The orchestrator chat has its own tab (OrchestratorView).
struct BoardOverviewView: View {
    var store: BoardStore
    var model: BoardOverviewModel
    var onOpenCard: (String) -> Void

    @State private var showDone = false

    var body: some View { usageTrackedBody.trackUsage("view", "BoardOverviewView") }

    @ViewBuilder private var usageTrackedBody: some View {
        let rows = model.rows(store.state)
        boardList(rows)
        .task(id: messageSignature) { await model.refreshMessages(store.state.filteredCards) }
    }

    /// Changes when a card's activity moves, so last messages are re-read.
    private var messageSignature: Int {
        var hasher = Hasher()
        for card in store.state.filteredCards where BoardDigest.includes(card) {
            hasher.combine(card.id)
            hasher.combine(card.link.lastActivity)
        }
        return hasher.finalize()
    }

    // MARK: Board

    private func boardList(_ rows: [BoardDigestRow]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                ForEach(CardStanding.allCases, id: \.self) { standing in
                    let group = rows.filter { $0.standing == standing }
                    if !group.isEmpty {
                        Section {
                            if standing != .done || showDone {
                                ForEach(group) { row in rowView(row) }
                            }
                        } header: {
                            sectionHeader(standing, count: group.count)
                        }
                    }
                }
                if rows.isEmpty {
                    Text("No cards on the board.")
                        .font(.app(.callout))
                        .foregroundStyle(.secondary)
                        .padding()
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
    }

    private func sectionHeader(_ standing: CardStanding, count: Int) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color(standing)).frame(width: 7, height: 7)
            Text(standing.label).font(.app(.caption).weight(.semibold))
            Text("\(count)").font(.app(.caption)).foregroundStyle(.secondary)
            Spacer()
            if standing == .done {
                Button(showDone ? "Hide" : "Show") { showDone.toggle() }
                    .buttonStyle(.borderless)
                    .font(.app(.caption))
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 4)
        .background(.bar)
    }

    private func rowView(_ row: BoardDigestRow) -> some View {
        Button { onOpenCard(row.cardId) } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.title)
                        .font(.app(.callout).weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let at = row.lastActivity {
                        Text(at, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                            .font(.app(.caption2))
                            .foregroundStyle(.tertiary)
                            .fixedSize()
                    }
                }
                if let detail = row.reason ?? row.lastMessage {
                    Text(detail)
                        .font(.app(.caption))
                        .foregroundStyle(row.reason != nil ? .primary : .secondary)
                        .lineLimit(2)
                }
                let facts = [row.project, row.pullRequests.isEmpty ? nil : row.pullRequests.joined(separator: " "),
                             row.queuedPrompts > 0 ? "\(row.queuedPrompts) queued" : nil,
                             row.parentTitle.map { "↳ \($0)" }].compactMap { $0 }
                if !facts.isEmpty {
                    Text(facts.joined(separator: " · "))
                        .font(.app(.caption2))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(store.state.selectedCardId == row.cardId ? Color.accentColor.opacity(0.15) : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private func color(_ standing: CardStanding) -> Color {
        switch standing {
        case .needsYou: .orange
        case .failed: .red
        case .working: .blue
        case .idle: .gray
        case .inReview: .purple
        case .notStarted: .secondary
        case .done: .green
        }
    }
}
