import SwiftUI
import KanbanCodeRemoteKit

/// A prompt held back because it carries secrets, waiting for Yes or No.
struct PendingSecretOffer {
    var text: String
    var mode: RemotePromptRequest.Mode
    var proposals: [SecretProposal]
    var error: String?
    var isSaving = false
}

/// Saves secrets through the master's vault: a new name is stored at once,
/// anything else is reported back as the reason it was not saved.
enum PhoneVault {
    static func save(_ offer: PendingSecretOffer, client: RemoteClient) async -> SecretDetector.SaveResult {
        let names = (try? await client.vaultSecretNames()) ?? []
        return await SecretDetector.save(offer.proposals, in: offer.text, existingNames: names) { proposal in
            do {
                let r = try await client.addVaultSecret(name: proposal.name, value: proposal.value,
                                                        tier: SecretDetector.pastedTier, rules: SecretDetector.pastedRules)
                switch r.status {
                case "granted": return nil
                case "pending": return "the vault asked for approval (\(r.message))"
                default: return r.message
                }
            } catch {
                return error.localizedDescription
            }
        }
    }
}

/// The offer above the composer: one editable name per secret, Yes / No.
struct VaultSecretOfferCard: View {
    @Binding var offer: PendingSecretOffer
    let onSave: () -> Void
    let onSendAsIs: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(offer.proposals.count == 1 ? "This prompt contains a secret. Save it to the vault?"
                                             : "This prompt contains \(offer.proposals.count) secrets. Save them to the vault?",
                  systemImage: "key.fill")
                .font(.subheadline.weight(.semibold))
            ForEach($offer.proposals) { $proposal in
                VStack(alignment: .leading, spacing: 2) {
                    TextField("Name", text: $proposal.name)
                        .font(.callout.monospaced())
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("vaultSecretName")
                    Text("\(proposal.value.prefix(4))... (\(proposal.value.count) chars)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            if let error = offer.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("Send as is", action: onSendAsIs)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("vaultSendAsIs")
                Spacer()
                Button(action: onSave) {
                    if offer.isSaving { ProgressView() } else { Text("Save and send") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(offer.isSaving)
                .accessibilityIdentifier("vaultSaveAndSend")
            }
        }
        .padding(12)
        .background(Color.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("vaultSecretOffer")
    }
}
