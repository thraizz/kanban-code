import SwiftUI
import KanbanCodeCore

/// The orchestrator chat: one Claude Code session per chat, continued with
/// every question, saved to `~/.kanban-code/orchestrator/chat.json` so it
/// survives a relaunch.
///
/// Kept by ContentView, so switching sidebar tabs keeps the conversation.
@Observable
@MainActor
final class OrchestratorModel {
    private(set) var turns: [OrchestratorTurn] = []
    var pendingQuestion: String?
    var partialAnswer = ""
    var partialSteps: [OrchestratorStep] = []
    var isRunning: Bool { task != nil }

    private var sessionId = UUID().uuidString.lowercased()
    /// The session exists on disk, so the next question resumes it.
    private var sessionStarted = false

    private var task: Task<Void, Never>?
    private let runner = ClaudeOrchestratorRunner()
    private var runId = ""
    private let chatFile: String

    private struct Saved: Codable {
        var sessionId: String
        var sessionStarted: Bool
        var turns: [OrchestratorTurn]
    }

    init() {
        chatFile = (runner.workDirectory as NSString).appendingPathComponent("chat.json")
        if let data = FileManager.default.contents(atPath: chatFile),
           let saved = try? JSONDecoder.iso.decode(Saved.self, from: data) {
            turns = saved.turns
            sessionId = saved.sessionId
            sessionStarted = saved.sessionStarted
        }
    }

    private func save() {
        let saved = Saved(sessionId: sessionId, sessionStarted: sessionStarted, turns: turns)
        guard let data = try? JSONEncoder.iso.encode(saved) else { return }
        try? FileManager.default.createDirectory(atPath: runner.workDirectory, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: chatFile), options: .atomic)
    }

    func ask(_ question: String, state: AppState, overview: BoardOverviewModel) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, task == nil else { return }
        pendingQuestion = question
        partialAnswer = ""
        partialSteps = []
        let askedAt = Date()
        task = Task { [weak self] in
            guard let self else { return }
            await overview.refreshMessages(state.filteredCards)
            let digest = BoardDigest.render(overview.rows(state))
            var turn = OrchestratorTurn(question: question, answer: "", askedAt: askedAt)
            do {
                let result = try await self.runOnce(question: question, digest: digest)
                turn.answer = result.answer
                turn.steps = result.steps
            } catch is CancellationError {
                turn.answer = self.partialAnswer
                turn.steps = self.partialSteps
                turn.error = "Stopped."
            } catch {
                turn.answer = self.partialAnswer
                turn.steps = self.partialSteps
                turn.error = error.localizedDescription
            }
            self.turns.append(turn)
            self.pendingQuestion = nil
            self.partialAnswer = ""
            self.partialSteps = []
            self.task = nil
            self.save()
        }
    }

    /// Runs the question in the chat's session. A session that cannot be
    /// resumed (its transcript is gone) is replaced by a new one that gets
    /// the recent exchanges as text.
    private func runOnce(question: String, digest: String) async throws -> OrchestratorResult {
        do {
            return try await run(question: question, digest: digest)
        } catch let error as SideChatFailed where partialSteps.isEmpty && partialAnswer.isEmpty {
            guard sessionStarted else { throw error }
            KanbanCodeLog.warn("orchestrator", "resume failed (\(error.message)); starting a new session")
            sessionId = UUID().uuidString.lowercased()
            sessionStarted = false
            return try await run(question: question, digest: digest)
        }
    }

    private func run(question: String, digest: String) async throws -> OrchestratorResult {
        let resume = sessionStarted
        let prompt = resume || turns.isEmpty
            ? OrchestratorPrompt.turn(digest: digest, question: question)
            : OrchestratorPrompt.build(digest: digest, history: turns, question: question)
        let id = ClaudeOrchestratorRunner.newRunId()
        runId = id
        let job = OrchestratorJob(sessionId: sessionId, resume: resume, prompt: prompt)
        do {
            let result = try await runner.run(id: id, job) { progress in
                Task { @MainActor [weak self] in
                    guard let self, self.runId == id else { return }
                    self.partialAnswer = progress.text
                    self.partialSteps = progress.steps
                    self.sessionStarted = true
                }
            }
            sessionStarted = true
            return result
        } catch {
            // A new session that wrote nothing gets a fresh id, so the next
            // try does not collide with a half-made one.
            if !resume && partialSteps.isEmpty && partialAnswer.isEmpty {
                sessionId = UUID().uuidString.lowercased()
                sessionStarted = false
            }
            throw error
        }
    }

    func stop() {
        let id = runId
        task?.cancel()
        Task { await runner.cancel(id: id) }
    }

    /// Starts over: a new session, an empty chat.
    func newChat() {
        stop()
        turns = []
        sessionId = UUID().uuidString.lowercased()
        sessionStarted = false
        save()
    }
}

