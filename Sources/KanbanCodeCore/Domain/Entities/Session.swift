import Foundation

/// A discovered coding assistant session, extracted from session files.
public struct Session: Identifiable, Sendable, Equatable {
    public let id: String // sessionId (UUID string)
    public var name: String? // Custom name or auto-generated summary
    public var firstPrompt: String? // First user message text
    public var projectPath: String? // Decoded project directory path
    public var gitBranch: String? // Git branch if in a worktree
    public var messageCount: Int
    public var modifiedTime: Date
    public var jsonlPath: String? // Full path to the session file (.jsonl or .json)
    public var assistant: CodingAssistant // Which assistant this session belongs to
    /// How the assistant was started, as its transcript records it:
    /// Claude Code writes "cli" for an interactive session, "sdk-cli" for
    /// `claude -p`, and "sdk-ts" / "sdk-py" for runs of the Agent SDK
    /// (claude-mem's observer sessions are "sdk-ts").
    public var entrypoint: String?

    /// Whether a script ran this session without a terminal (`claude -p`).
    public var isHeadless: Bool { Self.isHeadless(entrypoint: entrypoint) }

    public static let headlessEntrypoint = "sdk-cli"

    /// Whether `entrypoint` names a run without a terminal: `claude -p` or
    /// any Agent SDK (`sdk-cli`, `sdk-ts`, `sdk-py`, ...).
    public static func isHeadless(entrypoint: String?) -> Bool {
        entrypoint?.hasPrefix("sdk-") == true
    }

    public init(
        id: String,
        name: String? = nil,
        firstPrompt: String? = nil,
        projectPath: String? = nil,
        gitBranch: String? = nil,
        messageCount: Int = 0,
        modifiedTime: Date = .now,
        jsonlPath: String? = nil,
        assistant: CodingAssistant = .claude,
        entrypoint: String? = nil
    ) {
        self.id = id
        self.name = name
        self.firstPrompt = firstPrompt
        self.projectPath = projectPath
        self.gitBranch = gitBranch
        self.messageCount = messageCount
        self.modifiedTime = modifiedTime
        self.jsonlPath = jsonlPath
        self.assistant = assistant
        self.entrypoint = entrypoint
    }

    /// Display title: custom name → summary → first prompt → session ID prefix.
    public var displayTitle: String {
        if let name, !name.isEmpty { return name }
        if let firstPrompt {
            let prompt = InjectedPromptText.strip(firstPrompt)
            if !prompt.isEmpty { return String(prompt.prefix(100)) }
        }
        return String(id.prefix(8)) + "..."
    }
}
