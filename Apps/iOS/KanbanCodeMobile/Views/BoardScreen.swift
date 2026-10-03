import SwiftUI
import KanbanCodeRemoteKit

struct BoardScreen: View {
    let fleet: FleetModel
    @State private var path: [String] = []
    /// The board's rows while a card is open on top of it. A list that
    /// changes while covered reloads when focus comes back to one of its
    /// cells, which UIKit refuses with a crash; so it waits for the card to close.
    @State private var covered: (sections: [BoardSection], down: [BoardModel])?
    @State private var search = ""
    @State private var showNewTask = false
    @State private var showAddMac = false
    @State private var showMachines = false
    @State private var showArchived = false
    @State private var showAttention = false
    @State private var attentionFocus: String?
    @State private var actions: CardActionController
    @State private var expandedSections: Set<String> = []
    /// Project name the board is narrowed to, "" for every project.
    @AppStorage("projectFilter.fleet") private var projectFilter = ""

    /// Cards shown per column before a "Show all" row.
    private static let columnPreviewCount = ProcessInfo.processInfo.environment["KANBANCODE_COLUMN_PREVIEW"].flatMap(Int.init) ?? 15

    init(fleet: FleetModel) {
        self.fleet = fleet
        _actions = State(initialValue: CardActionController(fleet: fleet))
    }

