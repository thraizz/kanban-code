import Foundation

/// Parses tmux capture-pane output to detect coding assistant state.
public enum PaneOutputParser {

    /// Count image attachments visible in Claude Code's TUI.
    /// Only counts lines containing `[Image` that also have context like "to select" or "to remove",
    /// to avoid false positives from user-typed text.
    public static func countImages(in paneOutput: String) -> Int {
        // Count actual [Image #N] occurrences, not lines — multiple images can appear on one line
        var count = 0
        var searchRange = paneOutput.startIndex..<paneOutput.endIndex
        while let range = paneOutput.range(of: "[Image #", range: searchRange) {
            count += 1
            searchRange = range.upperBound..<paneOutput.endIndex
        }
        return count
    }

    /// Check if the assistant's input prompt is visible (ready for input).
    public static func isReady(_ paneOutput: String, assistant: CodingAssistant) -> Bool {
        switch assistant {
        case .claude, .gemini:
            return paneOutput.contains(assistant.promptCharacter)
        case .codex:
            // Codex also prefixes historical user turns with `› text`; only a
            // prompt in the bottom input area means it is idle/ready. Current
            // no-alt-screen Codex can render that input as either bare `›` or
            // with a placeholder/suggestion like `› Implement {feature}`.
            let lines = paneOutput
                .components(separatedBy: .newlines)
                .suffix(12)
                .map { stripAnsi($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            if lines.contains(where: { $0.hasPrefix("• Working") }) {
                return false
            }
            if lines.contains(assistant.promptCharacter) {
                return true
            }
            guard let promptIndex = lines.lastIndex(where: { $0.hasPrefix("\(assistant.promptCharacter) ") }) else {
                return false
            }
            let footerLines = lines.dropFirst(promptIndex + 1)
            return footerLines.contains { line in
                line.contains(" · ") && line.localizedCaseInsensitiveContains("gpt-")
            }
        case .opencode:
            // OpenCode's full-screen TUI draws its footer ("ctrl+p commands",
            // wrapped or not) only once the input box takes keys; before that
            // the pane is blank or the logo, and a prompt sent then is lost.
            // While it works the footer shows "esc interrupt", and a
            // permission request replaces the input with its own dialog.
            let lines = paneOutput
                .components(separatedBy: .newlines)
                .map { stripAnsi($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .suffix(16)
            if lines.contains(where: { $0.contains("esc interrupt") || $0.contains("Permission required") }) {
                return false
            }
            return lines.contains { $0.contains("ctrl+p") || $0.contains("Ask anything") }
        }
    }

    /// Codex can stop on startup confirmation screens before showing its input
    /// prompt, for example when entering a new/untrusted project directory.
    /// The default selected option is "Yes, continue", so pressing Enter is safe
    /// and lets launch automation reach the real prompt.
    public static func codexNeedsStartupConfirmation(_ paneOutput: String) -> Bool {
        let lines = paneOutput
            .components(separatedBy: .newlines)
            .suffix(12)
            .map { stripAnsi($0).trimmingCharacters(in: .whitespacesAndNewlines) }

        let hasContinueOption = lines.contains { line in
            line == "› 1. Yes, continue" || line == "❯ 1. Yes, continue"
        }
        let hasQuitOption = lines.contains { $0 == "2. No, quit" }
        let asksForEnter = lines.contains { $0.localizedCaseInsensitiveContains("press enter to continue") }
        return hasContinueOption && hasQuitOption && asksForEnter
    }

    /// Backward-compatible: check if Claude Code's input prompt is visible.
    public static func isClaudeReady(_ paneOutput: String) -> Bool {
        isReady(paneOutput, assistant: .claude)
    }

    /// Check if the assistant is actively working.
    ///
    /// Claude exposes a status line while working, so we look for its ellipsis
    /// marker near the bottom of the pane. Gemini and Codex do not expose the
    /// same stable status line; for them, the most reliable cheap signal is
    /// whether the bottom of the pane is missing the ready prompt.
    public static func isWorking(_ paneOutput: String) -> Bool {
        isWorking(paneOutput, assistant: .claude)
    }

    public static func isWorking(_ paneOutput: String, assistant: CodingAssistant) -> Bool {
        // Check last ~1000 chars — the status line / prompt can be 600+ chars
        // from the end due to border lines and footer text in TUIs.
        let tail = String(paneOutput.suffix(1000))
        switch assistant {
        case .claude:
            return tail.contains("\u{2026}")
        case .gemini, .codex:
            guard !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            return !isReady(tail, assistant: assistant)
        case .opencode:
            return paneOutput.contains("esc interrupt")
        }
    }

    /// Parse numbered options from Claude Code's plan approval prompt.
    /// Looks for lines matching "❯ N. Option text" or "  N. Option text" pattern
    /// in the pane output. Returns the options in order.
    ///
    /// Example pane output:
    /// ```
    /// ❯ 1. Yes, and bypass permissions
    ///   2. Yes, manually approve edits
    ///   3. Type here to tell Claude what to change
    /// ```
    public static func parsePlanOptions(from paneOutput: String) -> [String] {
        var options: [String] = []
        let lines = paneOutput.components(separatedBy: "\n")

        // Scan from the bottom up to find the option block
        var foundOptions = false
        var rawOptions: [(Int, String)] = []

        for line in lines.reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Match "N. text" pattern, optionally preceded by ❯ or spaces
            // Strip ANSI escape codes first
            let clean = stripAnsi(trimmed)

            if let match = parseNumberedOption(clean) {
                rawOptions.insert(match, at: 0)
                foundOptions = true
            } else if foundOptions {
                // We were in the options block and hit a non-option line — stop
                break
            }
        }

        // Sort by number and extract text
        options = rawOptions.sorted { $0.0 < $1.0 }.map(\.1)
        return options
    }

    /// Parse a single numbered option line like "❯ 1. Yes, and bypass permissions"
    /// or "  2. Yes, manually approve edits". Returns (number, text) or nil.
    private static func parseNumberedOption(_ line: String) -> (Int, String)? {
        // Remove leading ❯ or › marker
        var s = line
        if s.hasPrefix("❯") || s.hasPrefix("›") {
            s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces)
        }

        // Match "N. text" where N is a digit
        guard let dotIdx = s.firstIndex(of: "."),
              dotIdx > s.startIndex else { return nil }
        let numStr = String(s[s.startIndex..<dotIdx]).trimmingCharacters(in: .whitespaces)
        guard let num = Int(numStr), num > 0, num < 20 else { return nil }
        let text = String(s[s.index(after: dotIdx)...]).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return (num, text)
    }

    /// Strip ANSI escape sequences from terminal output.
    private static func stripAnsi(_ s: String) -> String {
        s.replacingOccurrences(
            of: "\\x1B\\[[0-9;]*[A-Za-z]|\\x1B\\]\\d+;[^\\x07]*\\x07",
            with: "",
            options: .regularExpression
        )
    }
}
