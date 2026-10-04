import Foundation
import Testing
@testable import KanbanCodeCore
import KanbanCodeRemoteKit

private final class PeerScript: @unchecked Sendable {
    let lock = NSLock()
    /// What the peer answers by hash; a missing hash is "not mine".
    var cards: [String: VaultPeerCard] = [:]
    var reachable = true
    var asked: [String] = []
    var time = Date(timeIntervalSince1970: 1_800_000_000)

    func answer(_ hash: String) -> VaultPeerCard?? {
        lock.withLock {
            asked.append(hash)
            guard reachable else { return nil }
            return .some(cards[hash])
        }
    }
    var count: Int { lock.withLock { asked.count } }
    func advance(_ seconds: TimeInterval) { lock.withLock { time += seconds } }
    var now: Date { lock.withLock { time } }
}

private let mac = PeerConfig(name: "Studio", url: "http://100.0.0.1:7780", token: "peer-token")
private let studioCard = VaultPeerCard(cardId: "card_mac", title: "Deploy the docs site", machine: "Studio")

private func verifier(_ script: PeerScript, peers: [PeerConfig] = [mac]) -> VaultPeerTokenVerifier {
    VaultPeerTokenVerifier(peers: { peers }, ask: { _, hash in script.answer(hash) }, now: { script.now })
}

