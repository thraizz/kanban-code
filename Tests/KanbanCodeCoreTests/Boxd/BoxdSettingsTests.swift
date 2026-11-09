import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("Boxd settings")
struct BoxdSettingsTests {

    private func decode(_ json: String) throws -> Settings {
        try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
    }

    // MARK: - Defaults

    @Test("A fresh Settings uses the ssh machines mode and no boxd block")
    func freshDefaults() {
        let settings = Settings()
        #expect(settings.remoteMode == .ssh)
        #expect(settings.boxd == nil)
        #expect(settings.assistantCommands.isEmpty)
    }

    @Test("BoxdSettings defaults match the documented values")
    func boxdDefaults() {
        let boxd = BoxdSettings()
        #expect(boxd.snapshotName == "kanban-code-base")
        #expect(boxd.sourceMachine == "good-wolf")
        #expect(boxd.folderTemplate == "~/${repo_name}")
        #expect(boxd.copyGlobs == ["**/.env"])
        #expect(boxd.inactivityTimeoutSeconds == 1800)
        #expect(boxd.initCommand == BoxdSettings.defaultInitCommand)
        #expect(boxd.claudeOAuthToken == "")
        #expect(boxd.initCommand.contains("${repo_dir}"))
        #expect(boxd.initCommand.contains("${repo_url}"))
    }

    @Test("The default init command only fetches and never touches the checkout")
    func initCommandOnlyFetches() {
        let command = BoxdSettings.defaultInitCommand
        #expect(command.contains(#"git -C "${repo_dir}" fetch --prune origin"#))
        #expect(!command.contains("git pull"))
        #expect(!command.contains("git checkout"))
        #expect(!command.contains("git stash"))
    }

    @Test("A stored init command from an older version is replaced by the current default")
    func legacyInitCommandUpgraded() throws {
        let json = #"{"boxd": {"initCommand": "if [ -d \"${repo_dir}\" ]; then\n  cd \"${repo_dir}\" && git pull --ff-only\nelse\n  git clone \"${repo_url}\" \"${repo_dir}\" && cd \"${repo_dir}\"\nfi"}}"#
        #expect(try decode(json).boxd?.initCommand == BoxdSettings.defaultInitCommand)
    }

    @Test("Every earlier default init command is replaced by the current default")
    func previousDefaultInitCommandsUpgraded() throws {
        for previous in BoxdSettings.supersededInitCommands {
            let data = try JSONEncoder().encode(["boxd": ["initCommand": previous]])
            let json = String(decoding: data, as: UTF8.self)
            #expect(try decode(json).boxd?.initCommand == BoxdSettings.defaultInitCommand)
        }
    }

    @Test("An edited init command is kept as it is")
    func customInitCommandKept() throws {
        let json = #"{"boxd": {"initCommand": "make bootstrap"}}"#
        #expect(try decode(json).boxd?.initCommand == "make bootstrap")
    }

