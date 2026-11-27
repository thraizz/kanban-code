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
    private var _failCreate: String?
    var pasted: [String] { lock.withLock { _pasted } }
    /// Makes every new session fail with this message.
    var failCreate: String? {
        get { lock.withLock { _failCreate } }
        set { lock.withLock { _failCreate = newValue } }
    }
    var created: [(name: String, command: String?)] { lock.withLock { _created } }
    var killed: [String] { lock.withLock { _killed } }

    func listSessions() async throws -> [TmuxSession] { [] }
    func createSession(name: String, path: String, command: String?) async throws {
        if let failure = failCreate { throw TmuxError.createFailed(name: name, message: failure) }
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

    init(name: String, root: String, alwaysOn: Bool = false, clonesMissingProjects: Bool = true) throws {
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
        platform.clonesMissingProjects = clonesMissingProjects
        engine = MasterEngine(
            store: store,
            settingsStore: SettingsStore(basePath: home),
            launcher: LaunchSession(tmux: tmux),
            tmux: RoutingTmuxAdapter(rush: RushCliAdapter(executable: "/nonexistent/rush")),
            registry: CodingAssistantRegistry(),
            platform: platform
        )
        store.dispatch(.localMachineLoaded(identity))
        devices = RemoteDeviceStore(path: "\(home)/devices.json")
        tokenForPeer = try devices.add(name: "peer", scope: .full).token
    }

    func start(peerURL: String, peerToken: String) async throws {
        try await start(peers: [PeerConfig(name: "peer", url: peerURL, token: peerToken)])
    }

    func start(peers: [PeerConfig], control: PeerControl.Options = PeerControl.Options()) async throws {
        let store = self.store
        // A master reads its own links before it pulls its peers.
        await store.loadLocalLinks()
        peerSync = PeerSync(identity: identity, peers: peers, version: "test", controlOptions: control) { action in
            await MainActor.run { store.dispatch(action) }
        }
        engine.peerSync = peerSync
        engine.installForeignCardHandler()
        latePeerServer?.peerSync = peerSync
    }

    /// Serves the peer routes from the sync `start` makes, control
    /// connections included, when `control`; else from no sync at all.
    private var latePeerServer: LatePeerLinksServer?

    func serve(control: Bool = false) async throws {
        let peerServer: any PeerLinksServing
        if control {
            let late = LatePeerLinksServer(store: store)
            late.peerSync = peerSync
            latePeerServer = late
            peerServer = late
        } else {
            peerServer = BoardPeerLinksServer(store: store, peerSync: nil)
        }
        server = RemoteControlServer(
            host: MasterRemoteControlHost(engine: engine), devices: devices, port: 0,
            bindAddresses: { [RemoteNetworkAddresses.loopback] },
            options: .init(appVersion: "test", hostName: identity.name),
            peerServer: peerServer
        )
        try await server.start()
    }

    var url: String { "http://127.0.0.1:\(server.port)" }
}

/// The peer routes of a test master, served from the sync it gets once
/// both servers are up (each master's peer entry needs the other's port).
private final class LatePeerLinksServer: PeerLinksServing, @unchecked Sendable {
    let store: BoardStore
    private let lock = NSLock()
    private var _peerSync: PeerSync?
    private var listening: (@Sendable () -> (addresses: [String], port: Int)?)?

    init(store: BoardStore) {
        self.store = store
    }

    var peerSync: PeerSync? {
        get { lock.withLock { _peerSync } }
        set {
            let provider = lock.withLock { () -> (@Sendable () -> (addresses: [String], port: Int)?)? in
                _peerSync = newValue
                return listening
            }
            if let provider { newValue?.control.setListening(provider) }
        }
    }

    private var inner: BoardPeerLinksServer { BoardPeerLinksServer(store: store, peerSync: peerSync) }

    func linksPage(since: Int?, epoch: String?, machine: String?) async -> LinksPage {
        await inner.linksPage(since: since, epoch: epoch, machine: machine)
    }
    func peerLinksChanged(machineId: String?) async { await inner.peerLinksChanged(machineId: machineId) }
    func peersOverview() async -> PeersOverview { await inner.peersOverview() }
    func peerReached(machineId: String, host: String) async { await inner.peerReached(machineId: machineId, host: host) }
    func servePeerControl(_ socket: PeerControlSocket, device: RemoteDevice) async {
        await inner.servePeerControl(socket, device: device)
    }
    func serverListening(_ provider: @escaping @Sendable () -> (addresses: [String], port: Int)?) {
        lock.withLock { listening = provider }
        peerSync?.control.setListening(provider)
    }
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

    @Test("a worktree of a card another master owns is removed by that master, not here")
    func foreignWorktreeRemoval() async throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("wt-remove-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repo = "\(root)/box/widgets"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try await sh(["git", "init", "-q"], in: repo)
        try await sh(["git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init"], in: repo)
        let onlyWorktree = "\(repo)/.claude/worktrees/only-worktree"
        let withSession = "\(repo)/.claude/worktrees/with-session"
        try await sh(["git", "worktree", "add", "-q", "-b", "only-worktree", onlyWorktree], in: repo)
        try await sh(["git", "worktree", "add", "-q", "-b", "with-session", withSession], in: repo)

        let mac = try TestMaster(name: "mac", root: root)
        let box = try TestMaster(name: "box", root: root)
        try await mac.serve()
        try await box.serve()
        try await mac.start(peerURL: box.url, peerToken: box.tokenForPeer)
        try await box.start(peerURL: mac.url, peerToken: mac.tokenForPeer)
        defer { mac.server.stop(); box.server.stop() }

        box.store.dispatch(.createManualTask(Link(
            id: "card_wt", name: "Only a worktree", projectPath: repo, column: .done,
            worktreeLink: WorktreeLink(path: onlyWorktree, branch: "only-worktree"))))
        box.store.dispatch(.createManualTask(Link(
            id: "card_wt_session", name: "With a session", projectPath: repo, column: .done,
            sessionLink: SessionLink(sessionId: "sid-wt"),
            worktreeLink: WorktreeLink(path: withSession, branch: "with-session"))))
        await mac.peerSync.pullAll()
        #expect(mac.store.state.worktreePlacement("card_wt") == .ownerMaster(machineId: box.identity.id))

        let first = try await mac.engine.removeCardWorktree(cardId: "card_wt")
        #expect(first == RemoteWorktreeRemoval(machine: "box", cardDeleted: true))
        #expect(!FileManager.default.fileExists(atPath: onlyWorktree))
        #expect(box.store.state.links["card_wt"] == nil)

        let second = try await mac.engine.removeCardWorktree(cardId: "card_wt_session")
        #expect(second.cardDeleted == false)
        #expect(!FileManager.default.fileExists(atPath: withSession))
        #expect(box.store.state.links["card_wt_session"]?.worktreeLink == nil)

        // A failure names the machine it ran on.
        box.store.dispatch(.createManualTask(Link(
            id: "card_gone", name: "Gone", projectPath: repo, column: .done,
            worktreeLink: WorktreeLink(path: "\(repo)/.claude/worktrees/never-made", branch: "never-made"))))
        await mac.peerSync.pullAll()
        do {
            try await mac.engine.removeCardWorktree(cardId: "card_gone")
            Issue.record("removing a missing worktree should fail")
        } catch let error as WorktreeRemovalError {
            #expect(error.message.hasPrefix("Worktree cleanup on box failed:"))
            #expect(error.message.contains("not a working tree"))
        }

        // Removing files takes a full token.
        let agent = RemoteClient(baseURL: URL(string: box.url)!, token: try box.devices.add(name: "agent", scope: .agent).token)
        await #expect(throws: RemoteClientError.self) { try await agent.removeWorktree(cardId: "card_gone") }
    }

