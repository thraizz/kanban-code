import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("Perf measurement")
struct PerfMeasurementTests {
    @Test("percentile uses nearest rank")
    func percentiles() {
        let samples = (1...100).map(Double.init)
        #expect(latencyPercentile(samples, 0.5) == 50)
        #expect(latencyPercentile(samples, 0.95) == 95)
        #expect(latencyPercentile(samples, 1.0) == 100)
        #expect(latencyPercentile([], 0.5) == 0)
        #expect(latencyPercentile([7], 0.95) == 7)
        #expect(latencyPercentile([5, 1, 3], 0.5) == 3)  // unsorted input
    }

    @Test("recorder summary and ring-buffer overwrite")
    func recorder() {
        var r = LatencyRecorder(capacity: 4)
        #expect(r.summary() == nil)
        for v in [1.0, 2, 3, 4] { r.record(v) }
        #expect(r.summary() == LatencySummary(count: 4, p50: 2, p95: 4, max: 4))
        r.record(100)  // overwrites the oldest (1)
        let s = r.summary()
        #expect(s?.count == 4)
        #expect(s?.max == 100)
        r.reset()
        #expect(r.summary() == nil)
    }

    @Test("metrics format input and staleness lines, then clear")
    func metricsLines() {
        let m = LatencyMetrics()
        #expect(m.flushLines().isEmpty)
        m.recordInput(ms: 4)
        m.recordInput(ms: 30)
        m.hookWriteObserved()
        m.hookWritesApplied()
        let lines = m.flushLines()
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("input n=2 "))
        #expect(lines[0].contains("OVER"))  // p95 30ms > 16ms target
        #expect(lines[1].hasPrefix("staleness n=1 "))
        #expect(m.flushLines().isEmpty)
    }

    @Test("last dispatched action is kept")
    func lastAction() {
        LastDispatchedAction.shared.set("reconciled")
        #expect(LastDispatchedAction.shared.get().name == "reconciled")
    }

    @Test("sample summary lists the heaviest app frames of the main thread")
    func sampleSummary() {
        let text = """
        Call graph:
            800 Thread_1   DispatchQueue_1: com.apple.main-thread  (serial)
            + 800 start  (in dyld) + 1  [0x1]
            +   790 AppMain  (in KanbanCode) + 10  [0x2]
            +   ! 700 Reducer.reduce  (in KanbanCode) + 5  [0x3]
            +   ! : 650 rebuildCards  (in KanbanCode) + 5  [0x4]
            +   ! : 40 swift_retain  (in libswiftCore.dylib) + 5  [0x5]
            800 Thread_2: com.apple.root.utility-qos
            + 500 otherThreadWork  (in KanbanCode) + 5  [0x6]
        Total number in stack (recursive counted multiple, when >=5):
        """
        let top = SampleSummary.topAppFrames(sampleText: text, module: "KanbanCode", limit: 5)
        #expect(top == ["AppMain", "Reducer.reduce", "rebuildCards"])
    }

    // MARK: - Reconcile reducer benchmark

    /// Budget for one `.reconciled` reduce on 1140 links / 827 sessions.
    /// Release builds must stay under 5ms (the spec); debug builds are 10-20x
    /// slower, so they get a generous bound that still catches accidental
    /// O(n^2) regressions. Run `swift test -c release` for the strict check.
    static let budgetMs: Double = {
        #if DEBUG
        return 50
        #else
        return 5
        #endif
    }()

    @Test("reconciled reducer stays within budget on 1140 links / 827 sessions")
    func reconcileReducerBenchmark() {
        let linkCount = 1140, sessionCount = 827
        let sessions = (0..<sessionCount).map { i in
            Session(id: "sess-\(i)", name: "Session \(i)", projectPath: "/Users/me/proj\(i % 20)",
                    gitBranch: "feature/\(i)", messageCount: i,
                    modifiedTime: Date(timeIntervalSince1970: 1_700_000_000 + Double(i)))
        }
        let links = (0..<linkCount).map { i -> Link in
            Link(
                id: "card-\(i)", name: "Card \(i)", projectPath: "/Users/me/proj\(i % 20)",
                column: i % 7 == 0 ? .inProgress : .allSessions,
                source: .discovered,
                sessionLink: i < sessionCount ? SessionLink(sessionId: "sess-\(i)") : nil,
                tmuxLink: i % 25 == 0 ? TmuxLink(sessionName: "tmux-\(i)") : nil
            )
        }
        let state = AppState()
        for link in links { state.links[link.id] = link }
        let result = ReconciliationResult(
            links: links, sessions: sessions,
            activityMap: Dictionary(uniqueKeysWithValues: sessions.prefix(40).map { ($0.id, ActivityState.activelyWorking) }),
            tmuxSessions: Set((0..<46).map { "tmux-\($0 * 25)" })
        )
        // Warm up: the first pass builds the board; later passes are the steady state.
        _ = Reducer.reduce(state: state, action: .reconciled(result))

        var timings: [Double] = []
        for _ in 0..<9 {
            let t = DispatchTime.now().uptimeNanoseconds
            _ = Reducer.reduce(state: state, action: .reconciled(result))
            timings.append(Double(DispatchTime.now().uptimeNanoseconds - t) / 1_000_000)
        }
        let median = latencyPercentile(timings, 0.5)
        print(String(format: "reconcile reducer benchmark: median %.2fms (budget %.0fms), max %.2fms",
                     median, Self.budgetMs, timings.max() ?? 0))
        #expect(median < Self.budgetMs, "reconciled reduce median \(median)ms exceeds \(Self.budgetMs)ms")
    }
}
