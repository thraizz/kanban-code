import AppKit
import KanbanCodeCore

/// The service graph of the app, built once and shared by every
/// `ContentView` value SwiftUI creates. The store, the boxd supervisor and
/// the remote session registry hold references to each other, so a second
/// copy would send its actions to a store nothing renders.
@MainActor
final class AppComposition {
    static var shared: AppComposition {
        if let current { return current }
        let built = AppComposition()
        current = built
        return built
    }
    private static var current: AppComposition?

    let store: BoardStore
    let orchestrator: BackgroundOrchestrator
    let settingsStore: SettingsStore
    let assistantRegistry: CodingAssistantRegistry
    let launcher: LaunchSession
    let tmuxAdapter: RoutingTmuxAdapter
    let boxdSupervisor: BoxdMachineSupervisor
    let engine: MasterEngine
    let peerSync: PeerSync
    let agentSync: AgentSyncEngine
    let transcriptMirror: PeerTranscriptMirror

    private init() {
        let claudeDiscovery = ClaudeCodeSessionDiscovery()
        let claudeDetector = ClaudeCodeActivityDetector()
        let claudeStore = ClaudeCodeSessionStore()
        let geminiDiscovery = GeminiSessionDiscovery()
        let geminiDetector = GeminiActivityDetector()
        let geminiStore = GeminiSessionStore()
        let codexDiscovery = CodexSessionDiscovery()
        let codexDetector = CodexActivityDetector()
        let codexStore = CodexSessionStore()
        let opencodeDiscovery = OpenCodeSessionDiscovery()
        let opencodeDetector = OpenCodeActivityDetector()
        let opencodeStore = OpenCodeSessionStore()
        let piDiscovery = PiSessionDiscovery()
        let piDetector = PiActivityDetector()
        let piStore = PiSessionStore()

        let enabledAssistants = ContentView.loadEnabledAssistants()
        let registry = CodingAssistantRegistry()
        if enabledAssistants.contains(.claude) {
            registry.register(.claude, discovery: claudeDiscovery, detector: claudeDetector, store: claudeStore)
        }
        if enabledAssistants.contains(.gemini) {
            registry.register(.gemini, discovery: geminiDiscovery, detector: geminiDetector, store: geminiStore)
        }
        if enabledAssistants.contains(.codex) {
            registry.register(.codex, discovery: codexDiscovery, detector: codexDetector, store: codexStore)
        }
        if enabledAssistants.contains(.opencode) {
            registry.register(.opencode, discovery: opencodeDiscovery, detector: opencodeDetector, store: opencodeStore)
        }
        if enabledAssistants.contains(.pi) {
            registry.register(.pi, discovery: piDiscovery, detector: piDetector, store: piStore)
        }

        let discovery = CompositeSessionDiscovery(registry: registry)
        let activityDetector = CompositeActivityDetector(registry: registry, defaultDetector: claudeDetector)

        let coordination = CoordinationStore()
        let settings = SettingsStore()
        let remoteRegistry = RemoteSessionRegistry()
        let tmux = RoutingTmuxAdapter(local: TmuxAdapter(), registry: remoteRegistry)
        let machinePort = MachinePortRouter(
            boxd: BoxdCliAdapter(),
            ssh: SshHostPort(machines: { (try? await settings.read())?.boxd?.sshMachines ?? [] })
        )
        let supervisor = BoxdMachineSupervisor(
            boxd: machinePort,
            registry: remoteRegistry,
            settingsProvider: { (try? await settings.read())?.boxd ?? BoxdSettings() },
            cliBundlePath: AppServices.cliBundlePath,
            appVersion: AppServices.appVersion
        )
        AppServices.tmux = tmux
        AppServices.remoteRegistry = remoteRegistry
        AppServices.boxdSupervisor = supervisor

        let effectHandler = EffectHandler(
            coordinationStore: coordination,
            tmuxAdapter: tmux,
            setClipboardImage: { data in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setData(data, forType: .png)
            },
            notifier: MacOSNotificationClient(),
            remoteMachines: supervisor
        )

        let boardStore = BoardStore(
            effectHandler: effectHandler,
            discovery: discovery,
            coordinationStore: coordination,
            activityDetector: activityDetector,
            settingsStore: settings,
            ghAdapter: GhCliAdapter(),
            worktreeAdapter: GitWorktreeAdapter(),
            tmuxAdapter: tmux
        )

        // Load Pushover from settings.json, wrap in CompositeNotifier with macOS fallback
        let (pushover, pushoverMode) = ContentView.loadPushoverConfig()
        let notifier = CompositeNotifier(primary: pushover, fallback: MacOSNotificationClient(), pushoverMode: pushoverMode)

        let orch = BackgroundOrchestrator(
            discovery: discovery,
            coordinationStore: coordination,
            activityDetector: activityDetector,
            tmux: tmux,
            prTracker: GhCliAdapter(),
            notifier: notifier,
            registry: registry
        )

        let launch = LaunchSession(tmux: tmux)

        orch.setDispatch { [weak boardStore] action in
            boardStore?.dispatch(action)
        }
        AppServices.pauseMachine = { [weak boardStore] cardId in
            boardStore?.dispatch(.stopRemoteMachine(cardId: cardId, reason: .manual))
        }
        AppServices.destroyMachine = { [weak boardStore] cardId in
            boardStore?.dispatch(.showDialog(.confirmDestroyMachine(cardId: cardId)))
        }
        Task { [weak boardStore] in
            await supervisor.setDispatch { action in
                boardStore?.dispatch(action)
            }
            await supervisor.setProxyRunner { invocation in
                await AppServices.runProxiedCommand(invocation)
            }
            await supervisor.setBusyCheck { machineName in
                await MainActor.run {
                    guard let boardStore else { return false }
                    let state = boardStore.state
                    return state.cardIds(onMachine: machineName).contains { cardId in
                        guard let sessionId = state.links[cardId]?.sessionLink?.sessionId else { return false }
                        return state.activityMap[sessionId] == .activelyWorking
                    }
                }
            }
            await supervisor.setLinksProvider {
                await MainActor.run { boardStore.map { Array($0.state.links.values) } ?? [] }
            }
        }


        // Restore persisted detail expansion and card selection before first render
        // to avoid flicker. @AppStorage values are available synchronously.
        let persistedExpanded = UserDefaults.standard.bool(forKey: "detailExpanded")
        let persistedCardId = UserDefaults.standard.string(forKey: "selectedCardId") ?? ""
        if persistedExpanded {
            boardStore.dispatch(.setDetailExpanded(true))
        }
        if !persistedCardId.isEmpty {
            boardStore.dispatch(.selectCard(cardId: persistedCardId))
        }

        let engine = MasterEngine(
            store: boardStore,
            settingsStore: settings,
            launcher: launch,
            tmux: tmux,
            boxdSupervisor: supervisor,
            registry: registry,
            platform: Self.platform()
        )
        // The machine identity is on the board before the first reconcile,
        // so every card this Mac stamps carries it.
        let identity = MachineIdentityStore().loadOrCreate(defaultName: RemoteControlServer.defaultHostName)
        boardStore.dispatch(.localMachineLoaded(identity))
        orch.localMachineId = identity.id
        let peerSync = PeerSync(identity: identity, peers: Self.readPeers()) { [weak boardStore] action in
            await MainActor.run { boardStore?.dispatch(action) }
        }
        engine.peerSync = peerSync
        engine.installForeignCardHandler()
        Task.detached { await peerSync.run() }
        Task { await engine.runOwnershipLoop() }
        let mirror = PeerTranscriptMirror(engine: engine)
        Task { await mirror.run() }
        // Channels live on the channels home when it is another master.
        Task { await effectHandler.setChannelsHome { [weak engine] in await engine?.channelsHomeRoute() } }
        Task { await engine.runChannelsMirror() }
        NotificationCenter.default.addObserver(forName: .kanbanCodeSettingsChanged, object: nil, queue: .main) { _ in
            let peers = Self.readPeers()
            Task { await peerSync.setPeers(peers) }
        }
        let agentSync = AgentSyncEngine(identity: identity) { [peerSync] in await peerSync.syncPeers() }
        Task.detached { await agentSync.run() }
        RemoteControlController.shared.attach(
            engine: engine,
            peerServer: BoardPeerLinksServer(store: boardStore, peerSync: peerSync),
            syncEngine: agentSync,
            settingsStore: settings
        )

        self.store = boardStore
        self.orchestrator = orch
        self.settingsStore = settings
        self.assistantRegistry = registry
        self.launcher = launch
        self.tmuxAdapter = tmux
        self.boxdSupervisor = supervisor
        self.engine = engine
        self.peerSync = peerSync
        self.agentSync = agentSync
        self.transcriptMirror = mirror
        KanbanCodeLog.info("app", "services composed machine=\(identity.name) (\(identity.id))")
    }

