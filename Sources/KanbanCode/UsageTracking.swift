import AppKit
import SwiftUI
import KanbanCodeCore

extension View {
    /// Counts each time this view comes on screen in the usage log.
    func trackUsage(_ kind: String, _ name: String) -> some View {
        onAppear { UsageLog.record(kind, name) }
    }
}

enum UsageTracking {
    /// Lets the usage log tell a click or key press from background work: an
    /// action dispatched within half a second of a mouse or key event that is
    /// still being handled counts as the user's.
    @MainActor static func install() {
        UsageLog.userInputProbe = {
            guard let event = NSApp.currentEvent else { return false }
            switch event.type {
            case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                 .otherMouseDown, .otherMouseUp, .keyDown, .keyUp:
                return ProcessInfo.processInfo.systemUptime - event.timestamp < 0.5
            default:
                return false
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { _ in
            UsageLog.flush()
        }
    }
}
