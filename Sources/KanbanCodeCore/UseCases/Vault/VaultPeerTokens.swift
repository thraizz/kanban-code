import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A card another master vouches for: the card its session token belongs
/// to, as the master that issued the token answered.
public struct VaultPeerCard: Codable, Sendable, Equatable {
    public var cardId: String
    public var title: String?
    /// Name of the master that runs the card.
    public var machine: String

    public init(cardId: String, title: String? = nil, machine: String) {
        self.cardId = cardId
        self.title = title
        self.machine = machine
    }
}

/// Body of `POST /v1/vault/card-token`: the SHA-256 of a session token,
/// never the token.
public struct VaultCardTokenQuery: Codable, Sendable, Equatable {
    public var hash: String

    public init(hash: String) {
        self.hash = hash
    }
}

/// Asks the paired masters which card a session token belongs to. A card
/// on one master that runs a command on another over ssh carries a token
/// only its own master issued; the master that gets it sends the token's
/// hash to its peers over their authenticated channel.
///
/// A yes is kept for `positiveLifetime`, a no for `negativeLifetime`. A
/// peer that does not answer is neither: the caller stays unverified and
/// the next call asks again.
public actor VaultPeerTokenVerifier {
    /// What one peer says: its card, `.some(nil)` for "not mine", nil when
    /// it could not be reached.
    public typealias Ask = @Sendable (PeerConfig, String) async -> VaultPeerCard??

    private let peers: @Sendable () async -> [PeerConfig]
    private let ask: Ask
    private let now: @Sendable () -> Date
    public var positiveLifetime: TimeInterval = 60
    public var negativeLifetime: TimeInterval = 15
    private var known: [String: (card: VaultPeerCard?, until: Date)] = [:]

    public init(peers: @escaping @Sendable () async -> [PeerConfig], ask: @escaping Ask = VaultPeerTokenVerifier.http,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.peers = peers
        self.ask = ask
        self.now = now
    }

    /// The card of `token` on a peer master, nil when no peer knows it.
    public func verify(token: String) async -> VaultPeerCard? {
        await verify(hash: VaultCardTokens.hash(token))
    }

    func verify(hash: String) async -> VaultPeerCard? {
        let at = now()
        known = known.filter { $0.value.until > at }
        if let cached = known[hash] { return cached.card }
        var everyPeerAnswered = true
        for peer in await peers() where peer.enabled {
            switch await ask(peer, hash) {
            case .some(.some(let card)):
                known[hash] = (card, at.addingTimeInterval(positiveLifetime))
                return card
            case .some(.none):
                continue
            case .none:
                everyPeerAnswered = false
            }
        }
        if everyPeerAnswered { known[hash] = (nil, at.addingTimeInterval(negativeLifetime)) }
        return nil
    }

    /// `POST /v1/vault/card-token` on the peer, with its device token.
    public static let http: Ask = { peer, hash in
        guard let url = URL(string: peer.url.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1/vault/card-token") else {
            return nil
        }
        var request = URLRequest(url: url, timeoutInterval: 4)
        request.httpMethod = "POST"
        request.setValue("Bearer \(peer.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(VaultCardTokenQuery(hash: hash))
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { return nil }
        if status == 200, let card = try? JSONDecoder().decode(VaultPeerCard.self, from: data) { return .some(card) }
        // 404: the peer knows no such token. Anything else is no answer.
        return status == 404 ? .some(nil) : nil
    }
}
