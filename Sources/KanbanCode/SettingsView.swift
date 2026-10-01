import SwiftUI
import KanbanCodeCore

// MARK: - Editor discovery

/// Discovers installed code editors and opens files/folders in them.
enum EditorDiscovery {
    /// Known code editor bundle IDs — only installed ones appear in the picker.
    private static let knownEditors: [(bundleId: String, name: String)] = [
        ("dev.zed.Zed", "Zed"),
        ("com.todesktop.230313mzl4w4u92", "Cursor"),
        ("com.microsoft.VSCode", "VS Code"),
        ("com.apple.dt.Xcode", "Xcode"),
        ("com.jetbrains.intellij", "IntelliJ IDEA"),
        ("com.jetbrains.intellij.ce", "IntelliJ CE"),
        ("com.jetbrains.CLion", "CLion"),
        ("com.jetbrains.WebStorm", "WebStorm"),
        ("com.jetbrains.pycharm", "PyCharm"),
        ("com.jetbrains.goland", "GoLand"),
        ("com.jetbrains.rider", "Rider"),
        ("com.jetbrains.rustrover", "RustRover"),
        ("com.sublimetext.4", "Sublime Text"),
        ("com.sublimetext.3", "Sublime Text 3"),
        ("org.vim.MacVim", "MacVim"),
        ("org.gnu.Emacs", "Emacs"),
        ("com.panic.Nova", "Nova"),
        ("com.barebones.bbedit", "BBEdit"),
        ("co.aspect.browser", "Windsurf"),
        ("com.neovide.neovide", "Neovide"),
        ("com.apple.TextEdit", "TextEdit"),
    ]

    struct Editor: Identifiable, Hashable {
        let bundleId: String
        let name: String
        let icon: NSImage
        var id: String { bundleId }
    }

    /// Returns only editors that are installed on this system.
    static func installedEditors() -> [Editor] {
        knownEditors.compactMap { entry in
            guard let appURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: entry.bundleId
            ) else { return nil }
            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            icon.size = NSSize(width: 16, height: 16)
            return Editor(bundleId: entry.bundleId, name: entry.name, icon: icon)
        }
    }

    /// CLI names for editors — used to open the correct folder as project root.
    /// NSWorkspace.open alone can't do this for already-running editors.
    /// CLI commands and extra flags for editors.
    private static let cliCommands: [String: (command: String, extraArgs: [String])] = [
        "dev.zed.Zed": ("zed", ["-n"]),
        "com.todesktop.230313mzl4w4u92": ("cursor", []),
        "com.microsoft.VSCode": ("code", []),
        "co.aspect.browser": ("windsurf", []),
        "com.sublimetext.4": ("subl", []),
        "com.sublimetext.3": ("subl", []),
    ]

    /// Open a path in the editor with the given bundle ID.
    static func open(path: String, bundleId: String) {
        // Try CLI first — the only reliable way to tell an already-running editor
        // to open a specific directory as project root
        if let entry = cliCommands[bundleId] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [entry.command] + entry.extraArgs + [path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            if (try? process.run()) != nil { return }
        }
        // Fallback to NSWorkspace
        let url = URL(fileURLWithPath: path)
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            NSWorkspace.shared.open(
                [url],
                withApplicationAt: appURL,
                configuration: NSWorkspace.OpenConfiguration()
            )
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Open a file in the editor, creating it first if needed (for config files).
    static func openFile(path: String, bundleId: String) {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: "{}".data(using: .utf8))
        }
        open(path: path, bundleId: bundleId)
    }
}

// MARK: - Settings root

struct SettingsView: View {
    @State private var ghAvailable = false
    @State private var tmuxAvailable = false
    @State private var assistantStatus: [CodingAssistant: AssistantStatus] = [:]

    var body: some View {
        TabView {
            ProjectsSettingsView()
                .tabItem { Label("Projects", systemImage: "folder") }

            AssistantsSettingsView(assistantStatus: $assistantStatus)
                .tabItem { Label("Assistants", systemImage: "terminal") }

            GeneralSettingsView(
                ghAvailable: ghAvailable,
                tmuxAvailable: tmuxAvailable
            )
            .tabItem { Label("General", systemImage: "gear") }

            SelfCompactSettingsView()
                .tabItem { Label("Self-Compact", systemImage: "arrow.triangle.2.circlepath") }

            SubagentSettingsView()
                .tabItem { Label("Subagents", systemImage: "point.3.connected.trianglepath.dotted") }

            NotificationSettingsView()
                .tabItem { Label("Notifications", systemImage: "bell") }

            RemoteSettingsView()
                .tabItem { Label("Remote", systemImage: "network") }

            RemoteControlSettingsView()
                .tabItem { Label("Remote Control", systemImage: "iphone.radiowaves.left.and.right") }

            SyncSettingsView()
                .tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath.circle") }

            AmphetamineSettingsView()
                .tabItem { Label("Amphetamine", systemImage: "bolt.fill") }
        }
        .frame(width: 720, height: 620)
        .task {
            await checkAvailability()
        }
    }

    private func checkAvailability() async {
        let settingsStore = SettingsStore()
        let enabledAssistants = (try? await settingsStore.read())?.enabledAssistants ?? CodingAssistant.allCases
        for assistant in CodingAssistant.allCases {
            let available = await ShellCommand.isAvailable(assistant.cliCommand)
            let hooks = assistant.supportsHooks && HookManager.isInstalled(for: assistant)
            assistantStatus[assistant] = AssistantStatus(
                available: available,
                hooksInstalled: hooks,
                enabled: enabledAssistants.contains(assistant)
            )
        }
        ghAvailable = await GhCliAdapter().isAvailable()
        tmuxAvailable = await TmuxAdapter().isAvailable()
    }
}

// MARK: - Subagents

struct SubagentSettingsView: View {
    @State private var maximumDepth = 1
    @State private var loaded = false
    private let settingsStore = SettingsStore()