    @Test("An inactivity timeout below the minimum is clamped")
    func timeoutClamped() throws {
        #expect(BoxdSettings(inactivityTimeoutSeconds: 5).inactivityTimeoutSeconds == 60)
        #expect(BoxdSettings(inactivityTimeoutSeconds: -1).inactivityTimeoutSeconds == 60)

        let decoded = try decode(#"{"boxd":{"inactivityTimeoutSeconds":10}}"#)
        #expect(decoded.boxd?.inactivityTimeoutSeconds == 60)
    }

    // MARK: - Mode decoding

    @Test("A settings file with no remote block decodes as ssh machines")
    func modeDefaultsToSsh() throws {
        #expect(try decode("{}").remoteMode == .ssh)
        #expect(try decode(#"{"remoteMode":"ssh"}"#).remoteMode == .ssh)
    }

    @Test("A settings file with only a mutagen remote block keeps the mutagen mode")
    func modeFromRemoteBlock() throws {
        let json = #"{"remote":{"host":"dev","remotePath":"/home/dev","localPath":"/Users/me"}}"#
        let settings = try decode(json)
        #expect(settings.remoteMode == .mutagen)
        #expect(settings.remote?.host == "dev")
    }

    @Test("A boxd block wins over an old remote block")
    func modeFromBoxdBlock() throws {
        let json = #"""
        {"remote":{"host":"dev","remotePath":"/home/dev","localPath":"/Users/me"},
         "boxd":{"snapshotName":"my-snap"}}
        """#
        let settings = try decode(json)
        #expect(settings.remoteMode == .boxd)
        #expect(settings.boxd?.snapshotName == "my-snap")
        // The fields the file does not carry fall back to their defaults.
        #expect(settings.boxd?.sourceMachine == "good-wolf")
    }

    @Test("An explicit remoteMode is kept")
    func explicitMode() throws {
        #expect(try decode(#"{"remoteMode":"mutagen","boxd":{}}"#).remoteMode == .mutagen)
    }

    @Test("An unknown remoteMode value falls back instead of failing the file")
    func unknownMode() throws {
        let settings = try decode(#"{"remoteMode":"carrier-pigeon","promptTemplate":"/orchestrate"}"#)
        #expect(settings.remoteMode == .ssh)
        #expect(settings.promptTemplate == "/orchestrate")
    }

    // MARK: - Tolerant decoding

    @Test("Garbage in one boxd field does not break the other fields")
    func garbageField() throws {
        let json = #"""
        {"boxd":{"snapshotName":"snap","sourceMachine":42,"copyGlobs":"nope",
                 "folderTemplate":"~/code/${repo_name}","inactivityTimeoutSeconds":"soon"}}
        """#
        let boxd = try #require(try decode(json).boxd)
        #expect(boxd.snapshotName == "snap")
        #expect(boxd.sourceMachine == "good-wolf")
        #expect(boxd.copyGlobs == ["**/.env"])
        #expect(boxd.folderTemplate == "~/code/${repo_name}")
        #expect(boxd.inactivityTimeoutSeconds == 1800)
    }

    @Test("Garbage in the boxd block does not drop the rest of the settings")
    func garbageBlock() throws {
        let settings = try decode(#"{"boxd":"nope","promptTemplate":"/plan","projects":[]}"#)
        #expect(settings.boxd == nil)
        #expect(settings.promptTemplate == "/plan")
    }

    @Test("Garbage in assistantCommands leaves the map empty")
    func garbageAssistantCommands() throws {
        let settings = try decode(#"{"assistantCommands":[1,2,3],"promptTemplate":"/plan"}"#)
        #expect(settings.assistantCommands.isEmpty)
        #expect(settings.promptTemplate == "/plan")
    }

    // MARK: - Round trip

    @Test("Round-trip through JSON keeps every new field")
    func roundTrip() throws {
        var settings = Settings()
        settings.remoteMode = .mutagen
        settings.boxd = BoxdSettings(
            snapshotName: "snap",
            sourceMachine: "wolf",
            folderTemplate: "~/src/${repo_name}",
            initCommand: "echo ${repo_dir}",
            copyGlobs: ["**/.env", "config/*.yaml"],
            inactivityTimeoutSeconds: 900
        )
        settings.assistantCommands = [
            CodingAssistant.claude.rawValue: AssistantCommandTemplate(local: "langwatch ${cli_command}", remote: "${cli_command} --rc"),
            CodingAssistant.codex.rawValue: AssistantCommandTemplate(local: "${cli_command}"),
        ]

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)

        #expect(decoded.remoteMode == .mutagen)
        #expect(decoded.boxd == settings.boxd)
        #expect(decoded.assistantCommands == settings.assistantCommands)
    }

    @Test("The settings store writes and reads the boxd block")
    func storeRoundTrip() async throws {
        let dir = NSTemporaryDirectory() + "kanban-boxd-settings-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let store = SettingsStore(basePath: dir)
        var settings = try await store.read()
        settings.boxd = BoxdSettings(snapshotName: "snap")
        settings.assistantCommands["claude"] = AssistantCommandTemplate(local: "langwatch ${cli_command}")
        try await store.write(settings)
        await store.invalidateCache()

        let read = try await store.read()
        #expect(read.boxd?.snapshotName == "snap")
        #expect(read.assistantCommands["claude"]?.local == "langwatch ${cli_command}")
    }

    // MARK: - commandTemplate(for:remote:)

    @Test("An assistant with no template has none")
    func templateAbsent() {
        let settings = Settings()
        #expect(settings.commandTemplate(for: .claude, remote: false) == nil)
        #expect(settings.commandTemplate(for: .claude, remote: true) == nil)
    }

    @Test("A blank or bare-placeholder template reads as none")
    func templateBlank() {
        var settings = Settings()
        settings.assistantCommands["claude"] = AssistantCommandTemplate(local: "   ")
        settings.assistantCommands["codex"] = AssistantCommandTemplate(local: "${cli_command}")
        #expect(settings.commandTemplate(for: .claude, remote: false) == nil)
        #expect(settings.commandTemplate(for: .codex, remote: false) == nil)
    }

    @Test("The remote template falls back to the local one")
    func templateRemoteFallback() {
        var settings = Settings()
        settings.assistantCommands["claude"] = AssistantCommandTemplate(local: "langwatch ${cli_command}")
        #expect(settings.commandTemplate(for: .claude, remote: true) == "langwatch ${cli_command}")

        settings.assistantCommands["claude"] = AssistantCommandTemplate(
            local: "langwatch ${cli_command}",
            remote: "${cli_command} --rc"
        )
        #expect(settings.commandTemplate(for: .claude, remote: false) == "langwatch ${cli_command}")
        #expect(settings.commandTemplate(for: .claude, remote: true) == "${cli_command} --rc")
    }

    @Test("A blank remote template reads as none even when the local one is set")
    func templateRemoteBlank() {
        var settings = Settings()
        settings.assistantCommands["claude"] = AssistantCommandTemplate(local: "langwatch ${cli_command}", remote: "  ")
        #expect(settings.commandTemplate(for: .claude, remote: true) == nil)
        #expect(settings.commandTemplate(for: .claude, remote: false) == "langwatch ${cli_command}")
    }


    @Test("The Claude token round-trips and is empty when absent")
    func claudeTokenRoundTrip() throws {
        var settings = Settings()
        settings.boxd = BoxdSettings(claudeOAuthToken: "sk-ant-oat01-abc")
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)
        #expect(decoded.boxd?.claudeOAuthToken == "sk-ant-oat01-abc")

        let absent = try decode(#"{"remoteMode":"boxd","boxd":{"snapshotName":"base"}}"#)
        #expect(absent.boxd?.claudeOAuthToken == "")
    }
}
