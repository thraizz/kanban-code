import SwiftUI
import AppKit
import KanbanCodeCore

// MARK: - Terminal cache

/// Keeps the tmux terminals (Ghostty surfaces) across drawer close/open cycles.
/// When the drawer closes, terminals are detached from the view hierarchy but kept alive.
/// When reopened, the cached terminal is reparented — no new tmux attach needed,
/// preserving scrollback and terminal state.
@MainActor
final class TerminalCache {
    static let shared = TerminalCache()

    private var terminals: [String: GhosttySurfaceView] = [:]
    private var lastLoggedTerminalCount = 0

    private init() {}

    /// Tracks which terminals have had their process started.
    private var startedSessions: Set<String> = []

    /// Resolved tmux binary path — checked once, reused for all terminals.
    static let tmuxPath: String = ShellCommand.findExecutable("tmux") ?? "tmux"

    /// Get or create a terminal view for the given tmux session name.
    /// The process is NOT started here — call `startProcessIfNeeded` after layout
    /// so the terminal has a non-zero frame (avoids tmux SIGWINCH clear on resize from 0x0).
    func terminal(for sessionName: String, frame: NSRect) -> GhosttySurfaceView {
        if let existing = terminals[sessionName] {
            return existing
        }
        let terminal = GhosttySurfaceView(frame: frame)
        // Do NOT set autoresizingMask — we manage frame explicitly in layout()
        // to avoid intermediate sizes triggering tmux redraws during animations.
        terminal.autoresizingMask = []
        terminal.isHidden = true
        terminal.sessionName = sessionName
        terminals[sessionName] = terminal
        logGrowthIfNeeded(trigger: "create session=\(sessionName)")
        return terminal
    }

    /// The terminal of a session, if one was made.
    func existing(_ sessionName: String) -> GhosttySurfaceView? {
        terminals[sessionName]
    }

    /// The shell script that attaches a terminal to `sessionName`: a peer's
    /// card, a remote machine, rush, or the local tmux session.
    func attachScript(for sessionName: String) -> String {
        let script: String
        if let peer = AppServices.peerCard(forSession: sessionName),
           let peerScript = AppServices.peerAttachScript(machineId: peer.machineId, cardId: peer.cardId, session: sessionName) {
            // Another master runs the card: its terminal streams from there.
            script = peerScript
        } else if let machine = AppServices.machine(forSession: sessionName),
                  let rushId = RushSessionName.rushId(fromName: sessionName),
                  let target = AppServices.sshTargets[machine] {
            script = Self.remoteRushScript(
                target: target, id: rushId, readyMarker: AppServices.remoteReadyMarkerPath(for: sessionName))
        } else if let machine = AppServices.machine(forSession: sessionName) {
            script = Self.remoteAttachScript(
                boxd: AppServices.boxdPath,
                machine: machine,
                session: sessionName,
                readyMarker: AppServices.remoteReadyMarkerPath(for: sessionName),
                sshTargets: AppServices.sshTargets
            )
        } else if AppServices.isRemoteSessionExpected(sessionName) {
            // The launch has not reached its machine yet; the marker names it.
            script = Self.remoteAttachScript(
                boxd: AppServices.boxdPath,
                machine: nil,
                session: sessionName,
                readyMarker: AppServices.remoteReadyMarkerPath(for: sessionName),
                sshTargets: AppServices.sshTargets
            )
        } else if let rushId = RushSessionName.rushId(fromName: sessionName) {
            script = Self.rushScript(rush: RushCliAdapter.findExecutable(), id: rushId)
        } else {
            script = Self.attachScript(tmux: Self.tmuxPath, session: sessionName)
        }
        return script
    }

    /// Retries of terminals waiting for their card's owner, by session.
    private var ownerWaits: [String: Int] = [:]

