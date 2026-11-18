import Foundation

/// One tool call the orchestrator made while answering, as the chat shows it.
public struct OrchestratorStep: Sendable, Equatable, Codable {
    public var tool: String
    public var summary: String

    public init(tool: String, summary: String) {
        self.tool = tool
        self.summary = summary
    }
}

/// One question to the orchestrator and its answer.
public struct OrchestratorTurn: Sendable, Equatable, Codable, Identifiable {
    public var id: String
    public var question: String
    public var answer: String
    public var steps: [OrchestratorStep]
    public var askedAt: Date
    /// Why the run ended without an answer, when it did.
    public var error: String?

    public init(id: String = UUID().uuidString, question: String, answer: String,
                steps: [OrchestratorStep] = [], askedAt: Date = Date(), error: String? = nil) {
        self.id = id
        self.question = question
        self.answer = answer
        self.steps = steps
        self.askedAt = askedAt
        self.error = error
    }
}

public enum OrchestratorPrompt {
    /// How many earlier exchanges go along when a chat has to start a new
    /// session (its old one could not be resumed).
    public static let historyLimit = 6

    public static let system = """
        You are the orchestrator of Kanban Code, a board where each card is a coding agent \
        session (Claude Code, Codex, Gemini), in tmux or on another machine. The human asks \
        you about their work across every card and every Claude Code session on this Mac, \
        and asks you to act on it. You are their hands on the board: find things, read \
        sessions, and steer them.

        Every message starts with a <board-digest>, built just now from the app's state: the \
        cards the human's board shows, with columns, activity and pending questions. It is \
        what is on the board now, not the limit of what you may look at. Archived cards, \
        cards the board's filters hide, and Claude Code sessions that never became a card \
        (started from the plain `claude` CLI) all count. Look for them when the question \
        needs it.

        Finding where something was said:
        - `kanban search <words>` reads every Claude Code transcript on this Mac (with or \
        without a card, archived cards too) and prints sessions with their card (or "no \
        card"), folder, branch and matching lines with timestamps. Default window is 30 days; \
        use `--days 0` for all time, `--role user` for the human's own prompts, `--json` for \
        detail. Try several wordings and synonyms before saying something is not there.
        - Transcripts are JSONL files in ~/.claude/projects/<folder>/<session-id>.jsonl. Use \
        Grep/Glob/Read on them when search is not enough (pasted images show as \
        "[Image #N]" in the prompt text).
        - `kanban show <card>`, `kanban transcript <card> -n 40`, `kanban capture <card>`, \
        `kanban export <card or session id>` (a whole session as Markdown; pipe through grep \
        or write it to a file and Read it), `kanban list --all --json`, `kanban status`.

        Acting:
        - `kanban send <card> "<text>"` prompts a card's running session; `kanban \
        interrupt <card>` stops its turn; `kanban open <card>` shows it in the app.
        - `kanban relink <card> <session-id>` points a card at another session, e.g. to put \
        a session that has no card on the board.
        - A Claude Code session without a card: to ask it something without changing it, \
        run `claude -p --resume <id> --fork-session --no-session-persistence "<question>"` \
        from its folder. To continue it for real, run `env -u KANBAN_SIDE_CHAT claude -p \
        --resume <id> "<prompt>"` from its folder, or tell the human `claude --resume <id>`.
        - Cards on another machine: see `kanban show <card>` for the machine, and `kanban \
        remote --help`.
        - `kanban --help` lists everything else (launch, subagent, archive, …).
        Do what the human asks. Before a step that changes a session or card they did not \
        ask for, ask first. Never edit code yourself: send the work to the card that owns \
        it. Some commands are refused (git writes, rm -r, killing processes, links.json \
        edits, the vault).

        Answer like a chat: short and concrete, markdown lists. Name cards by title and \
        give the card or session id when the human may act on it. Lead with what needs the \
        human. When you could not find something, say what you searched.
        """

    /// The message for a question in a running chat: a fresh digest and the question.
    public static func turn(digest: String, question: String) -> String {
        "<board-digest>\n\(digest)\n</board-digest>\n\n\(question)"
    }