    @Test("archiving on the Mac a card the box runs ends its sessions on the box")
    func foreignArchiveEndsSessions() async throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("archive-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let mac = try TestMaster(name: "mac", root: root)
        let box = try TestMaster(name: "box", root: root)
        try await mac.serve()
        try await box.serve()
        try await mac.start(peerURL: box.url, peerToken: box.tokenForPeer)
        try await box.start(peerURL: mac.url, peerToken: mac.tokenForPeer)
        defer { mac.server.stop(); box.server.stop() }

        box.store.dispatch(.createManualTask(Link(
            id: "card_live", name: "Running on the box", projectPath: "/tmp/acme", column: .waiting,
            sessionLink: SessionLink(sessionId: "sid-live"), tmuxLink: TmuxLink(sessionName: "rush-0badcafe"))))
        await mac.peerSync.pullAll()
        mac.store.dispatch(.archiveCard(cardId: "card_live"))
        await box.peerSync.pullAll()
        #expect(box.store.state.links["card_live"]?.manuallyArchived == true)
        for _ in 0..<40 where !box.tmux.killed.contains("rush-0badcafe") { try await Task.sleep(for: .milliseconds(50)) }
        #expect(box.tmux.killed.contains("rush-0badcafe"))
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

    @Test("a prompt of seventeen screenshots on a card another master owns reaches that master, journalled here first")
    func foreignPromptManyImages() async throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("foreign-images-\(UUID().uuidString)")
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
        #expect(mac.engine.isForeign("card_box"))

        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="))
        let paths = try (1...17).map { n -> String in
            let path = "\(root)/pasted-\(n).png"
            try png.write(to: URL(fileURLWithPath: path))
            return path
        }
        let body = (1...17).map { "\($0). [Image #\($0)] look" }.joined(separator: "\n")
        let prompt = QueuedPrompt(body: body, imagePaths: paths, humanWrittenAt: .now)
        mac.store.dispatch(.addQueuedPrompt(cardId: "card_box", prompt: prompt, placement: .back))

        let boxJournal = QueuedPromptJournal(basePath: box.home)
        var arrived: QueuedPromptJournalEntry?
        for _ in 0..<100 where arrived == nil {
            arrived = await boxJournal.entries(forCard: "card_box").first { $0.body == body }
            if arrived == nil { try await Task.sleep(for: .milliseconds(50)) }
        }
        #expect(arrived?.imagePaths?.count == 17)
        let sent = await QueuedPromptJournal(basePath: mac.home).entries(forCard: "card_box")
        #expect(sent.contains { $0.promptId == prompt.id && $0.reason == .sent && $0.imagePaths == paths })
        #expect(mac.store.state.failedPrompts["card_box"] == nil)
    }

    @Test("a prompt the owning master refuses comes back to the chat as failed, text and images kept")
    func foreignPromptRefused() async throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("foreign-refused-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let mac = try TestMaster(name: "mac", root: root)
        let box = try TestMaster(name: "box", root: root)
        try await mac.serve()
        try await box.serve()
        try await mac.start(peerURL: box.url, peerToken: box.tokenForPeer)
        try await box.start(peerURL: mac.url, peerToken: mac.tokenForPeer)
        defer { mac.server.stop(); box.server.stop() }

        // No live session on the box: it refuses the prompt.
        box.store.dispatch(.createManualTask(Link(
            id: "card_box", name: "On the box", projectPath: "/tmp/acme", column: .waiting,
            sessionLink: SessionLink(sessionId: "sid-box")
        )))
        await mac.peerSync.pullAll()
        #expect(mac.engine.isForeign("card_box"))

        let image = "\(root)/pasted.png"
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: URL(fileURLWithPath: image))
        let prompt = QueuedPrompt(body: "this one: [Image #1]", imagePaths: [image], humanWrittenAt: .now)
        mac.store.dispatch(.addQueuedPrompt(cardId: "card_box", prompt: prompt, placement: .back))

        for _ in 0..<100 where mac.store.state.failedPrompts["card_box"] == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        let failed = try #require(mac.store.state.failedPrompts["card_box"]?.first)
        #expect(failed.prompt.body == "this one: [Image #1]")
        #expect(failed.prompt.imagePaths == [image])
        #expect(!failed.message.isEmpty)

        var reasons: [QueuedPromptJournalReason] = []
        for _ in 0..<40 where !reasons.contains(.failed) {
            reasons = await QueuedPromptJournal(basePath: mac.home).entries(forCard: "card_box")
                .filter { $0.promptId == prompt.id }.map(\.reason)
            if !reasons.contains(.failed) { try await Task.sleep(for: .milliseconds(50)) }
        }
        #expect(reasons == [.sent, .failed])

