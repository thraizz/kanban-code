import Foundation

/// Decides whether a card's session runs on rush, and builds the
/// `rush session start` request for it.
public enum RushLaunchPlanner {
    /// Why a card set to rush still runs on tmux, or nil when it runs on rush.
    public enum Fallback: Equatable, Sendable {
        case notClaude
        case remote
        case commandOverride
        case modelVariantOverride
        case notInstalled

        public var reason: String {
            switch self {
            case .notClaude: "cards run only Claude Code on rush"
            case .remote: "remote cards run on tmux"
            case .commandOverride: "a custom command runs on tmux"
            case .modelVariantOverride: "a model variant runs on tmux"
            case .notInstalled: "rush is not installed"
            }
        }
    }

    public enum Choice: Equatable, Sendable {
        case tmux
        case rush
        /// The card is set to rush but runs on tmux.
        case fallback(Fallback)
    }

    public static func choose(
        assistant: CodingAssistant,
        runtime: SessionRuntime,
        remote: Bool,
        commandOverride: String?,
        hasModelVariantOverride: Bool = false,
        rushInstalled: Bool
    ) -> Choice {
        guard runtime == .rush else { return .tmux }
        if assistant != .claude { return .fallback(.notClaude) }
        if remote { return .fallback(.remote) }
        if hasModelVariantOverride { return .fallback(.modelVariantOverride) }
        if let commandOverride, !commandOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .fallback(.commandOverride)
        }
        if !rushInstalled { return .fallback(.notInstalled) }
        return .rush
    }

    /// The command rush runs in place of `claude`, or nil when plain
    /// `claude` does. A command template or an API service launcher wraps
    /// the CLI, so rush gets a script that runs the wrapped command with
    /// rush's own arguments appended.
    public static func wrapperCommand(template: String?, service: APIService?) -> String? {
        var parts: [String] = []
        if let launcher = service?.launcherPrefix { parts.append(launcher) }
        parts.append(CodingAssistant.claude.cliCommand)
        if service?.launcherPrefix != nil { parts.append("--") }
        let bare = parts.joined(separator: " ")
        let wrapped = CodingAssistant.applyCommandTemplate(bare, template: template)
        return wrapped == CodingAssistant.claude.cliCommand ? nil : wrapped
    }

    /// What rush runs in place of `claude`: the wrapper script when there
    /// is one, else the absolute path of `claude` on this machine, so a host
    /// that rush restarts later from a process with a bare PATH still finds
    /// it. Nil when the host runs on another machine or `claude` is not
    /// found here; rush then looks `claude` up on its own PATH.
    public static func binary(
        wrapper: String?,
        remote: Bool,
        findExecutable: (String) -> String?
    ) -> String? {
        if let wrapper { return wrapper }
        guard !remote else { return nil }
        return findExecutable(CodingAssistant.claude.cliCommand)
    }

    /// A shell script that runs `command` with the arguments it is given.
    public static func wrapperScript(command: String) -> String {
        "#!/bin/sh\nexec \(command) \"$@\"\n"
    }

    /// Environment the hosted Claude gets. `KANBAN_CARD_ID` tells the
    /// kanban CLI inside the session which card it runs in.
    public static func environment(cardId: String, extraEnv: [String: String]) -> [String: String] {
        var env = extraEnv
        env["KANBAN_CARD_ID"] = cardId
        return env
    }

    public static func request(
        cardId: String,
        cwd: String,
        sessionId: String,
        resume: Bool,
        name: String?,
        prompt: String?,
        imagePaths: [String],
        extraEnv: [String: String],
        skipPermissions: Bool,
        model: String?,
        binary: String?
    ) -> RushStartRequest {
        RushStartRequest(
            cwd: cwd,
            sessionId: sessionId,
            resume: resume,
            name: name,
            prompt: prompt,
            imagePaths: imagePaths,
            env: environment(cardId: cardId, extraEnv: extraEnv),
            model: model,
            permissionMode: skipPermissions ? "bypassPermissions" : nil,
            binary: binary,
            meta: ["kanban_card": cardId, RushSessionName.metaKey: RushSessionName.name(sessionId: sessionId)]
        )
    }
}
