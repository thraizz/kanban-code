import AppKit
import KanbanCodeCore
import SwiftUI

// MARK: - Rows

/// One line group of the transcript, drawn the way Claude Code draws it in
/// the terminal: a bullet, then the text, then the first lines of a tool
/// result behind a `⎿`.
enum TerminalTranscriptRow: Identifiable, Equatable {
    /// Something the person typed.
    case user(id: String, text: String)
    /// A message of the assistant.
    case assistant(id: String, text: String)
    /// A thinking block, dimmed.
    case thinking(id: String, excerpt: TerminalTranscript.Excerpt)
    /// A tool call with the start of its result.
    case toolCall(id: String, title: String, output: TerminalTranscript.Excerpt?)
    /// A note of the harness: a task notification, an interruption, plan mode.
    case system(id: String, text: String)

    var id: String {
        switch self {
        case .user(let id, _), .assistant(let id, _), .thinking(let id, _),
             .toolCall(let id, _, _), .system(let id, _):
            id
        }
    }
}

/// Builds the rows of the terminal skin from a transcript window. Kept out
/// of the view so the shape of every row can be checked on its own.
enum TerminalTranscript {
    /// The first lines of a long text, and how many lines were left out.
    struct Excerpt: Equatable {
        var text: String
        var hiddenLines: Int
    }

    /// How many lines of a tool result the skin shows, as Claude Code does
    /// before "+N lines".
    static let outputLineLimit = 4
    /// Lines of a thinking block shown before the cut.
    static let thinkingLineLimit = 3
    /// A tool result line longer than this is cut; the terminal wraps it
    /// anyway, and a result can carry a whole file on one line.
    static let outputLineWidth = 400

