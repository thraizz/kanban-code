import Foundation

/// Decides whether a card's session runs on agtop, and builds the
/// `agtop session start` request for it.
public enum AgtopLaunchPlanner {
    /// Why a card set to agtop still runs on tmux, or nil when it runs on agtop.
    public enum Fallback: Equatable, Sendable {
        case notClaude
        case remote
        case commandOverride
        case notInstalled

        public var reason: String {
            switch self {
            case .notClaude: "cards run only Claude Code on rush"
            case .remote: "remote cards run on tmux"
            case .commandOverride: "a custom command runs on tmux"
            case .notInstalled: "rush is not installed"
            }
        }
    }

    public enum Choice: Equatable, Sendable {
        case tmux
        case agtop
        /// The card is set to agtop but runs on tmux.
        case fallback(Fallback)
    }

    public static func choose(
        assistant: CodingAssistant,
        runtime: SessionRuntime,
        remote: Bool,
        commandOverride: String?,
        agtopInstalled: Bool
    ) -> Choice {
        guard runtime == .agtop else { return .tmux }
        if assistant != .claude { return .fallback(.notClaude) }
        if remote { return .fallback(.remote) }
        if let commandOverride, !commandOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .fallback(.commandOverride)
        }
        if !agtopInstalled { return .fallback(.notInstalled) }
        return .agtop
    }

    /// The command agtop runs in place of `claude`, or nil when plain
    /// `claude` does. A command template or an API service launcher wraps
    /// the CLI, so agtop gets a script that runs the wrapped command with
    /// agtop's own arguments appended.
    public static func wrapperCommand(template: String?, service: APIService?) -> String? {
        var parts: [String] = []
        if let launcher = service?.launcherPrefix { parts.append(launcher) }
        parts.append(CodingAssistant.claude.cliCommand)
        if service?.launcherPrefix != nil { parts.append("--") }
        let bare = parts.joined(separator: " ")
        let wrapped = CodingAssistant.applyCommandTemplate(bare, template: template)
        return wrapped == CodingAssistant.claude.cliCommand ? nil : wrapped
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
    ) -> AgtopStartRequest {
        AgtopStartRequest(
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
            meta: ["kanban_card": cardId]
        )
    }
}
