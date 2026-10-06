import Foundation
import KanbanCodeRemoteKit

/// What a side run needs: the session it reads and the prompt it answers.
public struct SideChatJob: Sendable, Equatable {
    public var sessionId: String
    /// The folder the session runs in; Claude Code finds a session by it.
    public var cwd: String
    public var prompt: String
    public var model: String?
    /// `CLAUDE_CONFIG_DIR` of the session, when it is not `~/.claude`.
    public var configDirectory: String?

    public init(sessionId: String, cwd: String, prompt: String, model: String? = nil, configDirectory: String? = nil) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.prompt = prompt
        self.model = model
        self.configDirectory = configDirectory
    }
}

public struct SideChatFailed: Error, LocalizedError, Sendable, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Answers a prompt from a session's context without writing into it.
public protocol SideChatRunning: Sendable {
    /// Runs `job`, reporting the answer so far as it grows, and returns the
    /// whole answer. `id` names the run for `cancel`.
    func run(id: String, _ job: SideChatJob, onText: @escaping @Sendable (String) -> Void) async throws -> String
    func cancel(id: String) async
}

/// A forked, unsaved run of the session's own Claude Code:
/// `claude -p --resume <session> --fork-session --no-session-persistence`.
///
/// The fork reads the session's transcript and writes none of its own, so
/// the main conversation is untouched and no stray session appears on the
/// board. It runs with the tools and the system prompt of the session (the
/// prompt cache of the session is reused), on the login the session uses,
/// and a hook refuses every tool call: a side chat only answers.
public final class ClaudeSideChatRunner: SideChatRunning, @unchecked Sendable {
    private let scratchDirectory: String
    private let executable: @Sendable () -> String?
    private let baseEnvironment: @Sendable () -> [String: String]
    public var timeout: TimeInterval = 600