    static func excerpt(_ text: String, limit: Int = outputLineLimit) -> Excerpt {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Excerpt(text: "", hiddenLines: 0) }
        let lines = trimmed.components(separatedBy: "\n")
        let shown = lines.prefix(limit).map { line -> String in
            line.count > outputLineWidth ? String(line.prefix(outputLineWidth)) + "…" : line
        }
        return Excerpt(text: shown.joined(separator: "\n"), hiddenLines: max(0, lines.count - limit))
    }

    /// The header of a tool call. `Bash` shows the command, as Claude Code
    /// does, not the description the transcript display text prefers.
    static func toolTitle(name: String, input: [String: String], displayText: String) -> String {
        if name == "Bash", let command = input["command"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !command.isEmpty {
            let firstLine = command.components(separatedBy: "\n").first ?? command
            let shown = firstLine.count > 200 ? String(firstLine.prefix(200)) + "…" : firstLine
            let more = command.contains("\n") ? " …" : ""
            return "\(name)(\(shown)\(more))"
        }
        let trimmed = displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? name : trimmed
    }

    /// Text of a user turn that the terminal shows as a note, not a prompt.
    static func isSystemNote(_ text: String) -> Bool {
        text.hasPrefix("✓ ") || text.hasPrefix("⏳ ") || text.contains("[Request interrupted by user")
    }

    /// The most lines a message row shows. A pasted log of thousands of
    /// lines would otherwise be measured whole, and the layout of the skin
    /// froze the app on such transcripts.
    static let messageLineLimit = 200

    /// A message cut to `messageLineLimit` lines, with a note for the rest.
    static func messageText(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        guard lines.count > messageLineLimit else { return text }
        return lines.prefix(messageLineLimit).joined(separator: "\n")
            + "\n… +\(lines.count - messageLineLimit) lines"
    }

    static func rows(from turns: [ConversationTurn]) -> [TerminalTranscriptRow] {
        // Tool results live in the user turn after the call. They are paired
        // by id so a call shows the start of what it got back.
        var results: [String: ContentBlock] = [:]
        for turn in turns where turn.role == "user" {
            for block in turn.contentBlocks {
                if case .toolResult(_, let toolUseId) = block.kind, let toolUseId {
                    results[toolUseId] = block
                }
            }
        }

        var rows: [TerminalTranscriptRow] = []
        for turn in turns {
            for (index, block) in turn.contentBlocks.enumerated() {
                let id = "\(turn.lineNumber):\(index)"
                switch block.kind {
                case .text:
                    let text = messageText(block.text.trimmingCharacters(in: .whitespacesAndNewlines))
                    guard !text.isEmpty else { continue }
                    if turn.role == "user" {
                        rows.append(isSystemNote(text) ? .system(id: id, text: text) : .user(id: id, text: text))
                    } else {
                        rows.append(.assistant(id: id, text: text))
                    }
                case .thinking:
                    let excerpt = excerpt(block.text, limit: thinkingLineLimit)
                    guard !excerpt.text.isEmpty else { continue }
                    rows.append(.thinking(id: id, excerpt: excerpt))
                case .toolUse(let name, let input, let toolUseId):
                    rows.append(.toolCall(
                        id: id,
                        title: toolTitle(name: name, input: input, displayText: block.text),
                        output: output(for: toolUseId, in: results)
                    ))
                case .toolResult:
                    continue
                case .planModeEnter:
                    rows.append(.system(id: id, text: "Entered plan mode"))
                case .planModeExit(let plan):
                    let excerpt = excerpt(plan)
                    rows.append(.toolCall(id: id, title: "ExitPlanMode", output: excerpt.text.isEmpty ? nil : excerpt))
                case .askUserQuestion(let questions, let toolUseId):
                    let header = questions.first?.header ?? ""
                    let title = header.isEmpty ? "AskUserQuestion" : "AskUserQuestion(\(header))"
                    rows.append(.toolCall(id: id, title: title, output: output(for: toolUseId, in: results)))
                case .agentCall(let description, let subagentType, let toolUseId):
                    let kind = subagentType.map { " · \($0)" } ?? ""
                    rows.append(.toolCall(
                        id: id,
                        title: "Agent(\(description)\(kind))",
                        output: output(for: toolUseId, in: results)
                    ))
                }
            }
        }
        return rows
    }

    private static func output(for toolUseId: String?, in results: [String: ContentBlock]) -> Excerpt? {
        guard let toolUseId, let result = results[toolUseId] else { return nil }
        let excerpt = excerpt(result.text)
        return excerpt.text.isEmpty ? nil : excerpt
    }

    /// The `owner/repo#123`, `repo#123` and `#123` references of a text, with
    /// where they go. The same rule the terminal uses for its own text.
    static func issueRefs(in text: String, githubBaseURL: String?) -> [String: URL] {
        guard let regex = issueRefRegex else { return [:] }
        let nsText = text as NSString
        var refs: [String: URL] = [:]
        for match in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
            let ref = nsText.substring(with: match.range)
            guard refs[ref] == nil,
                  let resolved = TerminalURLDetector.resolveIssueRef(ref, githubBaseURL: githubBaseURL),
                  let url = URL(string: resolved) else { continue }
            refs[ref] = url
        }
        return refs
    }

    private static let issueRefRegex = try? NSRegularExpression(
        pattern: TerminalURLDetector.markdownIssueRefPattern, options: [])
}

// MARK: - View

/// The transcript drawn like the terminal it stands in for.
///
/// Shown in the assistant tab when the session is not on the screen: the
/// tmux session ended, or the machine that runs it is paused. It reads the
/// same transcript window as the chat, but in the skin of Claude Code: the
/// terminal font on the terminal background, no markdown, the whole width,
/// and the first lines of every tool result instead of a card to open. It
/// scrolls, and its links and pull request references open like the ones in
/// the chat. The bar at the bottom carries the way back to the session.
struct TranscriptTerminalView<Bar: View>: View {
    let turns: [ConversationTurn]
    var githubBaseURL: String?
    @ViewBuilder var bar: () -> Bar

    static var background: Color { Color(red: 0.07, green: 0.07, blue: 0.07) }

    private var rows: [TerminalTranscriptRow] {
        TerminalTranscript.rows(from: turns)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(rows) { row in
                        TranscriptTerminalRowView(row: row, githubBaseURL: githubBaseURL)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.bottom)
            bar()
        }
        // Kept inside the detail: a background that spreads into the safe
        // area shows under the sidebar next to it.
        .background(Self.background, ignoresSafeAreaEdges: [])
        .colorScheme(.dark)
    }
}

/// One row of the skin. The bullet stands in its own column, as in the
/// terminal, and the text takes the rest of the width.
private struct TranscriptTerminalRowView: View {
    let row: TerminalTranscriptRow
    var githubBaseURL: String?

