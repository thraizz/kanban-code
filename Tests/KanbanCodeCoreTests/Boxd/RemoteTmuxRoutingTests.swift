import Testing
import Foundation
@testable import KanbanCodeCore

private let ok = ShellCommand.Result(exitCode: 0, stdout: "", stderr: "")
private let failed = ShellCommand.Result(exitCode: 1, stdout: "", stderr: "no such session")

private func sessionList(_ sessions: [(String, String)]) -> ShellCommand.Result {
    ShellCommand.Result(
        exitCode: 0,
        stdout: sessions.map { "\($0.0)\(TmuxAdapter.listSeparator)\($0.1)\(TmuxAdapter.listSeparator)0" }.joined(separator: "\n"),
        stderr: ""
    )
}

private let listArgs = ["list-sessions", "-F", "#{session_name}\(TmuxAdapter.listSeparator)#{session_path}\(TmuxAdapter.listSeparator)#{session_attached}"]

@Suite("BridgeTmuxTransport")
struct BridgeTmuxTransportTests {

    @Test("run prefixes tmux and passes the arguments through")
    func runPrefixesTmux() async throws {
        let runner = FakeRemoteCommandRunner()
        runner.script(["tmux", "kill-session", "-t", "card"], ok)
        let transport = BridgeTmuxTransport(runner: runner, remoteHome: "/home/boxd")

        let result = try await transport.run(["kill-session", "-t", "card"], timeout: 5)

        #expect(result.succeeded)
        #expect(runner.execCalls == [["tmux", "kill-session", "-t", "card"]])
    }

    @Test("writeTempFile puts the file under the remote kanban tmp directory")
    func writeTempFile() async throws {
        let runner = FakeRemoteCommandRunner()
        let transport = BridgeTmuxTransport(runner: runner, remoteHome: "/home/boxd")

        let path = try await transport.writeTempFile(name: "launch-card.sh", contents: "echo hi\n")

        #expect(path == "/home/boxd/.kanban-code/tmp/kanban-code-launch-card.sh")
        #expect(transport.tempDirectory == "/home/boxd/.kanban-code/tmp")
        #expect(runner.files[path] == Data("echo hi\n".utf8))
        #expect(runner.mode(of: path) == nil)
    }

    @Test("removeTempFile removes the file on the machine")
    func removeTempFile() async throws {
        let runner = FakeRemoteCommandRunner()
        let transport = BridgeTmuxTransport(runner: runner, remoteHome: "/home/boxd")
        let path = try await transport.writeTempFile(name: "x.txt", contents: "x")

        await transport.removeTempFile(path)

        #expect(runner.removedPaths == [path])
        #expect(runner.files[path] == nil)
    }

    @Test("isAvailable follows the connection of the runner")
    func isAvailableFollowsConnection() async {
        let runner = FakeRemoteCommandRunner(connected: false)
        let transport = BridgeTmuxTransport(runner: runner, remoteHome: "/home/boxd")

        #expect(await transport.isAvailable() == false)
        runner.connected = true
        #expect(await transport.isAvailable() == true)
    }
}

@Suite("TmuxAdapter over a transport")
struct TmuxAdapterTransportTests {