    var body: some View {
        Form {
            Section("Hierarchy") {
                Stepper(value: $maximumDepth, in: 0...SubagentSettings.maximumSupportedDepth) {
                    HStack {
                        Text("Maximum subagent depth")
                        Spacer()
                        Text(maximumDepth == 0 ? "Disabled" : "\(maximumDepth)")
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: maximumDepth) { save() }

                Text(maximumDepthDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("CLI") {
                Text("Create a child from an agent's primary tmux session with `kanban subagent spawn`. Use `kanban subagent --help` for fork, reporting, archive, resume, transcript, and capture commands.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .padding()
        .task {
            maximumDepth = (try? await settingsStore.read().subagents.maximumDepth) ?? 1
            loaded = true
        }
    }

    private var maximumDepthDescription: String {
        switch maximumDepth {
        case 0:
            "Agents cannot create subagents."
        case 1:
            "Top-level cards can create children, but those children cannot create more agents."
        default:
            "Top-level cards can create subagent hierarchies up to \(maximumDepth) levels deep."
        }
    }

    private func save() {
        guard loaded else { return }
        Task {
            guard var settings = try? await settingsStore.read() else { return }
            settings.subagents.maximumDepth = maximumDepth
            try? await settingsStore.write(settings)
            NotificationCenter.default.post(name: .kanbanCodeSettingsChanged, object: nil)
        }
    }
}

/// Per-assistant availability and hook status, used by Settings and Onboarding.
struct AssistantStatus {
    var available: Bool
    var hooksInstalled: Bool
    var enabled: Bool
}

// MARK: - Assistants

private struct ServiceSheetRequest: Identifiable {
    let id = UUID()
    let assistant: CodingAssistant
    let existingService: APIService? // nil = add mode
}

struct AssistantsSettingsView: View {
    @Binding var assistantStatus: [CodingAssistant: AssistantStatus]

    private let settingsStore = SettingsStore()
    @State private var apiServices: [APIService] = []
    @State private var defaultAPIServiceIds: [String: String] = [:]
    @State private var serviceSheetRequest: ServiceSheetRequest? = nil
    @State private var assistantCommands: [String: AssistantCommandTemplate] = [:]
    @State private var commandsLoaded = false
    @State private var commandsSaveTask: Task<Void, Never>?
    @State private var savedCommands: [String: AssistantCommandTemplate] = [:]
    @State private var remoteClaudeToken = ""
    @State private var remoteTokenSaveTask: Task<Void, Never>?
    @State private var claudeRuntime: SessionRuntime = .tmux
    @State private var agtopInstalled = AgtopCliAdapter.findExecutable() != nil

    var body: some View {
        Form {
            ForEach(CodingAssistant.allCases, id: \.self) { assistant in
                let status = assistantStatus[assistant] ?? AssistantStatus(available: false, hooksInstalled: false, enabled: true)
                Section {
                    Toggle("Enabled", isOn: Binding(
                        get: { status.enabled },
                        set: { newValue in
                            assistantStatus[assistant] = AssistantStatus(
                                available: status.available,
                                hooksInstalled: status.hooksInstalled,
                                enabled: newValue
                            )
                            saveEnabledAssistants()
                        }
                    ))

                    if status.enabled && assistant.supportsHooks {
                        HStack {
                            Label("Hooks", systemImage: status.hooksInstalled ? "checkmark.circle.fill" : "xmark.circle")
                                .foregroundStyle(status.hooksInstalled ? .green : .secondary)
                            Spacer()
                            if status.hooksInstalled {
                                Text("Installed")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                            } else {
                                Button("Install Hooks") {
                                    do {
                                        try HookManager.install(for: assistant)
                                        assistantStatus[assistant] = AssistantStatus(
                                            available: status.available,
                                            hooksInstalled: true,
                                            enabled: status.enabled
                                        )
                                    } catch {
                                        // Show error
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }
                        }
                    } else if status.enabled {
                        HStack {
                            Label("Activity", systemImage: "doc.text.magnifyingglass")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("Session file polling")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                    }

                    // API Services subsection
                    let services = apiServices.filter { $0.assistant == assistant }
                    if !services.isEmpty {
                        ForEach(services) { service in
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(service.name)
                                        .font(.body)
                                    Group {
                                        if let launcher = service.launcherPrefix, let model = service.modelFlag {
                                            Text("\(launcher) \(assistant.cliCommand) --model \(model) -- …")
                                        } else if let model = service.modelFlag {
                                            Text("--model \(model) -- …")
                                        } else if let launcher = service.launcherPrefix {
                                            Text("\(launcher) \(assistant.cliCommand) -- …")
                                        }
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                }
                                Spacer()
                                Button {
                                    toggleDefault(service: service, for: assistant)
                                } label: {
                                    Image(systemName: defaultAPIServiceIds[assistant.rawValue] == service.id
                                        ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(defaultAPIServiceIds[assistant.rawValue] == service.id
                                            ? Color.blue : Color.secondary)
                                }
                                .buttonStyle(.plain)
                                .help(defaultAPIServiceIds[assistant.rawValue] == service.id
                                    ? "Default for \(assistant.displayName)" : "Set as default")

                                Button {
                                    serviceSheetRequest = ServiceSheetRequest(assistant: assistant, existingService: service)
                                } label: {
                                    Image(systemName: "pencil")
                                }
                                .buttonStyle(.borderless)
                                .help("Edit service")

                                Button(role: .destructive) {
                                    deleteService(service, for: assistant)
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    Button {
                        serviceSheetRequest = ServiceSheetRequest(assistant: assistant, existingService: nil)
                    } label: {
                        Label("Add API Service", systemImage: "plus")
                            .font(.body)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)

                    launchCommandRows(for: assistant)
                    if assistant == .claude {
                        runtimeRows
                        remoteLoginRows
                    }
                } header: {
                    HStack {
                        Text(assistant.displayName)
                        Spacer()
                        if status.available {
                            Label("CLI Available", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                        } else {
                            Text("Not Installed")
                                .foregroundStyle(.orange)
                                .font(.caption)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .task { await loadServices() }
        .onChange(of: assistantCommands) { scheduleCommandsSave() }
        .sheet(item: $serviceSheetRequest) { request in
            AddAPIServiceSheet(assistant: request.assistant, existingService: request.existingService) { service in
                if let existing = request.existingService,
                   let idx = apiServices.firstIndex(where: { $0.id == existing.id }) {
                    apiServices[idx] = service
                } else {
                    apiServices.append(service)
                }
                saveServices()
            }
        }
    }

    // MARK: - Launch commands

    @ViewBuilder
    private func launchCommandRows(for assistant: CodingAssistant) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Launch command", text: localCommandBinding(for: assistant))
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
            Text("`${cli_command}` is the command Kanban Code builds. Example: `langwatch ${cli_command}` or `${cli_command} --rc`.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Toggle("Different command when running on a remote machine", isOn: remoteCommandEnabledBinding(for: assistant))

        if assistantCommands[assistant.rawValue]?.remote != nil {
            TextField("Remote launch command", text: remoteCommandBinding(for: assistant))
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
        }
    }

    // MARK: - Runtime

    @ViewBuilder
    private var runtimeRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Run sessions in", selection: $claudeRuntime) {
                ForEach(SessionRuntime.allCases, id: \.self) { runtime in
                    Text(runtime.displayName).tag(runtime)
                }
            }
            .onChange(of: claudeRuntime) { saveRuntime() }
            Text(agtopInstalled || claudeRuntime == .tmux
                ? "rush keeps each session running in the background and shows it in the card's terminal. Cards on an ssh machine run on rush there when the machine has it. Custom commands and boxd cards run on tmux. Applies to new launches and resumes."
                : "rush is not installed. Install it with `go install github.com/0xdeafcafe/rush/cmd/rush@latest`, sessions run on tmux until then.")
                .font(.caption)
                .foregroundStyle(agtopInstalled || claudeRuntime == .tmux ? .tertiary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func saveRuntime() {
        guard commandsLoaded else { return }
        let runtime = claudeRuntime
        Task {
            var settings = (try? await settingsStore.read()) ?? Settings()
            guard settings.runtime(for: .claude) != runtime else { return }
            settings.assistantRuntimes[CodingAssistant.claude.rawValue] = runtime == .tmux ? nil : runtime
            try? await settingsStore.write(settings)
            NotificationCenter.default.post(name: .kanbanCodeSettingsChanged, object: nil)
        }
    }

    // MARK: - Remote login

    @ViewBuilder
    private var remoteLoginRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            SecureField("Remote token (optional)", text: $remoteClaudeToken)
                .textFieldStyle(.roundedBorder)
                .onChange(of: remoteClaudeToken) { scheduleRemoteTokenSave() }
            Text("Machines get the login of this Mac and send a refresh back, so one account switch reaches every session, local and remote. A long-lived token from `claude setup-token` replaces that login on the machines only.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func scheduleRemoteTokenSave() {
        guard commandsLoaded else { return }
        let token = remoteClaudeToken.trimmingCharacters(in: .whitespacesAndNewlines)
        remoteTokenSaveTask?.cancel()
        remoteTokenSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            var settings = (try? await settingsStore.read()) ?? Settings()
            var boxd = settings.boxd ?? BoxdSettings()
            guard boxd.claudeOAuthToken != token else { return }
            boxd.claudeOAuthToken = token
            settings.boxd = boxd
            try? await settingsStore.write(settings)
            NotificationCenter.default.post(name: .kanbanCodeSettingsChanged, object: nil)
        }
    }

    private func localCommandBinding(for assistant: CodingAssistant) -> Binding<String> {
        Binding(
            get: { assistantCommands[assistant.rawValue]?.local ?? AssistantCommandTemplate.placeholder },
            set: { newValue in
                var entry = assistantCommands[assistant.rawValue] ?? AssistantCommandTemplate()
                entry.local = newValue
                assistantCommands[assistant.rawValue] = entry
            }
        )
    }

    private func remoteCommandBinding(for assistant: CodingAssistant) -> Binding<String> {
        Binding(
            get: { assistantCommands[assistant.rawValue]?.remote ?? AssistantCommandTemplate.placeholder },
            set: { newValue in
                var entry = assistantCommands[assistant.rawValue] ?? AssistantCommandTemplate()
                entry.remote = newValue
                assistantCommands[assistant.rawValue] = entry
            }
        )
    }

    private func remoteCommandEnabledBinding(for assistant: CodingAssistant) -> Binding<Bool> {
        Binding(
            get: { assistantCommands[assistant.rawValue]?.remote != nil },
            set: { isOn in
                var entry = assistantCommands[assistant.rawValue] ?? AssistantCommandTemplate()
                entry.remote = isOn ? AssistantCommandTemplate.placeholder : nil
                assistantCommands[assistant.rawValue] = entry
            }
        )
    }

    private func scheduleCommandsSave() {
        guard commandsLoaded else { return }
        let commands = normalizedCommands()
        guard commands != savedCommands else { return }
        savedCommands = commands
        commandsSaveTask?.cancel()
        commandsSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            var settings = (try? await settingsStore.read()) ?? Settings()
            settings.assistantCommands = commands
            try? await settingsStore.write(settings)
            NotificationCenter.default.post(name: .kanbanCodeSettingsChanged, object: nil)
        }
    }

    /// Drops entries that carry no instruction: the bare placeholder or a
    /// blank local command with no remote command.
    private func normalizedCommands() -> [String: AssistantCommandTemplate] {
        assistantCommands.filter { _, template in
            let local = template.local.trimmingCharacters(in: .whitespacesAndNewlines)
            let isDefaultLocal = local.isEmpty || local == AssistantCommandTemplate.placeholder
            return !isDefaultLocal || template.remote != nil
        }
    }

    private func saveEnabledAssistants() {
        let enabled = CodingAssistant.allCases.filter { assistantStatus[$0]?.enabled ?? true }
        Task {
            var settings = (try? await settingsStore.read()) ?? Settings()
            settings.enabledAssistants = enabled
            try? await settingsStore.write(settings)
            NotificationCenter.default.post(name: .kanbanCodeSettingsChanged, object: nil)
        }
    }

    private func loadServices() async {
        let settings = (try? await settingsStore.read()) ?? Settings()
        apiServices = settings.apiServices
        defaultAPIServiceIds = settings.defaultAPIServiceIds
        assistantCommands = settings.assistantCommands
        savedCommands = settings.assistantCommands
        remoteClaudeToken = settings.boxd?.claudeOAuthToken ?? ""
        claudeRuntime = settings.runtime(for: .claude)
        commandsLoaded = true
    }

    private func saveServices() {
        let services = apiServices
        let defaults = defaultAPIServiceIds
        Task {
            var settings = (try? await settingsStore.read()) ?? Settings()
            settings.apiServices = services
            settings.defaultAPIServiceIds = defaults
            try? await settingsStore.write(settings)
            NotificationCenter.default.post(name: .kanbanCodeSettingsChanged, object: nil)
        }
    }

    private func toggleDefault(service: APIService, for assistant: CodingAssistant) {
        if defaultAPIServiceIds[assistant.rawValue] == service.id {
            defaultAPIServiceIds.removeValue(forKey: assistant.rawValue)
        } else {
            defaultAPIServiceIds[assistant.rawValue] = service.id
        }
        saveServices()
    }

    private func deleteService(_ service: APIService, for assistant: CodingAssistant) {
        apiServices.removeAll { $0.id == service.id }
        if defaultAPIServiceIds[assistant.rawValue] == service.id {
            defaultAPIServiceIds.removeValue(forKey: assistant.rawValue)
        }
        saveServices()
    }
}

// MARK: - Add API Service sheet

struct AddAPIServiceSheet: View {
    let assistant: CodingAssistant
    let existingService: APIService?
    let onSave: (APIService) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var launcherPrefix = ""
    @State private var modelFlag = ""
    @State private var baseURL = ""

    init(assistant: CodingAssistant, existingService: APIService? = nil, onSave: @escaping (APIService) -> Void) {
        self.assistant = assistant
        self.existingService = existingService
        self.onSave = onSave
        _name = State(initialValue: existingService?.name ?? "")
        _launcherPrefix = State(initialValue: existingService?.launcherPrefix ?? "")
        _modelFlag = State(initialValue: existingService?.modelFlag ?? "")
        _baseURL = State(initialValue: existingService?.baseURL ?? "")
    }

    private var isEditing: Bool { existingService != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(isEditing ? "Edit" : "Add") API Service — \(assistant.displayName)")
                .font(.headline)
                .padding()

            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("e.g. Ollama (local)"))
                    TextField("Launcher prefix", text: $launcherPrefix, prompt: Text("e.g. ollama launch"))
                    TextField("Model", text: $modelFlag, prompt: Text("e.g. qwen3-coder-next:cloud"))
                    TextField("Base URL", text: $baseURL, prompt: Text("e.g. http://localhost:11434/v1"))
                } header: {
                    Text("Command preview:")
                        .font(.caption)
                } footer: {
                    Text(previewCommand)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)
                Button(isEditing ? "Save" : "Add") {
                    let service = APIService(
                        id: existingService?.id ?? UUID().uuidString,
                        name: name.isEmpty ? "Unnamed" : name,
                        assistant: assistant,
                        launcherPrefix: launcherPrefix.isEmpty ? nil : launcherPrefix,
                        modelFlag: modelFlag.isEmpty ? nil : modelFlag,
                        baseURL: baseURL.isEmpty ? nil : baseURL
                    )
                    onSave(service)
                    dismiss()
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty)
            }
            .padding()
        }
        .frame(width: 420, height: 400)
    }

    private var previewCommand: String {
        let prefix = launcherPrefix.isEmpty ? nil : launcherPrefix
        let model = modelFlag.isEmpty ? nil : modelFlag
        let service = APIService(name: "", assistant: assistant, launcherPrefix: prefix, modelFlag: model)
        return assistant.launchCommand(skipPermissions: true, worktreeName: nil, service: service)
    }
}

// MARK: - Self-Compact

struct SelfCompactSettingsView: View {
    private let settingsStore = SettingsStore()

    @State private var config = SelfCompactSettings()
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        Form {
            Section("Context Guard") {
                Toggle("Enable self-compact guard", isOn: Binding(
                    get: { config.enabled },
                    set: {
                        config.enabled = $0
                        scheduleSave()
                    }
                ))

                HStack {
                    Text("Poll every")
                    Spacer()
                    Text("\(config.pollIntervalSeconds)s")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Stepper("", value: Binding(
                        get: { config.pollIntervalSeconds },
                        set: {
                            config.pollIntervalSeconds = $0
                            scheduleSave()
                        }
                    ), in: 10...300, step: 10)
                    .labelsHidden()
                }

                Text("Kanban Code reads Claude's statusline context usage for live cards. Queued messages wait for the agent to go idle, steered messages are pasted straight away and read between turns, and interrupts stop the current turn with Escape first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Thresholds") {
                ForEach($config.rules) { $rule in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            TextField("Tokens", value: $rule.thresholdTokens, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 96)
                                .monospacedDigit()
                                .onChange(of: rule.thresholdTokens) { scheduleSave() }

                            Picker("Action", selection: $rule.action) {
                                ForEach(SelfCompactAction.allCases, id: \.self) { action in
                                    Text(action.displayName).tag(action)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 150)
                            .help(rule.action.detail)
                            .onChange(of: rule.action) { scheduleSave() }

                            Spacer()

                            Button {
                                config.rules.removeAll { $0.id == rule.id }
                                scheduleSave()
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Remove threshold")
                        }

                        TextEditor(text: $rule.message)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 54, maxHeight: 78)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.18))
                            )
                            .onChange(of: rule.message) { scheduleSave() }
                    }
                    .padding(.vertical, 4)
                }

                HStack {
                    Button("Add Threshold") {
                        config.rules.append(SelfCompactRule(
                            id: UUID().uuidString,
                            thresholdTokens: 800_000,
                            action: .interrupt,
                            message: "/compact"
                        ))
                        config.rules.sort { $0.thresholdTokens < $1.thresholdTokens }
                        scheduleSave()
                    }
                    .controlSize(.small)

                    Spacer()

                    Button("Reset Defaults") {
                        config.rules = SelfCompactRule.defaults
                        config.pollIntervalSeconds = 30
                        scheduleSave()
                    }
                    .controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .task {
            if let settings = try? await settingsStore.read() {
                config = settings.selfCompact
            }
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            do {
                var settings = try await settingsStore.read()
                settings.selfCompact = config
                try await settingsStore.write(settings)
                NotificationCenter.default.post(name: .kanbanCodeSettingsChanged, object: nil)
            } catch {
                KanbanCodeLog.warn("settings", "Failed to save self-compact settings: \(error)")
            }
        }
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    let ghAvailable: Bool
    let tmuxAvailable: Bool

    @AppStorage("preferredEditorBundleId") private var editorBundleId: String = "dev.zed.Zed"
    @AppStorage("uiTextSize") private var uiTextSize: Int = 1
    @AppStorage("sessionDetailFontSize") private var sessionDetailFontSize: Double = Double(TerminalCache.defaultFontSize)
    @State private var installedEditors: [EditorDiscovery.Editor] = []
    @State private var showOnboarding = false
    @State private var mergeCommand: String = GitHubSettings.defaultMergeCommand
    @State private var mergeSaveTask: Task<Void, Never>?

    private let settingsStore = SettingsStore()

    var body: some View {
        Form {
            Section("Editor") {
                Picker("Open files with", selection: $editorBundleId) {
                    ForEach(installedEditors) { editor in
                        Label {
                            Text(editor.name)
                        } icon: {
                            Image(nsImage: editor.icon)
                        }
                        .tag(editor.bundleId)
                    }
                }
            }

            Section("Appearance") {
                Picker("UI text size", selection: $uiTextSize) {
                    Text("Small").tag(0)
                    Text("Medium").tag(1)
                    Text("Large").tag(2)
                    Text("X-Large").tag(3)
                    Text("XX-Large").tag(4)
                }

                HStack {
                    Text("Session details monospace font size")
                    Spacer()
                    Text("\(Int(sessionDetailFontSize)) pt")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Stepper("", value: $sessionDetailFontSize, in: 8...24, step: 1)
                        .labelsHidden()
                }

                HStack {
                    Text("⌘+ / ⌘- to adjust both, or set independently here.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("Reset to Defaults") {
                        uiTextSize = 1
                        sessionDetailFontSize = Double(TerminalCache.defaultFontSize)
                    }
                    .controlSize(.small)
                    .disabled(uiTextSize == 1 && sessionDetailFontSize == Double(TerminalCache.defaultFontSize))
                }
            }

            Section("Integrations") {
                statusRow("tmux", available: tmuxAvailable)
                statusRow("GitHub CLI (gh)", available: ghAvailable)
            }

            Section("Permissions") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Agents launched by Kanban Code inherit Kanban Code's macOS privacy permissions. Grant Full Disk Access once to stop repeated prompts when agents read protected app data or new project folders.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button("Open Full Disk Access") {
                            openFullDiskAccessSettings()
                        }
                        .controlSize(.small)
                    }
                }
            }

            Section("PR Merge") {
                TextField("Merge command", text: $mergeCommand)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .onChange(of: mergeCommand) { scheduleMergeSave() }
                Text("Use ${number} for the PR number. Default: \(GitHubSettings.defaultMergeCommand)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                HStack {
                    Spacer()
                    Button("Reset to Default") {
                        mergeCommand = GitHubSettings.defaultMergeCommand
                        scheduleMergeSave()
                    }
                    .controlSize(.small)
                }
            }

            Section("Settings File") {
                HStack {
                    Text("~/.kanban-code/settings.json")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open in Editor") {
                        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code/settings.json")
                        EditorDiscovery.openFile(path: path, bundleId: editorBundleId)
                    }
                    .controlSize(.small)
                }
            }

            Section {
                Button("Open Setup Wizard...") {
                    showOnboarding = true
                }
                .controlSize(.small)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            installedEditors = EditorDiscovery.installedEditors()
        }
        .task {
            if let settings = try? await settingsStore.read() {
                mergeCommand = settings.github.mergeCommand
            }
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingWizard(
                settingsStore: settingsStore,
                onComplete: {
                    showOnboarding = false
                }
            )
        }
    }

    private func scheduleMergeSave() {
        mergeSaveTask?.cancel()
        mergeSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            do {
                var settings = try await settingsStore.read()
                settings.github.mergeCommand = mergeCommand.isEmpty ? GitHubSettings.defaultMergeCommand : mergeCommand
                try await settingsStore.write(settings)
                NotificationCenter.default.post(name: .kanbanCodeSettingsChanged, object: nil)
            } catch {}
        }
    }

    private func openFullDiskAccessSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.preference.security?Privacy",
        ]
        for raw in urls {
            guard let url = URL(string: raw) else { continue }
            if NSWorkspace.shared.open(url) { return }
        }
    }

    private func statusRow(_ name: String, available: Bool) -> some View {
        HStack {
            Label(name, systemImage: available ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(available ? .green : .secondary)
            Spacer()
            Text(available ? "Available" : "Not found")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }
}

// MARK: - Amphetamine

struct AmphetamineSettingsView: View {
    @AppStorage("sessionLingerTimeout") private var lingerTimeout: Double = 60

    var body: some View {
        Form {
            Section("Setup") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Kanban spawns a **kanban-code-active-session** helper process when Claude sessions are actively working. Configure Amphetamine to detect it:")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        instructionRow(1, "Install **Amphetamine** from the Mac App Store")
                        instructionRow(2, "Open Amphetamine → Preferences → **Triggers**")
                        instructionRow(3, "Add new trigger → select **Application**")
                        instructionRow(4, "Search for **\"kanban-code-active-session\"** and select it")
                    }

                    Text("Amphetamine will keep your Mac awake whenever Claude is working, and allow sleep when all sessions finish. Cards that run on a boxd machine do not count: their work continues on the machine while the Mac sleeps.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Section("Linger Timeout") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Slider(value: $lingerTimeout, in: 0...900, step: 30)
                        Text(formatTimeout(lingerTimeout))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 50, alignment: .trailing)
                    }
                    Text("Keep the helper running for this long after the last active session ends, so Amphetamine doesn't immediately allow sleep.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Section("Logs") {
                HStack {
                    Text("~/.kanban-code/logs/")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open in Finder") {
                        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code/logs")
                        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(URL(fileURLWithPath: path))
                    }
                    .controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func formatTimeout(_ seconds: Double) -> String {
        if seconds == 0 { return "Off" }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        if mins == 0 { return "\(secs)s" }
        if secs == 0 { return "\(mins)m" }
        return "\(mins)m \(secs)s"
    }

    private func instructionRow(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\(number).")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .trailing)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Notifications

struct NotificationSettingsView: View {
    @State private var pushoverMode: PushoverMode = .disabled
    @State private var pushoverToken = ""
    @State private var pushoverUserKey = ""
    @State private var renderMarkdownImage = false
    @State private var isSaving = false
    @State private var testSending = false
    @State private var testResult: String?
    @State private var pandocAvailable = false
    @State private var wkhtmltoimageAvailable = false
    @State private var saveTask: Task<Void, Never>?

    private let settingsStore = SettingsStore()

    private var pushoverConfigured: Bool {
        pushoverMode != .disabled && !pushoverToken.isEmpty && !pushoverUserKey.isEmpty
    }

    var body: some View {
        Form {
            Section("Pushover") {
                Picker("Pushover notifications", selection: $pushoverMode) {
                    Text("Disabled").tag(PushoverMode.disabled)
                    Text("Enabled").tag(PushoverMode.enabled)
                    Text("When lid is closed").tag(PushoverMode.whenLidClosed)
                }
                .onChange(of: pushoverMode) { scheduleSave() }

                if pushoverMode == .whenLidClosed {
                    Text("Sends Pushover when MacBook lid is closed and no external display is active, local notifications otherwise.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                TextField("App Token", text: $pushoverToken)
                    .textFieldStyle(.roundedBorder)
                    .disabled(pushoverMode == .disabled)
                    .onChange(of: pushoverToken) { scheduleSave() }
                TextField("User Key", text: $pushoverUserKey)
                    .textFieldStyle(.roundedBorder)
                    .disabled(pushoverMode == .disabled)
                    .onChange(of: pushoverUserKey) { scheduleSave() }

                HStack {
                    Button {
                        testNotification()
                    } label: {
                        HStack(spacing: 4) {
                            if testSending {
                                ProgressView()
                                    .controlSize(.mini)
                            } else {
                                Image(systemName: "play.circle")
                            }
                            Text("Send Test")
                        }
                    }
                    .controlSize(.small)
                    .disabled(!pushoverConfigured || testSending)

                    if let testResult {
                        Text(testResult)
                            .font(.caption)
                            .foregroundStyle(testResult.contains("Sent") ? .green : .red)
                    }
                }

                Text("Get your keys at pushover.net")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Section("Rich Notification Images") {
                Toggle("Render full output as markdown image", isOn: $renderMarkdownImage)
                    .disabled(!pushoverConfigured)
                    .onChange(of: renderMarkdownImage) { scheduleSave() }

                if !pushoverConfigured {
                    Text("Configure Pushover above to enable this option.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else if renderMarkdownImage {
                    statusRow("pandoc", available: pandocAvailable,
                              hint: "brew install pandoc")
                    statusRow("wkhtmltoimage", available: wkhtmltoimageAvailable,
                              hint: "Download .pkg from github.com/wkhtmltopdf/packaging/releases")

                    if !(pandocAvailable && wkhtmltoimageAvailable) {
                        Text("Install the missing dependencies above to enable image rendering.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } else {
                    Text("When enabled, Claude's full markdown output is rendered as an image and attached to push notifications.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Section("macOS Fallback") {
                HStack {
                    Label("Native Notifications", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Text("Always available")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                Text("When Pushover is not configured, notifications are sent via macOS notification center.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

        }
        .formStyle(.grouped)
        .padding()
        .task { await loadSettings() }
    }

    private func statusRow(_ name: String, available: Bool, hint: String) -> some View {
        HStack {
            Label(name, systemImage: available ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(available ? .green : .secondary)
            Spacer()
            if available {
                Text("Available")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else {
                Text(hint)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
    }

    private func loadSettings() async {
        do {
            let settings = try await settingsStore.read()
            pushoverMode = settings.notifications.pushoverMode
            pushoverToken = settings.notifications.pushoverToken ?? ""
            pushoverUserKey = settings.notifications.pushoverUserKey ?? ""
            renderMarkdownImage = settings.notifications.renderMarkdownImage
        } catch {}
        pandocAvailable = await ShellCommand.isAvailable("pandoc")
        wkhtmltoimageAvailable = await ShellCommand.isAvailable("wkhtmltoimage")
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            do {
                var settings = try await settingsStore.read()
                settings.notifications.pushoverMode = pushoverMode
                settings.notifications.pushoverToken = pushoverToken.isEmpty ? nil : pushoverToken
                settings.notifications.pushoverUserKey = pushoverUserKey.isEmpty ? nil : pushoverUserKey
                settings.notifications.renderMarkdownImage = renderMarkdownImage
                try await settingsStore.write(settings)
                NotificationCenter.default.post(name: .kanbanCodeSettingsChanged, object: nil)
            } catch {}
        }
    }

    private func testNotification() {
        testSending = true
        testResult = nil
        Task {
            do {
                let client = PushoverClient(token: pushoverToken, userKey: pushoverUserKey)
                try await client.sendNotification(
                    title: "Kanban Test",
                    message: "Notifications are working!",
                    imageData: nil,
                    cardId: nil
                )
                testResult = "Sent!"
            } catch {
                testResult = "Failed: \(error.localizedDescription)"
            }
            testSending = false
        }
    }
}

// MARK: - Remote

struct RemoteSettingsView: View {
    @State private var remoteHost = ""
    @State private var remotePath = ""
    @State private var localPath = ""
    @State private var syncIgnoresText = ""
    @State private var saveTask: Task<Void, Never>?
    @State private var mutagenAvailable = false
    @State private var remoteMode: RemoteMode = .ssh
    @State private var loaded = false

    private let settingsStore = SettingsStore()

    var body: some View {
        Form {
            Section("Mode") {
                ForEach(RemoteMode.allCases, id: \.self) { mode in
                    modeRow(mode)
                }
            }

            if remoteMode.runsOnMachines {
                BoxdSettingsView(mode: remoteMode)
            } else {
                mutagenSections
            }
        }
        .formStyle(.grouped)
        .padding()
        .task {
            await loadSettings()
            mutagenAvailable = await ShellCommand.isAvailable("mutagen")
        }
    }

    @ViewBuilder
    private var mutagenSections: some View {
        Section("Host") {
            TextField("Remote Host", text: $remoteHost)
                .textFieldStyle(.roundedBorder)
                .onChange(of: remoteHost) { scheduleSave() }
            TextField("Remote Path", text: $remotePath)
                .textFieldStyle(.roundedBorder)
                .onChange(of: remotePath) { scheduleSave() }
            TextField("Local Path", text: $localPath)
                .textFieldStyle(.roundedBorder)
                .onChange(of: localPath) { scheduleSave() }
        }

        if !remoteHost.isEmpty && !mutagenAvailable {
            Section("Dependency") {
                HStack {
                    Label("Mutagen", systemImage: "minus.circle")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("brew install mutagen")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
                Text("Mutagen is required for syncing files between local and remote machines.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }

        Section("Sync Ignores") {
            Text("Patterns excluded from mutagen sync (one per line)")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $syncIgnoresText)
                .font(.system(.body, design: .monospaced))
                .frame(height: 140)
                .onChange(of: syncIgnoresText) { scheduleSave() }
            HStack {
                Spacer()
                Button("Reset to Defaults") {
                    syncIgnoresText = MutagenAdapter.defaultIgnores.joined(separator: "\n")
                    scheduleSave()
                }
            }
        }
    }

    private func modeRow(_ mode: RemoteMode) -> some View {
        Button {
            guard remoteMode != mode else { return }
            remoteMode = mode
            saveMode()
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: remoteMode == mode ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(remoteMode == mode ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.settingsTitle)
                    Text(mode.settingsDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func saveMode() {
        guard loaded else { return }
        let mode = remoteMode
        Task {
            guard var settings = try? await settingsStore.read() else { return }
            settings.remoteMode = mode
            try? await settingsStore.write(settings)
            NotificationCenter.default.post(name: .kanbanCodeSettingsChanged, object: nil)
        }
    }

    private func loadSettings() async {
        do {
            let settings = try await settingsStore.read()
            remoteMode = settings.remoteMode
            remoteHost = settings.remote?.host ?? ""
            remotePath = settings.remote?.remotePath ?? ""
            localPath = settings.remote?.localPath ?? ""
            let ignores = settings.remote?.syncIgnores ?? MutagenAdapter.defaultIgnores
            syncIgnoresText = ignores.joined(separator: "\n")
            loaded = true
        } catch {}
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            do {
                var settings = try await settingsStore.read()
                if remoteHost.isEmpty && remotePath.isEmpty && localPath.isEmpty {
                    settings.remote = nil
                } else {
                    let ignores = syncIgnoresText
                        .components(separatedBy: "\n")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    settings.remote = RemoteSettings(
                        host: remoteHost,
                        remotePath: remotePath,
                        localPath: localPath,
                        syncIgnores: ignores == MutagenAdapter.defaultIgnores ? nil : ignores
                    )
                }
                try await settingsStore.write(settings)
                NotificationCenter.default.post(name: .kanbanCodeSettingsChanged, object: nil)
            } catch {}
        }
    }
}

// MARK: - Projects

struct ProjectsSettingsView: View {
    @State private var projects: [Project] = []
    @State private var excludedPaths: [String] = []
    @State private var newExcludedPath = ""
    @State private var sessionExclusion = SessionExclusion()
    @State private var newTitlePattern = ""
    @State private var error: String?
    @State private var editingProject: Project?
    @State private var isEditingNew = false

    private let settingsStore = SettingsStore()

    var body: some View {
        Form {
            Section("Projects") {
                if projects.isEmpty {
                    Text("No projects configured")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                } else {
                    List {
                        ForEach(projects) { project in
                            projectRow(project)
                                .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                        }
                        .onMove { source, destination in
                            projects.move(fromOffsets: source, toOffset: destination)
                            Task { try? await settingsStore.reorderProjects(projects) }
                        }
                    }
                    .listStyle(.plain)
                    .scrollDisabled(true)
                    .frame(maxHeight: .infinity)
                }

                Button("Add Project...") {
                    addProjectViaFolderPicker()
                }
                .controlSize(.small)
            }

            Section("Global View Exclusions") {
                ForEach(excludedPaths, id: \.self) { path in
                    HStack {
                        Text(path)
                            .font(.caption)
                        Spacer()
                        Button {
                            excludedPaths.removeAll { $0 == path }
                            saveExclusions()
                        } label: {
                            Image(systemName: "xmark.circle")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }

                HStack {
                    TextField("Path to exclude from global view", text: $newExcludedPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                    Button("Add") {
                        guard !newExcludedPath.isEmpty else { return }
                        excludedPaths.append(newExcludedPath)
                        newExcludedPath = ""
                        saveExclusions()
                    }
                    .controlSize(.small)
                    .disabled(newExcludedPath.isEmpty)
                }

                Text("Sessions from excluded paths won't appear in All Projects view. Wildcards supported (e.g. langwatch-skill-*)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Section("Hidden Sessions") {
                Toggle("Hide scheduled tasks", isOn: Binding(
                    get: { sessionExclusion.hideScheduledTasks },
                    set: {
                        sessionExclusion.hideScheduledTasks = $0
                        saveSessionExclusion()
                    }
                ))
                .font(.caption)

                ForEach(sessionExclusion.titlePatterns, id: \.self) { pattern in
                    HStack {
                        Text(pattern)
                            .font(.caption.monospaced())
                        Spacer()
                        Button {
                            sessionExclusion.titlePatterns.removeAll { $0 == pattern }
                            saveSessionExclusion()
                        } label: {
                            Image(systemName: "xmark.circle")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }

                HStack {
                    TextField("Prompt or title pattern to hide", text: $newTitlePattern)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .onSubmit(addTitlePattern)
                    Button("Add", action: addTitlePattern)
                        .controlSize(.small)
                        .disabled(newTitlePattern.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                Text("Discovered sessions whose prompt matches are hidden from every view. Plain text matches anywhere; wildcards match the whole prompt (e.g. *nightly-report*). Case-insensitive. Cards you launched, named or pinned always stay.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .padding()
        .task { await loadSettings() }
        .sheet(item: $editingProject) { project in
            ProjectEditSheet(
                project: project,
                automaticColor: ProjectColor.automatic(
                    path: project.path,
                    in: projects.contains { $0.path == project.path } ? projects : projects + [project]
                ),
                isNew: isEditingNew,
                onSave: { updated in
                    Task {
                        if isEditingNew {
                            try? await settingsStore.addProject(updated)
                        } else {
                            try? await settingsStore.updateProject(updated)
                        }
                        await loadSettings()
                        NotificationCenter.default.post(name: .kanbanCodeSettingsChanged, object: nil)
                    }
                    isEditingNew = false
                    editingProject = nil
                },
                onCancel: {
                    isEditingNew = false
                    editingProject = nil
                }
            )
        }
    }

    private func projectRow(_ project: Project) -> some View {
        HStack {
            Circle()
                .fill(ProjectColor.resolve(path: project.path, in: projects).color)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .fontWeight(.medium)
                Text(project.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let filter = project.githubFilter, !filter.isEmpty {
                    Text("gh: \(filter)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            if !project.visible {
                Image(systemName: "eye.slash")
                    .foregroundStyle(.tertiary)
                    .font(.caption)
            }

            Button {
                editingProject = project
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Edit project")

            Button {
                deleteProject(project)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red.opacity(0.7))
            }
            .buttonStyle(.borderless)
            .help("Remove project")
        }
    }

    private func addProjectViaFolderPicker() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a project directory"
        panel.prompt = "Add Project"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.path
        // Check for duplicates
        if projects.contains(where: { $0.path == path }) {
            error = "Project already configured at this path"
            return
        }
        // Add directly then open edit sheet — avoids sheet-from-settings issues
        let project = Project(path: path)
        Task {
            try? await settingsStore.addProject(project)
            await loadSettings()
            NotificationCenter.default.post(name: .kanbanCodeSettingsChanged, object: nil)
            // Open edit sheet so user can configure name/filter
            editingProject = projects.first(where: { $0.path == path })
        }
    }

    private func deleteProject(_ project: Project) {
        Task {
            try? await settingsStore.removeProject(path: project.path)
            await loadSettings()
            NotificationCenter.default.post(name: .kanbanCodeSettingsChanged, object: nil)
        }
    }

    private func saveExclusions() {
        Task {
            var settings = try await settingsStore.read()
            settings.globalView.excludedPaths = excludedPaths
            try await settingsStore.write(settings)
            NotificationCenter.default.post(name: .kanbanCodeSettingsChanged, object: nil)
        }
    }

    private func addTitlePattern() {
        let pattern = newTitlePattern.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty else { return }
        if !sessionExclusion.titlePatterns.contains(pattern) {
            sessionExclusion.titlePatterns.append(pattern)
        }
        newTitlePattern = ""
        saveSessionExclusion()
    }

    private func saveSessionExclusion() {
        let exclusion = sessionExclusion
        Task {
            var settings = try await settingsStore.read()
            settings.globalView.sessionExclusion = exclusion
            try await settingsStore.write(settings)
            NotificationCenter.default.post(name: .kanbanCodeSettingsChanged, object: nil)
        }
    }

    private func loadSettings() async {
        do {
            let settings = try await settingsStore.read()
            projects = settings.projects
            excludedPaths = settings.globalView.excludedPaths
            sessionExclusion = settings.globalView.sessionExclusion
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Project Edit Sheet

struct ProjectEditSheet: View {
    @State private var name: String
    @State private var repoRoot: String
    @State private var githubFilter: String
    @State private var visible: Bool
    @State private var color: ProjectColor?
    @State private var testResultCount: Int?
    @State private var testRunning = false
    let original: Project
    let automaticColor: ProjectColor
    let path: String
    let isNew: Bool
    let onSave: (Project) -> Void
    let onCancel: () -> Void

    init(
        project: Project,
        automaticColor: ProjectColor,
        isNew: Bool = false,
        onSave: @escaping (Project) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.original = project
        self.automaticColor = automaticColor
        self.path = project.path
        self.isNew = isNew
        self._name = State(initialValue: project.name)
        self._repoRoot = State(initialValue: project.repoRoot ?? "")
        self._githubFilter = State(initialValue: project.githubFilter ?? "")
        self._visible = State(initialValue: project.visible)
        self._color = State(initialValue: project.projectColor)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "Add Project" : "Edit Project")
                .font(.title3)
                .fontWeight(.semibold)

            Form {
                Section {
                    TextField("Name", text: $name)
                    Text(path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Repo root (if different from path)", text: $repoRoot)
                        .font(.caption)
                    Toggle("Visible in project selector", isOn: $visible)
                    Picker("Card color", selection: $color) {
                        colorOption("Automatic (\(automaticColor.displayName))", automaticColor).tag(ProjectColor?.none)
                        ForEach(ProjectColor.allCases, id: \.self) { option in
                            colorOption(option.displayName, option).tag(Optional(option))
                        }
                    }
                }

                Section("GitHub Issues") {
                    TextField("Filter", text: $githubFilter)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))

                    Text("Uses `gh search issues` syntax — e.g.\nassignee:@me repo:org/repo is:open label:bug")
                        .font(.caption)
                        .foregroundStyle(.tertiary)

                    HStack {
                        Button {
                            testFilter()
                        } label: {
                            HStack(spacing: 4) {
                                if testRunning {
                                    ProgressView()
                                        .controlSize(.mini)
                                } else {
                                    Image(systemName: "play.circle")
                                }
                                Text("Test filter")
                            }
                        }
                        .controlSize(.small)
                        .disabled(githubFilter.isEmpty || testRunning)

                        if let count = testResultCount {
                            Text("\(count) issue\(count == 1 ? "" : "s") found")
                                .font(.caption)
                                .foregroundStyle(count > 0 ? .green : .orange)
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") {
                    var project = original
                    project.name = name
                    project.repoRoot = repoRoot.isEmpty ? nil : repoRoot
                    project.visible = visible
                    project.githubFilter = githubFilter.isEmpty ? nil : githubFilter
                    project.projectColor = color
                    onSave(project)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func colorOption(_ title: String, _ color: ProjectColor) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: "circle.fill")
                .foregroundStyle(color.color)
        }
    }

    private func testFilter() {
        testRunning = true
        testResultCount = nil
        let filterArgs = githubFilter.split(separator: " ").map(String.init)
        Task.detached {
            let process = Process()
            let ghPath = ShellCommand.findExecutable("gh") ?? "gh"
            process.executableURL = URL(fileURLWithPath: ghPath)
            process.arguments = ["search", "issues", "--limit", "100", "--json", "number"] + filterArgs
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            defer { try? pipe.fileHandleForReading.close() }
            try? process.run()
            // Drain before waiting: a child that fills the pipe buffer blocks on
            // its own write and never exits.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let count: Int
            if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                count = arr.count
            } else {
                count = 0
            }
            await MainActor.run {
                testResultCount = count
                testRunning = false
            }
        }
    }
}
