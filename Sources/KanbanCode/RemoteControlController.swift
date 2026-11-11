import Foundation
import KanbanCodeCore
import KanbanCodeRemoteKit
import Observation

/// Runs the remote control server of Settings > Remote Control and holds
/// the paired devices. The server itself runs off the main actor; this
/// controller only starts, stops and reports on it.
@MainActor
@Observable
final class RemoteControlController {
    static let shared = RemoteControlController()

    private(set) var isRunning = false
    private(set) var port = RemoteAPI.defaultPort
    private(set) var addresses: [String] = []
    private(set) var lastError: String?
    private(set) var devices: [RemoteDevice] = []

    @ObservationIgnored let deviceStore = RemoteDeviceStore()
    @ObservationIgnored private var server: RemoteControlServer?
    @ObservationIgnored private var host: MasterRemoteControlHost?
    @ObservationIgnored private var applied: RemoteControlSettings?
    @ObservationIgnored private weak var engine: MasterEngine?
    @ObservationIgnored private var peerServer: (any PeerLinksServing)?
    @ObservationIgnored private var syncEngine: AgentSyncEngine?
    @ObservationIgnored private var vault: VaultService?
    /// Set by the composition root before `attach`.
    @ObservationIgnored var scrubber: SecretScrubber?
    @ObservationIgnored private var settingsObserver: NSObjectProtocol?

    private init() {}

    /// Wires the controller to the app's master engine and starts following
    /// the settings. Called once by the composition root.
    func attach(engine: MasterEngine, peerServer: (any PeerLinksServing)?, syncEngine: AgentSyncEngine?, vault: VaultService?,
                settingsStore: SettingsStore) {
        self.syncEngine = syncEngine
        self.vault = vault
        self.engine = engine
        self.peerServer = peerServer
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .kanbanCodeSettingsChanged, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in await RemoteControlController.shared.reload(settingsStore: settingsStore) }
        }
        Task { await reload(settingsStore: settingsStore) }
    }

    func reload(settingsStore: SettingsStore) async {
        // A settings file that can't be read keeps the server as it is: only
        // a setting that says so turns it off.
        guard let settings = try? await settingsStore.read() else { return }
        await apply(settings.remoteControl)
    }

    func apply(_ settings: RemoteControlSettings) async {
        guard settings != applied || (settings.enabled && server == nil) else {
            refreshStatus()
            return
        }
        applied = settings
        stopServer()
        port = settings.port
        guard settings.enabled else {
            refreshStatus()
            return
        }
        guard let engine else { return }
        let host = MasterRemoteControlHost(engine: engine)
        let store = engine.store
        // A changed list restarts the server (above); the server's own
        // periodic check binds a configured address once it appears.
        let configured = settings.bindAddresses
        let server = RemoteControlServer(
            host: host, devices: deviceStore, port: settings.port,
            bindAddresses: { RemoteNetworkAddresses.bindable(configured: configured) },
            peerServer: peerServer, syncEngine: syncEngine,
            vault: vault, scrubber: scrubber,
            // The phone using a card this Mac owns keeps the Mac awake for a while.
            activity: { cardId in
                let ownedHere = await MainActor.run { store.state.links[cardId].map(store.state.isOwnedLocally) ?? false }
                if ownedHere { RemoteWakeHold.shared.touch(card: cardId) }
            })
        do {
            try await server.start()
            self.host = host
            self.server = server
            lastError = nil
        } catch {
            server.stop()
            lastError = "\(error)"
            KanbanCodeLog.warn("remote", "remote control did not start: \(error)")
        }
        refreshStatus()
    }

    private func stopServer() {
        server?.stop()
        server = nil
        host = nil
    }

    func refreshStatus() {
        isRunning = server?.isRunning ?? false
        addresses = server?.listeningAddresses ?? []
        if let server { port = server.port }
        devices = deviceStore.list().sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - Devices

    func addDevice(name: String, scope: RemoteScope) throws -> (device: RemoteDevice, token: String) {
        let (device, token) = try deviceStore.add(name: name, scope: scope)
        refreshStatus()
        return (device, token)
    }

    func revoke(deviceId: String) {
        _ = try? deviceStore.revoke(id: deviceId)
        server?.closeConnections(deviceId: deviceId)
        refreshStatus()
    }

    /// The URL another device reaches the server at: the first bind address
    /// listened on, else the first configured one, else loopback.
    var baseURL: String {
        let listening = addresses.filter { $0 != RemoteNetworkAddresses.loopback }
        return RemoteNetworkAddresses.publicBaseURL(configured: listening + (applied?.bindAddresses ?? []), port: port)
    }

    func pairLink(token: String) -> String {
        RemotePairLink.make(url: baseURL, token: token, name: RemoteControlServer.defaultHostName)
    }
}
