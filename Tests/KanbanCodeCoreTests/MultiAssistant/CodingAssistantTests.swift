import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("CodingAssistant Enum")
struct CodingAssistantTests {

    // MARK: - Display Names

    @Test("Claude display name")
    func claudeDisplayName() {
        #expect(CodingAssistant.claude.displayName == "Claude Code")
    }

    @Test("Gemini display name")
    func geminiDisplayName() {
        #expect(CodingAssistant.gemini.displayName == "Gemini CLI")
    }

    @Test("Codex display name")
    func codexDisplayName() {
        #expect(CodingAssistant.codex.displayName == "Codex CLI")
    }

    // MARK: - CLI Commands

    @Test("Claude CLI command")
    func claudeCliCommand() {
        #expect(CodingAssistant.claude.cliCommand == "claude")
    }

    @Test("Gemini CLI command")
    func geminiCliCommand() {
        #expect(CodingAssistant.gemini.cliCommand == "gemini")
    }

    @Test("Codex CLI command")
    func codexCliCommand() {
        #expect(CodingAssistant.codex.cliCommand == "codex")
    }

    // MARK: - Prompt Characters

    @Test("Claude prompt character is ❯")
    func claudePromptCharacter() {
        #expect(CodingAssistant.claude.promptCharacter == "❯")
    }

    @Test("Gemini prompt character detects input prompt")
    func geminiPromptCharacter() {
        #expect(CodingAssistant.gemini.promptCharacter == "Type your message")
    }

    @Test("Codex prompt character is ›")
    func codexPromptCharacter() {
        #expect(CodingAssistant.codex.promptCharacter == "›")
    }

    // MARK: - Auto-Approve Flags

    @Test("Claude auto-approve flag")
    func claudeAutoApproveFlag() {
        #expect(CodingAssistant.claude.autoApproveFlag == "--dangerously-skip-permissions")
    }

    @Test("Gemini auto-approve flag")
    func geminiAutoApproveFlag() {
        #expect(CodingAssistant.gemini.autoApproveFlag == "--yolo")
    }

    @Test("Codex auto-approve flag")
    func codexAutoApproveFlag() {
        #expect(CodingAssistant.codex.autoApproveFlag == "--dangerously-bypass-approvals-and-sandbox")
    }

    // MARK: - Resume Flag

    @Test("Assistant resume flags match CLI syntax")
    func resumeFlag() {
        #expect(CodingAssistant.claude.resumeFlag == "--resume")
        #expect(CodingAssistant.gemini.resumeFlag == "--resume")
        #expect(CodingAssistant.codex.resumeFlag == "resume")
        #expect(CodingAssistant.opencode.resumeFlag == "--session")
    }

    // MARK: - Capabilities

    @Test("Claude supports worktrees")
    func claudeSupportsWorktree() {
        #expect(CodingAssistant.claude.supportsWorktree == true)
    }

    @Test("Gemini does not support worktrees")
    func geminiNoWorktree() {
        #expect(CodingAssistant.gemini.supportsWorktree == false)
    }

    @Test("Codex does not support worktrees")
    func codexNoWorktree() {
        #expect(CodingAssistant.codex.supportsWorktree == false)
    }

    @Test("Claude supports image upload")
    func claudeSupportsImageUpload() {
        #expect(CodingAssistant.claude.supportsImageUpload == true)
    }

    @Test("Gemini does not support image upload")
    func geminiNoImageUpload() {
        #expect(CodingAssistant.gemini.supportsImageUpload == false)
    }

    @Test("Codex does not support image upload")
    func codexNoImageUpload() {
        #expect(CodingAssistant.codex.supportsImageUpload == false)
    }

    @Test("Codex uses paste submission and file polling")
    func codexPromptAndHooks() {
        #expect(CodingAssistant.codex.submitsPromptWithPaste)
        #expect(!CodingAssistant.codex.supportsHooks)
    }

    // MARK: - Config Directory

    @Test("Claude config dir")
    func claudeConfigDir() {
        #expect(CodingAssistant.claude.configDirName == ".claude")
    }

    @Test("Gemini config dir")
    func geminiConfigDir() {
        #expect(CodingAssistant.gemini.configDirName == ".gemini")
    }