        mac.store.dispatch(.dismissFailedPrompt(cardId: "card_box", promptId: prompt.id))
        #expect(mac.store.state.failedPrompts["card_box"] == nil)
    }

    @Test("an image pasted into the terminal of a card another master owns is stored on that master")
    func pastedImageGoesToTheOwner() async throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("pasted-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let mac = try TestMaster(name: "mac", root: root)
        let box = try TestMaster(name: "box", root: root)
        try await mac.serve()
        try await box.serve()
        // The Mac holds a peer-scope token of the box, as a paired master does.
        try await mac.start(peerURL: box.url, peerToken: try box.devices.add(name: "mac", scope: .peer).token)
        try await box.start(peerURL: mac.url, peerToken: mac.tokenForPeer)
        defer { mac.server.stop(); box.server.stop() }

        box.store.dispatch(.createManualTask(Link(
            id: "card_box", name: "On the box", projectPath: "/tmp/acme", column: .waiting,
            sessionLink: SessionLink(sessionId: "sid-box"), tmuxLink: TmuxLink(sessionName: "box-session")
        )))
        mac.store.dispatch(.createManualTask(Link(id: "card_mac", name: "On the Mac", projectPath: "/tmp/acme", column: .waiting)))
        await mac.peerSync.pullAll()
        await box.peerSync.pullAll()
        #expect(mac.engine.isForeign("card_box"))

        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data((0..<4096).map { UInt8($0 % 251) })
        let path = try await mac.engine.uploadPastedImage(cardId: "card_box", data: png)
        #expect(path.hasPrefix(PastedImages.directory(kanbanHome: box.home) + "/"))
        #expect(path.hasSuffix(".png"))
        #expect(FileManager.default.contents(atPath: path) == png)

        // A device of the Mac asking for the box's card is passed on to the box.
        let phone = RemoteClient(baseURL: URL(string: mac.url)!, token: try mac.devices.add(name: "phone", scope: .full).token)
        let forwarded = try await phone.uploadPastedImage(cardId: "card_box", data: png).path
        #expect(forwarded.hasPrefix(PastedImages.directory(kanbanHome: box.home) + "/"))
        #expect(forwarded != path)
        // Its own card is stored on the Mac.
        let own = try await phone.uploadPastedImage(cardId: "card_mac", data: png).path
        #expect(own.hasPrefix(PastedImages.directory(kanbanHome: mac.home) + "/"))

        // The Mac's own card has no owner to upload to; a body that is no image is refused by the owner.
        await #expect(throws: MasterPeerError.self) { try await mac.engine.uploadPastedImage(cardId: "card_mac", data: png) }
        await #expect(throws: RemoteClientError.self) {
            try await mac.engine.uploadPastedImage(cardId: "card_box", data: Data("not an image".utf8))
        }
    }

    @Test("a file attached on the Mac to a card another master owns is uploaded in chunks to that master")
    func promptFileGoesToTheOwner() async throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("files-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let mac = try TestMaster(name: "mac", root: root)
        let box = try TestMaster(name: "box", root: root)
        try await mac.serve()
        try await box.serve()
        try await mac.start(peerURL: box.url, peerToken: try box.devices.add(name: "mac", scope: .peer).token)
        try await box.start(peerURL: mac.url, peerToken: mac.tokenForPeer)
        defer { mac.server.stop(); box.server.stop() }

        box.store.dispatch(.createManualTask(Link(
            id: "card_box", name: "On the box", projectPath: "/tmp/acme", column: .waiting,
            sessionLink: SessionLink(sessionId: "sid-box"), tmuxLink: TmuxLink(sessionName: "box-session")
        )))
        mac.store.dispatch(.createManualTask(Link(id: "card_mac", name: "On the Mac", projectPath: "/tmp/acme", column: .waiting)))
        await mac.peerSync.pullAll()
        await box.peerSync.pullAll()

        // Over one chunk, so the upload takes several requests.
        let bytes = Data((0..<(PromptFiles.chunkBytes + 12345)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let local = (root as NSString).appendingPathComponent("demo video.mp4")
        try bytes.write(to: URL(fileURLWithPath: local))

        let progress = ProgressLog()
        let path = try await mac.engine.attachPromptFile(cardId: "card_box", fileURL: URL(fileURLWithPath: local)) { sent, total in
            progress.add(sent, total)
        }
        #expect(path.hasPrefix(PromptFileStore.directory(kanbanHome: box.home) + "/"))
        #expect(path.hasSuffix("/demo video.mp4"))
        #expect(FileManager.default.contents(atPath: path) == bytes)
        #expect(!FileManager.default.fileExists(atPath: path + ".part"))
        #expect(progress.last == [Int64(bytes.count), Int64(bytes.count)])
        #expect(progress.count >= 3)

        // A device of the Mac uploading for the box's card is passed on to the box.
        let phone = RemoteClient(baseURL: URL(string: mac.url)!, token: try mac.devices.add(name: "phone", scope: .full).token)
        let forwarded = try await phone.uploadPromptFile(cardId: "card_box", fileURL: URL(fileURLWithPath: local))
        #expect(forwarded.hasPrefix(PromptFileStore.directory(kanbanHome: box.home) + "/"))
        #expect(forwarded != path)
        // The Mac's own card keeps the file on the Mac.
        let own = try await phone.uploadPromptFile(cardId: "card_mac", fileURL: URL(fileURLWithPath: local))
        #expect(own.hasPrefix(PromptFileStore.directory(kanbanHome: mac.home) + "/"))
        #expect(FileManager.default.contents(atPath: own) == bytes)
        // A local card gets a copy in the Mac's store.
        let copied = try await mac.engine.attachPromptFile(cardId: "card_mac", fileURL: URL(fileURLWithPath: local))
        #expect(copied.hasPrefix(PromptFileStore.directory(kanbanHome: mac.home) + "/") && copied.hasSuffix("/demo video.mp4"))

        // A chunk out of order is refused with where the upload stands.
        let chunk = RemotePromptFileChunk(upload: "u-gap", name: "a.bin", size: 10, offset: 4, data: Data([1, 2]))
        await #expect(throws: RemoteClientError.self) { try await phone.uploadPromptFileChunk(cardId: "card_mac", chunk) }
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

    @Test("pin, archive, unarchive and delete from the phone apply on either master and converge on both")
    func cardActionsConverge() async throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("card-actions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let mac = try TestMaster(name: "mac", root: root)
        let box = try TestMaster(name: "box", root: root)
        try await mac.serve()
        try await box.serve()
        try await mac.start(peerURL: box.url, peerToken: box.tokenForPeer)
        try await box.start(peerURL: mac.url, peerToken: mac.tokenForPeer)
        defer { mac.server.stop(); box.server.stop() }
        box.store.dispatch(.createManualTask(Link(id: "card_p", name: "Throwaway", projectPath: "/tmp/acme", column: .waiting)))
        await mac.peerSync.pullAll()
        await box.peerSync.pullAll()

        let macClient = RemoteClient(baseURL: URL(string: mac.url)!, token: try mac.devices.add(name: "phone", scope: .full).token)
        let boxClient = RemoteClient(baseURL: URL(string: box.url)!, token: try box.devices.add(name: "phone", scope: .full).token)
        #expect(try await macClient.health().supports(RemoteAPI.Feature.cardActions))

        // Pinned on the Mac, the box's own card shows pinned on both.
        let pinned = try await macClient.updateCard(cardId: "card_p", RemoteCardUpdate(pinned: true))
        #expect(pinned.pinned)
        await box.peerSync.pullAll()
        #expect(box.store.state.links["card_p"]?.isPinned == true)
        #expect(try await boxClient.card(id: "card_p").pinned)

        // A card on the board is not deleted: archive first, as on the Mac.
        await #expect(throws: RemoteClientError.self) { try await boxClient.deleteCard(cardId: "card_p") }
        #expect(box.store.state.links["card_p"] != nil)

        let archived = try await boxClient.updateCard(cardId: "card_p", RemoteCardUpdate(archived: true))
        #expect(archived.archived && !archived.pinned && archived.column == .allSessions)
        await mac.peerSync.pullAll()
        #expect(mac.store.state.links["card_p"]?.manuallyArchived == true)

        let back = try await macClient.updateCard(cardId: "card_p", RemoteCardUpdate(archived: false))
        #expect(!back.archived && back.column == .backlog)
        await box.peerSync.pullAll()
        #expect(box.store.state.links["card_p"]?.manuallyArchived == false)

        _ = try await macClient.updateCard(cardId: "card_p", RemoteCardUpdate(archived: true))
        await box.peerSync.pullAll()
        try await boxClient.deleteCard(cardId: "card_p")
        #expect(box.store.state.links["card_p"] == nil)
        await mac.peerSync.pullAll()
        #expect(mac.store.state.links["card_p"] == nil)
        await #expect(throws: RemoteClientError.self) { _ = try await macClient.card(id: "card_p") }
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

    @Test("a first launch on a peer releases the card, opens it here, and the peer starts it")
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
        #expect(mac.store.state.selectedCardId == "card_new")

        await box.peerSync.pullAll()
        try await box.engine.adopt(cardId: "card_new")
        #expect(box.store.state.links["card_new"]?.projectPath == "\(box.home)/Projects/widgets")
        for _ in 0..<50 where box.tmux.created.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        #expect(box.tmux.created.count == 1)
    }

    @Test("a first launch right after a start waits for the peer to fetch from here once, then hands the card over")
    func launchOnPeerWaitsForFirstFetch() async throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("peer-launch-wait-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repoA = "\(root)/mac/widgets"
        try FileManager.default.createDirectory(atPath: repoA, withIntermediateDirectories: true)

        let mac = try TestMaster(name: "mac", root: root)
        let box = try TestMaster(name: "box", root: root)
        try await mac.serve()
        try await box.serve()
        try await mac.start(peerURL: box.url, peerToken: box.tokenForPeer)
        try await box.start(peerURL: mac.url, peerToken: mac.tokenForPeer)
        defer { mac.server.stop(); box.server.stop() }
        // The mac knows box, but box has not fetched from the mac yet, and
        // the mac just started: whether box would pick a card up is not known.
        await mac.peerSync.pullAll()

        mac.store.dispatch(.createManualTask(Link(id: "card_new", name: "New work", projectPath: repoA, column: .backlog, promptBody: "do it")))
        mac.engine.launch(cardId: "card_new", prompt: "do it now", projectPath: repoA, worktreeName: nil,
                          runRemotely: true, machineChoice: .existing("box"))
        #expect(mac.store.state.links["card_new"]?.ownerMachine != box.identity.id)
        guard case .handingOver(let line) = mac.store.state.cardStarts["card_new"] else {
            Issue.record("the card does not say what it waits for")
            return
        }
        #expect(line.contains("box"))
        // A second start while it waits hands nothing over twice.
        mac.engine.launch(cardId: "card_new", prompt: "do it now", projectPath: repoA, worktreeName: nil,
                          runRemotely: true, machineChoice: .existing("box"))
        #expect(mac.store.state.links["card_new"]?.ownerMachine != box.identity.id)

        await box.peerSync.pullAll()
        for _ in 0..<40 where mac.store.state.links["card_new"]?.ownerMachine != box.identity.id {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(mac.store.state.links["card_new"]?.ownerMachine == box.identity.id)
        #expect(mac.store.state.cardStarts["card_new"] == nil)
    }

    @Test("a first launch on a peer hands the prompt's images to the peer")
    func launchOnPeerWithImages() async throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("peer-launch-img-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let origin = "\(root)/origin/widgets.git"
        let repoA = "\(root)/mac/widgets"
        try FileManager.default.createDirectory(atPath: "\(root)/origin", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: "\(root)/mac", withIntermediateDirectories: true)
        try await sh(["git", "init", "--bare", "-q", origin], in: root)
        try await sh(["git", "clone", "-q", origin, repoA], in: root)
        try await sh(["git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init"], in: repoA)
        try await sh(["git", "push", "-q", "origin", "HEAD"], in: repoA)
        // As big as a Retina screenshot.
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data((0..<3_000_000).map { UInt8($0 % 251) })
        let imagePath = "\(root)/shot.png"
        try png.write(to: URL(fileURLWithPath: imagePath))

        let mac = try TestMaster(name: "mac", root: root)
        let box = try TestMaster(name: "box", root: root)
        try await mac.serve()
        try await box.serve()
        try await mac.start(peerURL: box.url, peerToken: box.tokenForPeer)
        try await box.start(peerURL: mac.url, peerToken: mac.tokenForPeer)
        defer { mac.server.stop(); box.server.stop() }
        await mac.peerSync.pullAll()
        await box.peerSync.pullAll()

        mac.store.dispatch(.createManualTask(Link(id: "card_img", name: "Fix it", projectPath: repoA, column: .backlog,
                                                  promptBody: "[Image #1] fix this", promptImagePaths: [imagePath])))
        mac.engine.launch(cardId: "card_img", prompt: "[Image #1] fix this", projectPath: repoA, worktreeName: nil,
                          runRemotely: true, machineChoice: .existing("box"))
        let info = try await mac.engine.handoverInfo(cardId: "card_img")
        #expect(info.launchPrompt == "[Image #1] fix this")
        #expect(info.launchImages?.count == 1)
        #expect(info.launchImages?.first?.bytes == png)
        #expect(info.launchImages?.first?.mediaType == "image/png")

        // The New Task dialog passes its images to the launch; the card keeps none.
        mac.store.dispatch(.createManualTask(Link(id: "card_dialog", name: "Look", projectPath: repoA, column: .backlog,
                                                  promptBody: "why? [Image #1]")))
        mac.engine.launch(cardId: "card_dialog", prompt: "why? [Image #1]", projectPath: repoA, worktreeName: nil,
                          runRemotely: true, images: [ImageAttachment(data: png)], machineChoice: .existing("box"))
        let dialogInfo = try await mac.engine.handoverInfo(cardId: "card_dialog")
        #expect(dialogInfo.launchImages?.first?.bytes == png)
        let overHTTP = try #require(await box.engine.peerClient(machineId: mac.identity.id))
        let fetched = try await overHTTP.handover(cardId: "card_dialog")
        #expect(fetched.launchImages?.first?.bytes == png)
    }

    @Test("a card of a project with no remote says whether the project has commits to bring")
    func unpublishedProjectTellsItsCommits() async throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("peer-launch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repo = "\(root)/mac/twin"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try await sh(["git", "init", "-q"], in: repo)
        let mac = try TestMaster(name: "mac", root: root)
        mac.store.dispatch(.createManualTask(Link(id: "card_new", name: "New work", projectPath: repo, column: .backlog, promptBody: "do it")))

        var info = try await mac.engine.handoverInfo(cardId: "card_new")
        #expect(info.repoUrl == nil)
        #expect(info.repoHasCommits == false)

        try await sh(["git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init"], in: repo)
        info = try await mac.engine.handoverInfo(cardId: "card_new")
        #expect(info.repoHasCommits == true)
    }

    @Test("a new project with no remote and no commits starts on the adopting master as a new repository")
    func unpublishedEmptyProjectStartsFresh() async throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("peer-launch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let box = try TestMaster(name: "box", root: root)

        let here = try await box.engine.localRepository(repoUrl: nil, fallback: "/nowhere/Projects/twin", hasCommits: false)
        #expect(here == "\(box.home)/Projects/twin")
        #expect(FileManager.default.fileExists(atPath: "\(here)/.git"))
        // The next card of the project finds the folder made for the first.
        #expect(try await box.engine.localRepository(repoUrl: nil, fallback: "/nowhere/Projects/twin", hasCommits: true) == here)
    }

    @Test("a project with commits and no remote is refused by the adopting master, naming the reason")
    func unpublishedCommitsAreRefused() async throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("peer-launch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let box = try TestMaster(name: "box", root: root)

        do {
            _ = try await box.engine.localRepository(repoUrl: nil, fallback: "/nowhere/Projects/twin", hasCommits: true)
            Issue.record("the project was taken")
        } catch {
            #expect(error.localizedDescription.contains("has no git remote"))
        }
        #expect(!FileManager.default.fileExists(atPath: "\(box.home)/Projects/twin"))
    }

    @Test("a card the peer cannot take comes back to the master that launched it, with the reason")
    func refusedLaunchComesBack() async throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("peer-launch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let origin = "\(root)/origin/widgets.git"
        let repoA = "\(root)/mac/widgets"
        try FileManager.default.createDirectory(atPath: "\(root)/origin", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: "\(root)/mac", withIntermediateDirectories: true)
        try await sh(["git", "init", "--bare", "-q", origin], in: root)
        try await sh(["git", "clone", "-q", origin, repoA], in: root)

        let mac = try TestMaster(name: "mac", root: root)
        // A master that has no clone of the project and may not make one.
        let box = try TestMaster(name: "box", root: root, clonesMissingProjects: false)
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
        #expect(mac.store.state.links["card_new"]?.column == .inProgress)
        await box.peerSync.pullAll()

        #expect(await box.engine.adoptOrHandBack(cardId: "card_new"))
        #expect(box.store.state.links["card_new"]?.ownerMachine == mac.identity.id)
        #expect(box.tmux.created.isEmpty)

        await mac.peerSync.pullAll()
        #expect(mac.store.state.links["card_new"]?.migrating == true)
        #expect(await mac.engine.adoptOrHandBack(cardId: "card_new"))
        let back = mac.store.state.links["card_new"]
        #expect(back?.ownerMachine == mac.identity.id)
        #expect(back?.migrating == nil)
        #expect(back?.column == .backlog)
        #expect(back?.projectPath == repoA)
        guard case .failed(let line) = mac.store.state.cardStarts["card_new"] else {
            Issue.record("the card does not say why it came back")
            return
        }
        #expect(line.contains("box could not take it"))
        #expect(line.contains("no project with origin"))
        #expect(mac.tmux.created.isEmpty)

        // The peer no longer queues the card.
        await box.peerSync.pullAll()
        #expect(box.store.state.links["card_new"]?.migrating == nil)
        #expect(box.store.state.links["card_new"]?.ownerMachine == mac.identity.id)
    }

    @Test("an adoption that may work on a later try leaves the card where it is")
    func transientFailureKeepsTheCard() {
        #expect(MasterPeerError.noProject("x").refusesAdoption)
        #expect(MasterPeerError.failed("x").refusesAdoption)
        #expect(!MasterPeerError.notReady("x").refusesAdoption)
        #expect(!MasterPeerError.peerOffline("x").refusesAdoption)
        #expect(!MasterPeerError.unknownPeer("x").refusesAdoption)
    }

    @Test("a fork asked from the phone on a card the peer owns is made on the peer, from the project root")
    func forkOnTheOwner() async throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("peer-fork-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let mac = try TestMaster(name: "mac", root: root)
        let box = try TestMaster(name: "box", root: root)
        try await mac.serve()
        try await box.serve()
        try await mac.start(peerURL: box.url, peerToken: box.tokenForPeer)
        try await box.start(peerURL: mac.url, peerToken: mac.tokenForPeer)
        defer { mac.server.stop(); box.server.stop() }

        let project = "\(box.home)/Projects/widgets"
        let worktree = "\(project)/.claude/worktrees/calm-river"
        let dir = "\(box.home)/claude-projects/\(SessionFileMover.encodeProjectPath(worktree))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let transcript = "\(dir)/s-1.jsonl"
        let line = #"{"type":"user","sessionId":"s-1","cwd":"\#(worktree)","message":{"role":"user","content":"hi"}}"#
        try (line + "\n").write(toFile: transcript, atomically: true, encoding: .utf8)
        box.store.dispatch(.createManualTask(Link(
            id: "card_src", name: "Source", projectPath: worktree, column: .waiting,
            sessionLink: SessionLink(sessionId: "s-1", sessionPath: transcript),
            worktreeLink: WorktreeLink(path: worktree, branch: "calm-river"))))
        await mac.peerSync.pullAll()
        #expect(mac.store.state.links["card_src"]?.ownerMachine == box.identity.id)

        let phone = RemoteClient(baseURL: URL(string: mac.url)!, token: mac.tokenForPeer)
        let fork = try await phone.fork(cardId: "card_src", keepWorktree: false)
        let made = try #require(box.store.state.links[fork.id])
        #expect(made.name == "Source (fork)")
        #expect(made.column == .waiting)
        #expect(made.projectPath == project)
        #expect(made.worktreeLink == nil)
        let path = try #require(made.sessionLink?.sessionPath)
        #expect(path.hasPrefix("\(box.home)/claude-projects/\(SessionFileMover.encodeProjectPath(project))/"))
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(mac.store.state.links[fork.id]?.ownerMachine == nil || mac.store.state.links[fork.id]?.ownerMachine == box.identity.id)

        let kept = try await phone.fork(cardId: "card_src", keepWorktree: true)
        #expect(box.store.state.links[kept.id]?.worktreeLink?.path == worktree)
    }

    @Test("a task for a peer in a project only the peer knows is created and run there")
    func taskForwardedToPeer() async throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("peer-task-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let mac = try TestMaster(name: "studio", root: root)
        let box = try TestMaster(name: "box", root: root, alwaysOn: true)
        let project = "\(mac.home)/Projects/app"
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        mac.store.dispatch(.settingsLoaded(projects: [Project(path: project)], excludedPaths: [], remote: nil,
                                           remoteMode: .ssh, boxd: nil))
        try await mac.serve()
        try await box.serve()
        try await mac.start(peerURL: box.url, peerToken: box.tokenForPeer)
        try await box.start(peerURL: mac.url, peerToken: mac.tokenForPeer)
        defer { mac.server.stop(); box.server.stop() }
        await mac.peerSync.pullAll()
        await box.peerSync.pullAll()

        let host = MasterRemoteControlHost(engine: box.engine)
        #expect(await host.machines().map(\.name) == ["box", "studio"])
        let card = try await host.createTask(RemoteTaskRequest(project: "app", prompt: "do it", machine: "STUDIO"))
        #expect(card.machineId == mac.identity.id)
        #expect(mac.store.state.links[card.id]?.projectPath == project)
        #expect(box.store.state.links[card.id] == nil)
        for _ in 0..<50 where mac.tmux.created.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        #expect(mac.tmux.created.count == 1)
        #expect(box.tmux.created.isEmpty)
    }
}

// MARK: - Roles across masters

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

    @Test("a resume while the card is still moving here waits for the adoption, and every master says it is moving")
    func resumeWhileMoving() async throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("moving-\(UUID().uuidString)")
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

        let sessionId = "0f1e2d3c-aaaa-bbbb-cccc-000000000003"
        let transcriptA = mac.engine.transcriptPath(cwd: repoA, sessionId: sessionId)
        try FileManager.default.createDirectory(atPath: (transcriptA as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let line = #"{"type":"user","cwd":"\#(repoA)","message":{"role":"user","content":"hello"}}"#
        try String(repeating: line + "\n", count: 200).write(toFile: transcriptA, atomically: true, encoding: .utf8)
        mac.store.dispatch(.createManualTask(Link(
            id: "card_big", name: "Big transcript", projectPath: repoA, column: .waiting,
            sessionLink: SessionLink(sessionId: sessionId, sessionPath: transcriptA)
        )))
        await mac.peerSync.pullAll()
        await box.peerSync.pullAll()

        try await mac.engine.moveCard("card_big", to: "box")
        await box.peerSync.pullAll()
        #expect(box.store.state.links["card_big"]?.migrating == true)
        #expect(box.store.state.links["card_big"]?.projectPath == repoA)

        // The Mac shows the move where "session ended" was, with no resume.
        let macStatus = try #require(mac.store.state.cards.first { $0.id == "card_big" }?.sessionStatus)
        #expect(macStatus == .moving("Moving to box"))
        #expect(!macStatus.canResume)

        // The box does not start it on the Mac's folder: it waits.
        #expect(!box.engine.resume(cardId: "card_big", runRemotely: false, commandOverride: nil))
        #expect(box.tmux.created.isEmpty)
        #expect(box.store.state.startFailure("card_big") == nil)
        #expect(box.store.state.cards.first { $0.id == "card_big" }?.sessionStatus == .moving("Moving here from mac"))

        // A resume asked over the API is answered with the move, not a silent failure.
        let phone = RemoteClient(baseURL: URL(string: box.url)!, token: try box.devices.add(name: "phone", scope: .full).token)
        do {
            _ = try await phone.resume(cardId: "card_big")
            Issue.record("a resume of a card still moving here succeeded")
        } catch {
            #expect(error.localizedDescription.contains("Moving here from mac"))
        }

        // The box copies the transcript; the Mac, which serves it, shows how far.
        try await box.engine.adopt(cardId: "card_big")
        let size = try #require((try FileManager.default.attributesOfItem(atPath: transcriptA))[.size] as? Int)
        #expect(mac.store.state.cardStarts["card_big"] == .moving(HandoverProgress(copiedBytes: size, totalBytes: size)))
        #expect(mac.store.state.handoverLine(cardId: "card_big")?.contains("copying the transcript") == true)

        // The adoption resumes it once, in the box's folder.
        for _ in 0..<50 where box.tmux.created.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        #expect(box.tmux.created.count == 1)
        #expect(box.tmux.created.first?.command?.contains("--resume \(sessionId)") == true)
        #expect(box.store.state.links["card_big"]?.projectPath == "\(box.home)/Projects/widgets")
        // A resume that arrives right after, before any tmux scan saw the
        // new session, does not start it over.
        _ = try await phone.resume(cardId: "card_big")
        #expect(box.tmux.created.count == 1)

        await mac.peerSync.pullAll()
        #expect(mac.store.state.links["card_big"]?.migrating == nil)
        if case .moving = mac.store.state.cards.first(where: { $0.id == "card_big" })?.sessionStatus {
            Issue.record("the Mac still shows the move after the adoption")
        }
    }

    @Test("a start that fails on the owner answers the caller, and the card here shows why")
    func remoteStartFailureReachesTheCaller() async throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("start-fail-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let mac = try TestMaster(name: "mac", root: root)
        let box = try TestMaster(name: "box", root: root)
        try await mac.serve()
        try await box.serve()
        try await mac.start(peerURL: box.url, peerToken: box.tokenForPeer)
        try await box.start(peerURL: mac.url, peerToken: mac.tokenForPeer)
        defer { mac.server.stop(); box.server.stop() }

        let folder = "\(root)/box-repo"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        box.store.dispatch(.createManualTask(Link(
            id: "card_fail", name: "Fails", projectPath: folder, column: .waiting,
            sessionLink: SessionLink(sessionId: "0f1e2d3c-aaaa-bbbb-cccc-000000000004")
        )))
        await mac.peerSync.pullAll()
        await box.peerSync.pullAll()
        #expect(mac.engine.isForeign("card_fail"))
        box.tmux.failCreate = "no such folder"

        // The Mac's resume goes to the box; the box's failure comes back to the card here.
        mac.engine.resume(cardId: "card_fail", runRemotely: false, commandOverride: nil)
        func failure() -> String? {
            if case .failed(let line) = mac.store.state.cards.first(where: { $0.id == "card_fail" })?.sessionStatus { return line }
            return nil
        }
        for _ in 0..<100 where failure() == nil { try await Task.sleep(for: .milliseconds(50)) }
        let line = try #require(failure())
        #expect(line.contains("Could not resume the card on box"))
        #expect(line.contains("no such folder"))
        #expect(mac.store.state.cards.first { $0.id == "card_fail" }?.sessionStatus.canResume == true)

        // The box's own card says the same, and the phone reads it.
        #expect(box.store.state.startFailure("card_fail")?.contains("no such folder") == true)
        let phone = RemoteClient(baseURL: URL(string: box.url)!, token: try box.devices.add(name: "phone", scope: .full).token)
        let card = try await phone.card(id: "card_fail")
        #expect(card.sessionStatus?.kind == .failed)
        #expect(card.sessionStatus?.canResume == true)
    }

    @Test("the resume dialog's pick moves a card another master runs, and the owner resumes it otherwise")
    func movePick() async throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("pick-\(UUID().uuidString)")
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
            sessionLink: SessionLink(sessionId: "sid-box"))))
        await mac.peerSync.pullAll()

        #expect(mac.store.state.ownerMachineChoice(cardId: "card_box") == "box")
        #expect(mac.engine.movePick(forForeignCard: "card_box", runRemotely: true, machineChoice: .existing("box")) == nil)
        #expect(mac.engine.movePick(forForeignCard: "card_box", runRemotely: false, machineChoice: nil) == "mac")
        #expect(mac.engine.movePick(forForeignCard: "card_box", runRemotely: true, machineChoice: .existing("gpu-box")) == "gpu-box")
        // A card this master runs is resumed the usual way.
        mac.store.dispatch(.createManualTask(Link(id: "card_mac", name: "Here", projectPath: "/tmp/acme", column: .waiting)))
        #expect(mac.engine.movePick(forForeignCard: "card_mac", runRemotely: false, machineChoice: nil) == nil)
    }

    @Test("an adoption takes the bytes it already mirrors and copies only the rest")
    func adoptionReusesTheMirror() async throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("mirror-seed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let mac = try TestMaster(name: "mac", root: root)
        let box = try TestMaster(name: "box", root: root)
        try await mac.serve()
        try await box.serve()
        try await mac.start(peerURL: box.url, peerToken: box.tokenForPeer)
        try await box.start(peerURL: mac.url, peerToken: mac.tokenForPeer)
        defer { mac.server.stop(); box.server.stop() }
        let sessionId = "0f1e2d3c-aaaa-bbbb-cccc-000000000005"
        let transcript = "\(root)/mac-transcript.jsonl"
        let lines = (0..<50).map { #"{"type":"user","message":{"role":"user","content":"line \#($0)"}}"# }
        try (lines.joined(separator: "\n") + "\n").write(toFile: transcript, atomically: true, encoding: .utf8)
        mac.store.dispatch(.createManualTask(Link(
            id: "card_seed", name: "Seed", projectPath: root, column: .waiting,
            sessionLink: SessionLink(sessionId: sessionId, sessionPath: transcript))))
        await box.peerSync.pullAll()
        let client = try #require(await box.engine.peerClient(machineId: mac.identity.id))
        let data = try Data(contentsOf: URL(fileURLWithPath: transcript))

        let mirror = "\(root)/mirror.jsonl"
        try data.prefix(1000).write(to: URL(fileURLWithPath: mirror))
        let seeded = await MasterEngine.mirroredPrefix(at: mirror, size: data.count, cardId: "card_seed", client: client)
        #expect(seeded == data.prefix(1000))

        // A mirror that is not the start of the transcript is not used.
        var wrong = Data(data.prefix(1000))
        wrong[wrong.count - 1] = UInt8(ascii: "X")
        try wrong.write(to: URL(fileURLWithPath: mirror))
        #expect(await MasterEngine.mirroredPrefix(at: mirror, size: data.count, cardId: "card_seed", client: client) == nil)
        // Nor one longer than the transcript.
        try (data + data).write(to: URL(fileURLWithPath: mirror))
        #expect(await MasterEngine.mirroredPrefix(at: mirror, size: data.count, cardId: "card_seed", client: client) == nil)
    }

    @Test("a resume whose worktree was removed continues in the repository, not in a bare shell")
    func resumeAfterWorktreeRemoved() async throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("gone-wt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let mac = try TestMaster(name: "mac", root: root)
        let repo = "\(root)/repo"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        mac.store.dispatch(.createManualTask(Link(
            id: "card_gone", name: "Gone", projectPath: repo, column: .waiting,
            sessionLink: SessionLink(sessionId: "0f1e2d3c-aaaa-bbbb-cccc-000000000005"),
            worktreeLink: WorktreeLink(path: "\(repo)/.claude/worktrees/removed", branch: "removed")
        )))

        #expect(mac.engine.resume(cardId: "card_gone", runRemotely: false, commandOverride: "claude"))
        for _ in 0..<100 where mac.tmux.created.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        let command = try #require(mac.tmux.created.first?.command)
        #expect(command.hasPrefix("cd '\(repo)' && "))

        // A card made for the worktree itself has it as its project folder.
        mac.store.dispatch(.createManualTask(Link(
            id: "card_gone2", name: "Gone too", projectPath: "\(repo)/.claude/worktrees/also-removed", column: .waiting,
            sessionLink: SessionLink(sessionId: "0f1e2d3c-aaaa-bbbb-cccc-000000000006")
        )))
        #expect(mac.engine.resume(cardId: "card_gone2", runRemotely: false, commandOverride: "claude"))
        for _ in 0..<100 where mac.tmux.created.count < 2 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(mac.tmux.created.last?.command?.hasPrefix("cd '\(repo)' && ") == true)
    }

    @Test("a search on one master finds the cards only its peer knows, and still answers when the peer is gone")
    func searchAcrossMasters() async throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("search-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let mac = try TestMaster(name: "mac", root: root)
        let box = try TestMaster(name: "box", root: root)
        try await mac.serve()
        try await box.serve()
        let macPeerToken = try mac.devices.add(name: "box as peer", scope: .peer).token
        try await mac.start(peerURL: box.url, peerToken: box.tokenForPeer)
        try await box.start(peerURL: mac.url, peerToken: macPeerToken)
        defer { mac.server.stop(); box.server.stop() }

        // An archived card syncs to the box; an unclaimed All Sessions card does not.
        mac.store.dispatch(.createManualTask(Link(
            id: "card_archived", name: "Export invoices to Parquet", projectPath: root, column: .allSessions,
            manuallyArchived: true)))
        mac.store.dispatch(.createManualTask(Link(
            id: "card_session", projectPath: root, column: .allSessions,
            source: .discovered, promptBody: "Draft the parquet schema notes")))
        box.store.dispatch(.createManualTask(Link(id: "card_box", name: "Parquet reader on the box", projectPath: root, column: .waiting)))
        await box.peerSync.pullAll()
        #expect(box.store.state.links["card_archived"] != nil)
        #expect(box.store.state.links["card_session"] == nil)

        let host = MasterRemoteControlHost(engine: box.engine)
        let found = await host.searchCards(RemoteCardSearchRequest(query: "parquet"))
        #expect(found.cards.map(\.id) == ["card_box", "card_archived", "card_session"]
            || found.cards.map(\.id) == ["card_box", "card_session", "card_archived"])
        #expect(found.unreachable.isEmpty)
        #expect(found.cards.first { $0.id == "card_archived" }?.archived == true)
        #expect(found.cards.first { $0.id == "card_session" }?.machineId == mac.identity.id)

        let localOnly = await host.searchCards(RemoteCardSearchRequest(query: "parquet", local: true))
        #expect(Set(localOnly.cards.map(\.id)) == ["card_box", "card_archived"])

        // Over HTTP, as the phone asks the box.
        let phone = RemoteClient(baseURL: URL(string: box.url)!, token: box.tokenForPeer)
        let older = try await phone.searchCards("parquet", scope: .older)
        #expect(Set(older.cards.map(\.id)) == ["card_archived", "card_session"])

        mac.server.stop()
        let started = Date()
        let without = await host.searchCards(RemoteCardSearchRequest(query: "parquet"))
        #expect(Date().timeIntervalSince(started) < RemoteCardSearch.peerTimeout + 2)
        #expect(Set(without.cards.map(\.id)) == ["card_box", "card_archived"])
        #expect(without.unreachable == ["mac"])
    }
}

