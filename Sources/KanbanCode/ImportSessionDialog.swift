import SwiftUI
import KanbanCodeCore

/// File › Import Claude Code Session: takes the id of a session started in
/// another terminal and continues it in Kanban Code.
struct ImportSessionDialog: View {
    @Binding var isPresented: Bool
    /// Imports the session named in the text; returns why it failed, or nil.
    var onImport: (String) async -> String?

    @State private var text = ""
    @State private var error: String?
    @State private var isImporting = false
    @FocusState private var fieldFocused: Bool

    var body: some View { usageTrackedBody.trackUsage("view", "ImportSessionDialog") }

    private var sessionId: String? { MasterEngine.claudeSessionId(in: text) }

    @ViewBuilder private var usageTrackedBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import Claude Code Session")
                .font(.app(.title3))
                .fontWeight(.semibold)

            TextField("Session id, e.g. 854054b6-24ff-45e2-bdb9-8feb1f70caf1", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.app(.body, design: .monospaced))
                .focused($fieldFocused)
                .onSubmit(submit)
                .onChange(of: text) { error = nil }

            Text("The id from `claude --resume <id>`, or the transcript's path. A session still open in a terminal continues here once you quit it there.")
                .font(.app(.caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.app(.caption))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                if isImporting {
                    ProgressView().controlSize(.small)
                }
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Import", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(sessionId == nil || isImporting)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { fieldFocused = true }
    }

    private func submit() {
        guard sessionId != nil, !isImporting else { return }
        isImporting = true
        Task {
            let failure = await onImport(text)
            isImporting = false
            if let failure {
                error = failure
            } else {
                isPresented = false
            }
        }
    }
}