    @Test("Codex config dir")
    func codexConfigDir() {
        #expect(CodingAssistant.codex.configDirName == ".codex")
    }

    // MARK: - Install Command

    @Test("Claude install command")
    func claudeInstallCommand() {
        #expect(CodingAssistant.claude.installCommand.contains("claude-code"))
    }

    @Test("Gemini install command")
    func geminiInstallCommand() {
        #expect(CodingAssistant.gemini.installCommand.contains("gemini-cli"))
    }

    @Test("Codex install command")
    func codexInstallCommand() {
        #expect(CodingAssistant.codex.installCommand.contains("@openai/codex"))
    }

    // MARK: - Command Building

    @Test("Codex launch command includes no alternate screen")
    func codexLaunchCommand() {
        let command = CodingAssistant.codex.launchCommand(skipPermissions: true, worktreeName: "ignored")
        #expect(command.contains("codex"))
        #expect(command.contains("--no-alt-screen"))
        #expect(command.contains("--dangerously-bypass-approvals-and-sandbox"))
        #expect(!command.contains("--worktree"))
    }

    @Test("Codex resume command uses resume subcommand")
    func codexResumeCommand() {
        let command = CodingAssistant.codex.resumeCommand(sessionId: "session-123", skipPermissions: true)
        #expect(command == "codex resume --dangerously-bypass-approvals-and-sandbox --no-alt-screen session-123")
    }

    // MARK: - APIService command building

    @Test("launchCommand without service is unchanged")
    func launchCommandNoService() {
        let cmd = CodingAssistant.claude.launchCommand(skipPermissions: true, worktreeName: nil, service: nil)
        #expect(cmd == "claude --dangerously-skip-permissions")
    }

    @Test("launchCommand with ollama service inserts launcher + model + separator")
    func launchCommandWithOllamaService() {
        let service = APIService(
            name: "Ollama",
            assistant: .claude,
            launcherPrefix: "ollama launch",
            modelFlag: "qwen3-coder-next:cloud"
        )
        let cmd = CodingAssistant.claude.launchCommand(skipPermissions: true, worktreeName: nil, service: service)
        #expect(cmd == "ollama launch claude --model qwen3-coder-next:cloud -- --dangerously-skip-permissions")
    }

    @Test("launchCommand with model-only service inserts -- separator")
    func launchCommandWithModelOnly() {
        let service = APIService(name: "Model override", assistant: .claude, modelFlag: "claude-opus-4-5")
        let cmd = CodingAssistant.claude.launchCommand(skipPermissions: false, worktreeName: nil, service: service)
        #expect(cmd == "claude --model claude-opus-4-5 --")
    }

    @Test("resumeCommand with ollama service for claude")
    func resumeCommandClaudeWithService() {
        let service = APIService(
            name: "Ollama",
            assistant: .claude,
            launcherPrefix: "ollama launch",
            modelFlag: "qwen3-coder-next:cloud"
        )
        let cmd = CodingAssistant.claude.resumeCommand(sessionId: "abc-123", skipPermissions: true, service: service)
        #expect(cmd == "ollama launch claude --model qwen3-coder-next:cloud -- --dangerously-skip-permissions --resume abc-123")
    }

    @Test("resumeCommand with ollama service for codex puts resume after separator")
    func resumeCommandCodexWithService() {
        let service = APIService(
            name: "Ollama",
            assistant: .codex,
            launcherPrefix: "ollama launch",
            modelFlag: "qwen3-coder-next:cloud"
        )
        let cmd = CodingAssistant.codex.resumeCommand(sessionId: "abc-123", skipPermissions: true, service: service)
        #expect(cmd == "ollama launch codex --model qwen3-coder-next:cloud -- resume --dangerously-bypass-approvals-and-sandbox --no-alt-screen abc-123")
    }

    @Test("resumeCommand without service is unchanged for codex")
    func resumeCommandCodexNoService() {
        let cmd = CodingAssistant.codex.resumeCommand(sessionId: "abc-123", skipPermissions: true, service: nil)
        #expect(cmd == "codex resume --dangerously-bypass-approvals-and-sandbox --no-alt-screen abc-123")
    }

