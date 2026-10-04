import SwiftUI
import KanbanCodeCore

/// Settings > Remote Control > Peers: the other masters (an always-on box,
/// another Mac) this Mac syncs cards with. Each peer is its Remote Control
/// URL and a device token that peer issued for this Mac
/// (`kanban-code-server pair <name>` on a box).
struct PeersSettingsSection: View {
    @State private var peers: [PeerConfig] = []
    @State private var name = ""
    @State private var url = ""
    @State private var token = ""
    @State private var terminalToken = ""
    @State private var machineName = ""
    private let settingsStore = SettingsStore()

    var body: some View {
        Section {
            if peers.isEmpty {
                Text("No peers.").foregroundStyle(.secondary)
            }
            ForEach(peers) { peer in
                let status = AppComposition.shared.store.state.peerStatuses[peer.id]
                HStack {
                    Circle()
                        .fill(!peer.enabled ? Color.secondary : (status?.online == true ? Color.green : Color.red))
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(status?.machine?.name ?? peer.name)
                        Text(detail(peer, status))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let ssh = sshMachineName(of: status) {
                            Text("Also the ssh machine \(ssh) in Settings > Remote: one machine, cards run there are owned by this master.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { peer.enabled },
                        set: { value in update(peer.id) { $0.enabled = value } }
                    ))
                    .labelsHidden()
                    Button("Remove", role: .destructive) { remove(peer.id) }
                        .controlSize(.small)
                }
            }
            HStack {
                TextField("Name", text: $name).frame(width: 120)
                TextField("http://100.x.y.z:7780", text: $url)
                SecureField("Token", text: $token).frame(width: 130)
                SecureField("Terminal token", text: $terminalToken).frame(width: 130)
                Button("Add") { add() }
                    .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty || token.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack {
                Text("This Mac is")
                TextField("Machine name", text: $machineName)
                    .onSubmit { renameMachine() }
                Text(AppComposition.shared.store.state.localMachineId)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        } header: {
            Text("Peers")
        } footer: {
            Text("Other masters this Mac syncs cards with. On a box, `kanban-code-server pair <name> --scope peer` prints a token for this Mac; give that box a Peer master token from Add Device here so it syncs back. A peer token cannot open terminals: to show the box's card terminals here, add the token of `kanban-code-server pair <name> --scope terminal` as the terminal token.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task {
            machineName = AppComposition.shared.store.state.localMachineName
            await load()
            // Online state changes behind the view.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                await load()
            }
        }
    }

    /// The ssh machine that is this peer's host, when there is one.
    private func sshMachineName(of status: PeerStatus?) -> String? {
        guard let id = status?.machine?.id else { return nil }
        return AppComposition.shared.store.state.machineChoices
            .first { $0.master?.id == id && $0.sshMachine != nil }?.name
    }

    private func detail(_ peer: PeerConfig, _ status: PeerStatus?) -> String {
        var parts = [peer.url]
        if !peer.enabled {
            parts.append("off")
        } else if status?.online == true {
            parts.append("online")
        } else if let error = status?.lastError {
            parts.append("offline: \(error.prefix(80))")
        } else {
            parts.append("offline")
        }
        if let seen = status?.lastSeen {
            parts.append("seen " + RelativeDateTimeFormatter().localizedString(for: seen, relativeTo: Date()))
        }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        let current = (try? await settingsStore.read())?.peers ?? []
        if current != peers { peers = current }
    }

    private func save(_ mutate: @escaping (inout [PeerConfig]) -> Void) {
        Task {
            var settings = (try? await settingsStore.read()) ?? Settings()
            mutate(&settings.peers)
            try? await settingsStore.write(settings)
            peers = settings.peers
            NotificationCenter.default.post(name: .kanbanCodeSettingsChanged, object: nil)
        }
    }

    private func add() {
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmedURL.contains("://") ? trimmedURL : "http://\(trimmedURL)"
        let peer = PeerConfig(
            name: name.trimmingCharacters(in: .whitespaces).isEmpty ? normalized : name.trimmingCharacters(in: .whitespaces),
            url: normalized,
            token: token.trimmingCharacters(in: .whitespacesAndNewlines),
            terminalToken: terminalToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : terminalToken.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        save { $0.append(peer) }
        name = ""
        url = ""
        token = ""
        terminalToken = ""
    }

    private func update(_ id: String, _ change: @escaping (inout PeerConfig) -> Void) {
        save { peers in
            if let index = peers.firstIndex(where: { $0.id == id }) { change(&peers[index]) }
        }
    }

    private func remove(_ id: String) {
        save { $0.removeAll { $0.id == id } }
    }

    private func renameMachine() {
        let trimmed = machineName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let identity = try? MachineIdentityStore().rename(to: trimmed) else { return }
        AppComposition.shared.store.dispatch(.localMachineLoaded(identity))
    }
}
