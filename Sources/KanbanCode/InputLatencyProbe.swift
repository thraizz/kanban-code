import AppKit
import KanbanCodeCore
import os

/// Records input latency into `LatencyMetrics` (logged as `[latency] input ...`).
///
/// Approximation: a local event monitor sees every keyDown / mouseDown before
/// dispatch and notes `event.timestamp` (so time spent queued before the
/// handler counts). The sample ends at the next main run-loop `beforeWaiting`
/// that runs after Core Animation's own commit observer (order 2_000_000),
/// i.e. when the loop has handled the event, run SwiftUI/AppKit updates and
/// committed the layer tree. It excludes GPU/display latency after the commit.
/// Only the first pending event per loop turn is measured.
final class InputLatencyProbe: @unchecked Sendable {
    static let shared = InputLatencyProbe()

    private let pendingStart = OSAllocatedUnfairLock<TimeInterval?>(initialState: nil)
    private var monitor: Any?

    /// Main thread only.
    func start() {
        guard monitor == nil else { return }
        LatencyMetrics.shared.startLogging()
        Self.installObserver(probe: self)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.noteInput(timestamp: event.timestamp)
            return event
        }
    }

    private func noteInput(timestamp: TimeInterval) {
        pendingStart.withLock { if $0 == nil { $0 = timestamp } }
    }

    fileprivate func turnCommitted() {
        let start = pendingStart.withLock { value -> TimeInterval? in
            defer { value = nil }
            return value
        }
        guard let start else { return }
        LatencyMetrics.shared.recordInput(ms: (ProcessInfo.processInfo.systemUptime - start) * 1000)
    }

    /// Created in a nonisolated context: the handler runs on the main thread
    /// but must not inherit actor isolation from a caller.
    private nonisolated static func installObserver(probe: InputLatencyProbe) {
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, 2_100_000
        ) { _, _ in
            probe.turnCommitted()
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }
}