/// Progress reports of an upload, from any thread.
private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [[Int64]] = []

    func add(_ sent: Int64, _ total: Int64) { lock.withLock { reports.append([sent, total]) } }
    var last: [Int64]? { lock.withLock { reports.last } }
    var count: Int { lock.withLock { reports.count } }
}

// MARK: - Control connections

/// Polls `condition` until it holds or `timeout` passed; whether it held.
@MainActor
private func eventually(within timeout: Duration = .seconds(5), _ condition: () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

/// Collects what a sync hands to its change and learning handlers.
private final class PeerSyncRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _changes: [(String, PeerChange)] = []
    private var _learned: [(peerId: String, machineId: String, hints: [String])] = []
    var changes: [(String, PeerChange)] { lock.withLock { _changes } }
    var learned: [(peerId: String, machineId: String, hints: [String])] { lock.withLock { _learned } }
    func change(_ machine: String, _ change: PeerChange) { lock.withLock { _changes.append((machine, change)) } }
    func learn(_ peerId: String, _ machineId: String, _ hints: [String]) { lock.withLock { _learned.append((peerId, machineId, hints)) } }
}

@Suite("Peer control connections", .serialized)
@MainActor
struct PeerControlConnectionTests {
    /// Short times, so a test sees a timeout in well under a second.
    static let fast = PeerControl.Options(
        pingInterval: .milliseconds(100), timeout: .milliseconds(600), helloTimeout: .seconds(2),
        dialTimeout: 2, firstRetry: .milliseconds(100), maxRetry: .milliseconds(400))

