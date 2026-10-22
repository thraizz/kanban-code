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
    /// True while AppKit handles a click or key press. A SwiftUI button or
    /// shortcut acts inside that handling, so an action dispatched meanwhile
    /// is the user's. The flag clears in the run loop's block phase, which
    /// comes before the main queue runs the work background tasks queued.
    @MainActor private static var handlingUserEvent = false

    @MainActor static func install() {
        NSEvent.addLocalMonitorForEvents(matching: [
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .keyDown,
        ]) { event in
            handlingUserEvent = true
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
                MainActor.assumeIsolated { handlingUserEvent = false }
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
            return event
        }
        UsageLog.userInputProbe = { handlingUserEvent }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { _ in
            UsageLog.flush()
        }
    }
}
