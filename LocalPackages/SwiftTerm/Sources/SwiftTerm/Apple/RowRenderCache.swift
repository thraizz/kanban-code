//
//  RowRenderCache.swift
//
//  Caches the styled text built for each terminal row so that unchanged rows
//  are not rebuilt (attributed strings, attribute dictionaries, CTLines) on
//  every draw pass, plus cheap draw-cost instrumentation.
//
#if os(macOS) || os(iOS) || os(visionOS)
import Foundation
import CoreText
import os

/// A glyph run with everything the draw pass needs already extracted from
/// CoreText, so drawing does not have to bridge CTRun attribute dictionaries.
struct PreparedRun {
    let attributes: [NSAttributedString.Key: Any]
    let startColumn: Int
    let endColumn: Int
    let glyphs: [CGGlyph]
    /// Baseline offset of each glyph as reported by CoreText.
    let glyphY: [CGFloat]
    let font: TTFont
    let foregroundCGColor: CGColor?
    let backgroundColor: TTColor?
    /// True if underline or strikethrough has to be drawn for this run.
    let needsRunAttributes: Bool
}

/// A segment together with the glyph runs needed to draw it.
struct PreparedSegment {
    let segment: ViewLineSegment
    let runs: [PreparedRun]
}

/// Everything derived from one buffer row that the draw pass needs.
struct CachedRowRender {
    /// Hash of the row's cells (characters, attributes, widths, link payload presence).
    let contentHash: Int
    let cols: Int
    /// Everything besides the cells that influences how the row is built.
    let context: RowRenderContext
    let info: ViewLineInfo
    let prepared: [PreparedSegment]
}

/// Non-cell state that changes the built row: selection, link highlight,
/// modifier state, renderer options and the cache generation (fonts/colors).
struct RowRenderContext: Hashable {
    var generation: Int
    var selection: Range<Int>?
    var linkModeTag: Int
    var commandActive: Bool
    var highlight: Range<Int>?
    var customBlockGlyphs: Bool
}

final class RowRenderCache {
    private(set) var entries: [Int: CachedRowRender] = [:]
    /// Bumped whenever fonts or colors change; invalidates everything lazily.
    var generation = 0
    /// Keeps memory bounded when scrolling through a long scrollback.
    let maxEntries = 800

    private(set) var hits = 0
    private(set) var misses = 0

    func lookup(row: Int, hash: Int, cols: Int, context: RowRenderContext) -> CachedRowRender? {
        if let e = entries[row], e.contentHash == hash, e.cols == cols, e.context == context {
            hits += 1
            return e
        }
        misses += 1
        return nil
    }

    func store(row: Int, _ entry: CachedRowRender) {
        if entries.count >= maxEntries { entries.removeAll(keepingCapacity: true) }
        entries[row] = entry
    }

    func invalidateAll() {
        generation &+= 1
        entries.removeAll(keepingCapacity: true)
    }

    func resetCounters() { hits = 0; misses = 0 }
}

/// Lightweight draw-time statistics for `TerminalView.draw(_:)`.
///
/// Every draw is wrapped in an os_signpost interval (category "draw") so it
/// shows up in Instruments. Set `SWIFTTERM_DRAW_STATS=1` to also log the
/// count / p50 / p95 / max draw time once per minute.
public final class TerminalDrawStats: @unchecked Sendable {
    public static let shared = TerminalDrawStats()

    static let signposter = OSSignposter(subsystem: "SwiftTerm", category: "draw")
    private static let logger = Logger(subsystem: "SwiftTerm", category: "draw")
    static let loggingEnabled = ProcessInfo.processInfo.environment["SWIFTTERM_DRAW_STATS"] == "1"

    private let lock = NSLock()
    private var samples: [UInt64] = []
    private var lastLog = DispatchTime.now().uptimeNanoseconds
    private var _drawCount = 0
    private var _skippedHidden = 0

    /// Total number of draw passes since launch (or last reset).
    public var drawCount: Int { lock.lock(); defer { lock.unlock() }; return _drawCount }
    /// Number of draw passes skipped because the view was not visible.
    public var skippedHiddenCount: Int { lock.lock(); defer { lock.unlock() }; return _skippedHidden }

    func record(nanos: UInt64) {
        lock.lock()
        _drawCount += 1
        samples.append(nanos)
        if samples.count > 4096 { samples.removeFirst(samples.count - 4096) }
        let now = DispatchTime.now().uptimeNanoseconds
        var report: String?
        if Self.loggingEnabled, now - lastLog > 60_000_000_000 {
            lastLog = now
            report = summaryLocked()
            samples.removeAll(keepingCapacity: true)
        }
        lock.unlock()
        if let report { Self.logger.notice("\(report, privacy: .public)") }
    }

    func recordSkippedHidden() {
        lock.lock(); _skippedHidden += 1; lock.unlock()
    }

    /// p95 draw time in nanoseconds over the retained samples.
    public var p95Nanos: UInt64 { percentile(0.95) }

    public func percentile(_ p: Double) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return percentileLocked(p)
    }

    public func reset() {
        lock.lock(); samples.removeAll(); _drawCount = 0; _skippedHidden = 0; lock.unlock()
    }

    private func percentileLocked(_ p: Double) -> UInt64 {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
    }

    private func summaryLocked() -> String {
        let max = samples.max() ?? 0
        return "[terminal-draw] draws=\(samples.count) p50=\(percentileLocked(0.5) / 1000)us p95=\(percentileLocked(0.95) / 1000)us max=\(max / 1000)us"
    }
}
#endif
