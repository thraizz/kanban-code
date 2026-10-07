import SwiftUI
import KanbanCodeCore

struct NewTaskDialog: View {
    @Binding var isPresented: Bool
    var projects: [Project] = []
    var defaultProjectPath: String?
    var globalRemoteSettings: RemoteSettings?
    /// Remote backend of this launch. When set it decides the remote row, and
    /// `globalRemoteSettings` is ignored.
    var remoteOptions: RemoteLaunchOptions?
    var enabledAssistants: [CodingAssistant] = CodingAssistant.allCases
    /// (prompt, projectPath, title, startImmediately, images, assistant, apiServiceId, model, variant)
    var onCreate: (String, String?, String?, Bool, [ImageAttachment], CodingAssistant, String?, String?, String?) -> Void = { _, _, _, _, _, _, _, _, _ in }
    /// (prompt, projectPath, title, createWorktree, runRemotely, skipPermissions, commandOverride, images, assistant, apiServiceId, model, variant) — creates and launches directly (skips LaunchConfirmation)
    var onCreateAndLaunch: (String, String?, String?, Bool, Bool, Bool, String?, [ImageAttachment], CodingAssistant, String?, String?, String?) -> Void = { _, _, _, _, _, _, _, _, _, _, _, _ in }
    /// Boxd machine the user picked. Called just before `onCreateAndLaunch`
    /// when the launch runs on boxd.
    var onMachineChoice: (BoxdMachineChoice) -> Void = { _ in }

    private let settingsStore = SettingsStore()
    @State private var settings = Settings()
    @State private var apiServices: [APIService] = []
    @State private var defaultAPIServiceIds: [String: String] = [:]
    @State private var selectedServiceId: String? = nil
    @State private var openCodeModels: [String] = []
    @State private var modelSearch = ""
    @State private var selectedModel = ""
    @State private var customModel = ""
    @State private var selectedVariant = ""
    @State private var customVariant = ""
    @AppStorage("selectedAssistant") private var selectedAssistantRaw: String = CodingAssistant.claude.rawValue
    private var selectedAssistant: CodingAssistant {
        get { CodingAssistant(rawValue: selectedAssistantRaw) ?? .claude }
        nonmutating set { selectedAssistantRaw = newValue.rawValue }
    }
    @State private var prompt = ""
    @FocusState private var titleFocused: Bool
    @State private var images: [ImageAttachment] = []
    @State private var title = ""
    @State private var selectedProjectPath: String = ""
    @State private var customPath = ""
    @State private var command = ""
    @State private var commandEdited = false
    @State private var worktreeBranch = ""
    @AppStorage("startTaskImmediately") private var startImmediately = true
    @State private var createWorktree = true
    @State private var runRemotely = true
    @State private var machineChoice: BoxdMachineChoice = .newMachine
    @AppStorage("dangerouslySkipPermissions") private var dangerouslySkipPermissions = true
    @AppStorage("lastSelectedProjectPath") private var lastSelectedProjectPath = ""

    private static let customPathSentinel = "__custom__"
    private static let customModelSentinel = "__custom_model__"
    private static let customVariantSentinel = "__custom_variant__"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Task")
                .font(.app(.title3))
                .fontWeight(.semibold)

            // Title (optional)
            TextField("Title (optional)", text: $title)
                .textFieldStyle(.roundedBorder)
                .font(.app(.callout))
                .focused($titleFocused)

            // Prompt
            PromptSection(
                text: $prompt,
                images: $images,
                placeholder: "Describe what you want \(selectedAssistant.displayName) to do...",
                maxHeight: 180,
                onSubmit: submitForm,
                onEscape: { isPresented = false }
            )

            // Project picker
            if projects.isEmpty {
                TextField("Project path (optional)", text: $customPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.app(.caption))
            } else {
                Picker("Project", selection: $selectedProjectPath) {
                    ForEach(projects) { project in
                        Text(project.name).tag(project.path)
                    }
                    Divider()
                    Text("Custom path...").tag(Self.customPathSentinel)
                }

                if selectedProjectPath == Self.customPathSentinel {
                    TextField("Project path", text: $customPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.app(.caption))
                }
            }

