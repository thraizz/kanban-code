import Foundation
import KanbanCodeCore
import KanbanCodeRemoteKit
#if canImport(Glibc)
import Glibc
#endif

/// The service graph and loops of a headless master: the same BoardStore and
/// master engine the Mac app drives, over the kanban home of this machine,
/// plus peer sync. Sessions run here on agtop or tmux, as the settings say.
@MainActor
final class ServerMaster {
    let home: String
    let store: BoardStore
    let settingsStore: SettingsStore
    let engine: MasterEngine
    let orchestrator: BackgroundOrchestrator
    let identity: MachineIdentity
    let peerSync: PeerSync
    let agentSync: AgentSyncEngine
    let reconciles: Bool

    init(home: String, reconciles: Bool) {
        self.home = home
        self.reconciles = reconciles

        let settingsStore = SettingsStore(basePath: home)
        let settings = Self.readSettings(home: home).settings
        let enabled = settings?.enabledAssistants ?? CodingAssistant.allCases

        let registry = CodingAssistantRegistry()
        let claudeDetector = ClaudeCodeActivityDetector()
        if enabled.contains(.claude) {
            registry.register(.claude, discovery: ClaudeCodeSessionDiscovery(), detector: claudeDetector, store: ClaudeCodeSessionStore())
        }
        if enabled.contains(.gemini) {
            registry.register(.gemini, discovery: GeminiSessionDiscovery(), detector: GeminiActivityDetector(), store: GeminiSessionStore())
        }
        if enabled.contains(.codex) {
            registry.register(.codex, discovery: CodexSessionDiscovery(), detector: CodexActivityDetector(), store: CodexSessionStore())
        }
        let discovery = CompositeSessionDiscovery(registry: registry)
        let activityDetector = CompositeActivityDetector(registry: registry, defaultDetector: claudeDetector)

        let coordination = CoordinationStore(basePath: home)
        let tmux = RoutingTmuxAdapter()
        let effectHandler = EffectHandler(
            coordinationStore: coordination,
            tmuxAdapter: tmux,
            notifier: Self.notifier(settings)
        )
        let store = BoardStore(
            effectHandler: effectHandler,
            discovery: discovery,
            coordinationStore: coordination,
            activityDetector: activityDetector,
            settingsStore: settingsStore,
            ghAdapter: GhCliAdapter(),
            worktreeAdapter: GitWorktreeAdapter(),
            tmuxAdapter: tmux
        )
        // Sessions other masters run on this host (over ssh) stay theirs.
        store.adoptsDiscoveredSessions = false
        self.store = store
        self.settingsStore = settingsStore

        var identity = MachineIdentityStore(basePath: home).loadOrCreate()
        // A server runs all the time: it keeps the channels and polls GitHub.
        identity.alwaysOn = true
        self.identity = identity

        let orchestrator = BackgroundOrchestrator(
            discovery: discovery,
            coordinationStore: coordination,
            activityDetector: activityDetector,
            tmux: tmux,
            prTracker: GhCliAdapter(),
            notifier: Self.notifier(settings),
            registry: registry
        )
        orchestrator.localMachineId = identity.id
        orchestrator.notifiesUnlinkedSessions = false
        orchestrator.setDispatch { [weak store] action in store?.dispatch(action) }
        self.orchestrator = orchestrator

        var platform = MasterPlatform()
        platform.kanbanHome = home
        let cli = (home as NSString).appendingPathComponent("cli/dist/kanban.js")
        platform.cliScript = FileManager.default.fileExists(atPath: cli) ? cli : nil
        platform.nodePath = ShellCommand.findExecutable("node")
        if getuid() == 0 { platform.sessionEnvironment["IS_SANDBOX"] = "1" }
        platform.defaultAssistant = {
            let enabled = Self.readSettings(home: home).settings?.enabledAssistants ?? [.claude]
            return enabled.contains(.claude) ? .claude : (enabled.first ?? .claude)
        }
        engine = MasterEngine(
            store: store,
            settingsStore: settingsStore,
            launcher: LaunchSession(tmux: tmux),
            tmux: tmux,
            registry: registry,
            platform: platform
        )

        peerSync = PeerSync(identity: identity, peers: settings?.peers ?? []) { [weak store] action in
            await MainActor.run { store?.dispatch(action) }
        }
        engine.peerSync = peerSync
        engine.installForeignCardHandler()
        agentSync = AgentSyncEngine(kanbanHome: home, identity: identity) { [peerSync] in
            await peerSync.syncPeers()
        }
    }