    public init(kanbanHome: String? = nil,
                executable: (@Sendable () -> String?)? = nil,
                environment: (@Sendable () -> [String: String])? = nil) {
        let home = kanbanHome ?? (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code")
        self.scratchDirectory = (home as NSString).appendingPathComponent("tmp/side-chat")
        self.executable = executable ?? { ShellCommand.findExecutable(CodingAssistant.claude.cliCommand) }
        self.baseEnvironment = environment ?? { ShellCommand.loginEnvironment }
    }

    /// Set in the fork's environment; Kanban's hook script leaves a session
    /// that carries it out of the hook events.
    public static let environmentMarker = "KANBAN_SIDE_CHAT"

    /// Refuses every tool call of the fork. The tools stay listed, so the
    /// request shares the session's prompt cache.
    static let settings = """
        {"hooks":{"PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"echo '{\\"hookSpecificOutput\\":{\\"hookEventName\\":\\"PreToolUse\\",\\"permissionDecision\\":\\"deny\\",\\"permissionDecisionReason\\":\\"This is a side chat: no tools. Answer in text from what the conversation already holds.\\"}}'"}]}]}}
        """

    /// The fork's environment: the user's login environment, without the
    /// variables of a session the app may have been started from, and
    /// without an API key, so the run bills the logged-in plan.
    public static func environment(base: [String: String], configDirectory: String?) -> [String: String] {
        var env = base
        for name in InheritedSessionEnvironment.names { env[name] = nil }
        for name in InheritedSessionEnvironment.temporaryFolderNames {
            if let tmp = env[name], InheritedSessionEnvironment.isSessionFolder(tmp) { env[name] = nil }
        }
        env["ANTHROPIC_API_KEY"] = nil
        env["ANTHROPIC_AUTH_TOKEN"] = nil
        env[environmentMarker] = "1"
        if let configDirectory, !configDirectory.isEmpty {
            env["CLAUDE_CONFIG_DIR"] = configDirectory
        } else {
            env["CLAUDE_CONFIG_DIR"] = nil
        }
        return env
    }

    public static func arguments(job: SideChatJob, settingsPath: String) -> [String] {
        var args = ["-p", "--resume", job.sessionId, "--fork-session", "--no-session-persistence",
                    "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                    "--settings", settingsPath]
        if let model = job.model, !model.isEmpty { args += ["--model", model] }
        return args
    }

    public func run(id: String, _ job: SideChatJob, onText: @escaping @Sendable (String) -> Void) async throws -> String {
        guard let claude = executable() else { throw SideChatFailed("Claude Code is not installed on this machine.") }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: job.cwd, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw SideChatFailed("The session's folder is gone: \(job.cwd)")
        }
        let folder = folder(id)
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let promptFile = folder + "/prompt.txt", outFile = folder + "/out.jsonl", errFile = folder + "/err.txt"
        let settingsFile = folder + "/settings.json", pidFile = folder + "/pid"
        try job.prompt.write(toFile: promptFile, atomically: true, encoding: .utf8)
        try Self.settings.write(toFile: settingsFile, atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: outFile, contents: nil)

        let quote = RushCliAdapter.shellQuote
        let argv = ([claude] + Self.arguments(job: job, settingsPath: settingsFile)).map(quote).joined(separator: " ")
        // The shell becomes Claude Code, so the pid written is the one to stop.
        let script = "echo $$ > \(quote(pidFile)); exec \(argv) < \(quote(promptFile)) > \(quote(outFile)) 2> \(quote(errFile))"
        let env = Self.environment(base: baseEnvironment(), configDirectory: job.configDirectory)
        let timeout = self.timeout

        let process = Task {
            try await ShellCommand.run("/bin/sh", arguments: ["-c", script], currentDirectory: job.cwd,
                                       environment: env, timeout: timeout)
        }
        // The output file is read as it grows: the answer streams.
        var stream = SideChatStream()
        var read = 0
        var result: ShellCommand.Result?
        let done = SideChatDoneFlag()
        Task {
            _ = await process.result
            done.set()
        }
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
        result = try? await process.value
        stream.finish()

        if let answer = stream.answer, !answer.isEmpty { return answer }
        let stderr = ((try? String(contentsOfFile: errFile, encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = stream.failure
            ?? stderr.split(separator: "\n").last.map(String.init)
            ?? result.map { "Claude Code exited with \($0.exitCode)." }
            ?? "Claude Code did not answer."
        throw SideChatFailed(reason)
    }

    public func cancel(id: String) async {
        let pidFile = folder(id) + "/pid"
        guard let text = try? String(contentsOfFile: pidFile, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else { return }
        kill(pid, SIGTERM)
    }

    private func folder(_ id: String) -> String {
        let safe = String(id.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" })
        return (scratchDirectory as NSString).appendingPathComponent(safe)
    }

    private static func read(_ path: String, from offset: Int) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        try? handle.seek(toOffset: UInt64(offset))
        return try? handle.readToEnd()
    }
}

private final class SideChatDoneFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    var isSet: Bool { lock.withLock { done } }
    func set() { lock.withLock { done = true } }
}

/// Reads Claude Code's `stream-json` output as it arrives: the text of the
/// answer so far, and the result once the run ends.
public struct SideChatStream: Sendable {
    private var buffer = Data()
    /// Text of the assistant messages finished so far.
    private var settled = ""
    /// Text of the message still streaming.
    private var current = ""
    private var result: String?
    public private(set) var failure: String?

    public init() {}

    /// The answer so far.
    public var text: String { settled + current }

    /// The whole answer once the run ended: the text streamed, or the
    /// result record's when nothing streamed.
    public var answer: String? {
        let streamed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !streamed.isEmpty { return streamed }
        return result?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Takes more output; true when the answer grew.
    public mutating func consume(_ chunk: Data) -> Bool {
        buffer.append(chunk)
        var changed = false
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer = buffer[buffer.index(after: newline)...]
            if consume(line: Data(line)) { changed = true }
        }
        return changed
    }

    /// Reads what is left after the last newline.
    public mutating func finish() {
        guard !buffer.isEmpty else { return }
        _ = consume(line: Data(buffer))
        buffer = Data()
    }

    private mutating func consume(line: Data) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = object["type"] as? String else { return false }
        switch type {
        case "stream_event":
            guard object["parent_tool_use_id"] == nil || object["parent_tool_use_id"] is NSNull,
                  let event = object["event"] as? [String: Any], let kind = event["type"] as? String else { return false }
            if kind == "content_block_delta", let delta = event["delta"] as? [String: Any],
               delta["type"] as? String == "text_delta", let text = delta["text"] as? String, !text.isEmpty {
                current += text
                return true
            }
            if kind == "message_stop", !current.isEmpty {
                settled += current + "\n\n"
                current = ""
            }
            return false
        case "assistant":
            // Without partial messages the whole message arrives at once.
            guard current.isEmpty, object["parent_tool_use_id"] == nil || object["parent_tool_use_id"] is NSNull,
                  let message = object["message"] as? [String: Any],
                  let blocks = message["content"] as? [[String: Any]] else { return false }
            let text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
            guard !text.isEmpty, !settled.hasSuffix(text + "\n\n") else { return false }
            settled += text + "\n\n"
            return true
        case "result":
            if object["is_error"] as? Bool == true {
                failure = (object["result"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? (object["subtype"] as? String).map { "Claude Code stopped: \($0)" }
            } else {
                result = object["result"] as? String
            }
            return false
        default:
            return false
        }
    }
}

/// The side chat runs of this master: started, read while they stream, and
/// kept a while after they end for a client that polls late.
public actor SideChatService {
    private let runner: any SideChatRunning
    private var runs: [String: RemoteSideChatRun] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var endedAt: [String: Date] = [:]
    /// How long an ended run is kept.
    public static let retention: TimeInterval = 15 * 60

    public init(runner: any SideChatRunning) {
        self.runner = runner
    }

    /// Starts the run and returns it at once, still running. `onDone`
    /// gets the run once it ended with an answer.
    public func start(
        cardId: String,
        kind: RemoteSideChatKind,
        since: RemoteSideChatSince? = nil,
        refs: [RemoteSideChatRef]? = nil,
        job: SideChatJob,
        onDone: (@Sendable (RemoteSideChatRun) -> Void)? = nil
    ) -> RemoteSideChatRun {
        prune()
        let id = "side_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(16)
        let run = RemoteSideChatRun(id: id, cardId: cardId, kind: kind, since: since, refs: refs)
        runs[id] = run
        let runner = self.runner
        tasks[id] = Task { [service = self] in
            do {
                let answer = try await runner.run(id: id, job) { text in
                    Task { await service.progress(id, text) }
                }
                if let done = await service.finish(id, answer: answer, error: nil) { onDone?(done) }
            } catch is CancellationError {
                await service.finish(id, answer: nil, error: "Cancelled.")
            } catch {
                await service.finish(id, answer: nil, error: error.localizedDescription)
            }
        }
        return run
    }

    public func run(id: String) -> RemoteSideChatRun? { runs[id] }

    public func cancel(id: String) async {
        tasks[id]?.cancel()
        await runner.cancel(id: id)
        runs[id] = nil
        tasks[id] = nil
        endedAt[id] = nil
    }

    private func progress(_ id: String, _ text: String) {
        guard var run = runs[id], run.state == .running, text.count >= run.text.count else { return }
        run.text = text
        runs[id] = run
    }

    /// Ends the run and returns it when it ended with an answer.
    @discardableResult
    private func finish(_ id: String, answer: String?, error: String?) -> RemoteSideChatRun? {
        guard var run = runs[id] else { return nil }
        run.finishedAt = .now
        if let answer {
            run.text = answer
            run.state = .done
        } else {
            run.state = .failed
            run.error = error
        }
        runs[id] = run
        tasks[id] = nil
        endedAt[id] = .now
        return run.state == .done ? run : nil
    }

    private func prune() {
        let cutoff = Date.now.addingTimeInterval(-Self.retention)
        for (id, at) in endedAt where at < cutoff {
            runs[id] = nil
            endedAt[id] = nil
        }
    }
}