    @Test("launchCommand with worktree and ollama service places worktree after separator")
    func launchCommandWorktreeWithService() {
        let service = APIService(
            name: "Ollama",
            assistant: .claude,
            launcherPrefix: "ollama launch",
            modelFlag: "qwen3"
        )
        let cmd = CodingAssistant.claude.launchCommand(skipPermissions: true, worktreeName: "feature-x", service: service)
        #expect(cmd == "ollama launch claude --model qwen3 -- --dangerously-skip-permissions --worktree feature-x")
    }

    // MARK: - Command preview with pre-selected default service

    /// Regression: NewTaskDialog / LaunchConfirmationDialog previously showed the
    /// bare command on first open even when a default API service was pre-selected,
    /// because the command string was set in onAppear before .task loaded apiServices.
    /// The fix refreshes the command at the end of .task.  These tests assert the
    /// pure command-resolution logic that the refresh must produce.

    @Test("Command preview reflects pre-selected default service immediately")
    func commandPreviewWithPreSelectedService() {
        // Simulate what happens after .task loads: selectedServiceId is resolved,
        // apiServices is populated, and commandPreview is re-evaluated.
        let services = [
            APIService(
                id: "svc-default",
                name: "Ollama",
                assistant: .claude,
                launcherPrefix: "ollama launch",
                modelFlag: "qwen3-coder-next:cloud"
            )
        ]
        let selectedServiceId: String? = "svc-default"
        let service = selectedServiceId.flatMap { id in services.first { $0.id == id } }
        let cmd = CodingAssistant.claude.launchCommand(
            skipPermissions: true,
            worktreeName: nil,
            service: service
        )
        #expect(cmd == "ollama launch claude --model qwen3-coder-next:cloud -- --dangerously-skip-permissions")
    }

    @Test("Command preview with nil selectedServiceId shows bare command (Default option)")
    func commandPreviewWithNilService() {
        let services = [
            APIService(id: "svc-1", name: "Ollama", assistant: .claude, launcherPrefix: "ollama launch", modelFlag: "qwen3")
        ]
        let selectedServiceId: String? = nil
        let service = selectedServiceId.flatMap { id in services.first { $0.id == id } }
        let cmd = CodingAssistant.claude.launchCommand(
            skipPermissions: true,
            worktreeName: nil,
            service: service
        )
        #expect(cmd == "claude --dangerously-skip-permissions")
    }

    @Test("Command preview with unknown service ID (stale ID) shows bare command")
    func commandPreviewWithStaleServiceId() {
        let services = [
            APIService(id: "svc-current", name: "Ollama", assistant: .claude, launcherPrefix: "ollama launch", modelFlag: "qwen3")
        ]
        let selectedServiceId: String? = "svc-deleted"
        let service = selectedServiceId.flatMap { id in services.first { $0.id == id } }
        let cmd = CodingAssistant.claude.launchCommand(
            skipPermissions: true,
            worktreeName: nil,
            service: service
        )
        #expect(cmd == "claude --dangerously-skip-permissions")
    }

    // MARK: - baseURLEnvKey