    /// Pushover when configured, nothing otherwise: a headless host has no
    /// notification center.
    nonisolated static func notifier(_ settings: Settings?) -> NotifierPort? {
        guard let notifications = settings?.notifications,
              notifications.pushoverMode != .disabled,
              let token = notifications.pushoverToken, let user = notifications.pushoverUserKey,
              !token.isEmpty, !user.isEmpty
        else { return nil }
        return PushoverClient(token: token, userKey: user)
    }

    /// Loads the board, then runs the loops until the task is cancelled.
    func start() async {
        installHooks()
        store.dispatch(.localMachineLoaded(identity))
        await store.loadSettingsAndCache()
        if reconciles { await store.reconcile() }

        let peerSync = self.peerSync
        Task.detached { await peerSync.run() }
        let agentSync = self.agentSync
        Task.detached { await agentSync.run() }
        Task { await self.settingsLoop() }
        orchestrator.start()
        let orchestrator = self.orchestrator
        let store = self.store
        Task.detached {
            await MasterEngine.watchHookEvents(kanbanHome: self.home) {
                await orchestrator.processHookEvents()
                await store.refreshActivity()
            }
        }
        if reconciles {
            Task { await engine.runReconcileLoop() }
        }
        Task { await engine.runSelfCompactMonitor() }
        Task { await engine.runSessionModelMonitor() }
        Task { await engine.runOwnershipLoop() }
        Task { await engine.monitorSubagentCommands() }
    }

    /// The assistants' hooks drive the busy state, the queue and the
    /// notifications; the statusline feeds context usage.
    private func installHooks() {
        // OpenCode sessions live in a SQLite database the Linux build does
        // not read, so the server leaves OpenCode to the Mac master.
        for assistant in CodingAssistant.allCases where assistant.supportsHooks && assistant != .opencode {
            guard (try? FileManager.default.contentsOfDirectory(atPath: NSHomeDirectory() + "/" + assistant.configDirName)) != nil else { continue }
            if !HookManager.isInstalled(for: assistant) {
                do {
                    try HookManager.install(for: assistant)
                    say("installed \(assistant.displayName) hooks")
                } catch {
                    say("could not install \(assistant.displayName) hooks: \(error)")
                }
            }
        }
        _ = HookManager.refreshHookScript()
        if !HookManager.isStatusLineInstalled(for: .claude) {
            try? HookManager.installStatusLine(for: .claude)
        }
    }

    /// Picks up settings edits (projects, peers, notifications) without a restart.
    private func settingsLoop() async {
        var last = Self.readSettings(home: home)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            let current = Self.readSettings(home: home)
            guard current.raw != last.raw, let settings = current.settings else { continue }
            if settings.peers != last.settings?.peers { await peerSync.setPeers(settings.peers) }
            orchestrator.updateNotifier(Self.notifier(settings))
            last = current
            await store.loadSettingsAndCache()
        }
    }

    nonisolated static func readSettings(home: String) -> (raw: Data?, settings: Settings?) {
        let path = (home as NSString).appendingPathComponent("settings.json")
        guard let data = FileManager.default.contents(atPath: path) else { return (nil, nil) }
        return (data, try? JSONDecoder().decode(Settings.self, from: data))
    }
}
