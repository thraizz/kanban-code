import SwiftUI
import AppKit
import KanbanCodeCore

private let systemTrayLogDir: String = {
    let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code/logs")
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}()

/// Manages the menu bar status item (system tray).
/// Shows session icon when Claude sessions are actively working.
/// Launches a helper .app so tools like Amphetamine can detect active sessions.
@MainActor
final class SystemTray: NSObject, @unchecked Sendable {
    private var statusItem: NSStatusItem?
    private var menu: NSMenu?
    private weak var store: BoardStore?
    /// PID of the helper we launched (or adopted). Tracked by pid so we never have to
    /// enumerate NSWorkspace.runningApplications (a synchronous LaunchServices XPC call)
    /// on the main thread.
    private var activeSessionPID: pid_t?
    /// True while an `openApplication` request for the helper is in flight.
    private var activeSessionLaunching = false
    /// Orphan discovery from earlier app instances runs once at startup.
    private var orphanScanStarted = false
    private var orphanScanDone = false
    /// Contents of the currently installed menu; rebuild only when this changes.
    private var lastMenuContent: MenuContent?
    /// Fallback for dev mode (bare binary, no .app bundle).
    private var activeSessionProcess: Process?
    /// Time when In Progress last had sessions (for linger timeout).
    private var lastActiveTime: Date?
    private var lastLocalActiveTime: Date?
    /// Timer for live-updating the countdown while menu is open.
    private var countdownTimer: Timer?
    /// Reference to the countdown menu item for live updates.
    private weak var countdownItem: NSMenuItem?

    private nonisolated static let activeSessionBundleID = "com.kanban-code.active-session"

    /// How long to keep tray visible after last active session.
    /// Reads from UserDefaults (synced with @AppStorage("sessionLingerTimeout") in settings).
    private var lingerTimeout: TimeInterval {
        let stored = UserDefaults.standard.double(forKey: "sessionLingerTimeout")
        return stored > 0 ? stored : 60
    }

    func setup(store: BoardStore) {
        self.store = store
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // Build icon with 1x + 2x representations for crisp rendering at 22x22pt
        // (same approach as cc-amphetamine's Electron nativeImage)
        let icon = NSImage(size: NSSize(width: 22, height: 22))
        var hasReps = false

        if let url = Bundle.appResources.url(forResource: "clawd", withExtension: "png", subdirectory: "Resources"),
           let rep = NSImageRep(contentsOf: url) {
            rep.size = NSSize(width: 22, height: 22)
            icon.addRepresentation(rep)
            hasReps = true
        }
        if let url = Bundle.appResources.url(forResource: "clawd@2x", withExtension: "png", subdirectory: "Resources"),
           let rep = NSImageRep(contentsOf: url) {
            rep.size = NSSize(width: 22, height: 22) // same logical size; 44px used on retina
            icon.addRepresentation(rep)
            hasReps = true
        }

        if hasReps {
            icon.isTemplate = true
            statusItem?.button?.image = icon
        } else {
            statusItem?.button?.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "Kanban")
        }