    @Test("A multi-line command is written to the transport and sourced")
    func multiLineCommandIsSourced() async throws {
        let transport = FakeTmuxTransport(label: "remote")
        transport.script(["has-session", "-t", "card"], failed)
        transport.script(["new-session", "-d", "-s", "card", "-c", "/home/boxd/repo"], ok)
        let adapter = TmuxAdapter(transport: transport)

        try await adapter.createSession(name: "card", path: "/home/boxd/repo", command: "export A=1\nclaude --resume x")

        let script = "export A=1\nclaude --resume x"
        #expect(transport.tempFiles["/fake/remote/launch-card.sh"] == script)
        #expect(transport.calls.contains([
            "send-keys", "-t", "card",
            ". '/fake/remote/launch-card.sh' ; rm -f '/fake/remote/launch-card.sh'",
            "Enter",
        ]))
    }

    @Test("A single-line command is sent as it is, with no temp file")
    func singleLineCommandIsSentDirectly() async throws {
        let transport = FakeTmuxTransport()
        transport.script(["has-session", "-t", "card"], failed)
        transport.script(["new-session", "-d", "-s", "card", "-c", "/repo"], ok)
        let adapter = TmuxAdapter(transport: transport)

        try await adapter.createSession(name: "card", path: "/repo", command: "claude")

        #expect(transport.tempFiles.isEmpty)
        #expect(transport.calls.contains(["send-keys", "-t", "card", "claude", "Enter"]))
    }

    @Test("An existing session is reused, not recreated")
    func existingSessionIsReused() async throws {
        let transport = FakeTmuxTransport()
        transport.script(["has-session", "-t", "card"], ok)
        let adapter = TmuxAdapter(transport: transport)

        try await adapter.createSession(name: "card", path: "/repo", command: "claude")

        #expect(transport.calls == [["has-session", "-t", "card"]])
    }

    @Test("listSessions parses the tab separated format")
    func listSessionsParses() async throws {
        let transport = FakeTmuxTransport()
        transport.script(listArgs, sessionList([("a", "/repo"), ("b", "/other")]))
        let adapter = TmuxAdapter(transport: transport)

        let sessions = try await adapter.listSessions()

        #expect(sessions.map(\.name) == ["a", "b"])
        #expect(sessions.map(\.path) == ["/repo", "/other"])
    }
}

@Suite("RoutingTmuxAdapter")
struct RoutingTmuxAdapterTests {

    private func makeRouter() -> (RoutingTmuxAdapter, FakeTmuxTransport, RemoteSessionRegistry) {
        let localTransport = FakeTmuxTransport(label: "local")
        let registry = RemoteSessionRegistry()
        let router = RoutingTmuxAdapter(
            local: TmuxAdapter(transport: localTransport),
            registry: registry,
            rush: RushCliAdapter(executable: "/nonexistent/rush")
        )
        return (router, localTransport, registry)
    }

    @Test("An unknown session name goes to the local adapter")
    func unknownNameIsLocal() async throws {
        let (router, localTransport, _) = makeRouter()

        _ = try await router.capturePane(sessionName: "plain-card")

        #expect(router.isRemote("plain-card") == false)
        #expect(localTransport.calls == [["capture-pane", "-p", "-t", "plain-card"]])
    }

    @Test("A name on a connected machine goes to that machine's adapter")
    func assignedNameGoesToTheMachine() async throws {
        let (router, localTransport, registry) = makeRouter()
        let remoteTransport = FakeTmuxTransport(label: "remote")
        registry.assign(sessionName: "remote-card", to: "kanban-repo-1")
        registry.setMachine("kanban-repo-1", state: .connected, tmux: TmuxAdapter(transport: remoteTransport))

        _ = try await router.capturePane(sessionName: "remote-card")

        #expect(router.isRemote("remote-card") == true)
        #expect(localTransport.calls.isEmpty)
        #expect(remoteTransport.calls == [["capture-pane", "-p", "-t", "remote-card"]])
    }

