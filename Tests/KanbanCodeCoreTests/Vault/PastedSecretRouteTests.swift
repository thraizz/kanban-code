import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import KanbanCodeRemoteKit
import Testing
@testable import KanbanCodeCore

/// The phone's composer flow against a real server: list names, pick a free
/// one, add the pasted secret, send the prompt with a reference.
@Suite("Pasted secret over the remote vault API", .serialized)
struct PastedSecretRouteTests {
    static let key = "sk-proj-" + "Qm7vT2xLp9Rk4Wn8Zb3Hc6Yd1Fg5Js0Ae" + "_Uq-Vt8Nr2Mx"

    @Test func aPastedKeyIsSavedUnderAFreeNameAndTheStoredOneIsKept() async throws {
        let home = NSTemporaryDirectory() + "vault-paste-\(UUID().uuidString.prefix(8))"
        let vault = VaultService(
            kanbanHome: home, keys: MemoryVaultKeyProvider(), machine: "test", approvals: nil,
            cardTitle: { _ in nil }, cardSessions: { [:] }, peers: nil
        )
        try await vault.store.upsert(VaultSecret(name: "OPENAI_API_KEY", value: "stored-value", tier: .ask))
        let f = try await RemoteServerFixture(vault: vault)
        defer { f.shutdown() }
        let client = RemoteClient(baseURL: URL(string: f.base)!, token: f.fullToken)

        let text = "call the gateway with \(Self.key) and report back"
        let names = try await client.vaultSecretNames()
        #expect(names == ["OPENAI_API_KEY"])
        let offers = SecretDetector.proposals(in: text, existingNames: names)
        #expect(offers.map(\.name) == ["OPENAI_API_KEY_2"])

        let result = await SecretDetector.save(offers, in: text, existingNames: names) { p in
            let r = try? await client.addVaultSecret(name: p.name, value: p.value,
                                                     tier: SecretDetector.pastedTier, rules: SecretDetector.pastedRules)
            return r?.status == "granted" ? nil : (r?.message ?? "no answer")
        }
        #expect(result.error == nil)
        #expect(!result.text.contains(Self.key))
        #expect(result.text.hasPrefix("call the gateway with {{vault:OPENAI_API_KEY_2}} and report back\n\n"))

        let saved = try #require(try await vault.store.secret("OPENAI_API_KEY_2"))
        #expect(saved.value == Self.key)
        #expect(saved.tier == .judged)
        #expect(saved.rules == SecretDetector.pastedRules)
        #expect(try await vault.store.secret("OPENAI_API_KEY")?.value == "stored-value")
    }
}
