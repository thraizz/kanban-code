import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import KanbanCodeRemoteKit
import Testing

@testable import KanbanCodeCore

/// Records the tmux sessions a master starts instead of running them.
private final class RecordingTmux: TmuxManagerPort, @unchecked Sendable {
    private let lock = NSLock()
    private var _created: [(name: String, command: String?)] = []
    private var _killed: [String] = []
    private var _pasted: [String] = []
    var pasted: [String] { lock.withLock { _pasted } }
    var created: [(name: String, command: String?)] { lock.withLock { _created } }
    var killed: [String] { lock.withLock { _killed } }

    func listSessions() async throws -> [TmuxSession] { [] }
    func createSession(name: String, path: String, command: String?) async throws {
        lock.withLock { _created.append((name, command)) }
    }
    func killSession(name: String) async throws { lock.withLock { _killed.append(name) } }
    func findSessionForWorktree(sessions: [TmuxSession], worktreePath: String, branch: String?) -> TmuxSession? { nil }
    func sendPrompt(to sessionName: String, text: String) async throws { lock.withLock { _pasted.append(text) } }
    func pastePrompt(to sessionName: String, text: String) async throws { lock.withLock { _pasted.append(text) } }
    func pasteText(to sessionName: String, text: String) async throws {}
    func submitPrompt(to sessionName: String) async throws {}
    func capturePane(sessionName: String) async throws -> String { "" }
    func sendBracketedPaste(to sessionName: String) async throws {}
    func isAvailable() async -> Bool { true }
}

/// One master: a board, an engine and its remote control server over a
/// temporary kanban home, with sessions recorded, not run.
@MainActor
private final class TestMaster {
    let home: String
    let identity: MachineIdentity
    let store: BoardStore
    let engine: MasterEngine
    let tmux = RecordingTmux()
    let devices: RemoteDeviceStore
    var server: RemoteControlServer!
    var peerSync: PeerSync!
    /// A token this master issued, for the other one.
    var tokenForPeer = ""

    init(name: String, root: String, alwaysOn: Bool = false) throws {
        home = "\(root)/\(name)"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        identity = MachineIdentity(name: name, alwaysOn: alwaysOn ? true : nil)
        let coordination = CoordinationStore(basePath: home)
        store = BoardStore(
            effectHandler: EffectHandler(
                coordinationStore: coordination, tmuxAdapter: tmux,
                queuedPromptJournal: QueuedPromptJournal(basePath: home)),
            discovery: ClaudeCodeSessionDiscovery(),
            coordinationStore: coordination
        )
        var platform = MasterPlatform()
        platform.projectsDirectory = "\(home)/Projects"
        platform.claudeProjectsDirectory = "\(home)/claude-projects"
        platform.kanbanHome = home
        engine = MasterEngine(
            store: store,
            settingsStore: SettingsStore(basePath: home),
            launcher: LaunchSession(tmux: tmux),
            tmux: RoutingTmuxAdapter(agtop: AgtopCliAdapter(executable: "/nonexistent/agtop")),
            registry: CodingAssistantRegistry(),
            platform: platform
        )
        store.dispatch(.localMachineLoaded(identity))
        devices = RemoteDeviceStore(path: "\(home)/devices.json")
        tokenForPeer = try devices.add(name: "peer", scope: .full).token
    }

    func start(peerURL: String, peerToken: String) async throws {
        let store = self.store
        // A master reads its own links before it pulls its peers.
        await store.loadLocalLinks()
        peerSync = PeerSync(identity: identity, peers: [PeerConfig(name: "peer", url: peerURL, token: peerToken)]) { action in
            await MainActor.run { store.dispatch(action) }
        }
        engine.peerSync = peerSync
        engine.installForeignCardHandler()
    }

    func serve() async throws {
        server = RemoteControlServer(
            host: MasterRemoteControlHost(engine: engine), devices: devices, port: 0,
            bindAddresses: { [RemoteNetworkAddresses.loopback] },
            options: .init(appVersion: "test", hostName: identity.name),
            peerServer: BoardPeerLinksServer(store: store, peerSync: nil)
        )
        try await server.start()
    }

    var url: String { "http://127.0.0.1:\(server.port)" }
}

@discardableResult
private func sh(_ args: [String], in dir: String) async throws -> String {
    let result = try await ShellCommand.run("/usr/bin/env", arguments: args, currentDirectory: dir, timeout: 60)
    #expect(result.exitCode == 0, "\(args.joined(separator: " ")): \(result.stderr)")
    return result.stdout
}

