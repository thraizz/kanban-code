import Testing
import Foundation
import SwiftTerm

private final class NullTerminalDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}

@Suite("Terminal scroll regions")
struct TerminalScrollRegionTests {
    private func screen(after sequence: String) -> [String] {
        let terminal = Terminal(delegate: NullTerminalDelegate(), options: TerminalOptions(cols: 20, rows: 10))
        var text = "\u{1b}[?1049h"
        for row in 1...10 { text += "\u{1b}[\(row);1Hrow\(row)" }
        terminal.feed(text: text + sequence)
        return (0..<10).map { terminal.getLine(row: $0)?.translateToString(trimRight: true) ?? "" }
    }

    /// rush scrolls its transcript with a region and SD (`CSI Ps T`);
    /// every column of the region moves, not only the first.
    @Test("Scroll down moves whole lines inside the region")
    func scrollDownInRegion() {
        let rows = screen(after: "\u{1b}[3;8r\u{1b}[3;1H\u{1b}[2T\u{1b}[1;10r")
        #expect(rows == ["row1", "row2", "", "", "row3", "row4", "row5", "row6", "row9", "row10"])
    }

    @Test("Scroll up moves whole lines inside the region")
    func scrollUpInRegion() {
        let rows = screen(after: "\u{1b}[3;8r\u{1b}[3;1H\u{1b}[2S\u{1b}[1;10r")
        #expect(rows == ["row1", "row2", "row5", "row6", "row7", "row8", "", "", "row9", "row10"])
    }
}
