import SwiftUI
import KanbanCodeCore

// MARK: - Boxd machines (toolbar pill)

extension ContentView {
    /// One pill for every boxd machine the app knows: how many run, how
    /// many are stopped, with a popover to stop or destroy each one.
    @ViewBuilder
    var boxdStatusView: some View {
        let states = store.state.remoteMachineStates
        let connected = states.values.filter(\.isConnected).count
        let paused = states.values.filter(\.isPaused).count
        Button { showBoxdPopover.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: connected > 0 ? "cloud.fill" : "cloud")
                    .foregroundStyle(connected > 0 ? Color.teal : Color.secondary)
                // The count belongs to the board, not to the card on screen.
                // Without it the icon alone reads as "this card is remote".
                Text(isExpandedDetail
                     ? "\(max(connected, states.count))"
                     : boxdPillLabel(connected: connected, paused: paused, total: states.count))
                    .font(.app(.headline))
                    .lineLimit(1)
            }
            .padding(.horizontal, isExpandedDetail ? 12 : 8)
        }
        .buttonStyle(.plain)
        .help("Machines of the whole board: \(boxdPillLabel(connected: connected, paused: paused, total: states.count))")
        .popover(isPresented: $showBoxdPopover) {
            boxdStatusPopover
        }
    }

    private func boxdPillLabel(connected: Int, paused: Int, total: Int) -> String {
        if connected > 0 { return connected == 1 ? "1 machine running" : "\(connected) machines running" }
        if paused > 0 { return paused == 1 ? "1 machine stopped" : "\(paused) machines stopped" }
        return total == 1 ? "1 machine" : "\(total) machines"
    }

    /// The card of a machine by name, or how many cards it has when there
    /// is more than one.
    private func boxdCardsLabel(_ cardIds: [String]) -> String {
        if cardIds.count == 1, let card = store.state.cards.first(where: { $0.id == cardIds[0] }) {
            return card.displayTitle
        }
        return "\(cardIds.count) card\(cardIds.count == 1 ? "" : "s")"
    }

    @ViewBuilder
    var boxdStatusPopover: some View {
        let states = store.state.remoteMachineStates.sorted { $0.key < $1.key }
        VStack(alignment: .leading, spacing: 10) {
            Text("Boxd machines of the cards on this board. Machines bill while they run and are stopped when a session stops, after inactivity, and when the app quits.")
                .font(.app(.callout))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(states, id: \.key) { name, state in
                let cardIds = store.state.cardIds(onMachine: name)
                HStack(spacing: 8) {
                    // The name and the state open the card of the machine.
                    Button {
                        guard let cardId = cardIds.first else { return }
                        showBoxdPopover = false
                        store.dispatch(.selectCard(cardId: cardId))
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: state.isConnected ? "cloud.fill" : state.isPaused ? "stop.circle" : "exclamationmark.icloud")
                                .foregroundStyle(state.isConnected ? Color.teal : Color.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(name).font(.app(.callout))
                                Text("\(state.label) · \(boxdCardsLabel(cardIds))")
                                    .font(.app(.caption))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                // ssh can be up while the master on the
                                // machine is not: its cards' terminals stay
                                // empty then.
                                if let outage = store.state.peerOutage(sshMachine: name) {
                                    Label(outage.line, systemImage: "exclamationmark.triangle.fill")
                                        .font(.app(.caption))
                                        .foregroundStyle(.orange)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .help("Cards this machine's Kanban Code runs show their terminals through it, not over ssh.")
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(cardIds.isEmpty)
                    .help(cardIds.isEmpty ? "No card uses this machine" : "Open the card of this machine")
                    Spacer()
                    if state.isConnected, let cardId = cardIds.first {
                        Button("Stop") {
                            store.dispatch(.stopRemoteMachine(cardId: cardId, reason: .manual))
                        }
                        .controlSize(.small)
                    }
                    if !state.isConnected, let cardId = cardIds.first {
                        Button("Destroy", role: .destructive) {
                            showBoxdPopover = false
                            presentDialog(.confirmDestroyMachine(cardId: cardId))
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 380)
    }
}
