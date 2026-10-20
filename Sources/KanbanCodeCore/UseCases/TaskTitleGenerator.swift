import Foundation

/// Writes a short card title from a task's prompt with a small, fast model.
///
/// Asks OpenRouter when a key is at hand (`OPENROUTER_API_KEY` in the login
/// environment, or the key opencode keeps in its `auth.json`), and otherwise
/// a one-shot `claude -p` on Haiku that bills the logged-in plan.
public enum TaskTitleGenerator {

    public enum GenerationError: Error, LocalizedError {
        case emptyPrompt
        case noBackend
        case request(String)
        case emptyTitle

        public var errorDescription: String? {
            switch self {
            case .emptyPrompt: "The task has no prompt to title."
            case .noBackend: "No OpenRouter key and no claude CLI to generate a title with."
            case .request(let detail): "Title generation failed: \(detail)"
            case .emptyTitle: "The model returned no title."
            }
        }
    }

    public static let openRouterModel = "anthropic/claude-haiku-5.5"
    static let claudeModel = "haiku"
    /// Enough of a prompt to know what it is about; long pasted logs add cost, not meaning.
    static let maxPromptCharacters = 4000
    static let maxTitleCharacters = 80

    static let instructions = """
        You write titles for tasks on a kanban board of coding tasks. \
        Given a task prompt, reply with a short, specific title of 3 to 7 words \
        in the language of the prompt, in sentence case. Reply with the title only: \
        no quotes, no markdown, no trailing period.
        """

    public static func generate(prompt: String) async throws -> String {
        let task = String(InjectedPromptText.strip(prompt)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(maxPromptCharacters))
        guard !task.isEmpty else { throw GenerationError.emptyPrompt }

        let raw: String
        if let key = openRouterKey() {
            raw = try await askOpenRouter(task: task, key: key)
        } else if let claude = ShellCommand.findExecutable(CodingAssistant.claude.cliCommand) {
            raw = try await askClaude(task: task, executable: claude)
        } else {
            throw GenerationError.noBackend
        }
        let title = clean(raw)
        guard !title.isEmpty else { throw GenerationError.emptyTitle }
        return title
    }

    /// The model's reply as a card title: its first line, without the quotes,
    /// markdown and trailing period models add despite being told not to.
    static func clean(_ reply: String) -> String {
        var title = reply
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        for prefix in ["Title:", "title:", "#"] where title.hasPrefix(prefix) {
            title = String(title.dropFirst(prefix.count))
        }
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`*_“”‘’ "))
        while title.hasSuffix(".") { title.removeLast() }
        if title.count > maxTitleCharacters {
            title = String(title.prefix(maxTitleCharacters)).trimmingCharacters(in: .whitespaces)
        }
        return title
    }

    // MARK: - OpenRouter

    static func openRouterKey(
        environment: [String: String] = ShellCommand.loginEnvironment,
        opencodeAuthPath: String = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".local/share/opencode/auth.json")
    ) -> String? {
        if let key = environment["OPENROUTER_API_KEY"], !key.isEmpty { return key }
        guard let data = FileManager.default.contents(atPath: opencodeAuthPath),
              let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = auth["openrouter"] as? [String: Any],
              let key = entry["key"] as? String, !key.isEmpty else { return nil }
        return key
    }

    private static func askOpenRouter(task: String, key: String) async throws -> String {
        guard let url = URL(string: "https://openrouter.ai/api/v1/chat/completions") else {
            throw GenerationError.request("bad URL")
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Kanban Code", forHTTPHeaderField: "X-Title")
        let body: [String: Any] = [
            "model": openRouterModel,
            "max_tokens": 40,
            "messages": [
                ["role": "system", "content": instructions],
                ["role": "user", "content": task],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let message = (json?["error"] as? [String: Any])?["message"] as? String
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw GenerationError.request("OpenRouter \(status)\(message.map { ": \($0)" } ?? "")")
        }
        guard let choices = json?["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw GenerationError.emptyTitle
        }
        return content
    }

    // MARK: - Claude CLI

    private static func askClaude(task: String, executable: String) async throws -> String {
        // Same environment as a side chat: no API key, and marked so the
        // hook leaves this run out of the board's events.
        let env = ClaudeSideChatRunner.environment(base: ShellCommand.loginEnvironment, configDirectory: nil)
        let result = try await ShellCommand.run(
            executable,
            arguments: [
                "-p", "--model", claudeModel, "--no-session-persistence",
                "--tools", "", "--system-prompt", instructions,
            ],
            currentDirectory: NSTemporaryDirectory(),
            stdin: task,
            environment: env,
            timeout: 60
        )
        guard result.succeeded else {
            throw GenerationError.request(result.stderr.isEmpty ? "claude exited \(result.exitCode)" : result.stderr)
        }
        return result.stdout
    }
}
