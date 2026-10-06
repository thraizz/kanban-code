import Foundation
#if canImport(os)
import os
#endif

// Performance instrumentation shared by the store and the app target:
// signposts, latency percentiles, the last dispatched action and the
// reconcile phase recorder. Everything here is cheap when nobody looks.

// MARK: - Signposts

/// `OSSignposter`s for Instruments (subsystem com.kanban-code.app). Intervals
/// cost close to nothing while Instruments is not recording; call sites that
/// build metadata should still check `isEnabled` first.
public enum PerfSignposts {
    #if canImport(os)
    public static let store = OSSignposter(subsystem: "com.kanban-code.app", category: "store")
    public static let reconcile = OSSignposter(subsystem: "com.kanban-code.app", category: "reconcile")
    #endif
}

// MARK: - Percentiles

/// Nearest-rank percentile of an unsorted sample set. `p` is in 0...1.
/// Returns 0 for an empty set.
public func latencyPercentile(_ samples: [Double], _ p: Double) -> Double {
    guard !samples.isEmpty else { return 0 }
    let sorted = samples.sorted()
    let rank = Int((p * Double(sorted.count)).rounded(.up))
    return sorted[min(max(rank, 1), sorted.count) - 1]
}

public struct LatencySummary: Sendable, Equatable {
    public let count: Int
    public let p50: Double
    public let p95: Double
    public let max: Double
}

/// Bounded sample buffer (milliseconds). Oldest samples are overwritten.
public struct LatencyRecorder: Sendable {
    public private(set) var samples: [Double] = []
    private var next = 0
    private let capacity: Int

    public init(capacity: Int = 4096) { self.capacity = capacity }

    public mutating func record(_ ms: Double) {
        if samples.count < capacity {
            samples.append(ms)
        } else {
            samples[next] = ms
            next = (next + 1) % capacity
        }
    }

    public func summary() -> LatencySummary? {
        guard !samples.isEmpty else { return nil }
        return LatencySummary(
            count: samples.count,
            p50: latencyPercentile(samples, 0.5),
            p95: latencyPercentile(samples, 0.95),
            max: samples.max() ?? 0
        )
    }

    public mutating func reset() { samples.removeAll(keepingCapacity: true); next = 0 }
}

// MARK: - Latency metrics

/// Input latency and board staleness, logged as `[latency]` lines every 5
/// minutes. Thread-safe; recording is a lock plus an array write.
public final class LatencyMetrics: @unchecked Sendable {
    public static let shared = LatencyMetrics()

    private let lock = NSLock()
    private var input = LatencyRecorder()
    private var staleness = LatencyRecorder()
    /// Uptime (ns) at which each unprocessed hook-event file write was observed.
    private var pendingHookWrites: [UInt64] = []
    private var started = false

    public init() {}

    /// Input latency in ms: input event to the run-loop turn after its commit.
    public func recordInput(ms: Double) {
        lock.lock(); input.record(ms); lock.unlock()
    }

    /// Call when a change to the outside world is observed (hook-events.jsonl written).
    public func hookWriteObserved() {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        if pendingHookWrites.count < 64 { pendingHookWrites.append(now) }
        lock.unlock()
    }

    /// Call when the board has processed the hook events (dispatch finished).
    public func hookWritesApplied() {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        for t in pendingHookWrites { staleness.record(Double(now - t) / 1_000_000) }
        pendingHookWrites.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    /// Formats and clears both recorders. Lines are `input n=… p50=… p95=… max=…`.
    public func flushLines() -> [String] {
        lock.lock()
        let i = input.summary(), s = staleness.summary()
        input.reset(); staleness.reset()
        lock.unlock()
        return [
            Self.format("input", i, targetMs: 16),
            Self.format("staleness", s, targetMs: 200),
        ].compactMap { $0 }
    }

    static func format(_ name: String, _ s: LatencySummary?, targetMs: Double) -> String? {
        guard let s else { return nil }
        return String(
            format: "%@ n=%d p50=%.1fms p95=%.1fms max=%.1fms (target p95<%.0fms)%@",
            name, s.count, s.p50, s.p95, s.max, targetMs, s.p95 > targetMs ? " OVER" : ""
        )
    }

    /// Starts the 5-minute logger (idempotent). The loop never touches the main actor.
    public func startLogging(every interval: Duration = .seconds(300)) {
        lock.lock()
        let already = started
        started = true
        lock.unlock()
        guard !already else { return }
        Task.detached(priority: .utility) { [self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                for line in flushLines() { KanbanCodeLog.info("latency", line) }
            }
        }
    }
}

// MARK: - Last dispatched action

/// Name of the most recent store action, readable from any thread (the
/// watchdog adds it to HANG lines).
public final class LastDispatchedAction: @unchecked Sendable {
    public static let shared = LastDispatchedAction()
    private let lock = NSLock()
    private var name = "none"
    private var at: UInt64 = 0