    /// The Mac and the box, each serving with its control route, each with
    /// an entry for the other ("peer_box" on the Mac, "peer_mac" on the
    /// box), unless an entry is given.
    private func pair(
        _ root: String,
        control: PeerControl.Options = PeerControlConnectionTests.fast,
        macPeers: (([TestMaster]) -> [PeerConfig])? = nil,
        boxPeers: (([TestMaster]) -> [PeerConfig])? = nil
    ) async throws -> (mac: TestMaster, box: TestMaster) {
        let mac = try TestMaster(name: "mac", root: root)
        let box = try TestMaster(name: "box", root: root)
        try await mac.serve(control: true)
        try await box.serve(control: true)
        let both = [mac, box]
        try await mac.start(peers: macPeers?(both)
            ?? [PeerConfig(id: "peer_box", name: "box", url: box.url, token: box.tokenForPeer)], control: control)
        try await box.start(peers: boxPeers?(both)
            ?? [PeerConfig(id: "peer_mac", name: "mac", url: mac.url, token: mac.tokenForPeer)], control: control)
        return (mac, box)
    }

    /// Runs a master's sync with the plain pull timer out of the way: only
    /// the first pull, pokes and pushes pull.
    private func run(_ master: TestMaster) -> Task<Void, Never> {
        let sync = master.peerSync!
        return Task.detached { await sync.run(interval: .seconds(60), offlineInterval: .seconds(60), connectedInterval: .seconds(60)) }
    }

