import Foundation

/// One question to the orchestrator, with the board digest and the
/// exchanges before it.
public struct OrchestratorTurn: Sendable, Equatable {
    public var question: String
    public var answer: String

    public init(question: String, answer: String) {
        self.question = question
        self.answer = answer
    }
}

public enum OrchestratorPrompt {
    /// How many earlier exchanges go along with a question.
    public static let historyLimit = 6

    public static let system = """
        You are the orchestrator of Kanban Code, a board where each card is a coding agent \
        session. The human asks you about the state of the whole board: what is blocked, \
        what waits on them, what is moving, where each piece of work sits.

        Every prompt starts with a digest of the board, built just now from the app's state. \
        Trust it for columns, activity and pending questions. It holds only the cards the \
        human's board shows; `kanban list` also prints cards their filters hide, so leave \
        out any card that is not in the digest. To look closer at a card, run \
        these read-only commands with the Bash tool (pass the card id from the digest):
        - kanban show <card>
        - kanban transcript <card> -n 10
        - kanban capture <card>
        - kanban list --json / kanban status
        - kanban conversation list --card <card> / kanban conversation show <id> --card <card>
        Nothing else is allowed: you observe, you do not act on cards.

        Answer short and concrete. Name cards by their title. Lead with what needs the human. \
        Say what a blocked card waits on and what would unblock it. Use markdown lists.
        """

    /// The prompt for `question`: digest, recent exchanges, question.
    public static func build(digest: String, history: [OrchestratorTurn], question: String) -> String {
        var parts = ["<board-digest>\n\(digest)\n</board-digest>"]
        let recent = history.suffix(historyLimit)
        if !recent.isEmpty {
            let lines = recent.map { "Human: \($0.question)\n\nYou: \($0.answer)" }
            parts.append("<earlier-exchanges>\n\(lines.joined(separator: "\n\n---\n\n"))\n</earlier-exchanges>")
        }
        parts.append(question)
        return parts.joined(separator: "\n\n")
    }
}

/// Runs the orchestrator: a fresh, unsaved `claude -p` that gets the board
/// digest and may only run read-only `kanban` commands.
///
/// No session is resumed or written, so nothing shows on the board and no
/// context grows between questions: each one starts from a fresh digest
/// and the last few exchanges.
public final class ClaudeOrchestratorRunner: SideChatRunning, @unchecked Sendable {
    private let workDirectory: String
    private let executable: @Sendable () -> String?
    private let baseEnvironment: @Sendable () -> [String: String]
    public var timeout: TimeInterval = 600
    public var model: String?

