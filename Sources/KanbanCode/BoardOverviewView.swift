import SwiftUI
import KanbanCodeCore
import KanbanCodeRemoteKit
import MarkdownUI

/// The orchestrator's state: the agents' last messages the digest reads,
/// and the questions asked about the board with their answers.
///
/// Kept by ContentView, so switching sidebar tabs keeps the conversation.
@Observable
@MainActor
final class BoardOverviewModel {
    var turns: [OrchestratorTurn] = []
    var pendingQuestion: String?
    var partialAnswer = ""
    var error: String?
    var isRunning: Bool { task != nil }

    /// Last agent message per card, and the activity date it was read at.
    private(set) var lastMessages: [String: String] = [:]
    private var readAt: [String: Date] = [:]

    private var task: Task<Void, Never>?
    private let runner = ClaudeOrchestratorRunner()
    private var runId = ""

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

    func ask(_ question: String, state: AppState) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, task == nil else { return }
        pendingQuestion = question
        partialAnswer = ""
        error = nil
        let id = "orch-" + UUID().uuidString.lowercased().prefix(12)
        runId = String(id)
        task = Task { [weak self] in
            guard let self else { return }
            await self.refreshMessages(state.filteredCards)
            let digest = BoardDigest.render(self.rows(state))
            let prompt = OrchestratorPrompt.build(digest: digest, history: self.turns, question: question)
            let job = SideChatJob(sessionId: "", cwd: NSHomeDirectory(), prompt: prompt)
            do {
                let answer = try await self.runner.run(id: String(id), job) { text in
                    Task { @MainActor [weak self] in
                        guard let self, self.runId == String(id) else { return }
                        self.partialAnswer = text
                    }
                }
                self.turns.append(OrchestratorTurn(question: question, answer: answer))
            } catch is CancellationError {
                // Stopped by the human; the question goes back to nothing.
            } catch {
                self.error = error.localizedDescription
                self.turns.append(OrchestratorTurn(question: question, answer: self.partialAnswer))
            }
            self.pendingQuestion = nil
            self.partialAnswer = ""
            self.task = nil
        }
    }

    func stop() {
        let id = runId
        task?.cancel()
        Task { await runner.cancel(id: id) }
    }

    func clear() {
        stop()
        turns = []
        error = nil
    }
}

/// Sidebar tab next to Sessions and Prompts: every card by where it stands,
/// and a chat with an orchestrator that answers about the whole board.
struct BoardOverviewView: View {
    var store: BoardStore
    var model: BoardOverviewModel
    var onOpenCard: (String) -> Void

    @State private var draft = ""
    @State private var showDone = false
    @FocusState private var inputFocused: Bool

    private static let suggestions = [
        "What needs me right now?",
        "What is blocked, and on what?",
        "Summarize what moved today.",
    ]

    var body: some View { usageTrackedBody.trackUsage("view", "BoardOverviewView") }

    @ViewBuilder private var usageTrackedBody: some View {
        let rows = model.rows(store.state)
        VSplitView {
            boardList(rows)
                .frame(minHeight: 120, idealHeight: 280)
            chat
                .frame(minHeight: 200)
        }
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

    // MARK: Chat

    private var chat: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Orchestrator", systemImage: "sparkles")
                    .font(.app(.caption).weight(.semibold))
                Spacer()
                if !model.turns.isEmpty {
                    Button("Clear") { model.clear() }
                        .buttonStyle(.borderless)
                        .font(.app(.caption))
                        .disabled(model.isRunning)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if model.turns.isEmpty && model.pendingQuestion == nil {
                            suggestions
                        }
                        ForEach(Array(model.turns.enumerated()), id: \.offset) { _, turn in
                            exchange(question: turn.question, answer: turn.answer)
                        }
                        if let question = model.pendingQuestion {
                            exchange(question: question, answer: model.partialAnswer, running: true)
                        }
                        if let error = model.error {
                            Text(error)
                                .font(.app(.caption))
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(12)
                }
                .onChange(of: model.partialAnswer) { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: model.turns.count) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            Divider()
            input
        }
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ask about every card on the board. Answers read the board as it is now and may look into a card's transcript; they never change a card.")
                .font(.app(.caption))
                .foregroundStyle(.secondary)
            ForEach(Self.suggestions, id: \.self) { text in
                Button(text) { model.ask(text, state: store.state) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private func exchange(question: String, answer: String, running: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(question)
                .font(.app(.callout).weight(.semibold))
                .textSelection(.enabled)
            if answer.isEmpty && running {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Reading the board…").font(.app(.caption)).foregroundStyle(.secondary)
                }
            } else {
                Markdown(answer)
                    .markdownTheme(.compact)
                    .textSelection(.enabled)
            }
        }
    }

    private var input: some View {
        HStack(alignment: .bottom, spacing: 6) {
            TextField("Ask about the board…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .focused($inputFocused)
                .onSubmit(send)
            if model.isRunning {
                Button { model.stop() } label: { Image(systemName: "stop.circle.fill") }
                    .buttonStyle(.borderless)
                    .help("Stop")
            } else {
                Button(action: send) { Image(systemName: "arrow.up.circle.fill") }
                    .buttonStyle(.borderless)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Ask (Return)")
            }
        }
        .font(.app(.callout))
        .padding(10)
    }

    private func send() {
        guard !model.isRunning else { return }
        let text = draft
        draft = ""
        model.ask(text, state: store.state)
    }
}