            // Assistant picker (when multiple enabled)
            if enabledAssistants.count > 1 {
                Picker("Assistant", selection: $selectedAssistantRaw) {
                    ForEach(enabledAssistants, id: \.self) { assistant in
                        Text(assistant.displayName).tag(assistant.rawValue)
                    }
                }
                .onChange(of: selectedAssistantRaw) {
                    selectedServiceId = defaultAPIServiceIds[selectedAssistant.rawValue]
                }
            }

            // API Service picker (when services exist for this assistant)
            let servicesForAssistant = apiServices.filter { $0.assistant == selectedAssistant }
            if !servicesForAssistant.isEmpty {
                Picker("API Service", selection: $selectedServiceId) {
                    Text("Default").tag(String?.none)
                    ForEach(servicesForAssistant) { service in
                        Text(service.name).tag(String?.some(service.id))
                    }
                }
                .onChange(of: selectedServiceId) {
                    if !commandEdited { command = commandPreview }
                }
            }

            modelSelectionSection

            // Start immediately toggle
            Toggle("Start immediately", isOn: $startImmediately)
                .font(.app(.callout))

            // Launch options (shown when "Start immediately" is checked)
            if startImmediately {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Create worktree", isOn: (isGitRepo && selectedAssistant.supportsWorktree) ? $createWorktree : .constant(false))
                        .font(.app(.callout))
                        .disabled(!isGitRepo || !selectedAssistant.supportsWorktree)
                    if !isGitRepo {
                        Label("Not a git repository", systemImage: "info.circle")
                            .font(.app(.caption2))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 20)
                    } else if !selectedAssistant.supportsWorktree {
                        Label("\(selectedAssistant.displayName) doesn't support worktrees", systemImage: "info.circle")
                            .font(.app(.caption2))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 20)
                    }
                    if createWorktree && isGitRepo {
                        HStack {
                            Text("Branch name")
                                .font(.app(.callout))
                                .foregroundStyle(.secondary)
                            TextField("", text: $worktreeBranch, prompt: Text("Leave empty for a random name"))
                                .textFieldStyle(.roundedBorder)
                                .font(.app(.callout))
                        }
                        .padding(.leading, 20)
                    }

                    remoteSection

                    Toggle("Dangerously skip permissions", isOn: $dangerouslySkipPermissions)
                        .font(.app(.callout))
                }

                // Editable command
                VStack(alignment: .leading, spacing: 4) {
                    Text("Command")
                        .font(.app(.caption))
                        .foregroundStyle(.secondary)
                    if runsOnBoxd {
                        Text("on machine \(selectedMachineLabel)")
                            .font(.app(.caption2))
                            .foregroundStyle(.secondary)
                        if createWorktree && isGitRepo && selectedAssistant.supportsWorktree {
                            Text("The worktree is created on the machine and on this Mac, so the command has no --worktree flag.")
                                .font(.app(.caption2))
                                .foregroundStyle(.secondary)
                        }
                    }
                    CommandTextEditor(text: $command, onSubmit: submitForm, onEscape: { isPresented = false })
                        .font(.app(.caption).monospaced())
                        .frame(minHeight: 36, maxHeight: 80)
                        .padding(4)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                        .onChange(of: command) {
                            if command != commandPreview {
                                commandEdited = true
                            }
                        }
                }
            }

            // Buttons
            HStack {
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button(startImmediately ? "Create & Start" : "Create", action: submitForm)
                .keyboardShortcut(.defaultAction)
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 450)
        .onAppear {
            if let defaultPath = defaultProjectPath,
               projects.contains(where: { $0.path == defaultPath }) {
                selectedProjectPath = defaultPath
            } else if !lastSelectedProjectPath.isEmpty,
               projects.contains(where: { $0.path == lastSelectedProjectPath }) {
                selectedProjectPath = lastSelectedProjectPath
            } else if let first = projects.first {
                selectedProjectPath = first.path
            }
            // Ensure selected assistant is enabled; fall back to first enabled
            if !enabledAssistants.contains(selectedAssistant),
               let first = enabledAssistants.first {
                selectedAssistant = first
            }
            applyProjectDefaults()
            command = commandPreview
            titleFocused = true
        }
        .task {
            await reloadServices()
            await reloadOpenCodeModels()
        }
        .onReceive(NotificationCenter.default.publisher(for: .kanbanCodeSettingsChanged)) { _ in
            Task {
                await reloadServices()
                await reloadOpenCodeModels()
            }
        }
        .onChange(of: createWorktree) {
            if let path = resolvedProjectPath {
                UserDefaults.standard.set(createWorktree, forKey: "createWorktree_\(path)")
            }
        }
        .onChange(of: runRemotely) {
            rememberRunRemotely()
        }
        .onChange(of: selectedProjectPath) {
            applyProjectDefaults()
            if selectedAssistant == .opencode { Task { await reloadOpenCodeModels() } }
        }
        .onChange(of: selectedAssistantRaw) {
            // Reset to default service for the newly selected assistant
            selectedServiceId = defaultAPIServiceIds[selectedAssistant.rawValue]
            selectedModel = ""
            modelSearch = ""
            customModel = ""
            selectedVariant = ""
            customVariant = ""
            Task { await reloadOpenCodeModels() }
        }
        .onChange(of: commandPreview) {
            if !commandEdited { command = commandPreview }
        }
    }

    // MARK: - Remote row

    @ViewBuilder
    private var modelSelectionSection: some View {
        if supportsModelSelection {
            VStack(alignment: .leading, spacing: 6) {
                Picker("Model", selection: $selectedModel) {
                    Text("Default").tag("")
                    ForEach(filteredModelOptions, id: \.self) { model in
                        Text(model).tag(model)
                    }
                    Divider()
                    Text("Custom…").tag(Self.customModelSentinel)
                }
                .pickerStyle(.menu)

                if selectedAssistant == .opencode && openCodeModels.count > 20 {
                    TextField("Filter models", text: $modelSearch)
                        .textFieldStyle(.roundedBorder)
                        .font(.app(.caption))
                        .padding(.leading, 20)
                }

                if selectedModel == Self.customModelSentinel {
                    TextField(
                        selectedAssistant == .opencode ? "provider/model" : "Model alias or ID",
                        text: $customModel
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.app(.callout))
                    .padding(.leading, 20)
                }

                Picker(selectedAssistant == .claude ? "Effort" : "Variant", selection: $selectedVariant) {
                    Text("Default").tag("")
                    ForEach(variantOptions, id: \.self) { variant in
                        Text(variant.capitalized).tag(variant)
                    }
                    Divider()
                    Text("Custom…").tag(Self.customVariantSentinel)
                }
                .pickerStyle(.menu)

                if selectedVariant == Self.customVariantSentinel {
                    TextField(
                        selectedAssistant == .claude ? "Effort level" : "Variant name",
                        text: $customVariant
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.app(.callout))
                    .padding(.leading, 20)
                }
            }
        }
    }

    @ViewBuilder
    private var remoteSection: some View {
        if remoteMode.runsOnMachines, canRunRemotely, let remoteOptions {
            RunTargetPicker(remote: remoteOptions, runRemotely: $runRemotely, machineChoice: $machineChoice)
        } else {
            Toggle(remoteToggleLabel, isOn: canRunRemotely ? $runRemotely : .constant(false))
                .font(.app(.callout))
                .disabled(!canRunRemotely)
        }

        if let hint = remoteHint {
            Label(hint, systemImage: "info.circle")
                .font(.app(.caption2))
                .foregroundStyle(.secondary)
                .padding(.leading, 20)
        }

    }

    private var selectedMachineLabel: String {
        machineChoice.machineName ?? "new machine"
    }

    private var remoteToggleLabel: String {
        switch remoteMode {
        case .ssh: "Run on an ssh machine"
        case .boxd: "Run on boxd"
        case .mutagen: "Run remotely"
        }
    }

    private var remoteHint: String? {
        guard !canRunRemotely else { return nil }
        switch remoteMode {
        case .ssh:
            return "Add an ssh machine in Settings > Remote"
        case .boxd:
            if remoteOptions?.boxd == nil { return "Configure boxd in Settings > Remote" }
            return "Install the boxd CLI to run on boxd"
        case .mutagen:
            if remoteOptions?.mutagen != nil || globalRemoteSettings != nil {
                return "Project not under remote sync path"
            }
            return "Configure remote execution in Settings > Remote"
        }
    }

    /// Reads the toggle defaults of the selected project.
    private func applyProjectDefaults() {
        machineChoice = remoteOptions?.cardMachine.map { BoxdMachineChoice.existing($0) } ?? .newMachine
        guard let path = resolvedProjectPath else { return }
        if let remoteOptions { machineChoice = remoteOptions.initialMachineChoice(projectPath: path) }
        runRemotely = remoteOptions?.cardMachine != nil
            ? true
            : RemoteLaunchOptions.defaultRunRemotely(mode: remoteMode, projectPath: path)
        createWorktree = UserDefaults.standard.object(forKey: "createWorktree_\(path)") as? Bool ?? true
    }

    private func rememberRunRemotely() {
        // A card that already has a machine keeps the toggle on by itself, so
        // its value is not the project default.
        guard remoteOptions?.cardMachine == nil, let path = resolvedProjectPath else { return }
        RemoteLaunchOptions.rememberRunRemotely(runRemotely, mode: remoteMode, projectPath: path)
    }

    // MARK: - Actions

    private func reloadServices() async {
        let loaded = (try? await settingsStore.read()) ?? Settings()
        settings = loaded
        apiServices = loaded.apiServices
        defaultAPIServiceIds = loaded.defaultAPIServiceIds
        // Keep current selection if it still exists; otherwise fall back to the new default.
        let currentStillValid = selectedServiceId.flatMap { id in
            apiServices.first { $0.id == id }
        } != nil
        if !currentStillValid {
            selectedServiceId = loaded.defaultAPIServiceIds[selectedAssistant.rawValue]
        }
        if !commandEdited { command = commandPreview }
    }

    private func reloadOpenCodeModels() async {
        guard selectedAssistant == .opencode,
              let executable = ShellCommand.findExecutable("opencode") else {
            openCodeModels = []
            return
        }
        let projectPath = resolvedProjectPath
        openCodeModels = []
        do {
            let result = try await ShellCommand.run(
                executable,
                arguments: ["models"],
                currentDirectory: projectPath,
                timeout: 20
            )
            guard selectedAssistant == .opencode,
                  resolvedProjectPath == projectPath,
                  result.succeeded else { return }
            openCodeModels = Array(Set(result.stdout
                .split(whereSeparator: \.isNewline)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.contains("/") && !$0.hasPrefix("#") }
            )).sorted()
        } catch {
            // Keep the custom-model option available when OpenCode's catalog
            // cannot be read (for example, when the CLI is not authenticated).
        }
        if !commandEdited { command = commandPreview }
    }

    private func submitForm() {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let proj = resolvedProjectPath
        let titleOrNil = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let proj { lastSelectedProjectPath = proj }
        if startImmediately {
            if runsOnBoxd {
                onMachineChoice(machineChoice)
                if remoteOptions?.cardMachine == nil, let proj {
                    RemoteLaunchOptions.rememberMachineChoice(machineChoice, projectPath: proj)
                }
            }
            onCreateAndLaunch(
                prompt,
                proj,
                titleOrNil,
                createWorktree && isGitRepo && selectedAssistant.supportsWorktree,
                effectiveRunRemotely,
                dangerouslySkipPermissions,
                commandEdited ? command : nil,
                images,
                selectedAssistant,
                selectedServiceId,
                selectedModelOverride,
                selectedModelVariantOverride
            )
        } else {
            onCreate(
                prompt,
                proj,
                titleOrNil,
                false,
                images,
                selectedAssistant,
                selectedServiceId,
                selectedModelOverride,
                selectedModelVariantOverride
            )
        }
        isPresented = false
    }

    // MARK: - Computed

    private var resolvedProjectPath: String? {
        if projects.isEmpty {
            return customPath.isEmpty ? nil : customPath
        }
        if selectedProjectPath == Self.customPathSentinel {
            return customPath.isEmpty ? nil : customPath
        }
        return selectedProjectPath.isEmpty ? nil : selectedProjectPath
    }

    private var selectedProject: Project? {
        projects.first(where: { $0.path == resolvedProjectPath })
    }

    private var isGitRepo: Bool {
        guard let path = resolvedProjectPath, !path.isEmpty else { return false }
        return FileManager.default.fileExists(
            atPath: (path as NSString).appendingPathComponent(".git")
        )
    }

    private var hasRemoteConfig: Bool {
        guard let remote = globalRemoteSettings else { return false }
        guard let path = resolvedProjectPath else { return false }
        return path.hasPrefix(remote.localPath)
    }

    private var remoteHost: String? {
        globalRemoteSettings?.host
    }

    private var remoteMode: RemoteMode {
        remoteOptions?.mode ?? .mutagen
    }

    private var canRunRemotely: Bool {
        remoteOptions?.canRunRemotely(projectPath: resolvedProjectPath) ?? hasRemoteConfig
    }

    private var effectiveRunRemotely: Bool {
        runRemotely && canRunRemotely
    }

    private var supportsModelSelection: Bool {
        selectedAssistant == .claude || selectedAssistant == .opencode
    }

    private var modelOptions: [String] {
        selectedAssistant == .claude ? ["sonnet", "opus", "haiku", "fable"] : openCodeModels
    }

    private var filteredModelOptions: [String] {
        let query = modelSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return modelOptions }
        return modelOptions.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    private var variantOptions: [String] {
        selectedAssistant == .claude
            ? ["low", "medium", "high", "xhigh", "max", "ultracode"]
            : ["none", "minimal", "low", "medium", "high", "xhigh", "max"]
    }

    private var selectedModelOverride: String? {
        let model = selectedModel == Self.customModelSentinel ? customModel : selectedModel
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var selectedModelVariantOverride: String? {
        let variant = selectedVariant == Self.customVariantSentinel ? customVariant : selectedVariant
        let trimmed = variant.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// True when the session runs on a machine: an ssh machine or boxd.
    private var runsOnBoxd: Bool {
        remoteMode.runsOnMachines && effectiveRunRemotely
    }

    private var commandPreview: String {
        var parts: [String] = []

        if effectiveRunRemotely && remoteMode == .mutagen {
            parts.append("SHELL=~/.kanban-code/remote/zsh")
            if selectedAssistant.requiresRemotePathWrapper {
                parts.append("PATH=~/.kanban-code/remote:$PATH")
            }
        }

        let worktreeName: String?
        // On boxd the app creates the worktree, so the command carries no
        // worktree flag.
        if createWorktree && isGitRepo && selectedAssistant.supportsWorktree && !runsOnBoxd {
            let branch = worktreeBranch.trimmingCharacters(in: .whitespacesAndNewlines)
            worktreeName = branch
        } else {
            worktreeName = nil
        }

        let service = selectedServiceId.flatMap { id in apiServices.first { $0.id == id } }
        let launchCmd = selectedAssistant.launchCommand(
            skipPermissions: dangerouslySkipPermissions,
            worktreeName: worktreeName,
            service: service,
            modelOverride: selectedModelOverride,
            modelVariantOverride: selectedModelVariantOverride
        )
        let template = settings.commandTemplate(for: selectedAssistant, remote: effectiveRunRemotely)
        parts.append(CodingAssistant.applyCommandTemplate(launchCmd, template: template))

        return parts.joined(separator: " \\\n  ")
    }
}