    public init(kanbanHome: String? = nil,
                model: String? = nil,
                executable: (@Sendable () -> String?)? = nil,
                environment: (@Sendable () -> [String: String])? = nil) {
        let home = kanbanHome ?? (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code")
        self.workDirectory = (home as NSString).appendingPathComponent("orchestrator")
        self.model = model
        self.executable = executable ?? { ShellCommand.findExecutable(CodingAssistant.claude.cliCommand) }
        self.baseEnvironment = environment ?? { ShellCommand.loginEnvironment }
    }

    /// The `kanban` subcommands the orchestrator may run.
    public static let allowedCommands: [String] = [
        "show", "transcript", "capture", "list", "ls", "status", "sessions", "projects",
        "conversation list", "conversation show",
    ]

    /// PreToolUse hook: allows a Bash call only when it is one plain
    /// `kanban <allowed subcommand> ...` with no shell operators; refuses
    /// every other tool call. It holds even when the user's settings bypass
    /// permissions.
    public static var hookScript: String {
        let subcommands = allowedCommands.map { $0.replacingOccurrences(of: " ", with: "[[:space:]]+") }
            .joined(separator: "|")
        return """
            #!/bin/sh
            input=$(cat)
            deny() {
              printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\\n' "$1"
              exit 0
            }
            tool=$(printf '%s' "$input" | /usr/bin/plutil -extract tool_name raw -o - - 2>/dev/null)
            [ "$tool" = "Bash" ] || deny "The orchestrator only runs read-only kanban commands."
            cmd=$(printf '%s' "$input" | /usr/bin/plutil -extract tool_input.command raw -o - - 2>/dev/null)
            nl=$(printf '\\nx'); nl=${nl%x}
            case "$cmd" in
              *[\\;\\&\\|\\`\\$\\<\\>\\(\\)]*|*"$nl"*) deny "One plain kanban command, no shell operators." ;;
            esac
            if printf '%s' "$cmd" | /usr/bin/grep -Eq '^[[:space:]]*kanban[[:space:]]+(\(subcommands))([[:space:]]|$)'; then
              printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}\\n'
              exit 0
            fi
            deny "Allowed: kanban \(allowedCommands.joined(separator: ", ")). The orchestrator only observes."
            """
    }

    public static func settings(hookPath: String) -> String {
        let escaped = hookPath.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return #"{"hooks":{"PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"\#(escaped)"}]}]}}"#
    }

    public static func arguments(settingsPath: String, model: String?) -> [String] {
        var args = ["-p", "--no-session-persistence",
                    "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                    "--settings", settingsPath,
                    "--tools", "Bash",
                    "--strict-mcp-config",
                    "--append-system-prompt", OrchestratorPrompt.system]
        if let model, !model.isEmpty { args += ["--model", model] }
        return args
    }

    public func run(id: String, _ job: SideChatJob, onText: @escaping @Sendable (String) -> Void) async throws -> String {
        guard let claude = executable() else { throw SideChatFailed("Claude Code is not installed on this machine.") }
        try FileManager.default.createDirectory(atPath: workDirectory, withIntermediateDirectories: true)
        let folder = folder(id)
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let promptFile = folder + "/prompt.txt", outFile = folder + "/out.jsonl", errFile = folder + "/err.txt"
        let settingsFile = folder + "/settings.json", hookFile = folder + "/allow-kanban.sh", pidFile = folder + "/pid"
        try job.prompt.write(toFile: promptFile, atomically: true, encoding: .utf8)
        try Self.hookScript.write(toFile: hookFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookFile)
        try Self.settings(hookPath: hookFile).write(toFile: settingsFile, atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: outFile, contents: nil)

        let quote = RushCliAdapter.shellQuote
        let argv = ([claude] + Self.arguments(settingsPath: settingsFile, model: job.model ?? model))
            .map(quote).joined(separator: " ")
        let script = "echo $$ > \(quote(pidFile)); exec \(argv) < \(quote(promptFile)) > \(quote(outFile)) 2> \(quote(errFile))"
        let env = ClaudeSideChatRunner.environment(base: baseEnvironment(), configDirectory: job.configDirectory)
        let timeout = self.timeout
        let cwd = workDirectory

        let process = Task {
            try await ShellCommand.run("/bin/sh", arguments: ["-c", script], currentDirectory: cwd,
                                       environment: env, timeout: timeout)
        }
        let done = OrchestratorDoneFlag()
        Task {
            _ = await process.result
            done.set()
        }
        var stream = SideChatStream()
        var read = 0
        while true {
            let finished = done.isSet
            if let chunk = Self.read(outFile, from: read), !chunk.isEmpty {
                read += chunk.count
                if stream.consume(chunk) { onText(stream.text) }
            }
            if finished { break }
            if Task.isCancelled {
                await cancel(id: id)
                process.cancel()
                throw CancellationError()
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        let result = try? await process.value
        stream.finish()

        if let answer = stream.answer, !answer.isEmpty { return answer }
        let stderr = ((try? String(contentsOfFile: errFile, encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        throw SideChatFailed(stream.failure
            ?? stderr.split(separator: "\n").last.map(String.init)
            ?? result.map { "Claude Code exited with \($0.exitCode)." }
            ?? "Claude Code did not answer.")
    }

    public func cancel(id: String) async {
        let pidFile = folder(id) + "/pid"
        guard let text = try? String(contentsOfFile: pidFile, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else { return }
        kill(pid, SIGTERM)
    }

    private func folder(_ id: String) -> String {
        let safe = String(id.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" })
        return (workDirectory as NSString).appendingPathComponent("runs/" + safe)
    }

    private static func read(_ path: String, from offset: Int) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        try? handle.seek(toOffset: UInt64(offset))
        return try? handle.readToEnd()
    }
}

private final class OrchestratorDoneFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    var isSet: Bool { lock.withLock { done } }
    func set() { lock.withLock { done = true } }
}
