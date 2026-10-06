import SwiftUI
import KanbanCodeRemoteKit

struct NewTaskSheet: View {
    let fleet: FleetModel
    /// The created card and the master that runs it.
    let onCreated: (RemoteCard, BoardModel) -> Void

    @Environment(\.dismiss) private var dismiss
    /// Name of the project last launched in: paths differ between machines.
    @AppStorage("newTask.lastProjectName") private var lastProject = ""
    /// The master the task runs on, by `SavedServer.id`.
    @State private var machineID: UUID?
    @State private var projectPath = ""
    @State private var prompt = ""
    @State private var useWorktree = false
    @State private var worktreeName = ""
    @State private var isLaunching = false
    @State private var error: String?
    @FocusState private var promptFocused: Bool

    /// Online masters with a board, primary first: where a task can start.
    private var machines: [BoardModel] { fleet.onlineMasters.filter { $0.board != nil } }

    /// What the machine picker lists: every master with a board, online or
    /// not. A machine going offline stays in the list, marked, so the menu
    /// never loses its items while it is open (UIKit aborts on a picker
    /// menu left with nothing to select).
    private var pickable: [BoardModel] { fleet.orderedMasters.filter { $0.board != nil } }

    private var board: BoardModel? {
        pickable.first { $0.server.id == machineID } ?? machines.first
    }

    private var projects: [RemoteProject] { board?.board?.projects ?? [] }

    var body: some View {
        NavigationStack {
            Form {
                if fleet.isMulti {
                    Section {
                        Picker("Machine", selection: $machineID) {
                            ForEach(pickable, id: \.server.id) { master in
                                Text(master.isOnline ? master.machineName : "\(master.machineName), offline")
                                    .tag(Optional(master.server.id))
                            }
                        }
                        .accessibilityIdentifier("machinePicker")
                    } footer: {
                        let offline = fleet.masters.filter { !$0.isOnline }.map(\.machineName)
                        if board.map({ !$0.isOnline }) == true {
                            Text("\(board?.machineName ?? "This machine") is offline. Pick another machine or wait for it to come back.")
                        } else if !offline.isEmpty {
                            Text("Offline: \(offline.joined(separator: ", ")).")
                        }
                    }
                }
                Section {
                    if projects.isEmpty {
                        Text("\(board?.machineName ?? "The machine") has no projects yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Project", selection: $projectPath) {
                            ForEach(projects) { project in
                                Text(project.name).tag(project.path)
                            }
                        }
                        .accessibilityIdentifier("projectPicker")
                    }
                }

                Section("Prompt") {
                    TextField("What should the agent do?", text: $prompt, axis: .vertical)
                        .lineLimit(4...12)
                        .focused($promptFocused)
                        .accessibilityIdentifier("taskPrompt")
                }

                Section {
                    Toggle("Own worktree", isOn: $useWorktree.animation())
                        .accessibilityIdentifier("worktreeToggle")
                    if useWorktree {
                        TextField("Name (random if empty)", text: $worktreeName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } footer: {
                    Text("A worktree gives the task its own branch and checkout.")
                }

                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.subheadline)
                    }
                }
            }
            .navigationTitle("New task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isLaunching {
                        ProgressView()
                    } else {
                        Button("Launch") { launch() }
                            .fontWeight(.semibold)
                            .disabled(!canLaunch)
                            .accessibilityIdentifier("launchTask")
                    }
                }
            }
            .onAppear {
                if machineID == nil { machineID = machines.first?.server.id }
                pickProject(named: lastProject)
                promptFocused = true
            }
            .onChange(of: machineID) { old, _ in
                // The same project on the other machine, by name.
                let before = fleet.masters.first { $0.server.id == old }?.board?.projects ?? []
                pickProject(named: before.first { $0.path == projectPath }?.name ?? lastProject)
            }
        }
        .presentationDetents([.large])
    }

    private func pickProject(named name: String) {
        guard !projects.contains(where: { $0.path == projectPath }) else { return }
        projectPath = projects.first { $0.name == name }?.path ?? projects.first?.path ?? ""
    }

    private var canLaunch: Bool {
        board?.isOnline == true && projects.contains(where: { $0.path == projectPath })
            && !projectPath.isEmpty && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func launch() {
        guard let master = board, let client = master.client, canLaunch else { return }
        isLaunching = true
        error = nil
        let request = RemoteTaskRequest(
            project: projectPath,
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            worktree: useWorktree ? worktreeName.trimmingCharacters(in: .whitespaces) : nil,
            human: true
        )
        Task {
            defer { isLaunching = false }
            do {
                let card = try await client.createTask(request)
                lastProject = projects.first { $0.path == projectPath }?.name ?? ""
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                dismiss()
                onCreated(card, master)
            } catch {
                self.error = error.localizedDescription
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }
}

#Preview {
    NewTaskSheet(fleet: FleetModel(preview: [BoardModel(preview: PreviewData.board),
                                             BoardModel(preview: PreviewData.boxBoard, name: "rchaves-platform")])) { _, _ in }
}
