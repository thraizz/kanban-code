import Foundation

/// Debug-only helper that flags blocking APIs invoked on the main thread.
/// In release builds `warnIfMain` is an empty no-op.
public enum MainThreadGuard {

    /// Pure formatting, kept separate so it can be unit tested.
    public static func message(label: String, fileID: String, line: UInt) -> String {
        "Blocking call '\(label)' on main thread at \(fileID):\(line)"
    }

    /// Logs a warning (with call site) when called on the main thread.
    /// Returns true if a warning was emitted (always false in release).
    @discardableResult
    public nonisolated static func warnIfMain(
        _ label: String,
        fileID: String = #fileID,
        line: UInt = #line
    ) -> Bool {
        #if DEBUG
        guard Thread.isMainThread else { return false }
        KanbanCodeLog.warn("main-thread-guard", message(label: label, fileID: fileID, line: line))
        return true
        #else
        return false
        #endif
    }
}