private struct FixedDiscovery: SessionDiscovery {
    let sessions: [Session]
    func discoverSessions() async throws -> [Session] { sessions }
    func discoverNewOrModified(since: Date) async throws -> [Session] { sessions }
}

@Suite("Master handover between peers", .serialized)
@MainActor
struct MasterHandoverTests {
    @Test("repository URLs compare across ssh and https forms")
    func repoURLs() {
        #expect(MasterEngine.normalizedRepoURL("git@github.com:ACME/Widgets.git") == "github.com/acme/widgets")
        #expect(MasterEngine.normalizedRepoURL("https://github.com/acme/widgets") == "github.com/acme/widgets")
        #expect(MasterEngine.normalizedRepoURL("ssh://git@github.com/acme/widgets.git/") == "github.com/acme/widgets")
        #expect(MasterEngine.repoName(of: "git@github.com:acme/widgets.git") == "widgets")
        #expect(MasterEngine.repoName(of: "/tmp/origin/widgets.git") == "widgets")
    }

    @Test("a card moves to a peer: session ends, branch and changes follow, the peer adopts and resumes")
    func handover() async throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("handover-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let origin = "\(root)/origin/widgets.git"
        let repoA = "\(root)/mac/widgets"
        try FileManager.default.createDirectory(atPath: "\(root)/origin", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: "\(root)/mac", withIntermediateDirectories: true)
        try await sh(["git", "init", "--bare", "-q", origin], in: root)
        try await sh(["git", "clone", "-q", origin, repoA], in: root)
        try await sh(["git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init"], in: repoA)
        try await sh(["git", "push", "-q", "origin", "HEAD"], in: repoA)
        let worktreeA = "\(repoA)/.claude/worktrees/fix-bug"
        try await sh(["git", "worktree", "add", "-q", "-b", "fix-bug", worktreeA], in: repoA)
        try await sh(["git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "work"], in: worktreeA)
        try "not committed yet\n".write(toFile: "\(worktreeA)/notes.txt", atomically: true, encoding: .utf8)

        let mac = try TestMaster(name: "mac", root: root)
        let box = try TestMaster(name: "box", root: root)
        try await mac.serve()
        try await box.serve()
        try await mac.start(peerURL: box.url, peerToken: box.tokenForPeer)
        try await box.start(peerURL: mac.url, peerToken: mac.tokenForPeer)
        defer { mac.server.stop(); box.server.stop() }

        let sessionId = "0f1e2d3c-aaaa-bbbb-cccc-000000000001"
        let transcriptA = mac.engine.transcriptPath(cwd: worktreeA, sessionId: sessionId)
        try FileManager.default.createDirectory(atPath: (transcriptA as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let line = #"{"type":"user","cwd":"\#(worktreeA)","message":{"role":"user","content":"edit \#(worktreeA)/notes.txt"}}"#
        try (line + "\n").write(toFile: transcriptA, atomically: true, encoding: .utf8)
        mac.store.dispatch(.createManualTask(Link(
            id: "card_move", name: "Fix the bug", projectPath: repoA, column: .waiting,
            sessionLink: SessionLink(sessionId: sessionId, sessionPath: transcriptA),
            tmuxLink: TmuxLink(sessionName: "claude-0f1e2d3c"),
            worktreeLink: WorktreeLink(path: worktreeA, branch: "fix-bug")
        )))

        await mac.peerSync.pullAll()
        await box.peerSync.pullAll()
        #expect(box.store.state.links["card_move"]?.ownerMachine == mac.identity.id)
        #expect(mac.engine.isPeerOnline(box.identity.id))

        try await mac.engine.moveCard("card_move", to: "box")
        #expect(mac.tmux.killed.contains("claude-0f1e2d3c") || mac.store.state.links["card_move"]?.tmuxLink != nil)
        #expect(mac.store.state.links["card_move"]?.ownerMachine == box.identity.id)
        #expect(mac.store.state.links["card_move"]?.migrating == true)
        let pushed = try await sh(["git", "branch", "--list", "fix-bug"], in: origin)
        #expect(pushed.contains("fix-bug"))

        await box.peerSync.pullAll()
        let released = try #require(box.store.state.links["card_move"])
        #expect(released.ownerMachine == box.identity.id)
        #expect(released.migrating == true)

        try await box.engine.adopt(cardId: "card_move")
        let adopted = try #require(box.store.state.links["card_move"])
        let repoB = "\(box.home)/Projects/widgets"
        let worktreeB = "\(repoB)/.claude/worktrees/fix-bug"
        #expect(adopted.migrating == nil)
        #expect(adopted.projectPath == repoB)
        #expect(adopted.worktreeLink?.path == worktreeB)
        #expect(FileManager.default.fileExists(atPath: "\(worktreeB)/notes.txt"))
        let log = try await sh(["git", "log", "--format=%s", "-1"], in: worktreeB)
        #expect(log.contains("work"))
        // Serving the uncommitted changes left the Mac's index alone.
        let statusA = try await sh(["git", "status", "--porcelain"], in: worktreeA)
        #expect(statusA.contains("?? notes.txt"))
        let transcriptB = try #require(adopted.sessionLink?.sessionPath)
        #expect(transcriptB == box.engine.transcriptPath(cwd: worktreeB, sessionId: sessionId))
        let copied = try String(contentsOfFile: transcriptB, encoding: .utf8)
        #expect(copied.contains(worktreeB))
        #expect(!copied.contains(worktreeA))

        // The resume runs on the box.
        for _ in 0..<50 where box.tmux.created.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        #expect(box.tmux.created.first?.command?.contains("--resume \(sessionId)") == true)

        // The Mac sees the box as the owner once it pulls.
        await mac.peerSync.pullAll()
        #expect(mac.store.state.links["card_move"]?.ownerMachine == box.identity.id)
        #expect(mac.store.state.links["card_move"]?.migrating == nil)
        #expect(mac.engine.isForeign("card_move"))
    }

    @Test("reconcile leaves a card released to this master alone until it is adopted")
    func migratingIsFrozen() async throws {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("frozen-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let coordination = CoordinationStore(basePath: dir)
        let store = BoardStore(
            effectHandler: EffectHandler(coordinationStore: coordination, tmuxAdapter: RecordingTmux(),
                                         queuedPromptJournal: QueuedPromptJournal(basePath: dir)),
            discovery: FixedDiscovery(sessions: [Session(id: "sid-1", projectPath: "/box/repo", jsonlPath: "/box/stale.jsonl")]),
            coordinationStore: coordination
        )
        store.dispatch(.localMachineLoaded(MachineIdentity(id: "machine_box", name: "box")))
        await store.loadLocalLinks()
        var link = Link(id: "card_x", name: "Moving", projectPath: "/mac/repo", column: .waiting,
                        sessionLink: SessionLink(sessionId: "sid-1", sessionPath: "/mac/live.jsonl"))
        link.ownerMachine = "machine_mac"
        link.ownerRev = SyncStamp(counter: 5, machine: "machine_mac")
        store.dispatch(.peerLinksMerged(peer: "machine_mac", links: [link]))
        var release = link
        release.ownerMachine = "machine_box"
        release.migrating = true
        release.ownerRev = SyncStamp(counter: 6, machine: "machine_mac")
        store.dispatch(.peerLinksMerged(peer: "machine_mac", links: [release]))
        #expect(store.state.links["card_x"]?.migrating == true)
        await store.reconcile()
        #expect(store.state.links["card_x"]?.sessionLink?.sessionPath == "/mac/live.jsonl")
        #expect(store.state.links["card_x"]?.ownerRev == SyncStamp(counter: 6, machine: "machine_mac"))
    }

    @Test("a prompt on a card another master owns goes to that master")
    func foreignPrompt() async throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("foreign-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let mac = try TestMaster(name: "mac", root: root)
        let box = try TestMaster(name: "box", root: root)
        try await mac.serve()
        try await box.serve()
        try await mac.start(peerURL: box.url, peerToken: box.tokenForPeer)
        try await box.start(peerURL: mac.url, peerToken: mac.tokenForPeer)
        defer { mac.server.stop(); box.server.stop() }

        box.store.dispatch(.createManualTask(Link(
            id: "card_box", name: "On the box", projectPath: "/tmp/acme", column: .waiting,
            sessionLink: SessionLink(sessionId: "sid-box"), tmuxLink: TmuxLink(sessionName: "box-session")
        )))
        box.store.dispatch(.tmuxLivenessScanned(live: ["box-session"]))
        await mac.peerSync.pullAll()
        await box.peerSync.pullAll()
        #expect(mac.engine.isForeign("card_box"))
        #expect(mac.store.state.cards.first { $0.id == "card_box" }?.owner?.name == "box")

        mac.store.dispatch(.addQueuedPrompt(cardId: "card_box", prompt: QueuedPrompt(body: "from the mac"), placement: .back))
        // Nothing queued on the Mac's copy; the box got it and sent it.
        #expect(mac.store.state.links["card_box"]?.queuedPrompts == nil)
        for _ in 0..<60 where box.tmux.created.isEmpty && box.store.state.links["card_box"]?.queuedPrompts == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        let boxLink = try #require(box.store.state.links["card_box"])
        // An idle live card sends at once: the prompt went through the box's queue.
        #expect(boxLink.queuedPrompts == nil || boxLink.queuedPrompts?.first?.body == "from the mac")
    }

    @Test("renames, moves and archives from either master converge on both")
    func sharedEditsConverge() async throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("converge-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let mac = try TestMaster(name: "mac", root: root)
        let box = try TestMaster(name: "box", root: root)
        try await mac.serve()
        try await box.serve()
        try await mac.start(peerURL: box.url, peerToken: box.tokenForPeer)
        try await box.start(peerURL: mac.url, peerToken: mac.tokenForPeer)
        defer { mac.server.stop(); box.server.stop() }
        box.store.dispatch(.createManualTask(Link(id: "card_c", name: "Start", projectPath: "/tmp/acme", column: .waiting)))
        await mac.peerSync.pullAll()
        await box.peerSync.pullAll()

        let macClient = RemoteClient(baseURL: URL(string: mac.url)!, token: try mac.devices.add(name: "phone", scope: .full).token)
        let boxClient = RemoteClient(baseURL: URL(string: box.url)!, token: try box.devices.add(name: "phone", scope: .full).token)
        // One after the other: both edits stay.
        _ = try await macClient.updateCard(cardId: "card_c", RemoteCardUpdate(name: "Renamed on the Mac"))
        await box.peerSync.pullAll()
        _ = try await boxClient.updateCard(cardId: "card_c", RemoteCardUpdate(column: .inReview))
        await mac.peerSync.pullAll()
        for master in [mac, box] {
            #expect(master.store.state.links["card_c"]?.name == "Renamed on the Mac")
            #expect(master.store.state.links["card_c"]?.column == .inReview)
        }
        // At the same time: both masters end on the same card.
        _ = try await macClient.updateCard(cardId: "card_c", RemoteCardUpdate(name: "Mac wins?"))
        _ = try await boxClient.updateCard(cardId: "card_c", RemoteCardUpdate(name: "Box wins?"))
        await mac.peerSync.pullAll()
        await box.peerSync.pullAll()
        #expect(mac.store.state.links["card_c"]?.name == box.store.state.links["card_c"]?.name)
        _ = try await macClient.updateCard(cardId: "card_c", RemoteCardUpdate(archived: true))
        await box.peerSync.pullAll()
        #expect(box.store.state.links["card_c"]?.manuallyArchived == true)
        #expect(box.store.state.links["card_c"]?.ownerMachine == nil)
    }

    @Test("a card that ran over ssh on the peer's machine continues there in the same folder, with its transcript")
    func sshCardMovesToTheMasterOnItsMachine() async throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("ssh-handover-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let origin = "\(root)/origin/widgets.git"
        let repoA = "\(root)/mac/widgets"
        try FileManager.default.createDirectory(atPath: "\(root)/origin", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: "\(root)/mac", withIntermediateDirectories: true)
        try await sh(["git", "init", "--bare", "-q", origin], in: root)
        try await sh(["git", "clone", "-q", origin, repoA], in: root)
        try await sh(["git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init"], in: repoA)
        try await sh(["git", "push", "-q", "origin", "HEAD"], in: repoA)

        let mac = try TestMaster(name: "mac", root: root)
        let box = try TestMaster(name: "box", root: root)
        try await mac.serve()
        try await box.serve()
        try await mac.start(peerURL: box.url, peerToken: box.tokenForPeer)
        try await box.start(peerURL: mac.url, peerToken: mac.tokenForPeer)
        defer { mac.server.stop(); box.server.stop() }

        // The box's own checkout, where the ssh session ran: a worktree with
        // work nobody committed, and the transcript the session wrote.
        let repoB = "\(box.home)/Projects/widgets"
        try FileManager.default.createDirectory(atPath: "\(box.home)/Projects", withIntermediateDirectories: true)
        try await sh(["git", "clone", "-q", origin, repoB], in: root)
        let worktreeB = "\(repoB)/.claude/worktrees/fix-bug"
        try await sh(["git", "worktree", "add", "-q", "-b", "fix-bug", worktreeB], in: repoB)
        try "written over ssh\n".write(toFile: "\(worktreeB)/notes.txt", atomically: true, encoding: .utf8)
        let sessionId = "0f1e2d3c-aaaa-bbbb-cccc-000000000002"
        let transcriptB = box.engine.transcriptPath(cwd: worktreeB, sessionId: sessionId)
        try FileManager.default.createDirectory(atPath: (transcriptB as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let first = #"{"type":"user","cwd":"\#(worktreeB)","message":{"role":"user","content":"first"}}"#
        let second = #"{"type":"user","cwd":"\#(worktreeB)","message":{"role":"user","content":"second"}}"#
        try (first + "\n" + second + "\n").write(toFile: transcriptB, atomically: true, encoding: .utf8)

        // The Mac's mirror of that conversation, and the card it drives there.
        let worktreeA = "\(repoA)/.claude/worktrees/fix-bug"
        let transcriptA = mac.engine.transcriptPath(cwd: worktreeA, sessionId: sessionId)
        try FileManager.default.createDirectory(atPath: (transcriptA as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try (first.replacingOccurrences(of: worktreeB, with: worktreeA) + "\n").write(toFile: transcriptA, atomically: true, encoding: .utf8)
        mac.store.dispatch(.settingsLoaded(projects: [], excludedPaths: [], remote: nil, remoteMode: .ssh, boxd: BoxdSettings(
            sshMachines: [SshMachine(name: "platform", target: "root@127.0.0.1")])))
        mac.store.dispatch(.createManualTask(Link(
            id: "card_ssh", name: "Fix the bug", projectPath: repoA, column: .waiting,
            sessionLink: SessionLink(sessionId: sessionId, sessionPath: transcriptA),
            worktreeLink: WorktreeLink(path: worktreeA, branch: "fix-bug"),
            isRemote: true,
            remote: RemoteLink(machineName: "platform", remoteProjectPath: repoB, remoteCwd: worktreeB)
        )))
        await mac.peerSync.pullAll()
        await box.peerSync.pullAll()
        #expect(mac.store.state.peerMachine(named: "platform")?.id == box.identity.id)

        // Its next resume on that machine hands it to the box's master.
        #expect(mac.engine.resume(cardId: "card_ssh", runRemotely: true, commandOverride: nil))
        for _ in 0..<100 where mac.store.state.links["card_ssh"]?.ownerMachine != box.identity.id {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(mac.store.state.links["card_ssh"]?.ownerMachine == box.identity.id)
        #expect(mac.tmux.created.isEmpty)

        await box.peerSync.pullAll()
        try await box.engine.adopt(cardId: "card_ssh")
        let adopted = try #require(box.store.state.links["card_ssh"])
        #expect(adopted.worktreeLink?.path == worktreeB)
        #expect(adopted.sessionLink?.sessionPath == transcriptB)
        // Nothing was stashed or replaced.
        #expect((try? String(contentsOfFile: "\(worktreeB)/notes.txt", encoding: .utf8)) == "written over ssh\n")
        #expect(BoxdLaunchPlanner.lineCount(ofFileAt: transcriptB) == 2)
        for _ in 0..<50 where box.tmux.created.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        #expect(box.tmux.created.first?.command?.contains("--resume \(sessionId)") == true)
    }

    @Test("a first launch on a peer releases the card and the peer starts it")
    func launchOnPeer() async throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("peer-launch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let origin = "\(root)/origin/widgets.git"
        let repoA = "\(root)/mac/widgets"
        try FileManager.default.createDirectory(atPath: "\(root)/origin", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: "\(root)/mac", withIntermediateDirectories: true)
        try await sh(["git", "init", "--bare", "-q", origin], in: root)
        try await sh(["git", "clone", "-q", origin, repoA], in: root)
        try await sh(["git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init"], in: repoA)
        try await sh(["git", "push", "-q", "origin", "HEAD"], in: repoA)

        let mac = try TestMaster(name: "mac", root: root)
        let box = try TestMaster(name: "box", root: root)
        try await mac.serve()
        try await box.serve()
        try await mac.start(peerURL: box.url, peerToken: box.tokenForPeer)
        try await box.start(peerURL: mac.url, peerToken: mac.tokenForPeer)
        defer { mac.server.stop(); box.server.stop() }
        await mac.peerSync.pullAll()
        await box.peerSync.pullAll()

        mac.store.dispatch(.createManualTask(Link(id: "card_new", name: "New work", projectPath: repoA, column: .backlog, promptBody: "do it")))
        mac.engine.launch(cardId: "card_new", prompt: "do it now", projectPath: repoA, worktreeName: nil,
                          runRemotely: true, machineChoice: .existing("box"))
        #expect(mac.store.state.links["card_new"]?.ownerMachine == box.identity.id)
        #expect(mac.store.state.links["card_new"]?.isLaunching != true)
        #expect(mac.tmux.created.isEmpty)

        await box.peerSync.pullAll()
        try await box.engine.adopt(cardId: "card_new")
        #expect(box.store.state.links["card_new"]?.projectPath == "\(box.home)/Projects/widgets")
        for _ in 0..<50 where box.tmux.created.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        #expect(box.tmux.created.count == 1)
    }
}

// MARK: - Roles, channels and commands across masters

@Suite("Masters share the work only one of them does", .serialized)
@MainActor
struct MasterRolesTests {
    private func peer(_ id: String, online: Bool, alwaysOn: Bool = false) -> PeerStatus {
        PeerStatus(peerId: "peer_\(id)", machine: MachineIdentity(id: id, name: id, alwaysOn: alwaysOn ? true : nil), online: online)
    }

    @Test("the always-on master polls pull requests while online, else the lowest machine id")
    func prLeader() {
        let mac = MachineIdentity(id: "machine_m", name: "mac")
        #expect(MasterRoles.prPollingLeader(local: mac, peers: [peer("machine_z", online: true, alwaysOn: true)]) == "machine_z")
        #expect(MasterRoles.prPollingLeader(local: mac, peers: [peer("machine_z", online: false, alwaysOn: true)]) == "machine_m")
        #expect(MasterRoles.prPollingLeader(local: mac, peers: [peer("machine_a", online: true)]) == "machine_a")
        #expect(MasterRoles.prPollingLeader(local: mac, peers: [peer("machine_x", online: true)]) == "machine_m")
        let box = MachineIdentity(id: "machine_z", name: "box", alwaysOn: true)
        #expect(MasterRoles.prPollingLeader(local: box, peers: [peer("machine_m", online: true)]) == "machine_z")
    }

    @Test("the channels home is the always-on master, online or not")
    func channelsHome() {
        let mac = MachineIdentity(id: "machine_m", name: "mac")
        #expect(MasterRoles.channelsHome(local: mac, peers: [peer("machine_a", online: true)]) == nil)
        #expect(MasterRoles.channelsHome(local: mac, peers: [peer("machine_z", online: false, alwaysOn: true)])?.machine?.id == "machine_z")
        let box = MachineIdentity(id: "machine_z", name: "box", alwaysOn: true)
        #expect(MasterRoles.channelsHome(local: box, peers: [peer("machine_m", online: true)]) == nil)
    }

    @Test("the polling master writes pull requests on cards another master runs; the other master does not")
    func prLinksOnForeignCards() {
        func master(_ identity: MachineIdentity, peer other: PeerStatus) -> AppState {
            let state = AppState()
            _ = Reducer.reduce(state: state, action: .localMachineLoaded(identity))
            _ = Reducer.reduce(state: state, action: .peerStatusChanged(other))
            var foreign = Link(id: "card_f", name: "Mac card", projectPath: "/Users/acme/widgets", column: .inProgress,
                               worktreeLink: WorktreeLink(path: "/Users/acme/widgets/.wt/x", branch: "feat/x"))
            foreign.ownerMachine = "machine_m"
            foreign.prLinks = [PRLink(number: 1, status: .reviewNeeded)]
            state.links[foreign.id] = foreign
            return state
        }
        var polled = Link(id: "card_f", name: "Mac card", projectPath: "/Users/acme/widgets", column: .done)
        polled.ownerMachine = "machine_m"
        polled.prLinks = [PRLink(number: 1, status: .merged), PRLink(number: 2, url: "https://github.com/acme/widgets/pull/2", status: .reviewNeeded)]
        let result = ReconciliationResult(links: [polled], sessions: [], activityMap: [:], tmuxSessions: [])

        let box = master(MachineIdentity(id: "machine_z", name: "box", alwaysOn: true), peer: peer("machine_m", online: true))
        _ = Reducer.reduce(state: box, action: .reconciled(result))
        let onBox = box.links["card_f"]
        #expect(onBox?.prLinks.map(\.number) == [1, 2])
        #expect(onBox?.prLinks.first?.status == .merged)
        // Only the pull requests: the column is the owner's to decide.
        #expect(onBox?.column == .inProgress)
        #expect(onBox?.fieldRevs?["prLinks"]?.machine == "machine_z")

        let mac = master(MachineIdentity(id: "machine_y", name: "other mac"), peer: peer("machine_z", online: true, alwaysOn: true))
        _ = Reducer.reduce(state: mac, action: .reconciled(result))
        #expect(mac.links["card_f"]?.prLinks.map(\.number) == [1])
        #expect(mac.isPRPollingLeader == false)
    }

    @Test("a card another master runs shows under the project here with the same repository")
    func projectMapping() {
        let state = AppState()
        _ = Reducer.reduce(state: state, action: .localMachineLoaded(MachineIdentity(id: "machine_m", name: "mac")))
        var foreign = Link(id: "card_b", name: "Box card", projectPath: "/root/Projects/widgets", column: .inProgress)
        foreign.ownerMachine = "machine_z"
        state.links[foreign.id] = foreign
        var other = Link(id: "card_o", name: "Unknown repo", projectPath: "/root/Projects/other", column: .inProgress)
        other.ownerMachine = "machine_z"
        state.links[other.id] = other
        _ = Reducer.reduce(state: state, action: .peerRepoSlugsLoaded(peer: "machine_z", slugs: [
            "/root/Projects/widgets": "github.com/acme/widgets", "/root/Projects/other": "github.com/acme/other",
        ]))
        _ = Reducer.reduce(state: state, action: .localProjectSlugsResolved(["/Users/acme/Projects/widgets": "github.com/ACME/widgets"]))
        #expect(state.cards.first { $0.id == "card_b" }?.link.projectPath == "/Users/acme/Projects/widgets")
        #expect(state.cards.first { $0.id == "card_o" }?.link.projectPath == "/root/Projects/other")
        // The stored card keeps its owner's path, for the owner and handovers.
        #expect(state.links["card_b"]?.projectPath == "/root/Projects/widgets")
    }

    @Test("a Mac mirrors the channels of an always-on master, after copying its own there once")
    func channelsMirror() async throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("channels-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let mac = try TestMaster(name: "mac", root: root)
        let box = try TestMaster(name: "box", root: root, alwaysOn: true)
        try await mac.serve()
        try await box.serve()
        try await mac.start(peerURL: box.url, peerToken: box.tokenForPeer)
        try await box.start(peerURL: mac.url, peerToken: mac.tokenForPeer)
        defer { mac.server.stop(); box.server.stop() }
        box.store.dispatch(.localMachineLoaded(box.identity))
        await mac.peerSync.pullAll()
        #expect(mac.store.state.peerStatuses.values.first?.machine?.alwaysOn == true)

        let fm = FileManager.default
        let macChannels = "\(mac.home)/channels"
        let boxChannels = "\(box.home)/channels"
        try fm.createDirectory(atPath: "\(macChannels)/dm", withIntermediateDirectories: true)
        try Data(#"{"channels":[{"id":"ch_1","name":"general","createdAt":"2026-09-28T00:00:00Z","createdBy":{"cardId":null,"handle":"acme"},"members":[]}]}"#.utf8)
            .write(to: URL(fileURLWithPath: "\(macChannels)/channels.json"))
        try Data("{\"id\":\"m1\"}\n".utf8).write(to: URL(fileURLWithPath: "\(macChannels)/general.jsonl"))
        try Data("{\"id\":\"d1\"}\n".utf8).write(to: URL(fileURLWithPath: "\(macChannels)/dm/a_b.jsonl"))
        try Data("{}".utf8).write(to: URL(fileURLWithPath: "\(macChannels)/read-state.json"))

        var mirror = ChannelsMirror(home: mac.home)
        await mac.engine.syncChannelsOnce(&mirror)
        // First pairing: the Mac's channels were copied to the home, not what it read.
        #expect(fm.fileExists(atPath: "\(boxChannels)/channels.json"))
        #expect(fm.contents(atPath: "\(boxChannels)/dm/a_b.jsonl") == Data("{\"id\":\"d1\"}\n".utf8))
        #expect(!fm.fileExists(atPath: "\(boxChannels)/read-state.json"))
        let info = try #require(fm.contents(atPath: "\(mac.home)/channels-home.json"))
        #expect(String(decoding: info, as: UTF8.self).contains(box.identity.id))

        // The home writes; the mirror follows: appends, new files, deletions.
        let log = try FileHandle(forWritingTo: URL(fileURLWithPath: "\(boxChannels)/general.jsonl"))
        try log.seekToEnd()
        try log.write(contentsOf: Data("{\"id\":\"m2\"}\n".utf8))
        try log.close()
        try Data("{\"id\":\"n1\"}\n".utf8).write(to: URL(fileURLWithPath: "\(boxChannels)/new.jsonl"))
        try fm.removeItem(atPath: "\(boxChannels)/dm/a_b.jsonl")
        await mac.engine.syncChannelsOnce(&mirror)
        #expect(fm.contents(atPath: "\(macChannels)/general.jsonl") == Data("{\"id\":\"m1\"}\n{\"id\":\"m2\"}\n".utf8))
        #expect(fm.contents(atPath: "\(macChannels)/new.jsonl") == Data("{\"id\":\"n1\"}\n".utf8))
        #expect(!fm.fileExists(atPath: "\(macChannels)/dm/a_b.jsonl"))
        #expect(fm.fileExists(atPath: "\(macChannels)/read-state.json"))

        // A file the home never had is never deleted here, nor copied again.
        try Data("{}\n".utf8).write(to: URL(fileURLWithPath: "\(macChannels)/local-only.jsonl"))
        await mac.engine.syncChannelsOnce(&mirror)
        #expect(fm.fileExists(atPath: "\(macChannels)/local-only.jsonl"))
        #expect(!fm.fileExists(atPath: "\(boxChannels)/local-only.jsonl"))

        // A second pairing does not copy again: the home's channels stand.
        try fm.removeItem(atPath: "\(boxChannels)")
        await mac.engine.syncChannelsOnce(&mirror)
        #expect(!fm.fileExists(atPath: "\(boxChannels)/channels.json"))

        // Paths that leave the channels directory are refused.
        #expect(MasterEngine.channelFilePath(home: box.home, relative: "../links.json") == nil)
        #expect(MasterEngine.channelFilePath(home: box.home, relative: "read-state.json") == nil)
    }

    @Test("the home runs only channel and DM commands for other masters")
    func cliAllowlist() async throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("cli-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let box = try TestMaster(name: "box", root: root, alwaysOn: true)
        let refused = await box.engine.runCLI(RemoteCLIRequest(argv: ["launch", "--prompt", "x"]))
        #expect(refused.code == 2)
        let missing = await box.engine.runCLI(RemoteCLIRequest(argv: ["channel", "list"]))
        #expect(missing.code == 1)
        #expect(missing.stderr.contains("not installed"))
    }

    @Test("a queued prompt the CLI writes for a card another master runs reaches that master")
    func inboxToForeignCard() async throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("inbox-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let mac = try TestMaster(name: "mac", root: root)
        let box = try TestMaster(name: "box", root: root, alwaysOn: true)
        try await mac.serve()
        try await box.serve()
        try await mac.start(peerURL: box.url, peerToken: box.tokenForPeer)
        try await box.start(peerURL: mac.url, peerToken: mac.tokenForPeer)
        defer { mac.server.stop(); box.server.stop() }
        mac.store.dispatch(.createManualTask(Link(
            id: "card_mac", name: "On the Mac", projectPath: "/tmp/acme", column: .inProgress,
            sessionLink: SessionLink(sessionId: "sid-mac"), tmuxLink: TmuxLink(sessionName: "mac-session")
        )))
        mac.store.dispatch(.tmuxLivenessScanned(live: ["mac-session"]))
        await box.peerSync.pullAll()
        await mac.peerSync.pullAll()
        #expect(box.engine.isForeign("card_mac"))

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let request = SubagentCommandRequest(
            id: "req_1", operation: .enqueuePrompt, createdAt: formatter.string(from: .now),
            parentCardId: "card_mac", cardId: "card_mac", prompt: "[Message from #general @acme]: hello")
        let inbox = "\(box.home)/commands/inbox"
        try FileManager.default.createDirectory(atPath: inbox, withIntermediateDirectories: true)
        try JSONEncoder().encode(request).write(to: URL(fileURLWithPath: "\(inbox)/req_1.json"))
        await box.engine.processPendingSubagentCommands()
        let text = "[Message from #general @acme]: hello"
        func arrived() -> Bool {
            mac.store.state.links["card_mac"]?.queuedPrompts?.first?.body == text || mac.tmux.pasted.contains(text)
        }
        for _ in 0..<100 where !arrived() {
            try await Task.sleep(for: .milliseconds(50))
        }
        // The Mac queued it, or sent it at once since the card is idle.
        #expect(arrived())
        #expect(box.store.state.links["card_mac"]?.queuedPrompts == nil)
        #expect(!box.tmux.pasted.contains(text))
    }
}
