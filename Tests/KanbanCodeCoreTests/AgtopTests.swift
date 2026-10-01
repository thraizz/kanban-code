import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("agtop runtime")
struct AgtopTests {
    /// A stand-in `agtop` that logs each call (argv, then stdin) and answers
    /// like the real one.
    struct FakeAgtop {
        let dir: String
        let name: String
        var path: String { "\(dir)/\(name)" }
        var logPath: String { "\(dir)/calls.log" }

        init(name: String = "agtop") throws {
            self.name = name
            dir = NSTemporaryDirectory() + "kanban-agtop-test-\(UUID().uuidString)"
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let script = """
            #!/bin/sh
            echo "ARGS $*" >> '\(dir)/calls.log'
            case "$2" in
              send) echo "STDIN $(cat)" >> '\(dir)/calls.log' ;;
              start) echo '{"id":"0a1b2c3d","sessionId":"0a1b2c3d-1111-2222-3333-444455556666","cwd":"/repo","state":"starting","hostPid":42,"alive":true}' ;;
              info)
                if [ "$3" = "0a1b2c3d" ]; then
                  echo '{"id":"0a1b2c3d","sessionId":"0a1b2c3d-1111","cwd":"/repo","state":"working","alive":true}'
                else
                  echo '{"error":"not found"}'; exit 1
                fi ;;
              list) echo '[{"id":"0a1b2c3d","sessionId":"s1","cwd":"/repo","state":"working","alive":true,"queue":["later","and this"]},{"id":"99999999","sessionId":"s2","cwd":"/old","state":"stopped","alive":false}]' ;;
            esac
            """
            try script.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }

        func calls() -> String { (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? "" }

        func cleanup() { try? FileManager.default.removeItem(atPath: dir) }

        func adapter() -> AgtopCliAdapter {
            AgtopCliAdapter(executable: path, scratchDirectory: "\(dir)/scratch")
        }
    }

    // MARK: - Session names

    @Test("The session name carries the agtop id of the Claude session")
    func sessionName() {
        let sid = "0a1b2c3d-1111-2222-3333-444455556666"
        #expect(AgtopSessionName.agtopId(sessionId: sid) == "0a1b2c3d")
        #expect(AgtopSessionName.name(sessionId: sid) == "agtop-0a1b2c3d")
        #expect(AgtopSessionName.agtopId(fromName: "agtop-0a1b2c3d") == "0a1b2c3d")
    }

    @Test("Extra shells and tmux sessions are not agtop sessions")
    func notAgtop() {
        #expect(!AgtopSessionName.isAgtop("agtop-0a1b2c3d-sh1"))
        #expect(!AgtopSessionName.isAgtop("claude-0a1b2c3d"))
        #expect(!AgtopSessionName.isAgtop("agtop-0A1B2C3D"))
        #expect(!AgtopSessionName.isAgtop("agtop-0a1b"))
    }

    // MARK: - Settings

    @Test("Settings keep the runtime of Claude, and default to tmux")
    func settingsRuntime() throws {
        let json = #"{"assistantRuntimes":{"claude":"agtop","gemini":"agtop","codex":"bogus"}}"#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        #expect(settings.runtime(for: .claude) == .agtop)
        #expect(settings.runtime(for: .gemini) == .tmux)
        #expect(settings.runtime(for: .codex) == .tmux)
        #expect(Settings().runtime(for: .claude) == .tmux)

        let encoded = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(Settings.self, from: encoded)
        #expect(decoded.runtime(for: .claude) == .agtop)
    }

    // MARK: - Launch planning

    @Test("A card set to agtop runs on agtop only when agtop can run it")
    func choose() {
        func choice(_ assistant: CodingAssistant = .claude, runtime: SessionRuntime = .agtop, remote: Bool = false,
                    override: String? = nil, installed: Bool = true) -> AgtopLaunchPlanner.Choice {
            AgtopLaunchPlanner.choose(assistant: assistant, runtime: runtime, remote: remote,
                                      commandOverride: override, agtopInstalled: installed)
        }
        #expect(choice() == .agtop)
        #expect(choice(runtime: .tmux) == .tmux)
        #expect(choice(.codex) == .fallback(.notClaude))
        #expect(choice(remote: true) == .fallback(.remote))
        #expect(choice(override: "claude --foo") == .fallback(.commandOverride))
        #expect(choice(override: "  ") == .agtop)
        #expect(choice(installed: false) == .fallback(.notInstalled))
    }