private extension JSONEncoder {
    static let iso: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

private extension JSONDecoder {
    static let iso: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

/// Sidebar tab: a chat with the orchestrator, which can search every
/// session on this Mac, read them, and steer cards.
struct OrchestratorView: View {
    var store: BoardStore
    var model: OrchestratorModel
    var overview: BoardOverviewModel

    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    private static let suggestions = [
        "What needs me right now?",
        "What is blocked, and on what?",
        "Summarize what moved today.",
        "Find the session where I asked about…",
    ]

    var body: some View { usageTrackedBody.trackUsage("view", "OrchestratorView") }

    private var usageTrackedBody: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messages
            input
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Label("Orchestrator", systemImage: "sparkles")
                .font(.app(.callout).weight(.semibold))
            Spacer()
            Button { model.newChat() } label: { Image(systemName: "square.and.pencil") }
                .buttonStyle(.borderless)
                .disabled(model.turns.isEmpty && !model.isRunning)
                .help("New chat")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if model.turns.isEmpty && model.pendingQuestion == nil {
                        emptyState
                    }
                    ForEach(model.turns) { turn in
                        OrchestratorExchange(question: turn.question, answer: turn.answer,
                                             steps: turn.steps, error: turn.error, running: false)
                    }
                    if let question = model.pendingQuestion {
                        OrchestratorExchange(question: question, answer: model.partialAnswer,
                                             steps: model.partialSteps, error: nil, running: true)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(12)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: model.partialAnswer) { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: model.partialSteps.count) { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: model.turns.count) { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: model.pendingQuestion) { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask about your work across every card and every Claude Code session on this Mac, archived ones and sessions without a card included. It can search transcripts, read sessions, and message or relink cards when you ask.")
                .font(.app(.caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Self.suggestions, id: \.self) { text in
                Button(text) {
                    if text.hasSuffix("…") {
                        draft = String(text.dropLast())
                        inputFocused = true
                    } else {
                        model.ask(text, state: store.state, overview: overview)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var input: some View {
        HStack(alignment: .bottom, spacing: 6) {
            TextField("Message the orchestrator…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...8)
                .focused($inputFocused)
                .onSubmit(send)
                .padding(.vertical, 3)
            if model.isRunning {
                Button { model.stop() } label: {
                    Image(systemName: "stop.circle.fill").font(.system(size: 20))
                }
                .buttonStyle(.borderless)
                .help("Stop")
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 20))
                }
                .buttonStyle(.borderless)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Send (Return)")
            }
        }
        .font(.app(.callout))
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .textBackgroundColor).opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(inputFocused ? 0.5 : 0.25)))
        .contentShape(Rectangle())
        .onTapGesture { inputFocused = true }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .padding(.top, 4)
    }

    private func send() {
        guard !model.isRunning else { return }
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ""
        model.ask(text, state: store.state, overview: overview)
    }
}

/// One question as a bubble on the right, the answer below it on the left,
/// with the tool calls it made folded into a line.
private struct OrchestratorExchange: View {
    let question: String
    let answer: String
    let steps: [OrchestratorStep]
    let error: String?
    let running: Bool

    @State private var showSteps = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer(minLength: 32)
                Text(question)
                    .font(.app(.callout))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.18)))
            }
            if !steps.isEmpty { stepsView }
            if !answer.isEmpty {
                ChatText(answer: answer)
            }
            if running {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(statusLine)
                        .font(.app(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.app(.caption))
                    .foregroundStyle(error == "Stopped." ? Color.secondary : Color.red)
                    .textSelection(.enabled)
            }
        }
    }

    private var statusLine: String {
        guard let last = steps.last else { return "Reading the board…" }
        return "\(last.tool): \(last.summary)"
    }

    private var stepsView: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button { showSteps.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: showSteps ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text("\(steps.count) step\(steps.count == 1 ? "" : "s")")
                        .font(.app(.caption))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showSteps {
                ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                    Text("\(step.tool)  \(step.summary)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                        .padding(.leading, 13)
                }
            }
        }
    }
}