    @Test("A name on a paused machine throws RemoteMachineUnavailable")
    func pausedMachineThrows() async throws {
        let (router, localTransport, registry) = makeRouter()
        let remoteTransport = FakeTmuxTransport(label: "remote")
        registry.assign(sessionName: "remote-card", to: "kanban-repo-1")
        registry.setMachine("kanban-repo-1", state: .connected, tmux: TmuxAdapter(transport: remoteTransport))
        registry.disconnectMachine("kanban-repo-1", state: .paused(.inactivity))

        #expect(throws: RemoteMachineUnavailable(machineName: "kanban-repo-1", state: .paused(.inactivity))) {
            _ = try router.adapter(for: "remote-card")
        }
        await #expect(throws: RemoteMachineUnavailable(machineName: "kanban-repo-1", state: .paused(.inactivity))) {
            _ = try await router.capturePane(sessionName: "remote-card")
        }
        // The command must never fall through to the local tmux server.
        #expect(localTransport.calls.isEmpty)
        #expect(remoteTransport.calls.isEmpty)
    }

    @Test("A name on a machine that was never connected reports unreachable")
    func neverConnectedMachineThrowsUnreachable() throws {
        let (router, _, registry) = makeRouter()
        registry.assign(sessionName: "remote-card", to: "kanban-repo-1")
        registry.setMachine("kanban-repo-1", state: .unreachable)

        #expect(throws: RemoteMachineUnavailable(machineName: "kanban-repo-1", state: .unreachable)) {
            _ = try router.adapter(for: "remote-card")
        }
    }

    @Test("listSessions merges the local list with the live list of a connected machine")
    func listSessionsMergesLive() async throws {
        let (router, localTransport, registry) = makeRouter()
        localTransport.script(listArgs, sessionList([("local-card", "/repo")]))
        let remoteTransport = FakeTmuxTransport(label: "remote")
        remoteTransport.script(listArgs, sessionList([("remote-card", "/home/boxd/repo")]))
        registry.assign(sessionName: "remote-card", to: "kanban-repo-1")
        registry.setMachine("kanban-repo-1", state: .connected, tmux: TmuxAdapter(transport: remoteTransport))

        let sessions = try await router.listSessions()

        #expect(sessions.map(\.name).sorted() == ["local-card", "remote-card"])
        // The live list is recorded, so a later pause still reports it.
        #expect(registry.knownSessions(on: "kanban-repo-1").map(\.name) == ["remote-card"])
    }

    @Test("listSessions reports the last known names of a paused machine")
    func listSessionsKeepsPausedNames() async throws {
        let (router, localTransport, registry) = makeRouter()
        localTransport.script(listArgs, sessionList([("local-card", "/repo")]))
        registry.assign(sessionName: "remote-card", to: "kanban-repo-1")
        registry.setMachine("kanban-repo-1", state: .connected)
        registry.recordSessions([TmuxSession(name: "remote-card", path: "/home/boxd/repo")], on: "kanban-repo-1")
        registry.disconnectMachine("kanban-repo-1", state: .paused(.appQuit))

        let sessions = try await router.listSessions()

        #expect(sessions.map(\.name).sorted() == ["local-card", "remote-card"])
    }

    @Test("killSession unassigns the name from its machine")
    func killSessionUnassigns() async throws {
        let (router, _, registry) = makeRouter()
        let remoteTransport = FakeTmuxTransport(label: "remote")
        registry.assign(sessionName: "remote-card", to: "kanban-repo-1")
        registry.setMachine("kanban-repo-1", state: .connected, tmux: TmuxAdapter(transport: remoteTransport))
        registry.recordSessions([TmuxSession(name: "remote-card", path: "/home/boxd/repo")], on: "kanban-repo-1")

        try await router.killSession(name: "remote-card")

        #expect(remoteTransport.calls == [["kill-session", "-t", "remote-card"]])
        #expect(registry.machine(forSession: "remote-card") == nil)
        #expect(registry.knownSessions(on: "kanban-repo-1").isEmpty)
        #expect(router.isRemote("remote-card") == false)
    }

    @Test("isAvailable only asks the local tmux")
    func isAvailableUsesLocal() async {
        let (router, localTransport, _) = makeRouter()
        localTransport.setAvailable(false)

        #expect(await router.isAvailable() == false)
    }
}

@Suite("RemoteSessionRegistry")
struct RemoteSessionRegistryTests {

    private func remoteLink(
        id: String,
        machine: String,
        sessionName: String,
        pausedReason: RemotePausedReason? = nil,
        remoteCwd: String? = "/home/boxd/repo"
    ) -> Link {
        Link(
            id: id,
            projectPath: "/repo",
            column: .inProgress,
            tmuxLink: TmuxLink(sessionName: sessionName),
            isRemote: true,
            remote: RemoteLink(
                machineName: machine,
                remoteCwd: remoteCwd,
                pausedReason: pausedReason
            )
        )
    }