    private func root(_ name: String) -> String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent("\(name)-\(UUID().uuidString)")
    }

    @Test("the defaults ping every 10 s and give up after 30 s of silence")
    func defaults() {
        let options = PeerControl.Options()
        #expect(options.pingInterval == .seconds(10))
        #expect(options.timeout == .seconds(30))
        #expect(options.maxRetry == .seconds(30))
        #expect(PeerSync.safetyPull == .seconds(60))
    }

    @Test("two masters connect, and a card made on one is on the other within 1 s without the 5 s timer")
    func pushReachesPeer() async throws {
        let dir = root("control-push")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let (mac, box) = try await pair(dir)
        let tasks = [run(mac), run(box),
                     Task { await mac.engine.runOwnershipLoop() }, Task { await box.engine.runOwnershipLoop() }]
        defer { tasks.forEach { $0.cancel() }; mac.server.stop(); box.server.stop() }

        #expect(await eventually {
            mac.store.state.peerStatuses["peer_box"]?.connected == true
                && box.store.state.peerStatuses["peer_mac"]?.connected == true
        })
        // The pulls the connection set off are done.
        try await Task.sleep(for: .milliseconds(300))

        let clock = ContinuousClock()
        var start = clock.now
        mac.store.dispatch(.createManualTask(Link(id: "card_push", name: "Pushed", projectPath: "/tmp/p", column: .backlog)))
        #expect(await eventually(within: .seconds(3)) { box.store.state.links["card_push"] != nil })
        #expect(clock.now - start < .seconds(1), "took \(clock.now - start)")

        start = clock.now
        box.store.dispatch(.createManualTask(Link(id: "card_back", name: "Back", projectPath: "/tmp/p", column: .backlog)))
        #expect(await eventually(within: .seconds(3)) { mac.store.state.links["card_back"] != nil })
        #expect(clock.now - start < .seconds(1), "took \(clock.now - start)")

        let macLinks = await mac.peerSync.control.links()
        let boxLinks = await box.peerSync.control.links()
        #expect(macLinks.count == 1)
        #expect(boxLinks.count == 1)
        #expect(macLinks.first?.dialer == boxLinks.first?.dialer)
        #expect(macLinks.first?.machine.id == box.identity.id)
        #expect(boxLinks.first?.machine.id == mac.identity.id)
    }

    @Test("a master that goes silent, as a Mac going to sleep, shows disconnected once the timeout passes")
    func silentPeer() async throws {
        let dir = root("control-silent")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let (mac, box) = try await pair(dir)
        let tasks = [run(mac), run(box)]
        defer { tasks.forEach { $0.cancel() }; mac.server.stop(); box.server.stop() }
        #expect(await eventually { mac.store.state.peerStatuses["peer_box"]?.connected == true })

        let clock = ContinuousClock()
        let start = clock.now
        box.peerSync.control.goSilentForTesting()
        #expect(await eventually(within: .seconds(3)) { mac.store.state.peerStatuses["peer_box"]?.connected == false })
        let took = clock.now - start
        // The timeout, and at most the watchdog's tick on top.
        #expect(took < Self.fast.timeout + .milliseconds(400), "took \(took)")
        #expect(mac.store.state.peerStatuses["peer_box"]?.controlError?.contains("no answer for 0.6 s") == true,
                "\(mac.store.state.peerStatuses["peer_box"]?.controlError ?? "nil")")
        // Redials reach nothing that answers.
        try await Task.sleep(for: .milliseconds(500))
        #expect(mac.store.state.peerStatuses["peer_box"]?.connected == false)
    }

    @Test("a master that stops shows disconnected on the other at once, with its reason")
    func stoppedPeer() async throws {
        let dir = root("control-stop")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let (mac, box) = try await pair(dir)
        let macTask = run(mac)
        let boxTask = run(box)
        defer { macTask.cancel(); boxTask.cancel(); mac.server.stop(); box.server.stop() }
        #expect(await eventually { mac.store.state.peerStatuses["peer_box"]?.connected == true })

        boxTask.cancel()
        box.server.stop()
        #expect(await eventually(within: .seconds(2)) { mac.store.state.peerStatuses["peer_box"]?.connected == false })
        let reason = mac.store.state.peerStatuses["peer_box"]?.controlError ?? ""
        #expect(reason.contains("box"), "\(reason)")
    }

    @Test("when both masters dial at once, the connection the lower machine id dialed is the one left")
    func simultaneousDials() async throws {
        for round in 0..<3 {
            let dir = root("control-both-\(round)")
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let (mac, box) = try await pair(dir)
            // Each side holds what it accepted a moment: both dial for sure.
            await mac.peerSync.control.delayAcceptsForTesting(.milliseconds(300))
            await box.peerSync.control.delayAcceptsForTesting(.milliseconds(300))
            let tasks = [run(mac), run(box)]
            defer { tasks.forEach { $0.cancel() }; mac.server.stop(); box.server.stop() }

            #expect(await eventually {
                mac.store.state.peerStatuses["peer_box"]?.connected == true
                    && box.store.state.peerStatuses["peer_mac"]?.connected == true
            })
            // The losing connection closes on both ends.
            try await Task.sleep(for: .milliseconds(400))
            let macLinks = await mac.peerSync.control.links()
            let boxLinks = await box.peerSync.control.links()
            let lower = min(mac.identity.id, box.identity.id)
            #expect(macLinks.count == 1 && boxLinks.count == 1)
            #expect(macLinks.first?.dialer == lower)
            #expect(boxLinks.first?.dialer == lower)
            let (low, high) = mac.identity.id == lower ? (mac, box) : (box, mac)
            let lowPeer = low === mac ? "peer_box" : "peer_mac"
            let highPeer = high === mac ? "peer_box" : "peer_mac"
            #expect(low.store.state.peerStatuses[lowPeer]?.connectedVia == .dialed)
            #expect(high.store.state.peerStatuses[highPeer]?.connectedVia == .accepted)
            #expect(low.store.state.peerStatuses[lowPeer]?.connected == true)
            #expect(high.store.state.peerStatuses[highPeer]?.connected == true)
        }
    }

    @Test("a dial tries the hints in order, and the one that worked and the peer's machine id are learned")
    func learnsHints() async throws {
        let dir = root("control-hints")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let dead = "http://127.0.0.1:1"
        let (mac, box) = try await pair(dir, macPeers: { both in
            [PeerConfig(id: "peer_box", name: "box", addressHints: [dead, both[1].url], token: both[1].tokenForPeer)]
        })
        let recorder = PeerSyncRecorder()
        await mac.peerSync.onEntryLearned { recorder.learn($0, $1, $2) }
        let boxRecorder = PeerSyncRecorder()
        await box.peerSync.onEntryLearned { boxRecorder.learn($0, $1, $2) }
        // Only the Mac dials.
        await box.peerSync.setPeers([PeerConfig(id: "peer_mac", name: "mac", addressHints: [], token: mac.tokenForPeer)])
        let tasks = [run(mac), run(box)]
        defer { tasks.forEach { $0.cancel() }; mac.server.stop(); box.server.stop() }

        #expect(await eventually { mac.store.state.peerStatuses["peer_box"]?.connected == true })
        #expect(mac.store.state.peerStatuses["peer_box"]?.connectedVia == .dialed)
        #expect(await eventually { !recorder.learned.isEmpty && !boxRecorder.learned.isEmpty })
        let learned = try #require(recorder.learned.last)
        #expect(learned.machineId == box.identity.id)
        #expect(learned.hints == [box.url, dead])
        let entry = try #require(await mac.peerSync.configuredPeers().first)
        #expect(entry.addressHints.first == box.url)
        #expect(entry.machineId == box.identity.id)
        // The box knew the Mac by no machine id; the only such entry is it.
        #expect(boxRecorder.learned.last?.machineId == mac.identity.id)
        #expect(await box.peerSync.configuredPeers().first?.machineId == mac.identity.id)
        // Pulls follow the hint that worked.
        #expect(mac.peerSync.endpoints.baseURL(forPeer: "peer_box")?.absoluteString == box.url)
    }

    @Test("a peer that answers as another machine than its entry names is not connected, and says why")
    func machineMismatch() async throws {
        let dir = root("control-mismatch")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let (mac, box) = try await pair(dir, macPeers: { both in
            [PeerConfig(id: "peer_box", machineId: "machine_someone_else", name: "box",
                        addressHints: [both[1].url], token: both[1].tokenForPeer)]
        })
        let tasks = [run(mac), run(box)]
        defer { tasks.forEach { $0.cancel() }; mac.server.stop(); box.server.stop() }

        #expect(await eventually { mac.store.state.peerStatuses["peer_box"]?.controlError?.contains("not machine_someone_else") == true })
        #expect(mac.store.state.peerStatuses["peer_box"]?.connected == false)
        // The box refused it before taking it: it never counted as connected there.
        let refused = await box.peerSync.control.links()
        #expect(refused.isEmpty)
        // The box's dial is refused by the Mac: its entry for the box names another machine.
        #expect(await eventually { box.store.state.peerStatuses["peer_mac"]?.controlError?.contains("no peer entry") == true })
    }

    @Test("a master with no entry for the dialer refuses its control connection with the reason")
    func noEntry() async throws {
        let dir = root("control-noentry")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let (mac, box) = try await pair(dir, boxPeers: { _ in [] })
        let tasks = [run(mac), run(box)]
        defer { tasks.forEach { $0.cancel() }; mac.server.stop(); box.server.stop() }

        #expect(await eventually {
            mac.store.state.peerStatuses["peer_box"]?.controlError?.contains("box has no peer entry for mac") == true
        }, "\(mac.store.state.peerStatuses["peer_box"]?.controlError ?? "nil")")
        #expect(mac.store.state.peerStatuses["peer_box"]?.connected == false)
    }

    @Test("only a peer or full token opens a control connection")
    func controlScopes() async throws {
        let dir = root("control-scope")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let (_, box) = try await pair(dir)
        defer { box.server.stop() }
        let base = try #require(URL(string: box.url))
        for scope in [RemoteScope.agent, .terminal] {
            let token = try box.devices.add(name: "x", scope: scope).token
            await #expect(throws: RemoteWebSocketDialError.self) {
                _ = try await RemoteWebSocketClient.connect(baseURL: base, path: PeerControl.path, token: token)
            }
            do {
                _ = try await RemoteWebSocketClient.connect(baseURL: base, path: PeerControl.path, token: token)
            } catch let error as RemoteWebSocketDialError {
                guard case .refused(let status, _) = error else { Issue.record("\(error)"); continue }
                #expect(status == 403)
            }
        }
        do {
            _ = try await RemoteWebSocketClient.connect(baseURL: base, path: PeerControl.path, token: "nope")
            Issue.record("an unknown token opened a control connection")
        } catch let error as RemoteWebSocketDialError {
            #expect(error == .refused(401, "unknown or revoked token"))
        }
        let peer = try box.devices.add(name: "mac", scope: .peer).token
        let ws = try await RemoteWebSocketClient.connect(baseURL: base, path: PeerControl.path, token: peer)
        ws.close()
    }

    @Test("the agent sync's change notes and attention go over the control connection")
    func syncAndAttentionPushes() async throws {
        let dir = root("control-sync")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let (mac, box) = try await pair(dir)
        let recorder = PeerSyncRecorder()
        await box.peerSync.onPeerChange { recorder.change($0, $1) }
        let tasks = [run(mac), run(box), Task { await mac.engine.runOwnershipLoop() }]
        defer { tasks.forEach { $0.cancel() }; mac.server.stop(); box.server.stop() }
        #expect(await eventually { mac.store.state.peerStatuses["peer_box"]?.connected == true })
        // What a fresh connection pokes.
        #expect(await eventually { recorder.changes.contains { $0.1.what == .sync } })

        let transport = PeerControlSyncTransport(peerSync: mac.peerSync)
        let syncPeer = SyncPeer(machine: box.identity, baseURL: URL(string: box.url)!, token: box.tokenForPeer, online: true)
        await transport.notify(peer: syncPeer, machineId: mac.identity.id, what: "git:entry_1")
        #expect(await eventually(within: .seconds(1)) {
            recorder.changes.contains { $0.0 == mac.identity.id && $0.1 == PeerChange(what: .sync, detail: "git:entry_1") }
        })

        let before = recorder.changes.filter { $0.1.what == .attention }.count
        mac.store.dispatch(.attentionRaised(AttentionRequest(id: "att_push", cardId: nil, kind: .question, title: "Q", body: "?")))
        #expect(await eventually(within: .seconds(2)) {
            recorder.changes.filter { $0.0 == mac.identity.id && $0.1.what == .attention }.count > before
        })
    }
}

