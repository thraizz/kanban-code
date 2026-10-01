import Foundation

/// Supported coding assistants that can be managed by Kanban Code.
public enum CodingAssistant: String, Codable, Sendable, CaseIterable {
    case claude
    case gemini
    case codex
    case opencode
    case pi

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .gemini: "Gemini CLI"
        case .codex: "Codex CLI"
        case .opencode: "OpenCode"
        case .pi: "Pi"
        }
    }

    public var cliCommand: String {
        switch self {
        case .claude: "claude"
        case .gemini: "gemini"
        case .codex: "codex"
        case .opencode: "opencode"
        case .pi: "pi"
        }
    }

    /// Text shown in the TUI when the assistant is ready for input.
    public var promptCharacter: String {
        switch self {
        case .claude: "❯"
        case .gemini: "Type your message"
        case .codex: "›"
        // The input box is drawn with a heavy left bar; readiness is decided
        // from the footer in PaneOutputParser, not from this character.
        case .opencode: "┃"
        // Pi's input is a bare editor between two rules; readiness is decided
        // from those rules in PaneOutputParser, not from this character.
        case .pi: "─"
        }
    }

    /// CLI flag to auto-approve all tool calls. Empty for an assistant whose
    /// TUI has no such flag; see `autoApproveEnvironment`.
    public var autoApproveFlag: String {
        switch self {
        case .claude: "--dangerously-skip-permissions"
        case .gemini: "--yolo"
        case .codex: "--dangerously-bypass-approvals-and-sandbox"
        // Pi has no permission prompts: every tool call runs.
        case .opencode, .pi: ""
        }
    }

    /// Environment that auto-approves all tool calls, for an assistant whose
    /// interactive TUI has no flag for it. OpenCode reads its permission
    /// config from `OPENCODE_PERMISSION`; a bare `"allow"` string is rejected
    /// at startup, so the wildcard object form is required.
    public var autoApproveEnvironment: [(key: String, value: String)] {
        switch self {
        case .opencode: [(key: "OPENCODE_PERMISSION", value: #"{"*":"allow"}"#)]
        case .claude, .gemini, .codex, .pi: []
        }
    }

    /// CLI flag to resume a session.
    public var resumeFlag: String {
        switch self {
        case .claude, .gemini: "--resume"
        case .codex: "resume"
        case .opencode, .pi: "--session"
        }
    }

    /// Whether this assistant supports git worktree creation.
    public var supportsWorktree: Bool {
        switch self {
        case .claude: true
        case .gemini, .codex, .opencode, .pi: false
        }
    }

    /// Whether this assistant supports image upload via clipboard paste.
    public var supportsImageUpload: Bool {
        switch self {
        case .claude: true
        case .gemini, .codex, .opencode, .pi: false
        }
    }

    /// Whether this assistant exposes a hooks settings file Kanban can install into.
    /// For OpenCode the "hook" is a plugin file that reports bus events, for
    /// Pi an extension file that reports its lifecycle events.
    public var supportsHooks: Bool {
        switch self {
        case .claude, .gemini, .opencode, .pi: true
        case .codex: false
        }
    }

    /// Whether prompt text should be submitted with bracketed paste semantics.
    public var submitsPromptWithPaste: Bool {
        switch self {
        case .claude: false
        case .gemini, .codex, .opencode, .pi: true
        }
    }

    /// Whether remote execution needs Kanban's bash wrapper first on PATH.
    public var requiresRemotePathWrapper: Bool {
        switch self {
        case .claude: false
        case .gemini, .codex, .opencode, .pi: true
        }
    }

    /// Native session file extension used by this assistant. OpenCode keeps
    /// its sessions in a SQLite database, so it has no per-session file.
    public var sessionFileExtension: String {
        switch self {
        case .claude, .codex, .pi: "jsonl"
        case .gemini: "json"
        case .opencode: ""
        }
    }

    /// Extra flags required for interactive startup in a tmux pane.
    public var interactiveLaunchFlags: [String] {
        switch self {
        case .claude, .gemini, .opencode, .pi: []
        case .codex: ["--no-alt-screen"]
        }
    }

    /// Name of the config directory under $HOME (e.g. ".claude", ".gemini").
    /// For OpenCode this is its data directory, which holds `opencode.db`
    /// and under which its virtual session paths live.
    public var configDirName: String {
        switch self {
        case .claude: ".claude"
        case .gemini: ".gemini"
        case .codex: ".codex"
        case .opencode: ".local/share/opencode"
        // Pi's agent directory; its sessions are under `sessions/`.
        case .pi: ".pi/agent"
        }
    }

    /// True if the given session file path lives under this assistant's config directory.
    /// Used by per-assistant activity detectors so they ignore paths that belong to
    /// another assistant — otherwise, Codex's mtime-only polling (which has no way
    /// of knowing a file is actually a Claude transcript) will fabricate
    /// `.activelyWorking` for any recently-modified Claude session, and the composite
    /// detector's highest-priority merge will let that win over the Claude detector's
    /// correct state. Symptom: archived Claude cards un-archive themselves.
    public func owns(sessionPath: String) -> Bool {
        sessionPath.contains("/\(configDirName)/")
    }

    /// The assistant whose config directory contains this session path, or nil
    /// if the path is not under any known assistant directory (e.g. test fixtures).
    public static func owner(ofSessionPath path: String) -> CodingAssistant? {
        for assistant in CodingAssistant.allCases where assistant.owns(sessionPath: path) {
            return assistant
        }
        return nil
    }

    /// True if another assistant's config dir appears in this path. Detectors use
    /// this to drop clearly cross-assistant paths from polling while still
    /// accepting unowned test fixture paths.
    public func ownedByOther(sessionPath: String) -> Bool {
        guard let owner = CodingAssistant.owner(ofSessionPath: sessionPath) else { return false }
        return owner != self
    }

    /// Whether Kanban Code can read this assistant's live context usage and
    /// enforce per-card compaction thresholds.
    public var supportsContextThresholdSelfCompact: Bool {
        self == .claude
    }

    /// Symbol used to mark user turns in conversation history UI.
    public var historyPromptSymbol: String {
        switch self {
        case .claude: "❯"
        case .gemini: "✦"
        case .codex: "›"
        case .opencode: "┃"
        case .pi: "π"
        }
    }

    /// npm package name for installation.
    public var installCommand: String {
        switch self {
        case .claude: "npm install -g @anthropic-ai/claude-code"
        case .gemini: "npm install -g @google/gemini-cli"
        case .codex: "npm install -g @openai/codex"
        case .opencode: "npm install -g opencode-ai"
        case .pi: "npm install -g @earendil-works/pi-coding-agent"
        }
    }

    /// Environment variable used to override the API base URL for this assistant's backend.
    public var baseURLEnvKey: String? {
        switch self {
        case .claude: "ANTHROPIC_BASE_URL"
        case .codex:  "OPENAI_BASE_URL"
        // OpenCode and Pi configure providers in their own config, not by env.
        case .gemini, .opencode, .pi: nil
        }
    }

    /// Builds the tmux launch command, optionally wrapping with an `APIService`.
    ///
    /// Without service: `claude --dangerously-skip-permissions --worktree foo`
    /// With service:    `ollama launch claude --model qwen3 -- --dangerously-skip-permissions --worktree foo`
    public func launchCommand(
        skipPermissions: Bool,
        worktreeName: String?,
        service: APIService? = nil,
        modelOverride: String? = nil
    ) -> String {
        var flags: [String] = []
        if skipPermissions { flags.append(contentsOf: autoApproveFlags) }
        flags.append(contentsOf: interactiveLaunchFlags)
        if supportsWorktree, let worktreeName {
            flags += worktreeName.isEmpty ? ["--worktree"] : ["--worktree", worktreeName]
        }
        return assemble(skipPermissions: skipPermissions, service: service, modelOverride: modelOverride, flags: flags)
    }

    /// Builds the tmux resume command, optionally wrapping with an `APIService`.
    ///
    /// Without service: `claude --dangerously-skip-permissions --resume <id>`
    /// With service:    `ollama launch claude --model qwen3 -- --dangerously-skip-permissions --resume <id>`
    public func resumeCommand(
        sessionId: String,
        skipPermissions: Bool,
        service: APIService? = nil,
        modelOverride: String? = nil
    ) -> String {
        var flags: [String] = []
        switch self {
        case .codex:
            // "resume" subcommand goes after -- when a separator is present
            flags = ["resume"]
            if skipPermissions { flags.append(contentsOf: autoApproveFlags) }
            flags.append(contentsOf: interactiveLaunchFlags)
            flags.append(sessionId)
        case .claude, .gemini, .opencode, .pi:
            if skipPermissions { flags.append(contentsOf: autoApproveFlags) }
            flags.append(resumeFlag)
            flags.append(sessionId)
        }
        return assemble(skipPermissions: skipPermissions, service: service, modelOverride: modelOverride, flags: flags)
    }

    /// `autoApproveFlag` as argv words: none for an assistant without one.
    private var autoApproveFlags: [String] {
        autoApproveFlag.isEmpty ? [] : [autoApproveFlag]
    }

    /// Joins `[env …] [launcher] cli [--model m] [--] flags`.
    ///
    /// The auto-approve environment goes first through `env`, so it still
    /// applies when a launcher prefix or a command template wraps the CLI.
    /// OpenCode and Pi read everything after `--` as positionals (Pi as the
    /// first prompt), so they only get the separator when a launcher (which
    /// needs it) is in front.
    private func assemble(
        skipPermissions: Bool,
        service: APIService?,
        modelOverride: String?,
        flags: [String]
    ) -> String {
        var prefix: [String] = []
        if skipPermissions, !autoApproveEnvironment.isEmpty {
            prefix.append("env")
            prefix += autoApproveEnvironment.map { "\($0.key)=\(shellEscapeCommandArgument($0.value))" }
        }
        if let launcher = service?.launcherPrefix { prefix.append(contentsOf: launcher.split(separator: " ").map(String.init)) }
        prefix.append(cliCommand)
        if let model = modelOverride ?? service?.modelFlag {
            prefix += ["--model", shellEscapeCommandArgument(model)]
        }
        let needsServiceSeparator: Bool
        switch self {
        case .opencode, .pi:
            needsServiceSeparator = service?.launcherPrefix != nil
        case .claude, .gemini, .codex:
            needsServiceSeparator = service?.launcherPrefix != nil
                || (service?.modelFlag != nil && modelOverride == nil)
        }
        let sep: [String] = needsServiceSeparator ? ["--"] : []
        return (prefix + sep + flags).joined(separator: " ")
    }

    /// The part of a session id that names its tmux session: the first 8
    /// characters of a UUID. OpenCode ids (`ses_` + a time-ordered part + a
    /// random part) and Pi's version 7 UUIDs (a millisecond timestamp first)
    /// share their first characters between sessions started close
    /// together, so theirs is the random tail.
    public func shortSessionId(_ sessionId: String) -> String {
        if sessionId.hasPrefix("ses_") || self == .pi { return String(sessionId.suffix(8)) }
        return String(sessionId.prefix(8))
    }

    /// The tmux session a resume of `sessionId` runs in.
    public func resumeSessionName(sessionId: String) -> String {
        "\(cliCommand)-\(shortSessionId(sessionId))"
    }

    /// Wraps a built assistant command with the user's launch command template.
    ///
    /// `langwatch ${cli_command}` gives `langwatch claude --resume abc`, and a
    /// template with no placeholder is treated as a prefix, so a user who types
    /// only `langwatch` gets the same result. A missing, blank or
    /// bare-placeholder template returns the command unchanged.
    public static func applyCommandTemplate(_ command: String, template: String?) -> String {
        guard let template else { return command }
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != AssistantCommandTemplate.placeholder else { return command }
        guard trimmed.contains(AssistantCommandTemplate.placeholder) else {
            return trimmed + " " + command
        }
        return trimmed.replacingOccurrences(of: AssistantCommandTemplate.placeholder, with: command)
    }

    private func shellEscapeCommandArgument(_ value: String) -> String {
        let safeCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._:/@+-"))
        guard !value.isEmpty,
              value.unicodeScalars.allSatisfy({ safeCharacters.contains($0) }) else {
            return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        return value
    }
}
