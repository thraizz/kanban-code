import AppKit
import Darwin
import Foundation
import KanbanCodeCore
import os

/// Lightweight process memory logging for diagnosing leaks after the fact.
///
/// Logs to the normal Kanban Code log when footprint grows meaningfully or
/// crosses a high-water threshold. Disable with `KANBAN_MEMORY_DIAGNOSTICS=0`.
final class MemoryDiagnostics: @unchecked Sendable {
    static let shared = MemoryDiagnostics()

    private struct Snapshot {
        let resident: UInt64
        let footprint: UInt64
        let virtualSize: UInt64
    }

    private struct RelatedProcessSnapshot {
        let label: String
        let pid: pid_t
        let resident: UInt64
        let virtualSize: UInt64
    }

    typealias MainActorMetricProvider = @MainActor @Sendable () -> String

    private let isRunning = OSAllocatedUnfairLock(initialState: false)
    private let checkInterval: TimeInterval = 10
    private let periodicInterval: TimeInterval = 60
    private let growthThreshold: UInt64 = 256 * 1024 * 1024
    private let warningThreshold: UInt64 = 1_024 * 1024 * 1024
    private let criticalThreshold: UInt64 = 4 * 1_024 * 1024 * 1024
    private let artifactInterval: TimeInterval = 600

    private var lastLoggedAt = OSAllocatedUnfairLock(initialState: Date.distantPast)
    private var lastLoggedFootprint = OSAllocatedUnfairLock(initialState: UInt64(0))
    private var lastLoggedTotalResident = OSAllocatedUnfairLock(initialState: UInt64(0))
    private var lastArtifactAt = OSAllocatedUnfairLock(initialState: Date.distantPast)
    private var relatedProcessPIDs = OSAllocatedUnfairLock(initialState: [String: Set<pid_t>]())
    private var mainActorMetricProviders = OSAllocatedUnfairLock(initialState: [String: MainActorMetricProvider]())
    private let pressureSource = OSAllocatedUnfairLock<DispatchSourceMemoryPressure?>(initialState: nil)

    private init() {}

