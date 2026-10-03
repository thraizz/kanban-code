import AppKit
import KanbanCodeCore

/// Mac attention notifications plus the Dock: the icon shows how many
/// requests are open, notified or shown in the app, and bounces until
/// Kanban Code comes to the front when a new notification posts, so a
/// request whose banner closed is still seen. A request shown in the app
/// opens its detail sheet instead.
actor DockAttentionNotifier: MacAttentionNotifier {
    private let inner: any MacAttentionNotifier
    private var posted: Set<String> = []

    init(_ inner: any MacAttentionNotifier) {
        self.inner = inner
    }

    func post(_ request: AttentionRequest, cardName: String?) async {
        await inner.post(request, cardName: cardName)
        let isNew = posted.insert(request.id).inserted
        guard isNew else { return }
        await MainActor.run {
            if !NSApp.isActive {
                NSApp.requestUserAttention(.criticalRequest)
            }
        }
        KanbanCodeLog.info("attention", "Dock bounced for \(request.id)")
    }

    func showOpenCount(_ count: Int) async {
        await MainActor.run {
            NSApp.dockTile.badgeLabel = count == 0 ? nil : String(count)
        }
        KanbanCodeLog.info("attention", "Dock shows \(count) open request(s)")
    }

    func showInApp(_ request: AttentionRequest) async {
        let id = request.id
        await MainActor.run {
            NotificationCenter.default.post(name: .kanbanCodeShowAttention, object: nil, userInfo: ["id": id])
        }
        KanbanCodeLog.info("attention", "Opened the detail sheet of \(id) in the app")
    }

    func remove(id: String) async {
        await inner.remove(id: id)
        posted.remove(id)
    }
}
