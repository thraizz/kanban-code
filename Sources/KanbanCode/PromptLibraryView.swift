import SwiftUI
import AppKit
import KanbanCodeCore

/// What the left sidebar shows in expanded mode.
enum SidebarMode: String, CaseIterable {
    case sessions
    case prompts

    var label: String {
        switch self {
        case .sessions: "Sessions"
        case .prompts: "Prompts"
        }
    }
}

/// Library of reusable prompts. Each preset can spawn a new task through the
/// New Task dialog, prefilled with its text.
struct PromptLibraryView: View {
    /// Opens the New Task dialog prefilled with the preset.
    var onNewTask: (PromptPreset) -> Void

    private let libraryStore = PromptLibraryStore()
    @State private var presets: [PromptPreset] = []
    @State private var selectedId: String?
    @State private var search = ""
    @State private var saveTask: Task<Void, Never>?

    private var filtered: [PromptPreset] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return presets }
        return presets.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.body.localizedCaseInsensitiveContains(query)
        }
    }

    private var selectedIndex: Int? {
        presets.firstIndex(where: { $0.id == selectedId })
    }

    var body: some View { usageTrackedBody.trackUsage("view", "PromptLibraryView") }

    @ViewBuilder private var usageTrackedBody: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if presets.isEmpty {
                emptyState
            } else {
                list
                if let index = selectedIndex {
                    Divider()
                    editor(index: index)
                }
            }
        }
        .task { presets = await libraryStore.load() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            TextField("Search prompts", text: $search)
                .textFieldStyle(.roundedBorder)
                .font(.app(.callout))
            Button { addPreset() } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("New prompt")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "text.book.closed")
                .font(.system(size: 32))
                .foregroundStyle(.quaternary)
            Text("No saved prompts yet")
                .font(.app(.callout))
                .foregroundStyle(.secondary)
            Button("New Prompt") { addPreset() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        List(selection: $selectedId) {
            ForEach(filtered) { preset in
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.displayTitle)
                        .font(.app(.callout))
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text(preset.body)
                        .font(.app(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(.vertical, 2)
                .tag(preset.id)
                .contextMenu {
                    Button("New Task from Prompt") { onNewTask(preset) }
                    Button("Copy Prompt") { copy(preset) }
                    Button("Duplicate") { duplicate(preset) }
                    Divider()
                    Button("Delete", role: .destructive) { delete(preset) }
                }
                .onTapGesture(count: 2) { onNewTask(preset) }
                .simultaneousGesture(TapGesture().onEnded { selectedId = preset.id })
            }
            .onMove { from, to in
                // Reordering only makes sense on the unfiltered list.
                guard search.isEmpty else { return }
                presets.move(fromOffsets: from, toOffset: to)
                scheduleSave()
            }
        }
        .listStyle(.sidebar)
    }

    private func editor(index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Title (optional)", text: Binding(
                get: { presets[safe: index]?.title ?? "" },
                set: { update(index: index) { $0.title = $1 }($0) }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.app(.callout))

            TextEditor(text: Binding(
                get: { presets[safe: index]?.body ?? "" },
                set: { update(index: index) { $0.body = $1 }($0) }
            ))
            .font(.app(.callout))
            .scrollContentBackground(.hidden)
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
            .frame(minHeight: 140, maxHeight: 280)

            HStack {
                Button {
                    if let preset = presets[safe: index] { onNewTask(preset) }
                } label: {
                    Label("New Task", systemImage: "square.and.pencil")
                }
                .buttonStyle(.borderedProminent)
                .disabled((presets[safe: index]?.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button {
                    if let preset = presets[safe: index] { copy(preset) }
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help("Copy prompt")

                Spacer()

                Button(role: .destructive) {
                    if let preset = presets[safe: index] { delete(preset) }
                } label: {
                    Image(systemName: "trash")
                }
                .help("Delete prompt")
            }
        }
        .padding(10)
    }

    // MARK: - Mutations

    private func update(index: Int, _ apply: @escaping (inout PromptPreset, String) -> Void) -> (String) -> Void {
        { value in
            guard presets.indices.contains(index) else { return }
            apply(&presets[index], value)
            presets[index].updatedAt = Date()
            scheduleSave()
        }
    }

    private func addPreset() {
        let preset = PromptPreset(title: "", body: "")
        presets.insert(preset, at: 0)
        search = ""
        selectedId = preset.id
        scheduleSave()
    }

    private func duplicate(_ preset: PromptPreset) {
        guard let index = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        let copy = PromptPreset(title: preset.title.isEmpty ? "" : "\(preset.title) copy", body: preset.body)
        presets.insert(copy, at: index + 1)
        selectedId = copy.id
        scheduleSave()
    }

    private func delete(_ preset: PromptPreset) {
        presets.removeAll { $0.id == preset.id }
        if selectedId == preset.id { selectedId = nil }
        scheduleSave()
    }

    private func copy(_ preset: PromptPreset) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(preset.body, forType: .string)
    }

    /// Debounced so typing in the editor doesn't write the file per keystroke.
    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = presets
        let store = libraryStore
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            do {
                try await store.save(snapshot)
            } catch {
                KanbanCodeLog.warn("prompt-library", "save failed: \(error)")
            }
        }
    }
}