    public func set(_ name: String) {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock(); self.name = name; at = now; lock.unlock()
    }

    /// The action name and how long ago (ms) it was dispatched.
    public func get() -> (name: String, ageMs: Double) {
        lock.lock(); defer { lock.unlock() }
        guard at > 0 else { return (name, 0) }
        return (name, Double(DispatchTime.now().uptimeNanoseconds - at) / 1_000_000)
    }
}

// MARK: - Reconcile phases

/// Times the phases of one reconcile pass: a signpost interval and a
/// `[reconcile]` log line each, plus a coverage line at the end so a gap
/// between the phases and TOTAL is visible. Main-actor use only.
public final class ReconcilePhases {
    public struct Token {
        let name: String
        let start: ContinuousClock.Instant
        #if canImport(os)
        let state: OSSignpostIntervalState
        #endif
    }

    private let passStart: ContinuousClock.Instant
    private var covered: Duration = .zero

    public init(start: ContinuousClock.Instant) { passStart = start }

    public func begin(_ name: StaticString) -> Token {
        #if canImport(os)
        let sp = PerfSignposts.reconcile
        let state = sp.beginInterval(name, id: sp.makeSignpostID())
        return Token(name: "\(name)", start: .now, state: state)
        #else
        return Token(name: "\(name)", start: .now)
        #endif
    }

    /// Ends the phase, logs `[reconcile] <name>: <duration> (<detail>)`.
    public func end(_ token: Token, _ name: StaticString, detail: String = "") {
        let d = token.start.duration(to: .now)
        covered += d
        #if canImport(os)
        PerfSignposts.reconcile.endInterval(name, token.state)
        #endif
        KanbanCodeLog.info("reconcile", "\(token.name): \(d)\(detail.isEmpty ? "" : " (\(detail))")")
    }

    /// Time to leave the main actor and come back: large when the main
    /// thread is busy with something else.
    public func probeMainActorHop() async {
        let t = begin("mainActorHop")
        await Self.hop()
        end(t, "mainActorHop")
    }

    private nonisolated static func hop() async {}

    public func logTotal() {
        let total = passStart.duration(to: .now)
        let totalSec = Self.seconds(total)
        let coveredSec = Self.seconds(covered)
        let pct = totalSec > 0 ? min(100, coveredSec / totalSec * 100) : 100
        KanbanCodeLog.info("reconcile", "TOTAL: \(total)")
        KanbanCodeLog.info("reconcile", String(
            format: "coverage: %.1f%% of TOTAL in logged phases (unaccounted %.0fms)",
            pct, max(0, totalSec - coveredSec) * 1000
        ))
    }

    private static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
}

// MARK: - Sample summary

public enum SampleSummary {
    /// Heaviest main-thread frames in `sample` output that belong to `module`.
    /// Lines look like `    + ! : 12 symbol  (in Module) + 123  [0x...]`.
    public static func topAppFrames(sampleText: String, module: String, limit: Int = 5) -> [String] {
        var inMain = false
        var counts: [String: Int] = [:]
        var order: [String] = []
        let marker = "(in \(module))"
        for raw in sampleText.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("Total number in stack") || line.hasPrefix("Sort by top of stack") { break }
            if line.contains("Thread_") {
                inMain = line.contains("com.apple.main-thread")
                continue
            }
            guard inMain, let r = line.range(of: marker) else { continue }
            let head = line[..<r.lowerBound].trimmingCharacters(in: CharacterSet(charactersIn: " +!:|"))
            let parts = head.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let n = Int(parts[0]) else { continue }
            let symbol = String(parts[1]).trimmingCharacters(in: .whitespaces)
            if counts[symbol] == nil { order.append(symbol) }
            counts[symbol] = max(counts[symbol] ?? 0, n)
        }
        return Array(order.sorted { (counts[$0] ?? 0) > (counts[$1] ?? 0) }.prefix(limit))
    }
}
