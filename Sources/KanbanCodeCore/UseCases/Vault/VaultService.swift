import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The vault of a master, wired: store, broker, caller resolution and the
/// replica sync with the peer masters. The Mac app and kanban-code-server
/// build one each over the same Core.
public final class VaultService: Sendable {
    public let store: VaultStore
    public let broker: VaultBroker
    public let resolver: LiveVaultCallerResolver
    public let replica: VaultReplicaSync?
    public let kanbanHome: String

    public init(
        kanbanHome: String,
        keys: any VaultKeyProvider,
        machine: String,
        approvals: (any VaultApprovals)?,
        cardTitle: @escaping @Sendable (String) async -> String?,
        cardPrompts: @escaping @Sendable (String) async -> CardPrompts? = { _ in nil },
        cardSessions: @escaping @Sendable () async -> [String: String],
        peers: (@Sendable () async -> [PeerConfig])?
    ) {
        self.kanbanHome = kanbanHome
        let store = VaultStore(directory: VaultStore.defaultDirectory(kanbanHome: kanbanHome), keys: keys)
        self.store = store
        let jev = JevClient(apiKey: { await VaultService.jevKey(store: store) })
        broker = VaultBroker(store: store, jev: jev, approvals: approvals, machine: machine, cardTitle: cardTitle,
                             cardPrompts: cardPrompts)
        resolver = LiveVaultCallerResolver(cardSessions: cardSessions)
        replica = peers.map { VaultReplicaSync(store: store, peers: $0) }
    }

    /// Jev's key is itself a vault secret (`JEV_API_KEY`), used only here.
    static func jevKey(store: VaultStore) async -> String? {
        if let s = try? await store.secret("JEV_API_KEY"), !s.value.isEmpty { return s.value }
        return ProcessInfo.processInfo.environment["JEV_API_KEY"]
    }

    /// Takes a key handed over in `vault/identity.import` (then deletes
    /// the file), and starts the replica sync.
    public func start() async {
        let importPath = VaultStore.defaultDirectory(kanbanHome: kanbanHome) + "/identity.import"
        if let data = FileManager.default.contents(atPath: importPath) {
            do {
                let identity = try Age.Identity(text: String(decoding: data, as: UTF8.self))
                try await store.importIdentity(identity)
                KanbanCodeLog.info("vault", "imported the vault key")
            } catch {
                KanbanCodeLog.warn("vault", "could not import the vault key: \(error)")
            }
            unlink(importPath)
        }
        await broker.restore()
        if let replica {
            Task.detached { await replica.run() }
        }
    }
}

/// Keeps `vault.age` the same on every master: pulls each enabled peer's
/// copy, merges it, and pushes back when the peer is behind.
public actor VaultReplicaSync {
    public let store: VaultStore
    public let peers: @Sendable () async -> [PeerConfig]
    public var interval: TimeInterval = 60
    private var wake: CheckedContinuation<Void, Never>?

    public init(store: VaultStore, peers: @escaping @Sendable () async -> [PeerConfig]) {
        self.store = store
        self.peers = peers
    }

    public func run() async {
        while !Task.isCancelled {
            await syncAll()
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                wake = c
                let seconds = interval
                Task {
                    try? await Task.sleep(for: .seconds(seconds))
                    self.fire()
                }
            }
        }
    }

    /// Something changed here: sync now.
    public func poke() {
        fire()
    }

    private func fire() {
        wake?.resume()
        wake = nil
    }

    public func syncAll() async {
        for peer in await peers() where peer.enabled {
            await sync(with: peer)
        }
    }

    private func sync(with peer: PeerConfig) async {
        guard let url = URL(string: peer.url.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1/vault/replica") else { return }
        var get = URLRequest(url: url, timeoutInterval: 15)
        get.setValue("Bearer \(peer.token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: get)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            var theirsBehind = false
            if status == 200, let body = try? JSONDecoder().decode(VaultReplicaBody.self, from: data),
               let blob = body.blob.flatMap({ Data(base64Encoded: $0) }) {
                let result = try await store.mergeReplica(blob)
                theirsBehind = result.otherIsBehind
                if result.changedHere { KanbanCodeLog.info("vault", "merged the vault of \(peer.name)") }
            } else if status == 200 {
                theirsBehind = await store.encryptedBlob() != nil
            } else {
                return
            }
            guard theirsBehind, let local = await store.encryptedBlob(), await store.isUnlocked else { return }
            var post = URLRequest(url: url, timeoutInterval: 15)
            post.httpMethod = "POST"
            post.setValue("Bearer \(peer.token)", forHTTPHeaderField: "Authorization")
            post.setValue("application/json", forHTTPHeaderField: "Content-Type")
            post.httpBody = try JSONEncoder().encode(VaultReplicaBody(blob: local.base64EncodedString()))
            _ = try await URLSession.shared.data(for: post)
        } catch {
            KanbanCodeLog.debug("vault", "replica sync with \(peer.name) failed: \(error.localizedDescription)")
        }
    }
}

/// Body of `GET|POST /v1/vault/replica`: the encrypted file, base64.
public struct VaultReplicaBody: Codable, Sendable {
    public var blob: String?

    public init(blob: String?) {
        self.blob = blob
    }
}

/// Body of `GET /v1/vault/status`.
public struct VaultStatus: Codable, Sendable {
    public var unlocked: Bool
    public var recipient: String?
    public var secrets: Int
    public var machine: String
    /// Who the master takes the caller for: a card id, "openclaw:<agent>",
    /// or nil when the caller is outside every card session.
    public var caller: String?
}