    /// Start the tmux attach process if the terminal has a non-zero frame and hasn't started yet.
    /// A terminal of a card whose owner is not known yet waits for it: up
    /// to 30 seconds while the identities load, and for as long as a peer
    /// that may own the card does not answer (the card shows why). Started
    /// before, it would attach to a session this Mac does not have.
    func startProcessIfNeeded(for sessionName: String) {
        guard let terminal = terminals[sessionName] else { return }
        guard !startedSessions.contains(sessionName) else { return }
        guard terminal.frame.width > 0, terminal.frame.height > 0 else { return }
        let wait = AppServices.terminalOwnerWait(sessionName)
        let waited = ownerWaits[sessionName] ?? 0
        if wait == .peerSilent || (wait == .loading && waited < 60) {
            ownerWaits[sessionName] = waited + 1
            let delay: TimeInterval = waited < 60 ? 0.5 : 2
            if waited == 60 {
                KanbanCodeLog.info("terminal-view", "session=\(sessionName) waits for the peer that owns its card")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.startProcessIfNeeded(for: sessionName)
            }
            return
        }
        ownerWaits[sessionName] = nil
        startedSessions.insert(sessionName)
        // A new terminal attaches; a hold from an earlier one is over.
        try? FileManager.default.removeItem(atPath: Self.detachMarkerPath(for: sessionName))

        let userShell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let script = attachScript(for: sessionName)
        // Ghostty runs this through `/bin/sh -c "exec -l …"` itself. The `env`
        // in front keeps its shell integration from recognizing the login shell
        // and replacing the command with a bare interactive shell.
        terminal.start(command: "/usr/bin/env \(Self.shellQuote(userShell)) -l -c \(Self.shellQuote(script))")
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Attaches to a tmux session on a boxd machine. The terminal opens when
    /// the launch starts, so it first waits for the ready marker the launch
    /// writes once the session exists (up to 20 minutes, a machine may have
    /// to be created and a repository checked out first). The marker names
    /// the machine, which wins over `machine` when it is not empty, so a
    /// terminal that started before the launch knew the machine still
    /// attaches to the right one. The machine may still be resuming after
    /// that, so the attach itself is retried for a while.
    ///
    /// The transport is `boxd machine connect`, the interactive shell of the
    /// CLI: it puts the local pty in raw mode, sizes the remote pty and
    /// follows resizes, and the session lives as long as the shell. (`exec
    /// --tty` does none of that and hangs up a full-screen program after a
    /// few seconds.) `connect` takes no command, so `expect` drives it: it
    /// waits for the prompt, types the tmux attach and hands the pty over
    /// with `interact`. The shell on the machine prints the exit status of
    /// tmux behind a sentinel and exits, so a detach ends the connection and
    /// is attached again, and a failed attach is retried. `connect` itself exits 0 whatever the
    /// command did, so the sentinel is the only word on the outcome. The
    /// tmux client runs with `-u` so it writes UTF-8 whatever the locale of
    /// the machine.
    ///
    /// A session that is not there yet is tried for 10 minutes: a resume
    /// creates the tmux session a few seconds after the bridge connects, and
    /// a push of a large transcript before it can take a while. A connection
    /// that fails or drops (no network, the machine still coming back) does
    /// not use up those tries: the session is still running on the machine,
    /// so the attach is retried for as long as the terminal is open.
    ///
    /// A machine reached over ssh (`sshTargets`, machine name to ssh target)
    /// needs none of that: `ssh -tt` sizes the remote pty and follows
    /// resizes, and it returns the exit status of the command, so the same
    /// statuses drive the loop (`noSessionStatus` for a missing session,
    /// `detachedStatus` for a detach, 255 for a connection that failed).
    static func remoteAttachScript(boxd: String, machine: String?, session: String, readyMarker: String? = nil, sshTargets: [String: String] = [:]) -> String {
        let quote = { (value: String) in "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let fallback = quote(machine ?? "")
        let program = expectProgram(boxd: boxd, session: session)
        let boxdAttach = "KANBAN_MACHINE=\"$m\" /usr/bin/expect -c \(quote(program)); r=$?"
        var attach: String
        if sshTargets.isEmpty {
            attach = boxdAttach
        } else {
            let cases = sshTargets.sorted { $0.key < $1.key }
                .map { "\(quote($0.key))) t=\(quote($0.value));;" }
                .joined(separator: " ")
            let remote = "tmux has-session -t \(quote(session)) 2>/dev/null || exit \(noSessionStatus); "
                + "COLORTERM=truecolor tmux -u -T hyperlinks attach-session -t \(quote(session)) || exit; "
                + "tmux has-session -t \(quote(session)) 2>/dev/null && exit \(detachedStatus); exit 0"
            let ssh = "/usr/bin/ssh -tt -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 \"$t\" -- \(quote(remote)); r=$?"
            attach = "t=; case \"$m\" in \(cases) esac; if [ -n \"$t\" ]; then \(ssh); else \(boxdAttach); fi"
        }
        // Detach Terminal holds the loop until Reattach Terminal. A detach
        // from anywhere else leaves the session running: attach again,
        // without using up a try.
        attach += "; \(holdClause(session: session)); [ $r -eq 0 ] && break"
            + "; if [ $r -eq \(detachedStatus) ]; then echo 'Detached, reattaching.'; sleep 1; continue; fi"
        // A missing session counts against the tries, a failed connection
        // only waits a little longer.
        let again = "if [ $r -eq \(noSessionStatus) ]; then n=$((n+1)); sleep 2; else sleep 3; fi"
        guard let readyMarker else {
            return "m=\(fallback); n=0; while [ $n -lt \(attachTries) ]; do \(attach); \(again); done; echo 'Session ended.'"
        }
        // `boxd machine connect` wakes a paused machine, so the pause marker
        // is read before every try, not after: a connect that succeeds takes
        // the machine out of standby and the loop never comes back to look.
        // The machine name is read from the marker on every try as well: a
        // resume may move the session.
        let marker = quote(readyMarker)
        let paused = quote(readyMarker + Self.pausedMarkerSuffix)
        return "for i in $(seq 1 2400); do [ -e \(marker) ] && break; sleep 0.5; done; "
            + "n=0; while [ $n -lt \(attachTries) ]; do "
            + "if [ -e \(paused) ]; then echo 'Machine paused.'; while [ -e \(paused) ]; do sleep 1; done; n=0; fi; "
            + "m=\"$(cat \(marker) 2>/dev/null)\"; [ -n \"$m\" ] || m=\(fallback); "
            + "\(attach); "
            + "if [ -e \(paused) ]; then continue; fi; "
            + "\(again); done; echo 'Session ended.'"
    }

    /// Suffix of the file next to the ready marker that tells the attach loop
    /// the app has the machine paused.
    static let pausedMarkerSuffix = BoxdMachineSupervisor.pausedMarkerSuffix

    /// How many times a session that is not on the machine is tried, 2
    /// seconds and a connect apart, before the terminal gives up on it.
    static let attachTries = 150

    /// The status the shell on the machine reports when the tmux session is
    /// not there, as opposed to tmux ending or the connection dropping.
    static let noSessionStatus = 9

    /// The status the shell on the machine reports when the tmux client
    /// ended cleanly but the session is still there: a detach (`prefix d`,
    /// `tmux detach-client` from elsewhere), not the end of the session.
    static let detachedStatus = 10

    /// The word the shell on the machine prints when tmux exits, followed by
    /// the exit status of tmux.
    static let attachExitSentinel = "KANBAN_TMUX_EXIT"

    /// The Tcl program `expect` runs for one attach. The machine comes in
    /// through `KANBAN_MACHINE`, because `expect -c` takes no arguments. A
    /// prompt that never shows (a machine still resuming) sends the command
    /// after the timeout anyway. The shell on the machine first asks tmux
    /// whether the session exists and reports `noSessionStatus` when it does
    /// not; otherwise it runs tmux, prints the sentinel with the exit status
    /// of tmux (`detachedStatus` when tmux ended cleanly and the session is
    /// still there) and exits. `interact` watches the output for the
    /// sentinel, swallows it, and ends with that status, so a session that
    /// is not there yet is retried a bounded number of times, a detach is
    /// attached again, a session that ended (status 0) ends the terminal,
    /// and a connection that never opens or drops before
    /// the sentinel (status 1) is retried for as long as the terminal is
    /// open. The WINCH trap copies the size of the local pty to the pty of
    /// `connect`, which forwards it to the machine.
    static func expectProgram(boxd: String, session: String) -> String {
        // The status is typed in quotes so the echo of the command, which
        // `interact` sees as well, never matches the sentinel pattern. Only
        // what the shell prints after running it does.
        let attach = " tmux has-session -t \(session) 2>/dev/null || { echo \(attachExitSentinel):\\\"\(noSessionStatus)\\\"; exit; }; "
            + "tmux -u -T hyperlinks attach-session -t \(session) 2>/dev/null; r=$?; "
            + "if test \\$r -eq 0 && tmux has-session -t \(session) 2>/dev/null; then r=\(detachedStatus); fi; "
            + "echo \(attachExitSentinel):\\$r; exit\\r"
        return [
            "set timeout 20",
            "spawn -noecho {\(boxd)} machine connect $env(KANBAN_MACHINE)",
            "trap {stty rows [stty rows] columns [stty columns] < $spawn_out(slave,name)} WINCH",
            "expect -re {\\$ $} {send \"\(attach)\"} timeout {send \"\(attach)\"} eof {exit 1}",
            "interact -o -re {\(attachExitSentinel):([0-9]+)} {exit $interact_out(1,string)} eof {exit 1}",
        ].joined(separator: "; ")
    }

    /// The shell command a terminal runs to reach its tmux session.
    ///
    /// `-T hyperlinks` tells tmux that this client understands OSC 8. Without
    /// it tmux drops the escape and passes on only the label, so a link an
    /// agent writes arrives as ordinary text with no destination behind it.
    /// The flag is probed rather than assumed, because tmux gained it in 3.2
    /// and an older one answers a flag it does not know by refusing to start.
    ///
    /// A detach (`prefix d`, or `tmux detach-client` from another shell)
    /// ends the client with status 0 while the session goes on, so the
    /// client attaches again. A session that is gone, or a client that
    /// fails, ends the terminal. Detach Terminal holds it off the session
    /// until Reattach Terminal (`holdClause`).
    static func attachScript(tmux: String, session: String) -> String {
        let escaped = session.replacingOccurrences(of: "'", with: "'\\''")
        let alive = "'\(tmux)' has-session -t '\(escaped)' 2>/dev/null"
        let attach = { (flags: String) in "'\(tmux)' \(flags)attach-session -t '\(escaped)'" }
        return "for i in $(seq 1 50); do \(alive) && break; sleep 0.1; done;"
            + " while \(alive); do"
            + " if '\(tmux)' -T hyperlinks -V >/dev/null 2>&1;"
            + " then \(attach("-T hyperlinks ")); else \(attach("")); fi; r=$?;"
            + " \(holdClause(session: session));"
            + " [ $r -eq 0 ] && \(alive) || break;"
            + " echo 'Detached, reattaching.'; sleep 1; done; echo 'Session ended.'"
    }

    /// The shell command a terminal runs to show a rush session on an ssh
    /// machine: `rush open <id>` there (`agtop open <id> --solo` on a machine
    /// that has only agtop), over `ssh -tt`, which sizes the remote pty and
    /// follows resizes. It waits for the ready marker of the launch first,
    /// like `remoteAttachScript`, and opens the view again when it is quit
    /// or the connection drops. ssh passes TERM on; COLORTERM it does not,
    /// so it is set on the machine.
    static func remoteRushScript(target: String, id: String, readyMarker: String?) -> String {
        let quote = { (value: String) in "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let remote = "PATH=\"$PATH:/usr/local/bin:$HOME/.local/bin:$HOME/go/bin\" COLORTERM=truecolor; "
            + "export COLORTERM \(RushCliAdapter.copyOnSelectOff); \(RushCliAdapter.remoteOpenScript(id: id))"
        let ssh = "/usr/bin/ssh -tt -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 "
            + "\(quote(target)) -- \(quote(remote))"
        let wait = readyMarker.map { "for i in $(seq 1 2400); do [ -e \(quote($0)) ] && break; sleep 0.5; done; " } ?? ""
        return wait + "while :; do \(ssh); sleep 1; done"
    }

    /// The shell command a terminal runs to show a rush session. The view
    /// shows that one session only, and quitting it leaves the host running,
    /// so it opens again.
    static func rushScript(rush: String?, id: String) -> String {
        guard let rush else { return "echo 'rush is not installed.'" }
        let open = RushCliAdapter.openArguments(executable: rush, id: id)
            .map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            .joined(separator: " ")
        // Copying is asked for with cmd+c here, never by letting go of a drag.
        return "export \(RushCliAdapter.copyOnSelectOff); while :; do \(open); sleep 0.3; done"
    }

    /// The marker that holds a terminal off its tmux session after Detach
    /// Terminal. While the app's client is attached, tmux sizes the window
    /// by it as well; detached, the other clients (a terminal on the machine
    /// itself) get the whole window.
    static func detachMarkerPath(for sessionName: String) -> String {
        NSHomeDirectory() + "/.kanban-code/terminal-detached/" + sessionName
    }

    static func isHeldDetached(_ sessionName: String) -> Bool {
        FileManager.default.fileExists(atPath: detachMarkerPath(for: sessionName))
    }

    /// What the attach loop does after its client ends: while the marker is
    /// there it waits, then it attaches again.
    static func holdClause(session: String) -> String {
        let marker = "'" + detachMarkerPath(for: session).replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "if [ -e \(marker) ]; then echo 'Detached. Reattach Terminal in the card menu attaches again.'; "
            + "while [ -e \(marker) ]; do sleep 1; done; continue; fi"
    }

    /// Detach Terminal: writes the marker, then ends the process in the
    /// foreground of the terminal, which is the tmux client (or the ssh or
    /// expect that carries it). Only this terminal's client goes; other
    /// clients of the session stay attached.
    func detach(_ sessionName: String) {
        let path = Self.detachMarkerPath(for: sessionName)
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let pid = terminals[sessionName]?.foregroundPid, pid > 0 else { return }
        kill(pid, SIGTERM)
        KanbanCodeLog.info("terminal-view", "detach session=\(sessionName) foregroundPid=\(pid)")
    }

    /// Reattach Terminal: the loop waiting on the marker attaches again.
    func reattach(_ sessionName: String) {
        try? FileManager.default.removeItem(atPath: Self.detachMarkerPath(for: sessionName))
        KanbanCodeLog.info("terminal-view", "reattach session=\(sessionName)")
    }

    /// Whether Detach Terminal works for the session: a tmux attach of this
    /// Mac's own, running in a terminal here. A card another master runs and
    /// a rush view have no tmux client here.
    func canDetach(_ sessionName: String) -> Bool {
        startedSessions.contains(sessionName)
            && !RushSessionName.isRush(sessionName)
            && AppServices.peerCard(forSession: sessionName) == nil
    }

    /// Remove and terminate a specific terminal (e.g., when user kills a session).
    /// Freeing the surface ends its process.
    func remove(_ sessionName: String) {
        try? FileManager.default.removeItem(atPath: Self.detachMarkerPath(for: sessionName))
        startedSessions.remove(sessionName)
        ownerWaits[sessionName] = nil
        terminals.removeValue(forKey: sessionName)?.removeFromSuperview()
    }

    /// Check if a terminal exists for this session.
    func has(_ sessionName: String) -> Bool {
        terminals[sessionName] != nil
    }

    func diagnosticSummary() -> String {
        "terminalCache terminals=\(terminals.count) started=\(startedSessions.count)"
    }

    private func logGrowthIfNeeded(trigger: String) {
        let terminalCount = terminals.count
        guard terminalCount >= 8, terminalCount != lastLoggedTerminalCount else { return }
        lastLoggedTerminalCount = terminalCount
        KanbanCodeLog.warn(
            "memory-context",
            "terminalCache grew trigger=\(trigger) terminals=\(terminalCount) started=\(startedSessions.count)"
        )
    }

    /// Focus the terminal for a session directly (bypasses NSViewRepresentable update).
    func focusTerminal(for sessionName: String) {
        guard let terminal = terminals[sessionName] else { return }
        DispatchQueue.main.async {
            terminal.window?.makeFirstResponder(terminal)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak terminal] in
            guard let terminal, terminal.window?.firstResponder !== terminal else { return }
            terminal.window?.makeFirstResponder(terminal)
        }
    }
}

// MARK: - Multi-terminal container (manages all terminals for a card)

/// A single NSViewRepresentable that manages multiple tmux terminal subviews.
/// Uses TerminalCache to persist terminals across drawer close/open cycles.
/// Terminals are created once globally and reparented as needed — never destroyed
/// just because the drawer was toggled.
struct TerminalContainerView: NSViewRepresentable, Equatable {
    /// All tmux session names to show tabs for.
    let sessions: [String]
    /// Which session is currently visible.
    let activeSession: String
    /// When true, the terminal grabs keyboard focus (user clicked a tab).
    /// When false, the terminal is shown but focus stays where it was (keyboard nav, drawer open).
    var grabFocus: Bool = false

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        // Ultra-strict: only sessions matter. grabFocus changes should NOT
        // trigger updateNSView — we handle focus separately.
        lhs.sessions == rhs.sessions
            && lhs.activeSession == rhs.activeSession
    }

    func makeNSView(context: Context) -> TerminalContainerNSView {
        KanbanCodeLog.info("terminal-view", "makeNSView: sessions=\(sessions) active=\(activeSession)")
        let container = TerminalContainerNSView()
        for session in sessions {
            container.ensureTerminal(for: session)
        }
        container.showTerminal(for: activeSession, grabFocus: grabFocus)
        return container
    }

    func updateNSView(_ nsView: TerminalContainerNSView, context: Context) {
        KanbanCodeLog.info("terminal-view", "updateNSView called: sessions=\(sessions) active=\(activeSession) grabFocus=\(grabFocus)")
        // When sessions are empty (terminal not yet created), just clean up and return.
        guard !sessions.isEmpty, !activeSession.isEmpty else {
            nsView.removeTerminalsNotIn([])
            return
        }
        // Add any new sessions (idempotent — reuses cached terminals)
        for session in sessions {
            nsView.ensureTerminal(for: session)
        }
        // Remove terminals that are no longer in the list
        nsView.removeTerminalsNotIn(Set(sessions))
        // Switch visible terminal
        nsView.showTerminal(for: activeSession, grabFocus: grabFocus)
    }

    static func dismantleNSView(_ nsView: TerminalContainerNSView, coordinator: ()) {
        KanbanCodeLog.info("terminal-view", "dismantleNSView — detaching all terminals")
        // Detach terminals from this container but do NOT terminate them.
        // They live on in TerminalCache and will be reparented when the drawer reopens.
        nsView.detachAll()
    }
}

/// AppKit container that owns the terminal views of a card.
/// Uses TerminalCache for process lifecycle — terminal processes survive view teardown.
final class TerminalContainerNSView: NSView {
    private static let terminalPadding: CGFloat = 6