        updateMenu()
        updateVisibility()
        scanForOrphanedHelpersOnce()
    }

    func update() {
        updateMenu()
        updateVisibility()
    }

    /// Lightweight description of everything the menu shows. Equal contents mean the
    /// existing NSMenu is still correct and must not be rebuilt.
    struct MenuContent: Equatable {
        enum Kind: Equatable { case working, active, waiting }
        struct Entry: Equatable {
            var title: String
            var kind: Kind
        }
        /// Whether the (live-updating) countdown line is shown. Its text is refreshed
        /// when the menu opens, so the text itself is not part of the content.
        var showsCountdown: Bool
        var active: [Entry]
        var waiting: [Entry]
        static let maxEntriesPerSection = 5

        static func make(active: [(title: String, isWorking: Bool)], waiting: [String]) -> MenuContent {
            MenuContent(
                showsCountdown: active.isEmpty,
                active: active.prefix(maxEntriesPerSection).map {
                    Entry(title: $0.title, kind: $0.isWorking ? .working : .active)
                },
                waiting: waiting.prefix(maxEntriesPerSection).map { Entry(title: $0, kind: .waiting) }
            )
        }
    }

    /// Pure decision: rebuild only when there is no menu yet or the content changed.
    nonisolated static func needsMenuRebuild(previous: MenuContent?, current: MenuContent) -> Bool {
        previous != current
    }

    private func currentMenuContent() -> MenuContent {
        guard let store else { return MenuContent.make(active: [], waiting: []) }
        return MenuContent.make(
            active: store.state.cards(in: .inProgress).map { ($0.displayTitle, $0.isActivelyWorking) },
            waiting: store.state.cards(in: .waiting).map { $0.displayTitle }
        )
    }

    private func updateMenu() {
        let content = currentMenuContent()
        guard menu == nil || Self.needsMenuRebuild(previous: lastMenuContent, current: content) else { return }
        lastMenuContent = content

        let menu = NSMenu()
        menu.delegate = self
        countdownItem = nil

        // Countdown at the top when lingering (no active sessions)
        if content.showsCountdown {
            let item = NSMenuItem(title: countdownText(), action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            countdownItem = item
            if !content.waiting.isEmpty {
                menu.addItem(NSMenuItem.separator())
            }
        }

        if !content.active.isEmpty {
            menu.addItem(NSMenuItem.sectionHeader(title: "In Progress"))
            for entry in content.active {
                let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
                item.image = NSImage(
                    systemSymbolName: entry.kind == .working ? "gear.circle.fill" : "play.circle.fill",
                    accessibilityDescription: nil)
                menu.addItem(item)
            }
        }

        if !content.waiting.isEmpty {
            menu.addItem(NSMenuItem.sectionHeader(title: "Waiting"))
            for entry in content.waiting {
                let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
                item.image = NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: nil)
                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.separator())

        let openItem = NSMenuItem(title: "Open Kanban", action: #selector(openMainWindow), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem?.menu = menu
        self.menu = menu
    }

    private func countdownText() -> String {
        guard let lastActive = lastActiveTime else {
            return "No active sessions"
        }
        let elapsed = Date().timeIntervalSince(lastActive)
        let remaining = max(0, Int(lingerTimeout - elapsed))
        let mins = remaining / 60
        let secs = remaining % 60
        let countdown = mins > 0 ? "\(mins)m \(secs)s" : "\(secs)s"
        return "No active sessions, sleeping in \(countdown)"
    }

    @objc func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }

    /// Show tray icon when there are In Progress sessions, or within linger timeout.
    /// Also manages the active-session helper app for Amphetamine integration.
    /// The tray icon shows any active session; the helper only runs for
    /// sessions on this Mac, so cards on a boxd machine never keep it awake.
    private func updateVisibility() {
        guard let store else { return }
        let hasActive = store.state.cardCount(in: .inProgress) > 0
        let hasLocalActive = store.state.hasLocalActiveCards

        if hasActive {
            lastActiveTime = Date()
            statusItem?.isVisible = true
        } else if let lastActive = lastActiveTime,
                  Date().timeIntervalSince(lastActive) < lingerTimeout {
            // Linger: keep visible for a bit after last active session
            statusItem?.isVisible = true
        } else {
            statusItem?.isVisible = false
        }

        if hasLocalActive {
            lastLocalActiveTime = Date()
            startActiveSessionIfNeeded()
        } else if let lastLocal = lastLocalActiveTime,
                  Date().timeIntervalSince(lastLocal) < lingerTimeout {
            // Keep the helper running during the linger window.
        } else {
            stopActiveSession()
        }
    }

    // MARK: - Active session helper app (for Amphetamine)

    /// Launches the active-session helper .app so tools like Amphetamine can detect it.
    /// Falls back to bare binary for development.
    private func startActiveSessionIfNeeded() {
        // Wait for the one-time orphan scan so we don't launch a duplicate helper.
        guard orphanScanDone else { return }
        // Already running (tracked by pid, no LaunchServices call)?
        if let pid = activeSessionPID, kill(pid, 0) == 0 { return }
        activeSessionPID = nil
        if let proc = activeSessionProcess, proc.isRunning { return }
        if activeSessionLaunching { return }

        // Try .app bundle first (Amphetamine can detect this)
        if let appURL = Self.findActiveSessionApp() {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            config.addsToRecentItems = false
            activeSessionLaunching = true
            NSWorkspace.shared.openApplication(at: appURL, configuration: config) { [weak self] app, error in
                Task { @MainActor in
                    self?.activeSessionLaunching = false
                    if let error {
                        Self.log("active-session app failed to start: \(error)")
                    } else if let app {
                        self?.activeSessionPID = app.processIdentifier
                        MemoryDiagnostics.shared.setRelatedProcessPIDs(label: "active-session", pids: [app.processIdentifier])
                        Self.log("active-session started: pid=\(app.processIdentifier)")
                    }
                }
            }
            return
        }

        // Fallback: bare binary (dev mode — no Amphetamine support)
        if let path = Self.findActiveSessionBinary() {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: path)
            proc.qualityOfService = .background
            proc.terminationHandler = { process in
                let reason = process.terminationReason == .exit ? "exit" : "uncaughtSignal"
                Self.log("active-session terminated: status=\(process.terminationStatus) reason=\(reason)")
            }
            do {
                try proc.run()
                activeSessionProcess = proc
                MemoryDiagnostics.shared.setRelatedProcessPIDs(label: "active-session", pids: [proc.processIdentifier])
                Self.log("active-session started (bare binary): pid=\(proc.processIdentifier)")
            } catch {
                Self.log("active-session failed to start: \(error)")
            }
            return
        }

        Self.log("active-session not found")
    }

    /// Stop the active-session helper when no more active sessions.
    /// Uses the stored pid only; orphans from earlier runs are handled once at startup.
    private func stopActiveSession() {
        var helperPIDs: [pid_t?] = []

        helperPIDs.append(activeSessionPID)
        activeSessionPID = nil

        if let proc = activeSessionProcess, proc.isRunning {
            helperPIDs.append(proc.processIdentifier)
        }
        activeSessionProcess = nil

        let pids = Self.uniqueActiveSessionPIDs(helperPIDs)
        guard !pids.isEmpty else { return }
        Self.terminate(pids)
        MemoryDiagnostics.shared.setRelatedProcessPIDs(label: "active-session", pids: [])
    }

    private static func terminate(_ pids: Set<pid_t>) {
        // Signal by pid rather than NSRunningApplication.terminate(): LaunchServices can
        // temporarily report a helper after SIGTERM, and sending an AppleEvent through a
        // stale application port can crash inside AE.framework.
        for pid in pids {
            log("stopping active-session: pid=\(pid)")
            kill(pid, SIGTERM)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
            }
        }
    }

    /// Finds helpers left over from earlier app instances, once, on a background task,
    /// so the main thread never blocks on LaunchServices.
    private func scanForOrphanedHelpersOnce() {
        guard !orphanScanStarted else { return }
        orphanScanStarted = true
        Task.detached(priority: .utility) { [weak self] in
            let pids = Self.discoverActiveSessionHelperPIDs()
            await MainActor.run { self?.finishOrphanScan(pids) }
        }
    }

    private nonisolated static func discoverActiveSessionHelperPIDs() -> [pid_t] {
        NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == activeSessionBundleID && !$0.isTerminated }
            .map { $0.processIdentifier }
    }

    private func finishOrphanScan(_ found: [pid_t]) {
        orphanScanDone = true
        let orphans = Self.uniqueActiveSessionPIDs(found.map { Optional($0) })
            .subtracting(Self.uniqueActiveSessionPIDs([activeSessionPID, activeSessionProcess?.processIdentifier]))
        if !orphans.isEmpty { Self.terminate(orphans) }
        // Now that scanning is done, apply the current start/stop decision.
        updateVisibility()
    }

    nonisolated static func uniqueActiveSessionPIDs(_ candidates: [pid_t?]) -> Set<pid_t> {
        Set(candidates.compactMap { pid in
            guard let pid, pid > 0 else { return nil }
            return pid
        })
    }

    // MARK: - Logging

    nonisolated static func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        let logPath = (systemTrayLogDir as NSString).appendingPathComponent("kanban.log")
        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8) ?? Data())
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: logPath, contents: line.data(using: .utf8))
        }
    }

    /// Find the active-session .app bundle.
    private static func findActiveSessionApp() -> URL? {
        var candidates: [String] = []

        // 1. Inside main app bundle: KanbanCode.app/Contents/Helpers/kanban-code-active-session.app
        candidates.append(
            (Bundle.main.bundlePath as NSString).appendingPathComponent("Contents/Helpers/kanban-code-active-session.app")
        )

        // 2. Next to the main app bundle
        candidates.append(
            ((Bundle.main.bundlePath as NSString).deletingLastPathComponent as NSString)
                .appendingPathComponent("kanban-code-active-session.app")
        )

        for candidate in candidates {
            if FileManager.default.fileExists(atPath: candidate) {
                log("active-session app found at: \(candidate)")
                return URL(fileURLWithPath: candidate)
            }
        }

        return nil
    }

    /// Find the bare active-session binary (fallback for development).
    private static func findActiveSessionBinary() -> String? {
        var candidates: [String] = []

        // 1. Next to the running Kanban binary (swift run, .app bundle)
        let kanbanPath = ProcessInfo.processInfo.arguments[0]
        let dir = (kanbanPath as NSString).deletingLastPathComponent
        candidates.append((dir as NSString).appendingPathComponent("kanban-code-active-session"))

        // 2. Inside .app bundle's MacOS directory
        if let bundlePath = Bundle.main.executablePath {
            let bundleDir = (bundlePath as NSString).deletingLastPathComponent
            candidates.append((bundleDir as NSString).appendingPathComponent("kanban-code-active-session"))
        }

        // 3. ~/.kanban-code/bin/kanban-code-active-session for installed locations
        candidates.append(
            (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code/bin/kanban-code-active-session")
        )

        for candidate in candidates {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                log("active-session found at: \(candidate)")
                return candidate
            }
        }

        log("active-session binary not found, searched: \(candidates)")
        return nil
    }
}

// MARK: - NSMenuDelegate (live countdown)

extension SystemTray: NSMenuDelegate {
    nonisolated func menuWillOpen(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            countdownTimer?.invalidate()
            guard countdownItem != nil else { return }
            countdownItem?.title = countdownText()
            countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.countdownItem?.title = self?.countdownText() ?? ""
                }
            }
        }
    }

    nonisolated func menuDidClose(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            countdownTimer?.invalidate()
            countdownTimer = nil
        }
    }
}
