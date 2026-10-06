import SwiftUI
import KanbanCodeCore
import KanbanCodeRemoteKit

/// The caller the Mac app acts as when a composer saves a pasted secret.
private let composerCaller = VaultCaller(ancestry: ["Kanban Code composer"])

/// A prompt held back because it carries secrets, and the offer to save them
/// to the vault before it is sent. Composers own one each; Yes saves every
/// offered secret under its (editable) name and sends the prompt with
/// `{{vault:NAME}}` references, No sends it unchanged.
@MainActor @Observable
final class VaultSecretOffer {
    var proposals: [SecretProposal] = []
    var error: String?
    var isSaving = false
    private var heldText = ""
    private var send: ((String) -> Void)?

    var isActive: Bool { send != nil }

    private var vault: VaultService { AppComposition.shared.vault }

    /// Sends `text` at once when it holds no secret; otherwise holds it and offers.
    func submit(_ text: String, send: @escaping (String) -> Void) {
        guard !isActive else { return }
        guard !SecretDetector.find(in: text).isEmpty else { send(text); return }
        heldText = text
        self.send = send
        error = nil
        Task {
            let names = await existingNames()
            proposals = SecretDetector.proposals(in: text, existingNames: names)
            if proposals.isEmpty { decline() }
        }
    }

    /// No: the prompt goes out as typed.
    func decline() {
        guard let send else { return }
        let text = heldText
        reset()
        send(text)
    }

    /// Yes: every offered secret is added under a name the vault does not
    /// hold yet, then the prompt goes out with references in their place.
    func accept() {
        guard let send, !isSaving, !proposals.isEmpty else { return }
        isSaving = true
        error = nil
        let offered = proposals
        let text = heldText
        Task {
            let result = await SecretDetector.save(offered, in: text, existingNames: await existingNames()) { proposal in
                let request = VaultAddRequest(name: proposal.name, value: proposal.value,
                                              tier: VaultTier(rawValue: SecretDetector.pastedTier),
                                              rules: SecretDetector.pastedRules)
                let response = await vault.broker.add(request, caller: composerCaller, trusted: false)
                return response.status == .granted ? nil : response.message
            }
            if let error = result.error {
                // Secrets already saved stay referenced, the rest stay offered.
                heldText = result.text
                proposals = result.remaining
                self.error = error
                isSaving = false
                return
            }
            reset()
            send(result.text)
        }
    }

    private func reset() {
        proposals = []
        heldText = ""
        send = nil
        error = nil
        isSaving = false
    }

    private func existingNames() async -> Set<String> {
        Set(((try? await vault.store.list()) ?? []).map(\.name))
    }
}

/// The offer shown above a composer: one editable name per secret, Yes / No.
/// Return or y saves, Esc or n sends unchanged.
struct VaultSecretOfferBar: View {
    @Bindable var offer: VaultSecretOffer
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(offer.proposals.count == 1 ? "This prompt contains a secret. Save it to the vault?" : "This prompt contains \(offer.proposals.count) secrets. Save them to the vault?")
                .font(.app(.callout))
                .fontWeight(.semibold)
            ForEach($offer.proposals) { $proposal in
                HStack(spacing: 8) {
                    Image(systemName: "key.fill").foregroundStyle(.secondary)
                    TextField("Name", text: $proposal.name)
                        .textFieldStyle(.roundedBorder)
                        .font(.app(.callout).monospaced())
                        .frame(maxWidth: 260)
                        .onSubmit { offer.accept() }
                    Text(Self.masked(proposal.value))
                        .font(.app(.caption).monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if let error = offer.error {
                Text(error).font(.app(.caption)).foregroundStyle(.red)
            }
            HStack {
                Text("Saved as judged secrets; the prompt gets {{vault:NAME}} instead.")
                    .font(.app(.caption))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("No, send as is (n)") { offer.decline() }
                Button("Save and send (y)") { offer.accept() }
                    .buttonStyle(.borderedProminent)
                    .disabled(offer.isSaving)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.yellow.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.yellow.opacity(0.4)))
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(characters: CharacterSet(charactersIn: "yYnN")) { press in
            if press.characters.lowercased() == "y" { offer.accept() } else { offer.decline() }
            return .handled
        }
        .onKeyPress(.return) { offer.accept(); return .handled }
        .onKeyPress(.escape) { offer.decline(); return .handled }
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    /// The first four characters and the length, never the value.
    static func masked(_ value: String) -> String {
        "\(value.prefix(4))... (\(value.count) chars)"
    }
}