    @Test("Native model override does not add a launcher separator")
    func nativeModelOverride() {
        #expect(CodingAssistant.claude.launchCommand(
            skipPermissions: true,
            worktreeName: nil,
            modelOverride: "opus"
        ) == "claude --model opus --dangerously-skip-permissions")
        #expect(CodingAssistant.codex.resumeCommand(
            sessionId: "session-1",
            skipPermissions: true,
            modelOverride: "gpt-5.4"
        ) == "codex --model gpt-5.4 resume --dangerously-bypass-approvals-and-sandbox --no-alt-screen session-1")
    }

    @Test("Model override is escaped as one shell argument")
    func modelOverrideShellEscaping() {
        #expect(CodingAssistant.claude.launchCommand(
            skipPermissions: true,
            worktreeName: nil,
            modelOverride: "custom model; echo 'unsafe'"
        ) == "claude --model 'custom model; echo '\\''unsafe'\\''' --dangerously-skip-permissions")
    }

    @Test("Claude base URL env key is ANTHROPIC_BASE_URL")
    func claudeBaseURLEnvKey() {
        #expect(CodingAssistant.claude.baseURLEnvKey == "ANTHROPIC_BASE_URL")
    }

    @Test("Codex base URL env key is OPENAI_BASE_URL")
    func codexBaseURLEnvKey() {
        #expect(CodingAssistant.codex.baseURLEnvKey == "OPENAI_BASE_URL")
    }

    @Test("Gemini has no base URL env key")
    func geminiBaseURLEnvKey() {
        #expect(CodingAssistant.gemini.baseURLEnvKey == nil)
    }

    @Test("Only Claude supports per-card context threshold compaction")
    func contextThresholdSelfCompactSupport() {
        #expect(CodingAssistant.claude.supportsContextThresholdSelfCompact)
        #expect(!CodingAssistant.codex.supportsContextThresholdSelfCompact)
        #expect(!CodingAssistant.gemini.supportsContextThresholdSelfCompact)
    }

    // MARK: - Codable

    @Test("CodingAssistant Codable round-trip")
    func codableRoundTrip() throws {
        for assistant in CodingAssistant.allCases {
            let data = try JSONEncoder().encode(assistant)
            let decoded = try JSONDecoder().decode(CodingAssistant.self, from: data)
            #expect(decoded == assistant)
        }
    }

    @Test("CodingAssistant raw value encoding")
    func rawValueEncoding() throws {
        let data = try JSONEncoder().encode(CodingAssistant.gemini)
        let json = String(data: data, encoding: .utf8)!
        #expect(json == "\"gemini\"")
    }

    @Test("CodingAssistant decodes from raw string")
    func decodeFromString() throws {
        let json = "\"claude\""
        let decoded = try JSONDecoder().decode(CodingAssistant.self, from: json.data(using: .utf8)!)
        #expect(decoded == .claude)
    }

    // MARK: - CaseIterable

    @Test("CaseIterable includes all known assistants")
    func caseIterable() {
        let all = CodingAssistant.allCases
        #expect(all.contains(.claude))
        #expect(all.contains(.gemini))
        #expect(all.contains(.codex))
        #expect(all.contains(.opencode))
        #expect(all.contains(.pi))
        #expect(all.count == 5)
    }

    // MARK: - OpenCode

    @Test("OpenCode basics")
    func opencodeBasics() {
        let opencode = CodingAssistant.opencode
        #expect(opencode.displayName == "OpenCode")
        #expect(opencode.cliCommand == "opencode")
        #expect(opencode.installCommand == "npm install -g opencode-ai")
        #expect(opencode.resumeFlag == "--session")
        #expect(opencode.supportsHooks)
        #expect(opencode.submitsPromptWithPaste)
        #expect(!opencode.supportsWorktree)
        #expect(!opencode.supportsImageUpload)
        #expect(!opencode.supportsContextThresholdSelfCompact)
        #expect(opencode.baseURLEnvKey == nil)
    }

    @Test("OpenCode auto-approves through its permission environment, not a flag")
    func opencodeLaunchSkipPermissions() {
        let cmd = CodingAssistant.opencode.launchCommand(skipPermissions: true, worktreeName: nil)
        #expect(cmd == #"env OPENCODE_PERMISSION='{"*":"allow"}' opencode"#)
        #expect(CodingAssistant.opencode.launchCommand(skipPermissions: false, worktreeName: "ignored") == "opencode")
    }

    @Test("OpenCode resumes with --session")
    func opencodeResume() {
        let cmd = CodingAssistant.opencode.resumeCommand(sessionId: "ses_abc", skipPermissions: true)
        #expect(cmd == #"env OPENCODE_PERMISSION='{"*":"allow"}' opencode --session ses_abc"#)
    }

    @Test("OpenCode takes a provider/model without a -- separator")
    func opencodeModelNoSeparator() {
        let service = APIService(name: "OpenRouter", assistant: .opencode, modelFlag: "openrouter/anthropic/claude-sonnet-4.5")
        let cmd = CodingAssistant.opencode.resumeCommand(sessionId: "ses_abc", skipPermissions: false, service: service)
        #expect(cmd == "opencode --model openrouter/anthropic/claude-sonnet-4.5 --session ses_abc")
    }

    @Test("OpenCode behind a launcher keeps the separator and the environment in front")
    func opencodeLauncher() {
        let service = APIService(name: "Ollama", assistant: .opencode, launcherPrefix: "ollama launch", modelFlag: "qwen3")
        let cmd = CodingAssistant.opencode.launchCommand(skipPermissions: true, worktreeName: nil, service: service)
        #expect(cmd == #"env OPENCODE_PERMISSION='{"*":"allow"}' ollama launch opencode --model qwen3 --"#)
    }

    @Test("Resume tmux names use the random tail of an OpenCode id")
    func opencodeResumeSessionName() {
        // Two sessions started seconds apart share their first 8 characters.
        let a = CodingAssistant.opencode.resumeSessionName(sessionId: "ses_f0f05e9cbffeuUlK5flVEb10mL")
        let b = CodingAssistant.opencode.resumeSessionName(sessionId: "ses_f0f04d857ffe89pU9QjzR1Tt5I")
        #expect(a == "opencode-lVEb10mL")
        #expect(a != b)
        #expect(CodingAssistant.claude.resumeSessionName(sessionId: "0f0e1d2c-aaaa-bbbb") == "claude-0f0e1d2c")
    }

    @Test("A command template wraps the whole OpenCode command, environment included")
    func opencodeTemplate() {
        let cmd = CodingAssistant.opencode.launchCommand(skipPermissions: true, worktreeName: nil)
        let wrapped = CodingAssistant.applyCommandTemplate(cmd, template: "langwatch ${cli_command}")
        #expect(wrapped == #"langwatch env OPENCODE_PERMISSION='{"*":"allow"}' opencode"#)
    }

    // MARK: - Pi

    @Test("Pi basics")
    func piBasics() {
        let pi = CodingAssistant.pi
        #expect(pi.displayName == "Pi")
        #expect(pi.cliCommand == "pi")
        #expect(pi.installCommand == "npm install -g @earendil-works/pi-coding-agent")
        #expect(pi.resumeFlag == "--session")
        #expect(pi.sessionFileExtension == "jsonl")
        #expect(pi.supportsHooks)
        #expect(pi.submitsPromptWithPaste)
        #expect(!pi.supportsWorktree)
        #expect(!pi.supportsImageUpload)
        #expect(pi.baseURLEnvKey == nil)
        #expect(pi.owns(sessionPath: "/Users/me/.pi/agent/sessions/--Users-me-project--/2026-09-30T18-10-40-290Z_01a0f382-f222-75c6-988d-fcb921b2821a.jsonl"))
        #expect(CodingAssistant.owner(ofSessionPath: "/Users/me/.pi/agent/sessions/x/y.jsonl") == .pi)
    }

    @Test("Pi has no permission prompts, so skipping them adds nothing")
    func piLaunchSkipPermissions() {
        #expect(CodingAssistant.pi.launchCommand(skipPermissions: true, worktreeName: "ignored") == "pi")
        #expect(CodingAssistant.pi.resumeCommand(sessionId: "01a0f382-f222-75c6-988d-fcb921b2821a", skipPermissions: true)
            == "pi --session 01a0f382-f222-75c6-988d-fcb921b2821a")
    }

    @Test("Pi takes a provider/model without a -- separator, which would make the flags a prompt")
    func piModelNoSeparator() {
        let service = APIService(name: "OpenRouter", assistant: .pi, modelFlag: "openrouter/moonshotai/kimi-k2.6")
        let cmd = CodingAssistant.pi.launchCommand(skipPermissions: false, worktreeName: nil, service: service)
        #expect(cmd == "pi --model openrouter/moonshotai/kimi-k2.6")
    }

    @Test("Resume tmux names use the random tail of Pi's time-ordered ids")
    func piResumeSessionName() {
        // Two sessions started a minute apart share their first 8 characters.
        let a = CodingAssistant.pi.resumeSessionName(sessionId: "01a0f385-0bf4-702d-b978-176fd2135394")
        let b = CodingAssistant.pi.resumeSessionName(sessionId: "01a0f385-6201-717b-b0eb-d7226a1b0fbd")
        #expect(a == "pi-d2135394")
        #expect(a != b)
        // Codex ids are time-ordered too; their names are left as they were.
        #expect(CodingAssistant.codex.resumeSessionName(sessionId: "019da64f-aaaa-7bbb-8ccc-c09931f2c099") == "codex-019da64f")
    }
}