    /// The size the terminal itself uses, so the transcript reads as the
    /// same screen.
    private static var fontSize: CGFloat {
        let stored = UserDefaults.standard.double(forKey: TerminalCache.fontSizeKey)
        return stored > 0 ? CGFloat(stored) : TerminalCache.defaultFontSize
    }

    private static var font: NSFont { .monospacedSystemFont(ofSize: fontSize, weight: .regular) }
    private static var boldFont: NSFont { .monospacedSystemFont(ofSize: fontSize, weight: .bold) }
    private static let text = NSColor(white: 0.88, alpha: 1)
    private static let dim = NSColor(white: 0.55, alpha: 1)
    private static let toolBullet = Color(red: 0.45, green: 0.75, blue: 0.45)
    private static let promptBackground = Color(white: 0.16)

    var body: some View {
        switch row {
        case .user(_, let text):
            HStack(alignment: .top, spacing: 0) {
                bullet(">", color: Color(nsColor: Self.dim))
                plainText(text, color: Self.text)
            }
            .padding(.vertical, 4)
            .padding(.trailing, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Self.promptBackground)

        case .assistant(_, let text):
            HStack(alignment: .top, spacing: 0) {
                bullet("●", color: Color(nsColor: Self.text))
                plainText(text, color: Self.text)
            }

        case .thinking(_, let excerpt):
            HStack(alignment: .top, spacing: 0) {
                bullet("∴", color: Color(nsColor: Self.dim))
                VStack(alignment: .leading, spacing: 2) {
                    plainText("Thinking…", color: Self.dim, italic: true)
                    plainText(excerpt.text, color: Self.dim, italic: true)
                    if excerpt.hiddenLines > 0 { moreLines(excerpt.hiddenLines) }
                }
            }

        case .toolCall(_, let title, let output):
            HStack(alignment: .top, spacing: 0) {
                bullet("●", color: Self.toolBullet)
                VStack(alignment: .leading, spacing: 2) {
                    toolTitle(title)
                    if let output {
                        HStack(alignment: .top, spacing: 0) {
                            Text("⎿  ")
                                .font(Font(Self.font))
                                .foregroundStyle(Color(nsColor: Self.dim))
                            VStack(alignment: .leading, spacing: 2) {
                                plainText(output.text, color: Self.dim)
                                if output.hiddenLines > 0 { moreLines(output.hiddenLines) }
                            }
                        }
                    }
                }
            }

        case .system(_, let text):
            HStack(alignment: .top, spacing: 0) {
                bullet(" ", color: .clear)
                plainText(text, color: Self.dim, italic: true)
            }
        }
    }

    private func bullet(_ symbol: String, color: Color) -> some View {
        Text(symbol)
            .font(Font(Self.font))
            .foregroundStyle(color)
            .frame(width: Self.fontSize * 1.6, alignment: .leading)
    }

    /// `Name(argument)` with the name in bold, as the terminal draws it.
    ///
    /// Not selectable. SwiftUI's selection overlay is a text field with one
    /// font, and for a text of two fonts it sets the other one on every
    /// update. Each change invalidates the field's intrinsic size, which asks
    /// the window for another constraint pass, until AppKit throws.
    private func toolTitle(_ title: String) -> some View {
        let open = title.firstIndex(of: "(")
        let name = open.map { String(title[..<$0]) } ?? title
        let rest = open.map { String(title[$0...]) } ?? ""
        return (Text(name).font(Font(Self.boldFont)) + Text(rest).font(Font(Self.font)))
            .foregroundStyle(Color(nsColor: Self.text))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func moreLines(_ count: Int) -> some View {
        Text("… +\(count) line\(count == 1 ? "" : "s")")
            .font(Font(Self.font))
            .foregroundStyle(Color(nsColor: Self.dim))
    }

    /// The text of a row, with its links. No markdown: the terminal shows
    /// the text as the assistant wrote it.
    private func plainText(_ text: String, color: NSColor, italic: Bool = false) -> some View {
        ChatText(
            content: .plain(text),
            appearance: .init(font: Self.font, foregroundColor: color, italic: italic),
            links: ChatTextLinks(
                issueRefs: TerminalTranscript.issueRefs(in: text, githubBaseURL: githubBaseURL),
                urls: true
            )
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