    /// The only master, when there is one.
    private var single: BoardModel? { fleet.isMulti ? nil : fleet.masters.first }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle(title)
                .navigationSubtitle(subtitle)
                .searchable(text: $search, prompt: "Search cards")
                .refreshable { await refreshAll() }
                .toolbar { toolbar }
                .navigationDestination(for: String.self) { id in
                    FleetCardScreen(cardId: id, fleet: fleet)
                }
                .cardActions(actions)
        }
        .task { fleet.start() }
        .onChange(of: path.isEmpty) { _, isEmpty in
            covered = isEmpty ? nil : (sections(of: fleet.cards), downMasters)
        }
        .sheet(isPresented: $showNewTask) {
            NewTaskSheet(fleet: fleet) { card, master in
                master.upsert(card)
                path = [card.id]
            }
        }
        .sheet(isPresented: $showAddMac) {
            NavigationStack { PairingView() }
        }
        .sheet(isPresented: $showMachines) {
            MachinesView(fleet: fleet)
        }
        .sheet(isPresented: $showArchived) {
            ArchivedCardsSheet(fleet: fleet)
        }
        .sheet(isPresented: $showAttention) {
            AttentionListView(fleet: fleet, openCard: { id in path = [id] }, focusId: attentionFocus)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openAttention)) { note in
            attentionFocus = note.object as? String
            showAttention = true
        }
    }

    @ViewBuilder private var attentionSection: some View {
        let count = fleet.attention.count
        if count > 0 {
            Section {
                AttentionBanner(count: count) {
                    attentionFocus = nil
                    showAttention = true
                }
            }
        }
    }

    private func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            for master in fleet.masters { group.addTask { await master.refresh() } }
        }
    }

    private var title: String {
        single?.machineName ?? "Kanban Code"
    }

    /// Every master refused this phone.
    private var refusedMessage: String? {
        let messages = fleet.masters.compactMap { master -> String? in
            if case .refused(let message) = master.link { return message }
            return nil
        }
        return !fleet.masters.isEmpty && messages.count == fleet.masters.count ? messages.first : nil
    }

    @ViewBuilder private var content: some View {
        if let message = refusedMessage {
            ContentUnavailableView {
                Label("Pairing no longer valid", systemImage: "lock.slash")
            } description: {
                Text("\(message)\nAdd this device again in Settings > Remote Control on the Mac, then pair.")
            } actions: {
                Button("Pair again") { showAddMac = true }
                    .buttonStyle(.borderedProminent)
            }
        } else if fleet.hasBoard {
            let sections = covered?.sections ?? sections(of: fleet.cards)
            if sections.isEmpty && fleet.isMulti && search.isEmpty {
                List { machineStatusSection }
                    .listStyle(.insetGrouped)
            } else if sections.isEmpty {
                if search.isEmpty {
                    ContentUnavailableView {
                        Label("No cards", systemImage: "rectangle.stack")
                    } description: {
                        Text("Start a task and it runs on one of your machines.")
                    } actions: {
                        Button("New task") { showNewTask = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    ContentUnavailableView.search(text: search)
                }
            } else {
                List {
                    attentionSection
                    machineStatusSection
                    ForEach(sections, id: \.id) { section in
                        Section {
                            let collapsed = search.isEmpty && !expandedSections.contains(section.id)
                                && section.cards.count > Self.columnPreviewCount
                            ForEach(collapsed ? Array(section.cards.prefix(Self.columnPreviewCount)) : section.cards) { entry in
                                NavigationLink(value: entry.card.id) {
                                    CardRow(card: entry.card, showsColumn: section.id == Self.liveSectionID,
                                            machine: fleet.showsMachines ? entry.machineName : nil,
                                            machineOffline: !entry.master.isOnline)
                                }
                                .contextMenu { CardActionsMenu(entry: entry, controller: actions) }
                                .accessibilityIdentifier("card-\(entry.card.id)")
                            }
                            if search.isEmpty && section.cards.count > Self.columnPreviewCount {
                                Button {
                                    withAnimation {
                                        if collapsed { expandedSections.insert(section.id) } else { expandedSections.remove(section.id) }
                                    }
                                } label: {
                                    Text(collapsed ? "Show all \(section.cards.count)" : "Show fewer")
                                        .font(.subheadline.weight(.medium))
                                }
                                .accessibilityIdentifier("showAll-\(section.id)")
                            }
                        } header: {
                            HStack {
                                Text(section.title)
                                Spacer()
                                Text("\(section.cards.count)")
                                    .monospacedDigit()
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        } else if let error = fleet.masters.compactMap(\.loadError).first {
            ContentUnavailableView {
                Label("Cannot reach \(single?.server.name ?? "any machine")", systemImage: "wifi.exclamationmark")
            } description: {
                Text("\(error)\n\nCheck that the machine is on, Remote Control is on in its Settings, and this phone is on the same tailnet.")
            } actions: {
                Button("Try again") { Task { await refreshAll() } }
                    .buttonStyle(.borderedProminent)
                Button("Machines") { showMachines = true }
            }
        } else {
            ProgressView("Loading board")
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                showMachines = true
            } label: {
                Label("Machines", systemImage: fleet.masters.allSatisfy(\.isOnline) ? "desktopcomputer" : "desktopcomputer.trianglebadge.exclamationmark")
            }
            .accessibilityIdentifier("machinesMenu")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if !projects.isEmpty {
                    Picker("Project", selection: $projectFilter) {
                        Text("All projects").tag("")
                        ForEach(projects) { project in
                            Text(project.name).tag(project.name)
                        }
                    }
                }
                Section {
                    Button("Archived cards", systemImage: "archivebox") { showArchived = true }
                        .accessibilityIdentifier("showArchived")
                }
            } label: {
                Label("Board", systemImage: projectFilter.isEmpty
                      ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            }
            .disabled(fleet.onlineMasters.isEmpty && projects.isEmpty)
            .accessibilityIdentifier("boardMenu")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showNewTask = true
            } label: {
                Label("New task", systemImage: "plus")
            }
            .disabled(fleet.onlineMasters.allSatisfy { $0.board == nil })
            .accessibilityIdentifier("newTask")
        }
    }

    private func linkText(_ master: BoardModel) -> String {
        switch master.link {
        case .connecting: "Connecting"
        case .live: "Live"
        case .reconnecting(let retryIn): "Offline, retrying in \(Int(retryIn))s"
        case .refused: "Refused"
        case .offline: "Preview"
        }
    }

    private var subtitle: String {
        let status: String
        if let single {
            status = linkText(single)
        } else {
            let online = fleet.masters.filter(\.isOnline).count
            status = online == fleet.masters.count ? "\(online) machines live" : "\(online) of \(fleet.masters.count) machines live"
        }
        guard let name = filteredProjectName else { return status }
        return "\(status) · \(name)"
    }

    private var projects: [RemoteProject] { fleet.projects }

    private var downMasters: [BoardModel] {
        fleet.isMulti ? fleet.orderedMasters.filter { !$0.isOnline } : []
    }

    private var filteredProjectName: String? {
        guard !projectFilter.isEmpty else { return nil }
        return projects.first { $0.name == projectFilter || $0.path == projectFilter }?.name
            ?? URL(fileURLWithPath: projectFilter).lastPathComponent
    }

    /// A row per master that is not live, when there are several: its cards
    /// stay on the board as last seen.
    @ViewBuilder private var machineStatusSection: some View {
        let down = covered?.down ?? downMasters
        if !down.isEmpty {
            Section {
                ForEach(down, id: \.server.id) { master in
                    Button { showMachines = true } label: {
                        MachineStatusLine(master: master)
                    }
                    .tint(.primary)
                    .accessibilityIdentifier("machineDown-\(master.machineName)")
                }
            }
        }
    }

    private static let liveSectionID = "live"

    private struct BoardSection {
        let id: String
        let title: String
        let cards: [FleetCard]
    }

    /// Live sessions first, whatever their column (busy ones on top), then
    /// the columns without them.
    private func sections(of entries: [FleetCard]) -> [BoardSection] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let filterName = filteredProjectName
        let visible = entries.filter { entry in
            let card = entry.card
            guard !card.archived else { return false }
            if !projectFilter.isEmpty, card.projectPath != projectFilter, card.projectName == nil || card.projectName != filterName {
                return false
            }
            guard !query.isEmpty else { return true }
            return [card.title, card.projectName, card.branch, fleet.showsMachines ? entry.machineName : nil]
                .compactMap { $0?.lowercased() }
                .contains { $0.contains(query) }
                || card.prs.contains { "#\($0.number)".contains(query) }
        }
        func recent(_ a: FleetCard, _ b: FleetCard) -> Bool {
            (a.card.lastActivity ?? a.card.updatedAt) > (b.card.lastActivity ?? b.card.updatedAt)
        }
        // A card of a machine that is off shows in its column, not as live.
        func isLive(_ entry: FleetCard) -> Bool { entry.card.isLive && entry.master.isOnline }
        let live = visible.filter(isLive).sorted { a, b in
            a.card.isBusy != b.card.isBusy ? a.card.isBusy : recent(a, b)
        }
        var out: [BoardSection] = []
        if !live.isEmpty { out.append(BoardSection(id: Self.liveSectionID, title: "Live", cards: live)) }
        let rest = visible.filter { !isLive($0) }
        for column in RemoteColumn.phoneOrder {
            let cards = rest.filter { $0.card.column == column }.sorted(by: recent)
            if !cards.isEmpty { out.append(BoardSection(id: column.rawValue, title: column.displayName, cards: cards)) }
        }
        return out
    }
}

#Preview("Board") {
    BoardScreen(fleet: FleetModel(preview: [BoardModel(preview: PreviewData.board)]))
        .environment(ServerStore())
        .environment(PairingCoordinator())
}

#Preview("Two machines") {
    BoardScreen(fleet: FleetModel(preview: [BoardModel(preview: PreviewData.board),
                                            BoardModel(preview: PreviewData.boxBoard, name: "rchaves-platform", online: false)]))
        .environment(ServerStore())
        .environment(PairingCoordinator())
}