    /// Ordered list of session names managed by this container.
    private var managedSessions: [String] = []
    private(set) var activeSession: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1.0).cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1.0).cgColor
    }

    // MARK: Display changes

    private var displayObservers: [NSObjectProtocol] = []
    private var displayRefreshWork: DispatchWorkItem?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        displayObservers.forEach(NotificationCenter.default.removeObserver)
        displayObservers.removeAll()
        guard let window else { return }
        let center = NotificationCenter.default
        let names: [(Notification.Name, AnyObject?)] = [
            (NSWindow.didChangeBackingPropertiesNotification, window),
            (NSWindow.didChangeScreenNotification, window),
            (NSApplication.didChangeScreenParametersNotification, nil),
        ]
        for (name, object) in names {
            let reason = name.rawValue
            displayObservers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleDisplayRefresh(reason: reason) }
            })
        }
    }

    /// A monitor was attached or detached. The terminal keeps a bitmap drawn
    /// for the old screen and shows it at the wrong size; redrawing in place
    /// does not clear it, but attaching the view again does (that is why
    /// switching cards fixes it). Displays settle over a moment and post
    /// several notifications, so wait for them to stop, then re-attach.
    private func scheduleDisplayRefresh(reason: String) {
        displayRefreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.reattachTerminals(reason: reason) }
        }
        displayRefreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func reattachTerminals(reason: String) {
        guard let window else { return }
        let terminals = subviews.compactMap { $0 as? GhosttySurfaceView }
        guard !terminals.isEmpty else { return }
        let scale = window.backingScaleFactor
        let layerScales = terminals.map { String(format: "%.1f", $0.layer?.contentsScale ?? 0) }
        KanbanCodeLog.info("terminal-layout", "display change (\(reason)): window scale=\(scale) layer scales=\(layerScales) frame=\(window.frame) — re-attaching \(terminals.count) terminal(s)")
        let responder = window.firstResponder
        for terminal in terminals {
            // Moving back into the window runs viewDidChangeBackingProperties,
            // which sets the layer and surface scale.
            terminal.removeFromSuperview()
            addSubview(terminal)
            terminal.needsDisplay = true
        }
        if let responder = responder as? NSView, terminals.contains(where: { $0 === responder }) {
            window.makeFirstResponder(responder)
        }
        needsLayout = true
    }

    /// Ensure a terminal for `sessionName` is attached to this container.
    func ensureTerminal(for sessionName: String) {
        guard !managedSessions.contains(sessionName) else { return }
        let terminal = TerminalCache.shared.terminal(for: sessionName, frame: bounds)
        if terminal.superview !== self {
            terminal.removeFromSuperview()
            addSubview(terminal)
        }
        terminal.isHidden = true
        managedSessions.append(sessionName)
        // The process starts in `layout()`. Selecting another card reuses
        // this container at the same size, so nothing else would ask for a
        // layout and the new card's terminal stayed blank until the
        // container was made again (switching to History and back).
        needsLayout = true
    }

    /// Show only the terminal for `sessionName`, hide all others.
    func showTerminal(for sessionName: String, grabFocus: Bool = false) {
        activeSession = sessionName
        for name in managedSessions {
            let terminal = TerminalCache.shared.terminal(for: name, frame: bounds)
            let isActive = (name == sessionName)
            if terminal.isHidden != !isActive {
                terminal.isHidden = !isActive
            }
            if isActive, grabFocus {
                // Try immediately, then retry after a delay for heavy cards
                // where SwiftUI re-renders steal focus during history loading.
                DispatchQueue.main.async { [weak self] in
                    self?.window?.makeFirstResponder(terminal)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak terminal] in
                    guard let self, let terminal, self.activeSession == sessionName,
                          self.window?.firstResponder !== terminal else { return }
                    self.window?.makeFirstResponder(terminal)
                }
            }
        }
    }

    /// Remove terminals whose session names are not in `keep`.
    func removeTerminalsNotIn(_ keep: Set<String>) {
        let toRemove = managedSessions.filter { !keep.contains($0) }
        for name in toRemove {
            TerminalCache.shared.remove(name)
            managedSessions.removeAll { $0 == name }
        }
    }

    /// Detach all terminals from this container without terminating them.
    func detachAll() {
        for sub in subviews {
            sub.removeFromSuperview()
        }
        managedSessions.removeAll()
        activeSession = nil
    }

    override func layout() {
        super.layout()
        let inset = bounds.insetBy(dx: Self.terminalPadding, dy: Self.terminalPadding)
        guard inset.width > 0, inset.height > 0 else { return }

        for sub in subviews {
            // Only resize if the change is >= 1px to avoid tmux SIGWINCH
            // from sub-pixel layout jitter during background state updates.
            let delta = abs(sub.frame.origin.x - inset.origin.x)
                + abs(sub.frame.origin.y - inset.origin.y)
                + abs(sub.frame.width - inset.width)
                + abs(sub.frame.height - inset.height)
            if delta >= 1.0 {
                KanbanCodeLog.info("terminal-layout", "RESIZE delta=\(String(format: "%.1f", delta))px old=\(sub.frame) new=\(inset) sessions=\(managedSessions)")
                sub.frame = inset
            }
        }

        for name in managedSessions {
            TerminalCache.shared.startProcessIfNeeded(for: name)
        }
    }

}
