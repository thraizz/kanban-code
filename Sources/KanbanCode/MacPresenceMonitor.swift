import AppKit
import CoreGraphics
import Foundation
import IOKit
import KanbanCodeCore

/// Whether Rogerio is at the Mac and looking at Kanban, for the attention
/// policy. The main-thread parts (front window, open card, tab) are pushed
/// in by the app; idle time, lock, lid, screensaver and display sleep are
/// read on demand from any thread.
final class MacPresenceMonitor: @unchecked Sendable {
    static let shared = MacPresenceMonitor()

    private let lock = NSLock()
    private var isKanbanFrontmost = false
    private var visibleCardId: String?
    private var visibleTab: String?
    private var screensaverActive = false
    private var screenLockedByNotification = false
    private var observers: [NSObjectProtocol] = []

    private init() {}

    /// Updates the front window and the open card; called on the main thread.
    func update(frontmost: Bool, cardId: String?) {
        lock.withLock {
            isKanbanFrontmost = frontmost
            visibleCardId = cardId
        }
    }

    /// The tab of the open card: "terminal" and "chat" show the session.
    func setTab(_ tab: String?) {
        lock.withLock { visibleTab = tab }
    }

    /// Samples the main-thread state every second until cancelled.
    @MainActor
    func follow(store: BoardStore) async {
        while !Task.isCancelled {
            // A sheet or dialog takes the key window; the board stays main.
            let front = NSApp.isActive && NSApp.mainWindow?.isMiniaturized == false
            update(frontmost: front, cardId: store.state.selectedCardId)
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// Starts following screensaver and lock notifications.
    func start() {
        let installed = Self.observeDistributed { [weak self] name in
            self?.handle(distributed: name)
        }
        lock.withLock { observers = installed }
    }

    private func handle(distributed name: String) {
        lock.withLock {
            switch name {
            case "com.apple.screensaver.didstart": screensaverActive = true
            case "com.apple.screensaver.didstop": screensaverActive = false
            case "com.apple.screenIsLocked": screenLockedByNotification = true
            case "com.apple.screenIsUnlocked": screenLockedByNotification = false
            default: break
            }
        }
    }

    /// Distributed notifications arrive on the queue given here; the block
    /// is formed outside any actor so it may run there.
    private nonisolated static func observeDistributed(_ handler: @escaping @Sendable (String) -> Void) -> [NSObjectProtocol] {
        let center = DistributedNotificationCenter.default()
        let names = ["com.apple.screensaver.didstart", "com.apple.screensaver.didstop",
                     "com.apple.screenIsLocked", "com.apple.screenIsUnlocked"]
        return names.map { name in
            center.addObserver(forName: Notification.Name(name), object: nil, queue: nil) { _ in
                handler(name)
            }
        }
    }

    func snapshot() -> MacPresence {
        let (front, card, tab, saver, lockedNote) = lock.withLock {
            (isKanbanFrontmost, visibleCardId, visibleTab, screensaverActive, screenLockedByNotification)
        }
        return MacPresence(
            isKanbanFrontmost: front,
            visibleCardId: card,
            visibleTab: tab,
            idleSeconds: Self.idleSeconds(),
            screenLocked: lockedNote || Self.sessionLocked(),
            screensaverActive: saver,
            lidClosed: LidStateDetector.isAway,
            displayAsleep: CGDisplayIsAsleep(CGMainDisplayID()) != 0,
            reportedAt: Date())
    }

    /// Seconds since the last keyboard, mouse or trackpad input.
    static func idleSeconds() -> Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    /// The login window covers the session: locked or switched away.
    static func sessionLocked() -> Bool {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        if (info["CGSSessionScreenIsLocked"] as? Bool) == true { return true }
        if let onConsole = info[kCGSessionOnConsoleKey as String] as? Bool, !onConsole { return true }
        return false
    }
}
