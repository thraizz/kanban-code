import AppKit
import Foundation
import KanbanCodeCore
import QuartzCore
import os

/// Detects main thread hangs by pinging from a background thread.
/// Logs any hang > threshold to ~/.kanban-code/logs/main-thread-hangs.log
/// Enabled by default; set KANBAN_WATCHDOG=0 to disable.
///
/// Timeline of one stall: at 250ms a `sample` of the main thread is started
/// right away (so the stack is captured while the hang is happening, not after
/// it), more samples follow while it lasts, and only a stall past 500ms counts
/// as a HANG. A stall while a modal panel/alert runs is ignored entirely.
final class MainThreadWatchdog: @unchecked Sendable {
    static let shared = MainThreadWatchdog()

    private let checkInterval: TimeInterval = 0.1
    private let minLogInterval: TimeInterval = 10
    private let minSampleInterval: TimeInterval = 300
    /// Stall length that starts a stack capture.
    private let sampleThreshold: TimeInterval = 0.25
    /// Stall length that counts as a hang.
    private let hangThreshold: TimeInterval = 0.5
    private let maxSamplesPerHang = 3
    private let modalDepth = os.OSAllocatedUnfairLock(initialState: 0)
    private let modalWindowUp = os.OSAllocatedUnfairLock(initialState: false)
    private let maxSampleFiles = 40
    private let maxSampleBytes: UInt64 = 250 * 1024 * 1024
    private let _isRunning = os.OSAllocatedUnfairLock(initialState: false)
    private let isSampling = os.OSAllocatedUnfairLock(initialState: false)
    private let lastLogTime = os.OSAllocatedUnfairLock(initialState: Date.distantPast)
    private let lastSampleTime = os.OSAllocatedUnfairLock(initialState: Date.distantPast)
    private let logPath: String
    private let samplesDir: String
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private init() {
        let logsDir = (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code/logs")
        try? FileManager.default.createDirectory(atPath: logsDir, withIntermediateDirectories: true)
        logPath = (logsDir as NSString).appendingPathComponent("main-thread-hangs.log")
        samplesDir = (logsDir as NSString).appendingPathComponent("main-thread-samples")
        try? FileManager.default.createDirectory(atPath: samplesDir, withIntermediateDirectories: true)
        pruneSamples()
    }

    func start() {
        guard ProcessInfo.processInfo.environment["KANBAN_WATCHDOG"] != "0" else { return }

        let alreadyRunning = _isRunning.withLock { val -> Bool in
            if val { return true }
            val = true
            return false
        }
        guard !alreadyRunning else { return }
        log("WATCHDOG START pid=\(ProcessInfo.processInfo.processIdentifier)")
        installModalTracking()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            var stats = StallStats()

            while self._isRunning.withLock({ $0 }) {
                let semaphore = DispatchSemaphore(value: 0)
                let pingTime = CACurrentMediaTime()

                DispatchQueue.main.async {
                    semaphore.signal()
                }

                var modalSeen = false
                if semaphore.wait(timeout: .now() + self.sampleThreshold) == .timedOut {
                    modalSeen = self.isModal()
                    var samples = 0
                    if !modalSeen {
                        self.captureSample(reason: "stall", force: false)
                        samples = 1
                    }
                    var counted = false
                    while semaphore.wait(timeout: .now() + 0.05) == .timedOut {
                        modalSeen = modalSeen || self.isModal()
                        if modalSeen { continue }
                        let elapsed = CACurrentMediaTime() - pingTime
                        if elapsed > self.hangThreshold && !counted {
                            counted = true
                            let last = LastDispatchedAction.shared.get()
                            self.logThrottled(String(
                                format: "HANG: main thread blocked for >500ms at %.3f lastAction=%@ (%.0fms before the stall)",
                                pingTime, last.name, last.ageMs
                            ))
                        }
                        if samples < self.maxSamplesPerHang {
                            // Keep capturing while the hang lasts; a running sample defers this.
                            if self.captureSample(reason: "stall", force: true) { samples += 1 }
                        }
                    }
                    if counted && !modalSeen {
                        let elapsed = CACurrentMediaTime() - pingTime
                        self.log(String(
                            format: "HANG END: main thread was blocked for %.0fms lastAction=%@",
                            elapsed * 1000, LastDispatchedAction.shared.get().name
                        ))
                    }
                }
                if modalSeen {
                    // A modal panel/alert owns the main thread: neither a hang nor a stall stat.
                    Thread.sleep(forTimeInterval: self.checkInterval)
                    continue
                }
                stats.record(CACurrentMediaTime() - pingTime)
                if let line = stats.flushIfDue(now: CACurrentMediaTime()) {
                    self.log(line)
                }

                Thread.sleep(forTimeInterval: self.checkInterval)
            }
        }
    }

    /// Per-minute counts of main-thread stalls, as seen by the pings.
    private struct StallStats {
        var windowStart = CACurrentMediaTime()
        var pings = 0
        var over50 = 0
        var over100 = 0
        var over250 = 0
        var over500 = 0
        var maxStall: Double = 0

        mutating func record(_ elapsed: Double) {
            pings += 1
            if elapsed > 0.05 { over50 += 1 }
            if elapsed > 0.1 { over100 += 1 }
            if elapsed > 0.25 { over250 += 1 }
            if elapsed > 0.5 { over500 += 1 }
            maxStall = max(maxStall, elapsed)
        }