    /// Settings > Peers, read straight from the file.
    private static func readPeers() -> [PeerConfig] {
        let path = NSHomeDirectory() + "/.kanban-code/settings.json"
        let settings = FileManager.default.contents(atPath: path).flatMap { try? JSONDecoder().decode(Settings.self, from: $0) }
        return settings?.peers ?? []
    }

    /// What the master engine needs from the Mac: the clipboard, the remote
    /// terminals of boxd and ssh machines, and the defaults of the launch
    /// dialogs for launches from the remote API.
    private static func platform() -> MasterPlatform {
        var platform = MasterPlatform()
        platform.setClipboardImage = { data in
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setData(data, forType: .png)
            }
        }
        platform.expectRemoteSession = { AppServices.expectRemoteSession($0) }
        platform.clearRemoteSessionReady = { AppServices.clearRemoteSessionReady($0) }
        platform.markRemoteSessionReady = { AppServices.markRemoteSessionReady($0, machine: $1) }
        platform.unassignRemoteSession = { AppServices.remoteRegistry?.unassign(sessionName: $0) }
        platform.machineForSession = { AppServices.machine(forSession: $0) }
        platform.remoteMachineChoice = { machine, projectPath in
            let options = AppComposition.shared.remoteLaunchOptions()
            return RemoteLaunchOptions.remoteMachineChoice(machine, options: options, projectPath: projectPath)
        }
        platform.defaultAssistant = {
            // The assistant the New Task dialog last used.
            let last = UserDefaults.standard.string(forKey: "selectedAssistant").flatMap(CodingAssistant.init(rawValue:))
            return last.flatMap { ContentView.loadEnabledAssistants().contains($0) ? $0 : nil } ?? .claude
        }
        platform.skipPermissions = { ContentView.remoteSkipPermissions }
        platform.terminalCommand = { session in AppServices.terminalCommand(forSession: session) }
        platform.peerTerminalCommand = { machineId, cardId, session in
            AppServices.peerTerminalCommand(machineId: machineId, cardId: cardId, session: session)
        }
        platform.clonesMissingProjects = false
        platform.cliScript = AppServices.cliBundlePath.map { "\($0)/dist/kanban.js" }
        platform.nodePath = AppServices.findNode()
        return platform
    }

    /// The launch options of a remote API launch: the board's remote mode
    /// and machines, no card.
    func remoteLaunchOptions() -> RemoteLaunchOptions {
        RemoteLaunchOptions(
            mode: store.state.remoteMode,
            mutagen: store.state.globalRemoteSettings,
            boxd: store.state.remoteMode.runsOnMachines ? (store.state.boxdSettings ?? BoxdSettings()) : nil,
            availableMachines: AppServices.boxdMachineNames,
            boxdAvailable: AppServices.boxdAvailable,
            machines: store.state.machineChoices
        )
    }
}
