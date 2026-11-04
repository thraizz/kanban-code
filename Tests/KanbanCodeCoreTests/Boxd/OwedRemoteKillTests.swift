import Testing
import Foundation
@testable import KanbanCodeCore

/// A bridge that dropped: every tmux command fails before tmux runs.
private struct DroppedBridgeTransport: TmuxTransport {
    struct Dropped: Error {}
    func run(_ arguments: [String], timeout: TimeInterval) async throws -> ShellCommand.Result { throw Dropped() }
    func writeTempFile(name: String, contents: String) async throws -> String { throw Dropped() }
    func removeTempFile(_ path: String) async {}
    func isAvailable() async -> Bool { false }
}

@Suite("Kills owed to a machine that was away")
struct OwedRemoteKillTests {

    private func router(_ registry: RemoteSessionRegistry) -> RoutingTmuxAdapter {
        RoutingTmuxAdapter(
            local: TmuxAdapter(transport: FakeTmuxTransport(label: "local")),
            registry: registry,
            rush: RushCliAdapter(executable: "/nonexistent/rush"))
    }

    private func supervisor(_ registry: RemoteSessionRegistry) -> BoxdMachineSupervisor {
        let home = NSTemporaryDirectory() + "owed-kills-\(UUID().uuidString)"
        return BoxdMachineSupervisor(
            boxd: FakeBoxdPort(),
            registry: registry,
            settingsProvider: { BoxdSettings() },
            cliBundlePath: nil,
            appVersion: "1.0.0-test",
            localHome: home,
            localKanbanHome: home + "/.kanban-code")
    }

    private func tempPath() -> String {
        NSTemporaryDirectory() + "owed-kills-\(UUID().uuidString)/pending-remote-kills.json"
    }

    // MARK: - Routing

    @Test("A kill for a machine that is away is owed to it")
    func killOnUnreachableMachineIsOwed() async {
        let registry = RemoteSessionRegistry()
        registry.assign(sessionName: "repo-card_1", to: "box")
        registry.setMachine("box", state: .unreachable)

        await #expect(throws: RemoteMachineUnavailable.self) {
            try await router(registry).killSession(name: "repo-card_1")
        }
        #expect(registry.pendingKills(on: "box") == ["repo-card_1"])
    }

    @Test("A kill that tmux answered is not owed, nor one for a destroyed machine, nor a local one")
    func answeredKillsAreFinal() async {
        let registry = RemoteSessionRegistry()
        let box = FakeTmuxTransport(label: "box")
        box.script(["kill-session", "-t", "repo-card_1"], ShellCommand.Result(exitCode: 1, stdout: "", stderr: "can't find session: repo-card_1"))
        registry.assign(sessionName: "repo-card_1", to: "box")
        registry.setMachine("box", state: .connected, tmux: TmuxAdapter(transport: box))
        registry.assign(sessionName: "repo-card_2", to: "gone")
        registry.setMachine("gone", state: .destroyed)
        let router = router(registry)

        _ = try? await router.killSession(name: "repo-card_1")
        _ = try? await router.killSession(name: "repo-card_2")
        _ = try? await router.killSession(name: "local-card_3")

        #expect(registry.pendingKills(on: "box").isEmpty)
        #expect(registry.pendingKills(on: "gone").isEmpty)
    }

    @Test("A kill lost with the bridge is owed")
    func killOnDroppedBridgeIsOwed() async {
        let registry = RemoteSessionRegistry()
        registry.assign(sessionName: "repo-card_1", to: "box")
        registry.setMachine("box", state: .connected, tmux: TmuxAdapter(transport: DroppedBridgeTransport()))

        _ = try? await router(registry).killSession(name: "repo-card_1")

        #expect(registry.pendingKills(on: "box") == ["repo-card_1"])
    }

    @Test("A new session under the name drops the kill owed to the old one")
    func newSessionClearsOwedKill() async throws {
        let registry = RemoteSessionRegistry()
        registry.assign(sessionName: "repo-card_1", to: "box")
        registry.queueKill(sessionName: "repo-card_1", on: "box")
        registry.setMachine("box", state: .connected, tmux: TmuxAdapter(transport: FakeTmuxTransport(label: "box")))

        try await router(registry).createSession(name: "repo-card_1", path: "/home/box/repo", command: nil)

        #expect(registry.pendingKills(on: "box").isEmpty)
    }

    // MARK: - Registry

    @Test("Owed kills survive a restart and go with a removed machine")
    func owedKillsPersist() {
        let path = tempPath()
        let registry = RemoteSessionRegistry(pendingKillsPath: path)
        registry.queueKill(sessionName: "repo-card_1", on: "box")
        registry.queueKill(sessionName: "repo-card_2", on: "box")
        registry.queueKill(sessionName: "repo-card_3", on: "other")

        let restarted = RemoteSessionRegistry(pendingKillsPath: path)
        #expect(restarted.pendingKills(on: "box") == ["repo-card_1", "repo-card_2"])
        #expect(restarted.pendingKills(on: "other") == ["repo-card_3"])

        restarted.removeMachine("box")
        restarted.clearPendingKill(sessionName: "repo-card_3")
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(RemoteSessionRegistry(pendingKillsPath: path).pendingKills(on: "box").isEmpty)
    }

    // MARK: - Supervisor

    @Test("Connecting kills the owed sessions; a gone session counts as killed")
    func connectKillsOwedSessions() async {
        let registry = RemoteSessionRegistry()
        let box = FakeTmuxTransport(label: "box")
        box.script(["kill-session", "-t", "repo-card_2"], ShellCommand.Result(exitCode: 1, stdout: "", stderr: "can't find session: repo-card_2"))
        registry.assign(sessionName: "repo-card_1", to: "box")
        registry.queueKill(sessionName: "repo-card_1", on: "box")
        registry.queueKill(sessionName: "repo-card_2", on: "box")
        registry.setMachine("box", state: .connected, tmux: TmuxAdapter(transport: box))

        await supervisor(registry).killOwedSessions(machineName: "box")

        #expect(box.calls.contains(["kill-session", "-t", "repo-card_1"]))
        #expect(box.calls.contains(["kill-session", "-t", "repo-card_2"]))
        #expect(registry.pendingKills(on: "box").isEmpty)
        #expect(registry.machine(forSession: "repo-card_1") == nil)
    }

    @Test("An owed kill the machine could not be asked about stays owed")
    func unreachedOwedKillStays() async {
        let registry = RemoteSessionRegistry()
        registry.queueKill(sessionName: "repo-card_1", on: "box")
        registry.setMachine("box", state: .connected, tmux: TmuxAdapter(transport: DroppedBridgeTransport()))

        await supervisor(registry).killOwedSessions(machineName: "box")

        #expect(registry.pendingKills(on: "box") == ["repo-card_1"])
    }
}
