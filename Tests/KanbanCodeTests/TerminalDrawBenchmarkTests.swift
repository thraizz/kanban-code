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
}
