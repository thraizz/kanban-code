import Testing
import Foundation
import AppKit
import SwiftTerm

private final class ClipboardRecorder: TerminalViewDelegate {
    var copied: [String] = []
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {
        copied.append(String(decoding: content, as: UTF8.self))
    }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

@Suite("Terminal clipboard")
@MainActor
struct TerminalClipboardTests {
    /// rush draws its own selection and copies it with OSC 52 when a drag
    /// ends. The Mac view has to pass that on to its delegate, which owns
    /// the pasteboard.
    @Test("OSC 52 from the program reaches the view's delegate")
    func osc52Copies() {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let recorder = ClipboardRecorder()
        view.terminalDelegate = recorder
        let payload = Data("selected text".utf8).base64EncodedString()
        view.feed(text: "\u{1b}]52;c;\(payload)\u{07}")
        #expect(recorder.copied == ["selected text"])
    }
}