    func start() {
        guard ProcessInfo.processInfo.environment["KANBAN_MEMORY_DIAGNOSTICS"] != "0" else { return }

        let alreadyRunning = isRunning.withLock { running -> Bool in
            if running { return true }
            running = true
            return false
        }
        guard !alreadyRunning else { return }

        if let snapshot = Self.currentSnapshot() {
            lastLoggedFootprint.withLock { $0 = snapshot.footprint }
            lastLoggedTotalResident.withLock { $0 = snapshot.resident }
            log(snapshot, reason: "start")
        }

        // userInitiated, not utility: during heavy swap thrash utility threads
        // can be starved for minutes — exactly the window worth observing.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            while self.isRunning.withLock({ $0 }) {
                Thread.sleep(forTimeInterval: self.checkInterval)
                guard let snapshot = Self.currentSnapshot() else { continue }
                self.logIfNeeded(snapshot)
            }
        }

        startPressureSource()
        startSleepWakeObservers()
    }

    /// Kernel-delivered memory pressure events. Unlike the polling loop these
    /// fire while a balloon inflates even when polling threads are starved,
    /// so the growth gets logged and vmmap'd instead of leaving a blind spot.
    private func startPressureSource() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: DispatchQueue.global(qos: .userInitiated)
        )
        // Capturing `source` in its own handler keeps it alive for the app's
        // lifetime, which is intended — the source is never cancelled.
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let event = DispatchSource.MemoryPressureEvent(rawValue: source.data)
            let level = event.contains(.critical) ? "critical" : "warning"
            guard let snapshot = Self.currentSnapshot() else { return }
            self.log(snapshot, reason: "pressure-\(level)")
            self.logSessionTrees(reason: "pressure-\(level)")
            // A warning fires many times a day on a busy machine, and `vmmap`
            // plus a full `ps` cost the most exactly when memory is short:
            // only a critical event earns the artifacts.
            if level == "critical" {
                self.captureArtifactsIfNeeded(snapshot: snapshot, reason: "pressure-\(level)")
            }
            self.lastLoggedFootprint.withLock { $0 = snapshot.footprint }
        }
        source.activate()
        pressureSource.withLock { $0 = source }
    }

    /// Bracket system sleep and wake with snapshots. Overnight growth is
    /// otherwise invisible: the polling loop freezes with the machine and can
    /// be starved right after wake while everything swaps back in.
    private func startSleepWakeObservers() {
        let center = NSWorkspace.shared.notificationCenter
        let events: [(Notification.Name, String)] = [
            (NSWorkspace.willSleepNotification, "system-sleep"),
            (NSWorkspace.didWakeNotification, "system-wake"),
        ]
        for (name, reason) in events {
            // Tokens are discarded on purpose: the center retains them, and
            // this app-lifetime singleton never unregisters.
            _ = center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                guard let self, let snapshot = Self.currentSnapshot() else { return }
                self.log(snapshot, reason: reason)
            }
        }
    }

    func stop() {
        isRunning.withLock { $0 = false }
    }

    func setRelatedProcessPIDs(label: String, pids: Set<pid_t>) {
        relatedProcessPIDs.withLock { current in
            if pids.isEmpty {
                current.removeValue(forKey: label)
            } else {
                current[label] = pids
            }
        }
    }

    func registerMainActorMetricProvider(name: String, provider: @escaping MainActorMetricProvider) {
        mainActorMetricProviders.withLock { $0[name] = provider }
    }

    // MARK: - Session process-tree attribution

    struct ProcessRecord {
        let pid: Int32
        let ppid: Int32
        let rssKB: Int
        let command: String
    }

    struct SessionTree {
        let session: String
        let rssKB: Int
        let processCount: Int
        let topCommand: String
        let topRssKB: Int
    }

    private static let tmuxPath: String? = ShellCommand.findExecutable("tmux")

    private static func runCapture(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        defer { try? pipe.fileHandleForReading.close() }
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private static func processTable() -> [ProcessRecord] {
        guard let out = runCapture("/bin/ps", ["-axo", "pid=,ppid=,rss=,command="]) else { return [] }
        return out.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 4,
                  let pid = Int32(parts[0]), let ppid = Int32(parts[1]), let rss = Int(parts[2])
            else { return nil }
            return ProcessRecord(pid: pid, ppid: ppid, rssKB: rss, command: parts[3...].joined(separator: " "))
        }
    }

    /// (sessionName, panePid) for every tmux pane on the default server.
    private static func tmuxPaneRoots() -> [(session: String, pid: Int32)] {
        guard let tmux = tmuxPath,
              let out = runCapture(tmux, ["list-panes", "-a", "-F", "#{session_name}\t#{pane_pid}"])
        else { return [] }
        return out.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t")
            guard parts.count == 2, let pid = Int32(parts[1]) else { return nil }
            return (String(parts[0]), pid)
        }
    }

    /// Attribute every tmux session's process subtree RSS, biggest first.
    ///
    /// macOS's out-of-application-memory dialog groups processes by their
    /// "responsible" app, and everything spawned under the cards (tmux server,
    /// claude, compilers, test runners) rolls up to Kanban Code. So when the
    /// dialog blames "Kanban Code" for tens of GB, the real eater is usually a
    /// single runaway process inside one card's tmux session. This names it.
    static func sessionTrees() -> [SessionTree] {
        sessionTrees(table: processTable(), paneRoots: tmuxPaneRoots())
    }

    static func sessionTrees(
        table: [ProcessRecord],
        paneRoots: [(session: String, pid: Int32)]
    ) -> [SessionTree] {
        guard !table.isEmpty, !paneRoots.isEmpty else { return [] }
        var childrenByPPID: [Int32: [ProcessRecord]] = [:]
        for record in table { childrenByPPID[record.ppid, default: []].append(record) }
        let byPid = Dictionary(table.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })

        var totals: [String: (rss: Int, count: Int, top: ProcessRecord?)] = [:]
        for (session, rootPid) in paneRoots {
            var current = totals[session] ?? (0, 0, nil)
            var stack = [rootPid]
            var visited = Set<Int32>()
            while let pid = stack.popLast() {
                guard visited.insert(pid).inserted else { continue }
                if let record = byPid[pid] {
                    current.rss += record.rssKB
                    current.count += 1
                    if record.rssKB > (current.top?.rssKB ?? 0) { current.top = record }
                }
                for child in childrenByPPID[pid] ?? [] { stack.append(child.pid) }
            }
            totals[session] = current
        }
        return totals.map { session, value in
            SessionTree(
                session: session,
                rssKB: value.rss,
                processCount: value.count,
                topCommand: shortCommand(value.top?.command ?? ""),
                topRssKB: value.top?.rssKB ?? 0
            )
        }
        .sorted { $0.rssKB > $1.rssKB }
    }

    static func shortCommand(_ command: String) -> String {
        guard let first = command.split(separator: " ").first else { return command }
        let name = (String(first) as NSString).lastPathComponent
        let rest = command.dropFirst(first.count)
        return String((name + rest).prefix(120))
    }

    /// Log the biggest session trees. Runs at every pressure event; on
    /// periodic ticks only when the biggest tree crosses the threshold, so a
    /// runaway inside a card is named in the log before the system drowns.
    private func logSessionTrees(reason: String, onlyIfTopExceedsKB: Int = 0) {
        let trees = Self.sessionTrees()
        guard let biggest = trees.first, biggest.rssKB >= onlyIfTopExceedsKB else { return }
        let summary = trees.prefix(5).map {
            "\($0.session)=\(Self.format(UInt64($0.rssKB) * 1024)) [\($0.processCount) procs, top: \($0.topCommand) \(Self.format(UInt64($0.topRssKB) * 1024))]"
        }.joined(separator: "; ")
        if onlyIfTopExceedsKB > 0 {
            KanbanCodeLog.warn("memory", "session-trees reason=\(reason) \(summary)")
        } else {
            KanbanCodeLog.info("memory", "session-trees reason=\(reason) \(summary)")
        }
    }

    /// A single tmux session tree beyond this is worth flagging on its own
    /// (the machine may have as little as 18GB total).
    private static let sessionTreeWarnKB = 2 * 1024 * 1024

    private func logIfNeeded(_ snapshot: Snapshot) {
        let previous = lastLoggedFootprint.withLock { $0 }
        let growth = snapshot.footprint > previous ? snapshot.footprint - previous : 0
        let relatedResident = relatedSnapshots().reduce(UInt64(0)) { $0 + $1.resident }
        let totalResident = snapshot.resident + relatedResident
        let previousTotal = lastLoggedTotalResident.withLock { $0 }
        let totalGrowth = totalResident > previousTotal ? totalResident - previousTotal : 0

        let now = Date()
        let periodic = lastLoggedAt.withLock { last -> Bool in
            guard now.timeIntervalSince(last) >= periodicInterval else { return false }
            last = now
            return true
        }

        if snapshot.footprint >= criticalThreshold || totalResident >= criticalThreshold {
            log(snapshot, reason: "critical")
            captureArtifactsIfNeeded(snapshot: snapshot, reason: "critical")
            lastLoggedFootprint.withLock { $0 = snapshot.footprint }
            lastLoggedTotalResident.withLock { $0 = totalResident }
        } else if (snapshot.footprint >= warningThreshold && growth >= growthThreshold)
                    || (totalResident >= warningThreshold && totalGrowth >= growthThreshold) {
            log(snapshot, reason: "growth")
            captureArtifactsIfNeeded(snapshot: snapshot, reason: "growth")
            lastLoggedFootprint.withLock { $0 = snapshot.footprint }
            lastLoggedTotalResident.withLock { $0 = totalResident }
        } else if periodic {
            log(snapshot, reason: "periodic")
            logSessionTrees(reason: "periodic", onlyIfTopExceedsKB: Self.sessionTreeWarnKB)
            lastLoggedFootprint.withLock { $0 = snapshot.footprint }
            lastLoggedTotalResident.withLock { $0 = totalResident }
        }
    }

    private func log(_ snapshot: Snapshot, reason: String) {
        let related = relatedSnapshots()
        let relatedResident = related.reduce(UInt64(0)) { $0 + $1.resident }
        let relatedDetail = related.isEmpty
            ? ""
            : " related=[\(related.map { "\($0.label):pid=\($0.pid),rss=\(Self.format($0.resident)),virtual=\(Self.format($0.virtualSize))" }.joined(separator: ";"))] relatedRSS=\(Self.format(relatedResident)) totalRSS=\(Self.format(snapshot.resident + relatedResident))"
        KanbanCodeLog.info(
            "memory",
            "reason=\(reason) footprint=\(Self.format(snapshot.footprint)) rss=\(Self.format(snapshot.resident)) virtual=\(Self.format(snapshot.virtualSize))\(relatedDetail)"
        )
        logMainActorMetrics(reason: reason)
    }

    private static func currentSnapshot() -> Snapshot? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<natural_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Snapshot(
            resident: UInt64(info.resident_size),
            footprint: UInt64(info.phys_footprint),
            virtualSize: UInt64(info.virtual_size)
        )
    }

    private func relatedSnapshots() -> [RelatedProcessSnapshot] {
        let pidsByLabel = relatedProcessPIDs.withLock { $0 }
        return pidsByLabel.flatMap { label, pids in
            pids.compactMap { Self.processSnapshot(pid: $0, label: label) }
        }
        .sorted { $0.pid < $1.pid }
    }

    private static func processSnapshot(pid: pid_t, label: String) -> RelatedProcessSnapshot? {
        guard pid > 0 else { return nil }
        var info = proc_taskinfo()
        let size = MemoryLayout<proc_taskinfo>.stride
        let result = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, Int32(size))
        guard result == Int32(size) else { return nil }
        return RelatedProcessSnapshot(
            label: label,
            pid: pid,
            resident: UInt64(info.pti_resident_size),
            virtualSize: UInt64(info.pti_virtual_size)
        )
    }

    private func logMainActorMetrics(reason: String) {
        let providers = mainActorMetricProviders.withLock { $0 }
        guard !providers.isEmpty else { return }
        Task { @MainActor in
            let metrics = providers
                .sorted { $0.key < $1.key }
                .map { "\($0.key){\($0.value())}" }
                .joined(separator: " ")
            KanbanCodeLog.info("memory-context", "reason=\(reason) \(metrics)")
        }
    }

    private func captureArtifactsIfNeeded(snapshot: Snapshot, reason: String) {
        let now = Date()
        let shouldCapture = lastArtifactAt.withLock { last -> Bool in
            guard now.timeIntervalSince(last) >= artifactInterval else { return false }
            last = now
            return true
        }
        guard shouldCapture else { return }

        let relatedPIDs = relatedSnapshots().map(\.pid)
        let pids = [ProcessInfo.processInfo.processIdentifier] + relatedPIDs
        let stamp = ISO8601DateFormatter().string(from: now)
            .replacingOccurrences(of: ":", with: "-")
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code/logs/memory-samples")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        runDiagnosticCommand(
            executable: "/bin/ps",
            arguments: ["-o", "pid,ppid,rss,vsz,command", "-p", pids.map(String.init).joined(separator: ",")],
            outputPath: (dir as NSString).appendingPathComponent("memory-\(stamp)-\(reason)-ps.txt")
        )
        // System-wide table sorted by memory. The app has repeatedly been
        // innocent while a session child ate the machine — capture everyone.
        runDiagnosticCommand(
            executable: "/bin/ps",
            arguments: ["axm", "-o", "pid,ppid,rss,vsz,command"],
            outputPath: (dir as NSString).appendingPathComponent("memory-\(stamp)-\(reason)-top.txt")
        )
        DispatchQueue.global(qos: .utility).async {
            let trees = Self.sessionTrees()
            guard !trees.isEmpty else { return }
            let text = trees.map {
                "\($0.session)\t\(Self.format(UInt64($0.rssKB) * 1024))\t\($0.processCount) procs\ttop: \($0.topCommand) \(Self.format(UInt64($0.topRssKB) * 1024))"
            }.joined(separator: "\n") + "\n"
            let path = (dir as NSString).appendingPathComponent("memory-\(stamp)-\(reason)-sessions.txt")
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }
        for pid in pids {
            runDiagnosticCommand(
                executable: "/usr/bin/vmmap",
                arguments: ["-summary", String(pid)],
                outputPath: (dir as NSString).appendingPathComponent("memory-\(stamp)-\(reason)-pid\(pid)-vmmap.txt")
            )
        }
    }

    private func runDiagnosticCommand(executable: String, arguments: [String], outputPath: String) {
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            defer { try? pipe.fileHandleForReading.close() }
            do {
                try process.run()
                // Read first: `vmmap -summary` writes more than a pipe buffer
                // holds, so waiting for exit before draining would hang here for
                // as long as the app runs.
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                try? data.write(to: URL(fileURLWithPath: outputPath))
                KanbanCodeLog.info("memory", "diagnostic artifact written: \(outputPath)")
            } catch {
                KanbanCodeLog.warn("memory", "diagnostic command failed: \(executable) \(arguments.joined(separator: " ")) error=\(error)")
            }
        }
    }

    private static func format(_ bytes: UInt64) -> String {
        let mib = Double(bytes) / 1024 / 1024
        if mib >= 1024 {
            return String(format: "%.2fGiB", mib / 1024)
        }
        return String(format: "%.0fMiB", mib)
    }
}