@Suite("Peer control wire format")
struct PeerControlWireTests {
    @Test("a peer status from before control connections decodes as not connected")
    func oldStatus() throws {
        let json = #"{"peerId":"peer_a","online":true,"url":"http://10.0.0.2:7780"}"#
        let status = try JSONDecoder().decode(PeerStatus.self, from: Data(json.utf8))
        #expect(status.online)
        #expect(!status.connected)
        #expect(status.connectedVia == nil)
        let round = try JSONDecoder().decode(PeerStatus.self, from: JSONEncoder().encode(
            PeerStatus(peerId: "p", online: true, connected: true, connectedVia: .accepted)))
        #expect(round.connected && round.connectedVia == .accepted)
    }

    @Test("control messages are one small JSON object each")
    func messages() throws {
        let changed = try JSONEncoder.remote.encode(PeerControlMessage(changed: PeerChange(what: .links)))
        #expect(String(decoding: changed, as: UTF8.self) == #"{"changed":{"what":"links"}}"#)
        let decoded = try JSONDecoder.remote.decode(PeerControlMessage.self, from: Data(#"{"ping":3,"later":{"x":1}}"#.utf8))
        #expect(decoded.ping == 3)
        let hello = PeerHello(machine: MachineIdentity(id: "machine_a", name: "a"), version: "1",
                              addresses: ["192.168.178.59", "127.0.0.1", "fe80::1", "2001:db8::2"], port: 7780)
        #expect(hello.hintURLs == ["http://192.168.178.59:7780", "http://[2001:db8::2]:7780"])
    }

    @Test("the hint that worked goes first, announced ones follow, and the list stays bounded")
    func mergedHints() {
        let merged = PeerControl.mergedHints(["http://a:1", "http://b:1/"], promote: "http://b:1",
                                             announced: ["http://c:1", "http://a:1"], limit: 8)
        #expect(merged == ["http://b:1", "http://a:1", "http://c:1"])
        let bounded = PeerControl.mergedHints(["http://a:1"], promote: nil,
                                              announced: (0..<20).map { "http://h\($0):1" }, limit: 4)
        #expect(bounded.count == 4)
        #expect(bounded.first == "http://a:1")
    }

    @Test("a hello announces the addresses the server listens on, every interface's for a wildcard")
    func advertised() {
        let fixed = PeerControl.advertised((addresses: ["127.0.0.1", "192.168.178.230"], port: 7780))
        #expect(fixed.addresses == ["192.168.178.230"])
        #expect(fixed.port == 7780)
        let wild = PeerControl.advertised((addresses: ["0.0.0.0"], port: 7780))
        #expect(!wild.addresses.contains("0.0.0.0"))
        #expect(!wild.addresses.contains("127.0.0.1"))
        #expect(PeerControl.advertised(nil).addresses.isEmpty)
    }
}