    @Test("A command template or a service launcher becomes the binary agtop runs")
    func wrapperCommand() {
        #expect(AgtopLaunchPlanner.wrapperCommand(template: nil, service: nil) == nil)
        #expect(AgtopLaunchPlanner.wrapperCommand(template: "${cli_command}", service: nil) == nil)
        #expect(AgtopLaunchPlanner.wrapperCommand(template: "langwatch ${cli_command}", service: nil) == "langwatch claude")
        let service = APIService(name: "Ollama", assistant: .claude, launcherPrefix: "ollama launch")
        #expect(AgtopLaunchPlanner.wrapperCommand(template: nil, service: service) == "ollama launch claude --")
        #expect(AgtopLaunchPlanner.wrapperScript(command: "langwatch claude") == "#!/bin/sh\nexec langwatch claude \"$@\"\n")
    }

    @Test("The start request carries the card id and the permission mode")
    func request() {
        let request = AgtopLaunchPlanner.request(
            cardId: "card_1", cwd: "/repo", sessionId: "sid", resume: false, name: "Fix it",
            prompt: "hi", imagePaths: [], extraEnv: ["ANTHROPIC_BASE_URL": "http://x"],
            skipPermissions: true, model: "opus", binary: nil
        )
        #expect(request.env == ["ANTHROPIC_BASE_URL": "http://x", "KANBAN_CARD_ID": "card_1"])
        #expect(request.permissionMode == "bypassPermissions")
        #expect(request.meta == ["kanban_card": "card_1"])
        let args = AgtopCliAdapter.startArguments(request, promptFile: "/p.txt")
        #expect(args == [
            "session", "start", "--cwd", "/repo", "--session-id", "sid", "--name", "Fix it",
            "--prompt-file", "/p.txt",
            "--env", "ANTHROPIC_BASE_URL=http://x", "--env", "KANBAN_CARD_ID=card_1",
            "--model", "opus", "--permission-mode", "bypassPermissions",
            "--meta", "kanban_card=card_1", "--json",
        ])
    }

    // MARK: - CLI adapter

    @Test("start runs agtop session start and reads the host back")
    func start() async throws {
        let fake = try FakeAgtop()
        defer { fake.cleanup() }
        let info = try await fake.adapter().start(AgtopStartRequest(
            cwd: "/repo", sessionId: "0a1b2c3d-1111-2222-3333-444455556666", resume: true,
            prompt: "do the thing", imagePaths: ["/img.png"]
        ))
        #expect(info.id == "0a1b2c3d")
        #expect(info.alive)
        let calls = fake.calls()
        #expect(calls.contains("session start --cwd /repo --session-id 0a1b2c3d-1111-2222-3333-444455556666 --resume --prompt-file"))
        #expect(calls.contains("--image /img.png --json"))
    }

    @Test("send passes the text on stdin, whatever it holds")
    func send() async throws {
        let fake = try FakeAgtop()
        defer { fake.cleanup() }
        try await fake.adapter().send(id: "0a1b2c3d", text: "it's \"quoted\" $HOME", imagePaths: ["/a b.png"], now: true)
        let calls = fake.calls()
        #expect(calls.contains("ARGS session send 0a1b2c3d --now --image /a b.png"))
        #expect(calls.contains("STDIN it's \"quoted\" $HOME"))
    }

    @Test("info reads a host, and nil for an unknown id")
    func info() async throws {
        let fake = try FakeAgtop()
        defer { fake.cleanup() }
        let adapter = fake.adapter()
        let info = try await adapter.info(id: "0a1b2c3d")
        #expect(info?.isBusy == true)
        #expect(try await adapter.info(id: "ffffffff") == nil)
    }

    @Test("The router sends agtop names to agtop and lists live hosts")
    func routing() async throws {
        let fake = try FakeAgtop()
        defer { fake.cleanup() }
        let router = RoutingTmuxAdapter(agtop: fake.adapter())
        try await router.pastePrompt(to: "agtop-0a1b2c3d", text: "hello", abortIf: nil)
        try await router.sendEscape(sessionName: "agtop-0a1b2c3d")
        try await router.killSession(name: "agtop-0a1b2c3d")
        #expect(try await router.capturePane(sessionName: "agtop-0a1b2c3d") == "")
        #expect(try await router.clearComposer(sessionName: "agtop-0a1b2c3d") == false)
        let calls = fake.calls()
        #expect(calls.contains("ARGS session send 0a1b2c3d\nSTDIN hello"))
        #expect(calls.contains("ARGS session interrupt 0a1b2c3d"))
        #expect(calls.contains("ARGS session stop 0a1b2c3d"))

        let sessions = try await router.listSessions()
        let names = sessions.map(\.name)
        #expect(names.contains("agtop-0a1b2c3d"))
        #expect(!names.contains("agtop-99999999"))
        #expect(sessions.first { $0.name == "agtop-0a1b2c3d" }?.agtopQueue == ["later", "and this"])
        #expect(BoardStore.agtopQueues(in: sessions) == ["agtop-0a1b2c3d": ["later", "and this"]])
    }

    @Test("A queued message is sent now or removed by its place and text")
    func queueCommands() async throws {
        let fake = try FakeAgtop()
        defer { fake.cleanup() }
        let adapter = fake.adapter()
        try await adapter.sendQueued(id: "0a1b2c3d", index: 1, was: "and this")
        try await adapter.removeQueued(id: "0a1b2c3d", index: 0, was: "later")
        let calls = fake.calls()
        #expect(calls.contains("ARGS session queue 0a1b2c3d send 1 --was and this"))
        #expect(calls.contains("ARGS session queue 0a1b2c3d remove 0 --was later"))
        #expect(try await adapter.list().first?.queue == ["later", "and this"])
    }

    @Test("rush sends now or removes a queued message with rush queue")
    func rushQueueCommands() async throws {
        let fake = try FakeAgtop(name: "rush")
        defer { fake.cleanup() }
        let adapter = fake.adapter()
        try await adapter.sendQueued(id: "0a1b2c3d", index: 1, was: "and this")
        try await adapter.removeQueued(id: "0a1b2c3d", index: 0, was: "later")
        let calls = fake.calls()
        #expect(calls.contains("ARGS queue send 0a1b2c3d 1 --was and this"))
        #expect(calls.contains("ARGS queue remove 0a1b2c3d 0 --was later"))
    }

    @Test("rush is told the agent is Claude Code, agtop is not")
    func rushStartNamesTheAgent() async throws {
        let rush = try FakeAgtop(name: "rush")
        defer { rush.cleanup() }
        _ = try await rush.adapter().start(AgtopStartRequest(cwd: "/repo", sessionId: "0a1b2c3d-1111-2222-3333-444455556666", resume: false))
        #expect(rush.calls().contains("ARGS session start --cwd /repo --session-id 0a1b2c3d-1111-2222-3333-444455556666 --agent claude --json"))
        let agtop = try FakeAgtop()
        defer { agtop.cleanup() }
        _ = try await agtop.adapter().start(AgtopStartRequest(cwd: "/repo", sessionId: "0a1b2c3d-1111-2222-3333-444455556666", resume: false))
        #expect(agtop.calls().contains("ARGS session start --cwd /repo --session-id 0a1b2c3d-1111-2222-3333-444455556666 --json"))
    }

    @Test("rush opens one session without --solo, agtop with it")
    func openArguments() {
        #expect(AgtopCliAdapter.openArguments(executable: "/Users/me/go/bin/rush", id: "0a1b2c3d")
            == ["/Users/me/go/bin/rush", "open", "0a1b2c3d"])
        #expect(AgtopCliAdapter.openArguments(executable: "/Users/me/go/bin/agtop", id: "0a1b2c3d")
            == ["/Users/me/go/bin/agtop", "open", "0a1b2c3d", "--solo"])
        #expect(AgtopCliAdapter.remoteOpenScript(id: "0a1b2c3d")
            == "if command -v rush >/dev/null 2>&1; then exec rush open '0a1b2c3d'; else exec agtop open '0a1b2c3d' --solo; fi")
    }

    @Test("Versions compare by build, not by the day each machine prints")
    func versionBuild() {
        #expect(AgtopCliAdapter.build(ofVersion: "rush b06e734 (Sep 30)") == AgtopCliAdapter.build(ofVersion: "rush b06e734 (Sep 29)"))
        #expect(AgtopCliAdapter.build(ofVersion: "rush b06e734 (Sep 30)") != AgtopCliAdapter.build(ofVersion: "agtop 31c008a (Sep 28)"))
    }

    // MARK: - agtop on a machine

    @Test("agtop on a machine runs through the bridge, with the prompt on stdin and the images copied over")
    func remoteAdapter() async throws {
        let runner = FakeRemoteCommandRunner()
        runner.script(["/usr/local/bin/agtop", "session", "info", "0a1b2c3d", "--json"], ShellCommand.Result(
            exitCode: 0, stdout: #"{"id":"0a1b2c3d","sessionId":"s","cwd":"/root/repo","state":"idle","alive":true}"#, stderr: ""))
        runner.setFallback(ShellCommand.Result(
            exitCode: 0, stdout: #"{"id":"0a1b2c3d","sessionId":"s","cwd":"/root/repo","state":"starting","alive":true}"#, stderr: ""))
        let agtop = AgtopCliAdapter(remote: runner, executable: "/usr/local/bin/agtop", scratchDirectory: "/root/.kanban-code/tmp/agtop")
        #expect(agtop.isAvailable)

        let image = NSTemporaryDirectory() + "kanban-agtop-image-\(UUID().uuidString).png"
        try Data([1, 2, 3]).write(to: URL(fileURLWithPath: image))
        defer { try? FileManager.default.removeItem(atPath: image) }

        _ = try await agtop.start(AgtopStartRequest(
            cwd: "/root/repo", sessionId: "0a1b2c3d-1111-2222-3333-444455556666", resume: true,
            prompt: "go on", imagePaths: [image]))
        let start = try #require(runner.execCalls.first)
        #expect(Array(start.prefix(3)) == ["/usr/local/bin/agtop", "session", "start"])
        #expect(start.contains("--prompt-file") && start[start.firstIndex(of: "--prompt-file")! + 1] == "-")
        #expect(runner.execStdins.first == "go on")
        let copied = try #require(runner.files.keys.first)
        #expect(copied.hasPrefix("/root/.kanban-code/tmp/agtop/") && copied.hasSuffix("/1.png"))
        #expect(start[start.firstIndex(of: "--image")! + 1] == copied)

        try await agtop.send(id: "0a1b2c3d", text: "hello", imagePaths: ["/root/already-there.png"])
        #expect(runner.execCalls.last == ["/usr/local/bin/agtop", "session", "send", "0a1b2c3d", "--image", "/root/already-there.png"])
        #expect(runner.execStdins.last == "hello")
        #expect(try await agtop.info(id: "0a1b2c3d")?.alive == true)
    }

    @Test("An agtop name on a machine routes to that machine's agtop, and only its own hosts are listed")
    func remoteRouting() async throws {
        let runner = FakeRemoteCommandRunner()
        runner.script(["/usr/local/bin/agtop", "session", "list", "--json"], ShellCommand.Result(exitCode: 0, stdout: """
            [{"id":"0a1b2c3d","sessionId":"s1","cwd":"/root/repo","state":"working","alive":true,"queue":["next"]},
             {"id":"feedbeef","sessionId":"s2","cwd":"/root/other","state":"idle","alive":true}]
            """, stderr: ""))
        let registry = RemoteSessionRegistry()
        let router = RoutingTmuxAdapter(
            local: TmuxAdapter(transport: FakeTmuxTransport(label: "local")),
            registry: registry,
            agtop: AgtopCliAdapter(executable: "/nonexistent/agtop"))
        registry.assign(sessionName: "agtop-0a1b2c3d", to: "box")
        registry.setMachine("box", state: .connected, tmux: TmuxAdapter(transport: FakeTmuxTransport(label: "box")))
        registry.setAgtop(AgtopCliAdapter(remote: runner, executable: "/usr/local/bin/agtop", scratchDirectory: "/tmp/a"), on: "box")

        try await router.sendPrompt(to: "agtop-0a1b2c3d", text: "hi")
        #expect(runner.execCalls.last == ["/usr/local/bin/agtop", "session", "send", "0a1b2c3d"])

        let sessions = try await router.listSessions()
        #expect(sessions.contains { $0.name == "agtop-0a1b2c3d" && $0.agtopQueue == ["next"] })
        // Another master's host on the same machine is not this one's.
        #expect(!sessions.contains { $0.name == "agtop-feedbeef" })

        try await router.killSession(name: "agtop-0a1b2c3d")
        #expect(runner.execCalls.last == ["/usr/local/bin/agtop", "session", "stop", "0a1b2c3d"])
        #expect(registry.machine(forSession: "agtop-0a1b2c3d") == nil)

        // A machine that is not connected refuses instead of falling back here.
        registry.assign(sessionName: "agtop-0a1b2c3d", to: "box")
        registry.disconnectMachine("box", state: .unreachable)
        #expect(throws: RemoteMachineUnavailable.self) { try router.agtop(forSession: "agtop-0a1b2c3d") }
    }
}