    /// The first message of a new session for a chat that already has
    /// exchanges: digest, recent exchanges, question.
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

/// One question to run.
public struct OrchestratorJob: Sendable, Equatable {
    /// The chat's Claude Code session.
    public var sessionId: String
    /// True when the session already exists and is continued.
    public var resume: Bool
    public var prompt: String
    public var model: String?

    public init(sessionId: String, resume: Bool, prompt: String, model: String? = nil) {
        self.sessionId = sessionId
        self.resume = resume
        self.prompt = prompt
        self.model = model
    }
}

public struct OrchestratorProgress: Sendable, Equatable {
    public var text: String
    public var steps: [OrchestratorStep]
}

public struct OrchestratorResult: Sendable, Equatable {
    public var answer: String
    public var steps: [OrchestratorStep]
}

/// Reads the run's stream-json: the answer text as it streams, and each
/// tool call as a step.
public struct OrchestratorStream: Sendable {
    private var text = SideChatStream()
    private var buffer = Data()
    private var seenTools: Set<String> = []
    public private(set) var steps: [OrchestratorStep] = []

    public init() {}

    public var answerSoFar: String { text.text }
    public var answer: String? { text.answer }
    public var failure: String? { text.failure }

    /// Takes more output; true when the text or the steps changed.
    public mutating func consume(_ chunk: Data) -> Bool {
        var changed = text.consume(chunk)
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[buffer.startIndex..<newline])
            buffer = buffer[buffer.index(after: newline)...]
            if consumeSteps(line) { changed = true }
        }
        return changed
    }

    public mutating func finish() {
        text.finish()
        if !buffer.isEmpty { _ = consumeSteps(Data(buffer)) }
        buffer = Data()
    }

    private mutating func consumeSteps(_ line: Data) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              object["type"] as? String == "assistant",
              object["parent_tool_use_id"] == nil || object["parent_tool_use_id"] is NSNull,
              let message = object["message"] as? [String: Any],
              let blocks = message["content"] as? [[String: Any]] else { return false }
        var changed = false
        for block in blocks where block["type"] as? String == "tool_use" {
            let id = block["id"] as? String ?? UUID().uuidString
            guard seenTools.insert(id).inserted else { continue }
            let name = block["name"] as? String ?? "Tool"
            steps.append(OrchestratorStep(tool: name, summary: Self.summary(tool: name, input: block["input"] as? [String: Any] ?? [:])))
            changed = true
        }
        return changed
    }

    static func summary(tool: String, input: [String: Any]) -> String {
        func string(_ key: String) -> String? {
            (input[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        let text: String
        switch tool {
        case "Bash": text = string("command") ?? string("description") ?? ""
        case "Read": text = string("file_path") ?? ""
        case "Grep": text = [string("pattern"), string("path").map { "in \($0)" }].compactMap { $0 }.joined(separator: " ")
        case "Glob": text = string("pattern") ?? ""
        default: text = input.keys.sorted().first.flatMap { string($0) } ?? ""
        }
        let line = text.split(separator: "\n").first.map(String.init) ?? ""
        let home = NSHomeDirectory()
        let short = line.replacingOccurrences(of: home, with: "~")
        return short.count > 160 ? String(short.prefix(159)) + "…" : short
    }
}

/// Runs the orchestrator: `claude -p` in ~/.kanban-code/orchestrator, one
/// real session per chat (continued with `--resume`, so later questions
/// keep what earlier ones read), with Bash, Read, Grep and Glob. A hook
/// refuses the few commands that could do lasting damage.
///
/// Each run keeps its prompt, stream and stderr in
/// `~/.kanban-code/orchestrator/runs/<id>/` (the newest `keptRuns`), and
/// logs an `[orchestrator]` line.
public final class ClaudeOrchestratorRunner: @unchecked Sendable {
    public let workDirectory: String
    private let executable: @Sendable () -> String?
    private let baseEnvironment: @Sendable () -> [String: String]
    public var timeout: TimeInterval = 1800
    public var model: String?
    public static let keptRuns = 40

    public init(kanbanHome: String? = nil,
                model: String? = nil,
                executable: (@Sendable () -> String?)? = nil,
                environment: (@Sendable () -> [String: String])? = nil) {
        let home = kanbanHome ?? (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code")
        self.workDirectory = Self.workDirectory(kanbanHome: home)
        self.model = model
        self.executable = executable ?? { ShellCommand.findExecutable(CodingAssistant.claude.cliCommand) }
        self.baseEnvironment = environment ?? { ShellCommand.loginEnvironment }
    }

    public static func workDirectory(kanbanHome: String) -> String {
        (kanbanHome as NSString).appendingPathComponent("orchestrator")
    }

    /// Claude Code's project directory for the orchestrator's sessions.
    /// Session discovery skips it, so chats never become cards.
    public static var claudeProjectDirName: String {
        let dir = workDirectory(kanbanHome: (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code"))
        return PathExclusion.claudeProjectDirName(dir)
    }

    public static let tools = ["Bash", "Read", "Grep", "Glob"]

    /// Bash commands the hook refuses, as extended regular expressions.
    static let refusedCommands: [(pattern: String, reason: String)] = [
        ("tmux[[:space:]]+kill-server", "tmux kill-server takes down every card's session."),
        ("(^|[^-[:alnum:]])(kill|pkill|killall)[[:space:]]", "No killing processes; use kanban interrupt."),
        ("(^|[^-[:alnum:]])sudo[[:space:]]", "No sudo."),
        ("(^|[^-[:alnum:]])rm[[:space:]]+(-[[:alnum:]]*[rR]|--recursive)", "No recursive deletes."),
        ("git[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?(push|commit|reset|clean|stash|checkout|switch|rebase|merge|restore|cherry-pick|am|apply)([[:space:]]|$)",
         "No git writes: send the work to the card that owns the repository."),
        ("(^|[^-[:alnum:]])(kanban[[:space:]]+vault|kv)([[:space:]]|$)", "The vault is off limits."),
    ]

    /// PreToolUse hook: allows Read, Grep, Glob and Bash, except the Bash
    /// commands in `refusedCommands` and writes to links.json. It holds
    /// whatever the user's own permission settings say.
    public static var hookScript: String {
        let checks = refusedCommands.map { rule in
            "printf '%s' \"$cmd\" | /usr/bin/grep -Eq '\(rule.pattern)' && deny \"\(rule.reason)\""
        }.joined(separator: "\n")
        return """
            #!/bin/sh
            input=$(cat)
            deny() {
              printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\\n' "$1"
              exit 0
            }
            allow() {
              printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}\\n'
              exit 0
            }
            tool=$(printf '%s' "$input" | /usr/bin/plutil -extract tool_name raw -o - - 2>/dev/null)
            case "$tool" in
              Read|Grep|Glob) allow ;;
              Bash) ;;
              *) deny "The orchestrator has Bash, Read, Grep and Glob." ;;
            esac
            cmd=$(printf '%s' "$input" | /usr/bin/plutil -extract tool_input.command raw -o - - 2>/dev/null)
            \(checks)
            if printf '%s' "$cmd" | /usr/bin/grep -q 'links[.]json'; then
              printf '%s' "$cmd" | /usr/bin/grep -Eq '>|tee|sed[[:space:]]+-i|(^|[[:space:]])(mv|cp|rm)[[:space:]]|write|dump' \\
                && deny "links.json changes only through kanban commands."
            fi
            allow
            """
    }

    public static func settings(hookPath: String) -> String {
        let escaped = hookPath.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return #"{"hooks":{"PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"\#(escaped)"}]}]}}"#
    }

    public static func arguments(job: OrchestratorJob, settingsPath: String, model: String?) -> [String] {
        var args = ["-p"]
        args += job.resume ? ["--resume", job.sessionId] : ["--session-id", job.sessionId]
        args += ["--output-format", "stream-json", "--verbose", "--include-partial-messages",
                 "--settings", settingsPath,
                 "--tools", tools.joined(separator: ","),
                 "--strict-mcp-config",
                 "--append-system-prompt", OrchestratorPrompt.system]
        if let model, !model.isEmpty { args += ["--model", model] }
        return args
    }

    /// A run id that sorts by time: `20261118-120102-1a2b3c`.
    public static func newRunId(now: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: now) + "-" + UUID().uuidString.lowercased().prefix(6)
    }

    public func run(id: String, _ job: OrchestratorJob,
                    onProgress: @escaping @Sendable (OrchestratorProgress) -> Void) async throws -> OrchestratorResult {
        guard let claude = executable() else { throw SideChatFailed("Claude Code is not installed on this machine.") }
        try FileManager.default.createDirectory(atPath: workDirectory, withIntermediateDirectories: true)
        let folder = folder(id)
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        pruneRuns()
        let promptFile = folder + "/prompt.txt", outFile = folder + "/out.jsonl", errFile = folder + "/err.txt"
        let settingsFile = folder + "/settings.json", hookFile = folder + "/hook.sh", pidFile = folder + "/pid"
        try job.prompt.write(toFile: promptFile, atomically: true, encoding: .utf8)
        try Self.hookScript.write(toFile: hookFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookFile)
        try Self.settings(hookPath: hookFile).write(toFile: settingsFile, atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: outFile, contents: nil)

        let quote = RushCliAdapter.shellQuote
        let argv = ([claude] + Self.arguments(job: job, settingsPath: settingsFile, model: job.model ?? model))
            .map(quote).joined(separator: " ")
        let script = "echo $$ > \(quote(pidFile)); exec \(argv) < \(quote(promptFile)) > \(quote(outFile)) 2> \(quote(errFile))"
        let env = ClaudeSideChatRunner.environment(base: baseEnvironment(), configDirectory: nil)
        let timeout = self.timeout
        let cwd = workDirectory
        let started = Date()
        KanbanCodeLog.info("orchestrator", "run=\(id) session=\(job.sessionId.prefix(8)) resume=\(job.resume) prompt=\(job.prompt.count)ch")

        let process = Task {
            try await ShellCommand.run("/bin/sh", arguments: ["-c", script], currentDirectory: cwd,
                                       environment: env, timeout: timeout)
        }
        let done = OrchestratorDoneFlag()
        Task {
            _ = await process.result
            done.set()
        }
        var stream = OrchestratorStream()
        var read = 0
        while true {
            let finished = done.isSet
            if let chunk = Self.read(outFile, from: read), !chunk.isEmpty {
                read += chunk.count
                if stream.consume(chunk) {
                    onProgress(OrchestratorProgress(text: stream.answerSoFar, steps: stream.steps))
                }
            }
            if finished { break }
            if Task.isCancelled {
                await cancel(id: id)
                process.cancel()
                KanbanCodeLog.info("orchestrator", "run=\(id) stopped steps=\(stream.steps.count)")
                throw CancellationError()
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        let result = try? await process.value
        stream.finish()
        let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
        let tools = Dictionary(grouping: stream.steps, by: \.tool).map { "\($0.key)×\($0.value.count)" }.sorted()
            .joined(separator: ",")

        if let answer = stream.answer, !answer.isEmpty {
            KanbanCodeLog.info("orchestrator", "run=\(id) ok seconds=\(seconds) steps=\(stream.steps.count) tools=\(tools) answer=\(answer.count)ch")
            return OrchestratorResult(answer: answer, steps: stream.steps)
        }
        let stderr = ((try? String(contentsOfFile: errFile, encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = stream.failure
            ?? stderr.split(separator: "\n").last.map(String.init)
            ?? result.map { "Claude Code exited with \($0.exitCode)." }
            ?? "Claude Code did not answer."
        KanbanCodeLog.warn("orchestrator", "run=\(id) failed seconds=\(seconds) steps=\(stream.steps.count) reason=\(reason)")
        throw SideChatFailed(reason)
    }

    public func cancel(id: String) async {
        let pidFile = folder(id) + "/pid"
        guard let text = try? String(contentsOfFile: pidFile, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else { return }
        kill(pid, SIGTERM)
    }

    public var runsDirectory: String { (workDirectory as NSString).appendingPathComponent("runs") }

    private func folder(_ id: String) -> String {
        let safe = String(id.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" })
        return (runsDirectory as NSString).appendingPathComponent(safe)
    }

    /// Keeps the newest `keptRuns` run folders (ids sort by time).
    private func pruneRuns() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: runsDirectory) else { return }
        let old = names.filter { !$0.hasPrefix(".") }.sorted().dropLast(Self.keptRuns)
        for name in old { try? fm.removeItem(atPath: (runsDirectory as NSString).appendingPathComponent(name)) }
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
