import SwiftUI
import AppKit
import KanbanCodeCore

/// Panel that answers the Escape key. A sheet without a close button drops the
/// key before it reaches the Cancel button, so the quit sheet needs its own
/// handler to stay dismissible from the keyboard.
final class EscapeCancellingPanel: NSPanel {
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
            return
        }
        super.keyDown(with: event)
    }
}

/// Shown while the app kills the remote sessions and stops their machines.
struct PausingMachinesView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("Stopping boxd machines…")
                .font(.app(.headline))
            Text("The sessions were killed; the machines are stopped, disk only.")
                .font(.app(.caption))
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 360, height: 140)
    }
}

struct QuitConfirmationSession: Identifiable {
    let session: TmuxSession
    let cardTitle: String?
    /// The boxd machine of the session, nil for a session on this Mac.
    let machineName: String?

    var id: String { session.name }
}

struct QuitConfirmationView: View {
    let sessions: [QuitConfirmationSession]
    let onCancel: () -> Void
    let onQuit: (Bool) -> Void

    @State private var killManagedSessions: Bool

    init(
        sessions: [QuitConfirmationSession],
        killManagedSessions: Bool,
        onCancel: @escaping () -> Void,
        onQuit: @escaping (Bool) -> Void
    ) {
        self.sessions = sessions
        self.onCancel = onCancel
        self.onQuit = onQuit
        _killManagedSessions = State(initialValue: killManagedSessions)
    }

    var body: some View { usageTrackedBody.trackUsage("view", "QuitConfirmationView") }

    @ViewBuilder private var usageTrackedBody: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Image(systemName: "terminal")
                    .font(.app(.largeTitle))
                    .foregroundStyle(.secondary)
                Text("Quit Kanban?")
                    .font(.app(.headline))
                Text("You have \(sessions.count) managed tmux session\(sessions.count == 1 ? "" : "s") running.")
                    .font(.app(.subheadline))
                    .foregroundStyle(.secondary)
                if sessions.contains(where: { $0.machineName != nil }) {
                    Text("Sessions on a machine keep running unless killed; killing them stops their machine.")
                        .font(.app(.caption))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.top, 20)
            .padding(.bottom, 12)

            Table(sessions) {
                TableColumn("") { row in
                    Circle()
                        .fill(row.session.attached ? .green : .gray)
                        .frame(width: 8, height: 8)
                }
                .width(16)

                TableColumn("Session") { row in
                    HStack(spacing: 4) {
                        Text(row.session.name)
                            .lineLimit(1)
                        if let machine = row.machineName {
                            Image(systemName: "cloud")
                                .font(.app(.caption))
                                .foregroundStyle(.secondary)
                                .help("Runs on \(machine)")
                        }
                    }
                }

                TableColumn("Card") { row in
                    if let cardTitle = row.cardTitle {
                        Text(cardTitle)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                TableColumn("Path") { row in
                    Text(abbreviateHomePath(row.session.path))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxHeight: .infinity)

            Divider()

            HStack {
                Toggle("Kill managed sessions on quit", isOn: $killManagedSessions)
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Quit Kanban") {
                    onQuit(killManagedSessions)
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 520, height: 380)
    }

    private func abbreviateHomePath(_ path: String) -> String {
        let home = NSHomeDirectory()
        guard path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
