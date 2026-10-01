import Testing
import Foundation
import AppKit
import SwiftTerm

/// Micro-benchmark for the CPU draw path: fills a terminal with ~200 rows of
/// colored text and times full redraws. Numbers are printed so before/after
/// runs can be compared; the assertions are deliberately loose.
@Suite("Terminal draw benchmark")
@MainActor
struct TerminalDrawBenchmarkTests {
    private func filledView(rows: Int = 200) -> TerminalView {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        var text = ""
        for i in 0..<rows {
            let c = 31 + (i % 7)
            text += "\u{1b}[\(c)mrow \(i) \u{1b}[1;4;\(c + 60)mcolored\u{1b}[0m \u{1b}[38;2;\(i % 255);120;200mtruecolor text here\u{1b}[0m plain trailing text to fill the line a bit more\r\n"
        }
        view.feed(text: text)
        return view
    }

    private func redraw(_ view: TerminalView, into rep: NSBitmapImageRep) {
        view.cacheDisplay(in: view.bounds, to: rep)
    }

    @Test("Full redraw of a screen of colored rows", .timeLimit(.minutes(2)))
    func fullRedraw() throws {
        let view = filledView()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        redraw(view, into: rep) // warm up fonts / attribute caches
        TerminalDrawStats.shared.reset()
        for _ in 0..<100 { redraw(view, into: rep) }
        let stats = TerminalDrawStats.shared
        print("[bench] full redraw: draws=\(stats.drawCount) p50=\(stats.percentile(0.5) / 1000)us p95=\(stats.p95Nanos / 1000)us")
        #expect(stats.drawCount >= 100)
    }

    @Test("Redraw with a few changing rows (streaming output)", .timeLimit(.minutes(2)))
    func streamingRedraw() throws {
        let view = filledView()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        redraw(view, into: rep)
        TerminalDrawStats.shared.reset()
        for i in 0..<100 {
            view.feed(text: "\u{1b}[3;1H\u{1b}[32mtick \(i)\u{1b}[0m")
            redraw(view, into: rep)
        }
        let stats = TerminalDrawStats.shared
        print("[bench] streaming redraw: draws=\(stats.drawCount) p50=\(stats.percentile(0.5) / 1000)us p95=\(stats.p95Nanos / 1000)us")
        #expect(stats.drawCount >= 100)
    }

    private func pixels(_ view: TerminalView) throws -> Data {
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return Data(bytes: rep.bitmapData!, count: rep.bytesPerRow * rep.pixelsHigh)
    }

    @Test("Cached rows render identically to freshly built rows")
    func cacheIsTransparent() throws {
        let view = filledView(rows: 60)
        let first = try pixels(view)
        let second = try pixels(view) // served from the row cache
        #expect(first == second)
        view.font = view.font // invalidates every cache
        #expect(try pixels(view) == first)
    }

    @Test("A changed row is redrawn, not served stale from the cache")
    func changedRowInvalidates() throws {
        let view = filledView(rows: 60)
        let before = try pixels(view)
        view.feed(text: "\u{1b}[5;1H\u{1b}[7mCHANGED\u{1b}[0m")
        #expect(try pixels(view) != before)
    }

    @Test("Selection changes are reflected despite cached rows")
    func selectionInvalidates() throws {
        let view = filledView(rows: 60)
        let before = try pixels(view)
        view.selectAll(nil)
        #expect(try pixels(view) != before)
        view.selectNone()
        #expect(try pixels(view) == before)
    }

    @Test("A terminal in a hidden window keeps its buffer but does not draw")
    func hiddenTerminalDoesNotDraw() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: true)
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        window.contentView = view // never ordered front: not visible
        let stats = TerminalDrawStats.shared
        stats.reset()
        view.feed(text: "still delivered\r\n")
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        #expect(stats.drawCount == 0)
        #expect(stats.skippedHiddenCount >= 1)
        #expect(view.getTerminal().getLine(row: 0)?.translateToString(trimRight: true) == "still delivered")
    }
}