private func tempDir() -> String {
    let path = NSTemporaryDirectory() + "vault-peer-\(UUID().uuidString.prefix(8))"
    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

@Suite("Vault session tokens across masters")
struct VaultPeerTokenTests {
    @Test func aTokenItsMasterKnowsMakesTheCallerThatCard() async {
        let script = PeerScript()
        script.cards[VaultCardTokens.hash("kct_mac")] = studioCard
        let v = verifier(script)
        #expect(await v.verify(token: "kct_mac") == studioCard)
        // The hash goes to the peer, never the token.
        #expect(script.asked == [VaultCardTokens.hash("kct_mac")])
        #expect(!script.asked.contains("kct_mac"))
    }

    @Test func aTokenNoMasterKnowsIsNotACard() async {
        let script = PeerScript()
        let v = verifier(script)
        #expect(await v.verify(token: "kct_forged") == nil)
        // The no is kept for a moment, then asked again.
        #expect(await v.verify(token: "kct_forged") == nil)
        #expect(script.count == 1)
        script.advance(20)
        #expect(await v.verify(token: "kct_forged") == nil)
        #expect(script.count == 2)
    }

    @Test func aPeerThatDoesNotAnswerLeavesTheCallerUnverifiedAndIsAskedAgain() async {
        let script = PeerScript()
        script.cards[VaultCardTokens.hash("kct_mac")] = studioCard
        script.reachable = false
        let v = verifier(script)
        #expect(await v.verify(token: "kct_mac") == nil)
        script.reachable = true
        #expect(await v.verify(token: "kct_mac") == studioCard)
        #expect(script.count == 2)
    }

    @Test func aYesIsKeptForAMinute() async {
        let script = PeerScript()
        script.cards[VaultCardTokens.hash("kct_mac")] = studioCard
        let v = verifier(script)
        _ = await v.verify(token: "kct_mac")
        script.reachable = false
        script.advance(50)
        #expect(await v.verify(token: "kct_mac") == studioCard)
        #expect(script.count == 1)
        // After that the card's session may be over: ask again.
        script.advance(20)
        #expect(await v.verify(token: "kct_mac") == nil)
        #expect(script.count == 2)
    }

    @Test func disabledPeersAreNotAsked() async {
        let script = PeerScript()
        var off = mac
        off.enabled = false
        #expect(await verifier(script, peers: [off]).verify(token: "kct_mac") == nil)
        #expect(script.count == 0)
    }

    @Test func theIssuingMasterAnswersByHashOnlyForLiveCards() async {
        let tokens = VaultCardTokens(directory: tempDir())
        let token = await tokens.issue(cardId: "card_mac")
        let hash = VaultCardTokens.hash(token)
        #expect(await tokens.verify(hash: hash, liveCards: ["card_mac"]) == "card_mac")
        #expect(await tokens.verify(hash: hash, liveCards: []) == nil)
        #expect(await tokens.verify(hash: VaultCardTokens.hash("kct_other"), liveCards: ["card_mac"]) == nil)
        // The token itself is not a hash on file.
        #expect(await tokens.verify(hash: token, liveCards: ["card_mac"]) == nil)
    }

    @Test func theResolverPlacesACallerWithAPeerToken() async {
        let script = PeerScript()
        script.cards[VaultCardTokens.hash("kct_mac")] = studioCard
        let resolver = LiveVaultCallerResolver(rush: nil, tokens: VaultCardTokens(directory: tempDir()),
                                               peerTokens: verifier(script), cardSessions: { [:] })
        // No local process on that port: only the token can place the caller.
        let caller = await resolver.resolve(clientPort: 1, serverPort: 2, claimedCardId: "card_mac", sessionId: nil, cardToken: "kct_mac")
        #expect(caller.cardId == "card_mac" && caller.insideCard)
        #expect(caller.byToken == true && caller.verifiedByPeer == "Studio" && caller.peerTitle == "Deploy the docs site")
        #expect(caller.tokenNote == "by session token, verified by Studio")

        let stranger = await resolver.resolve(clientPort: 1, serverPort: 2, claimedCardId: "card_mac", sessionId: nil, cardToken: "kct_forged")
        #expect(stranger.cardId == nil && !stranger.insideCard && stranger.verifiedByPeer == nil)
        let none = await resolver.resolve(clientPort: 1, serverPort: 2, claimedCardId: "card_mac", sessionId: nil, cardToken: nil)
        #expect(none.cardId == nil)
    }

    @Test func aCardFromAPeerIsNamedWithHowItGotHere() {
        let overSsh = VaultCaller(cardId: "card_mac", ancestry: ["node", "bash", "sshd-session", "sshd"], byToken: true,
                                  verifiedByPeer: "Studio", peerTitle: "Deploy the docs site")
        #expect(overSsh.peerOrigin == "via ssh from Studio")
        let other = VaultCaller(cardId: "card_mac", ancestry: ["node", "bash"], byToken: true, verifiedByPeer: "Studio")
        #expect(other.peerOrigin == "from Studio")
        #expect(VaultCaller(cardId: "card_1", ancestry: ["kv", "sshd"]).peerOrigin == nil)
        #expect(VaultCaller(cardId: "card_1", byToken: true).tokenNote == "by session token")
    }

    @Test func aPeerCardGetsNoOwnProjectShortcutAndIsShownAndAuditedAsSuch() async throws {
        let store = VaultStore(directory: tempDir(), keys: MemoryVaultKeyProvider())
        try await store.ensureIdentity()
        try await store.upsert(VaultSecret(name: "shop/dev/DATABASE_URL", value: "db", tier: .judged))
        let approvals = RecordingApprovals()
        // No card of that id on this master: the title is the peer's.
        let broker = VaultBroker(store: store, jev: nil, approvals: approvals, machine: "box")
        await broker.configure(projectsOf: { _ in ["shop"] })
        let request = VaultReleaseRequest(mode: "run", names: ["shop/dev/DATABASE_URL"], command: "psql",
                                          reason: "Check the migration ran on the dev database")

        let local = VaultCaller(cardId: "card_local", ancestry: ["kv", "zsh"], cwd: "/root/Projects/shop")
        #expect(VaultPolicy.isOwnProjectDev(try #require(try await store.secret("shop/dev/DATABASE_URL")), caller: local, callerProjects: ["shop"]))
        #expect(await broker.release(request, caller: local).status == .granted)

        let peer = VaultCaller(cardId: "card_mac", ancestry: ["kv", "bash", "sshd"], cwd: "/root/Projects/shop", byToken: true,
                               verifiedByPeer: "Studio", peerTitle: "Deploy the docs site")
        #expect(!VaultPolicy.isOwnProjectDev(try #require(try await store.secret("shop/dev/DATABASE_URL")), caller: peer, callerProjects: ["shop"]))
        // Judged, and Jev is not reachable here: the human is asked.
        let asked = await broker.release(request, caller: peer)
        #expect(asked.status == .pending)
        let attention = try #require(approvals.raised.last)
        #expect(attention.title.hasPrefix("Deploy the docs site wants to use"))
        #expect(attention.vault?.rows().first == .init("Card", "Deploy the docs site, via ssh from Studio"))
        let line = try #require(await store.log(limit: 5).first { $0.outcome == .asked })
        #expect(line.cardId == "card_mac")
        #expect(line.detail?.hasSuffix("by session token, verified by Studio") == true)
    }

    @Test func aCardsVariablesFromAnSshLoginDoNotReachLaterSessions() {
        let env = ["KANBAN_CARD_ID": "card_mac", "KANBAN_CARD_TOKEN": "kct_mac", "PATH": "/usr/bin"]
        #expect(InheritedSessionEnvironment.inherited(in: env) == ["KANBAN_CARD_ID", "KANBAN_CARD_TOKEN"])
        let unset = InheritedSessionEnvironment.tmuxUnsetArguments(serverTMPDIR: nil).joined(separator: " ")
        #expect(unset.contains("set-environment -g -u KANBAN_CARD_ID"))
        #expect(unset.contains("set-environment -g -u KANBAN_CARD_TOKEN"))
    }
}

private final class RecordingApprovals: VaultApprovals, @unchecked Sendable {
    let lock = NSLock()
    var items: [AttentionRequest] = []
    var raised: [AttentionRequest] { lock.withLock { items } }
    func raise(_ request: AttentionRequest) async { lock.withLock { items.append(request) } }
    func resolution(of id: String) async -> (resolution: String?, by: String)? { nil }
    func close(id: String, resolution: String, by: String) async {}
}