        mutating func flushIfDue(now: Double) -> String? {
            guard now - windowStart >= 60 else { return nil }
            let line = String(
                format: "STATS %.0fs pings=%d >50ms=%d >100ms=%d >250ms=%d >500ms=%d max=%.0fms",
                now - windowStart, pings, over50, over100, over250, over500, maxStall * 1000
            )
            self = StallStats(windowStart: now)
            return line
        }
    }

    /// True while the main thread is inside a modal session (NSOpenPanel,
    /// NSSavePanel, NSAlert.runModal, app-modal windows). Safe from any thread.
    private func isModal() -> Bool {
        modalDepth.withLock { $0 > 0 } || modalWindowUp.withLock { $0 }
    }

    /// Tracks modal sessions without touching AppKit from the watchdog thread:
    /// a main run-loop observer counts entries into the modal-panel mode, and
    /// key-window changes refresh `NSApp.modalWindow != nil`.
    private func installModalTracking() {
        Self.addModalObserver(watchdog: self)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let center = NotificationCenter.default
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                         NSApplication.didBecomeActiveNotification] {
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    let up = NSApp.modalWindow != nil
                    self?.modalWindowUp.withLock { $0 = up }
                }
            }
        }
    }

    /// Nonisolated so the run-loop callback does not inherit main-actor isolation.
    private nonisolated static func addModalObserver(watchdog: MainThreadWatchdog) {
        let activities = CFRunLoopActivity.entry.rawValue | CFRunLoopActivity.exit.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, activities, true, 0) { _, activity in
            guard let mode = CFRunLoopCopyCurrentMode(CFRunLoopGetCurrent()) else { return }
            guard (mode.rawValue as String) == "NSModalPanelRunLoopMode" else { return }
            let entering = activity.contains(.entry)
            watchdog.modalDepth.withLock { $0 = max(0, $0 + (entering ? 1 : -1)) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    func stop() {
        _isRunning.withLock { $0 = false }
    }

    private func log(_ message: String) {
        let timestamp = formatter.string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        if let data = line.data(using: .utf8) {
            do {
                let url = URL(fileURLWithPath: logPath)
                if !FileManager.default.fileExists(atPath: logPath) {
                    FileManager.default.createFile(atPath: logPath, contents: nil)
                }
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                // Diagnostic logging must never make an existing hang worse.
            }
        }
    }

    private func logThrottled(_ message: String) {
        let shouldLog = lastLogTime.withLock { last -> Bool in
            let now = Date()
            guard now.timeIntervalSince(last) >= minLogInterval else { return false }
            last = now
            return true
        }
        if shouldLog {
            log(message)
            KanbanCodeLog.warn("main-thread", message)
        }
    }

    /// Starts a 1s `sample` of this process. Returns false when one is already
    /// running or the 5-minute throttle holds (`force` skips the throttle, used
    /// for follow-up samples of a hang already being captured).
    @discardableResult
    private func captureSample(reason: String, force: Bool) -> Bool {
        let startedSampling = isSampling.withLock { sampling -> Bool in
            guard !sampling else { return false }
            sampling = true
            return true
        }
        guard startedSampling else { return false }

        let shouldSample = lastSampleTime.withLock { last -> Bool in
            let now = Date()
            guard force || now.timeIntervalSince(last) >= minSampleInterval else { return false }
            last = now
            return true
        }
        guard shouldSample else {
            isSampling.withLock { $0 = false }
            return false
        }

        let pid = String(ProcessInfo.processInfo.processIdentifier)
        let stamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        let samplePath = (samplesDir as NSString).appendingPathComponent(
            "main-thread-\(reason)-\(stamp)-pid\(pid).sample.txt"
        )
        log("SAMPLE START reason=\(reason) path=\(samplePath)")

        DispatchQueue.global(qos: .utility).async { [samplePath] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
            process.arguments = [pid, "1", "-file", samplePath]
            process.standardOutput = nil
            process.standardError = nil
            process.terminationHandler = { proc in
                self.log("SAMPLE END status=\(proc.terminationStatus) path=\(samplePath)")
                self.logSampleSummary(path: samplePath)
                self.pruneSamples()
                self.isSampling.withLock { $0 = false }
            }
            do {
                try process.run()
            } catch {
                self.log("SAMPLE FAILED error=\(error) path=\(samplePath)")
                self.isSampling.withLock { $0 = false }
            }
        }
        return true
    }

    /// Writes the top app frames of the main thread so a hang is readable
    /// without opening the sample file.
    private func logSampleSummary(path: String) {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        let frames = SampleSummary.topAppFrames(sampleText: text, module: "KanbanCode", limit: 5)
        let last = LastDispatchedAction.shared.get()
        let line = "SAMPLE SUMMARY top5=[\(frames.joined(separator: " | "))] lastAction=\(last.name)"
        log(line)
        KanbanCodeLog.warn("main-thread", line)
    }

    private func pruneSamples() {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: URL(fileURLWithPath: samplesDir),
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let files = urls.compactMap { url -> (url: URL, date: Date, size: UInt64)? in
            guard url.pathExtension == "txt",
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            else { return nil }
            return (
                url,
                values.contentModificationDate ?? .distantPast,
                UInt64(values.fileSize ?? 0)
            )
        }
        .sorted { $0.date > $1.date }

        var totalBytes: UInt64 = 0
        for (index, file) in files.enumerated() {
            totalBytes += file.size
            if index >= maxSampleFiles || totalBytes > maxSampleBytes {
                try? fm.removeItem(at: file.url)
            }
        }
    }
}
