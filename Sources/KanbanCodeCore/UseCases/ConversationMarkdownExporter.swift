import Foundation
import KanbanCodeRemoteKit

/// Converts native assistant transcripts into a plain message-only Markdown log.
public enum ConversationMarkdownExporter {
    public static func exportMarkdown(
        title: String,
        assistant: CodingAssistant,
        sessionId: String?,
        sessionPath: String,
        sessionStore: SessionStore
    ) async throws -> String {
        var output = ""
        try await streamMarkdown(
            title: title,
            assistant: assistant,
            sessionId: sessionId,
            sessionPath: sessionPath,
            sessionStore: sessionStore
        ) { output += $0 }
        return output
    }

    /// Same Markdown as `exportMarkdown`, handed to `write` piece by piece as the
    /// transcript is read, so a long session never sits in memory as one string.
    public static func streamMarkdown(
        title: String,
        assistant: CodingAssistant,
        sessionId: String?,
        sessionPath: String,
        sessionStore: SessionStore,
        write: (String) -> Void
    ) async throws {
        write(header(title: title, assistant: assistant, sessionId: sessionId))
        switch assistant {
        case .claude:
            for await turn in TranscriptReader.streamAllTurns(from: sessionPath) {
                if let section = section(for: turn, assistant: assistant) { write(section) }
            }
        case .codex:
            for turn in try await CodexSessionParser.readTurns(from: sessionPath) {
                if let section = section(for: turn, assistant: assistant) { write(section) }
            }
        case .gemini, .opencode:
            for turn in try await sessionStore.readTranscript(sessionPath: sessionPath) {
                if let section = section(for: turn, assistant: assistant) { write(section) }
            }
        }
        write("\n")
    }

    static func markdown(
        title: String,
        assistant: CodingAssistant,
        sessionId: String?,
        turns: [ConversationTurn]
    ) -> String {
        var output = header(title: title, assistant: assistant, sessionId: sessionId)
        for turn in turns {
            if let section = section(for: turn, assistant: assistant) { output += section }
        }
        return output + "\n"
    }

    /// Title and metadata lines, without a trailing newline: every section
    /// starts with the blank line that separates it from what came before.
    private static func header(title: String, assistant: CodingAssistant, sessionId: String?) -> String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines: [String] = [
            "# \(trimmedTitle.isEmpty ? "Conversation" : trimmedTitle)",
            "",
            "_Assistant: \(assistant.displayName)_"
        ]

        if let sessionId = sessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !sessionId.isEmpty {
            lines.append("_Session: `\(sessionId)`_")
        }
        return lines.joined(separator: "\n")
    }

    private static func section(for turn: ConversationTurn, assistant: CodingAssistant) -> String? {
        guard let heading = heading(for: turn.role, assistant: assistant) else { return nil }
        let text = messageText(for: turn).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return "\n\n## \(heading)\n\n\(text)"
    }

    private static func heading(for role: String, assistant: CodingAssistant) -> String? {
        switch role {
        case "user":
            return "User"
        case "assistant":
            return assistant.displayName
        default:
            return nil
        }
    }

    private static func messageText(for turn: ConversationTurn) -> String {
        let textBlocks = turn.contentBlocks.compactMap { block -> String? in
            if case .text = block.kind { return block.text }
            return nil
        }

        if !textBlocks.isEmpty {
            return textBlocks.joined(separator: "\n\n")
        }

        return turn.textPreview
    }
}

/// Converts channel chat logs into a plain message-only Markdown transcript.
public enum ChannelConversationMarkdownExporter {
    public static func markdown(channelName: String, messages: [ChannelMessage]) -> String {
        let name = channelName.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines: [String] = [
            "# #\(name.isEmpty ? "channel" : name)",
            "",
            "_Channel conversation_",
            ""
        ]

        for message in messages where message.type == .message {
            let text = messageText(for: message).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            lines.append("## @\(message.from.handle) · \(timestamp(for: message.ts))")
            lines.append("")
            lines.append(text)
            lines.append("")
        }

        return lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private static func messageText(for message: ChannelMessage) -> String {
        PromptImageLayout.replacingMarkersWithMarkdown(
            in: message.body,
            imagePaths: message.imagePaths ?? []
        )
    }

    private static func timestamp(for date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