    @Test("seed maps every tmux name of a remote link to its machine")
    func seedMapsNames() {
        let registry = RemoteSessionRegistry()
        var link = remoteLink(id: "card_1", machine: "kanban-repo-1", sessionName: "primary")
        link.tmuxLink?.extraSessions = ["extra"]
        let plain = Link(id: "card_2", projectPath: "/repo", column: .inProgress, tmuxLink: TmuxLink(sessionName: "local"))

        registry.seed(from: [link, plain])

        #expect(registry.machine(forSession: "primary") == "kanban-repo-1")
        #expect(registry.machine(forSession: "extra") == "kanban-repo-1")
        #expect(registry.machine(forSession: "local") == nil)
        #expect(registry.sessionNames(on: "kanban-repo-1") == ["primary", "extra"])
        #expect(registry.knownSessions(on: "kanban-repo-1").first(where: { $0.name == "primary" })?.path == "/home/boxd/repo")
    }

    @Test("seed sets paused when the link carries a paused reason, else unreachable")
    func seedSetsState() {
        let registry = RemoteSessionRegistry()
        registry.seed(from: [
            remoteLink(id: "card_1", machine: "kanban-paused", sessionName: "a", pausedReason: .systemSleep),
            remoteLink(id: "card_2", machine: "kanban-cold", sessionName: "b"),
        ])

        #expect(registry.state(of: "kanban-paused") == .paused(.systemSleep))
        #expect(registry.state(of: "kanban-cold") == .unreachable)
        #expect(registry.machineNames == ["kanban-cold", "kanban-paused"])
    }

    @Test("seed skips a link with no tmux session")
    func seedSkipsLinkWithoutTmux() {
        let registry = RemoteSessionRegistry()
        let link = Link(
            id: "card_1",
            projectPath: "/repo",
            column: .inProgress,
            isRemote: true,
            remote: RemoteLink(machineName: "kanban-repo-1")
        )

        registry.seed(from: [link])

        #expect(registry.machineNames.isEmpty)
    }

    @Test("seed skips a card that no longer runs remotely")
    func seedSkipsCardThatIsNotRemote() {
        let registry = RemoteSessionRegistry()
        var link = remoteLink(id: "card_1", machine: "kanban-repo-1", sessionName: "primary")
        link.isRemote = false

        registry.seed(from: [link])

        #expect(registry.machineNames.isEmpty)
        #expect(registry.machine(forSession: "primary") == nil)
    }

    @Test("A destroyed machine loses its adapter and its known sessions")
    func destroyedMachineIsCleared() {
        let registry = RemoteSessionRegistry()
        registry.assign(sessionName: "a", to: "kanban-repo-1")
        registry.setMachine("kanban-repo-1", state: .connected, tmux: TmuxAdapter(transport: FakeTmuxTransport()))
        registry.recordSessions([TmuxSession(name: "a", path: "/home/boxd/repo")], on: "kanban-repo-1")

        registry.setMachine("kanban-repo-1", state: .destroyed)

        #expect(registry.tmux(for: "kanban-repo-1") == nil)
        #expect(registry.knownSessions(on: "kanban-repo-1").isEmpty)
    }

    @Test("assign registers an unknown machine as connecting")
    func assignRegistersMachine() {
        let registry = RemoteSessionRegistry()

        registry.assign(sessionName: "a", to: "kanban-new")

        #expect(registry.state(of: "kanban-new") == .connecting)
        #expect(registry.states["kanban-new"] == .connecting)
    }

    @Test("recordSessions also maps names the app did not assign")
    func recordSessionsMapsNewNames() {
        let registry = RemoteSessionRegistry()
        registry.setMachine("kanban-repo-1", state: .connected)

        registry.recordSessions([TmuxSession(name: "found", path: "/home/boxd/repo")], on: "kanban-repo-1")

        #expect(registry.machine(forSession: "found") == "kanban-repo-1")
    }

    @Test("forgetSession drops one name, removeMachine drops them all")
    func forgetAndRemove() {
        let registry = RemoteSessionRegistry()
        registry.setMachine("kanban-repo-1", state: .connected)
        registry.recordSessions([
            TmuxSession(name: "a", path: "/x"),
            TmuxSession(name: "b", path: "/x"),
        ], on: "kanban-repo-1")

        registry.forgetSession("a", on: "kanban-repo-1")
        #expect(registry.knownSessions(on: "kanban-repo-1").map(\.name) == ["b"])

        registry.removeMachine("kanban-repo-1")
        #expect(registry.state(of: "kanban-repo-1") == nil)
        #expect(registry.machine(forSession: "b") == nil)
    }
}
