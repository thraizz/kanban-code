import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("TerminalLink")
struct TerminalLinkTests {

    @Test("Web and mail links open directly")
    func webAndMail() {
        #expect(TerminalLink.classify("https://github.com/x/y/pull/1") == .open(URL(string: "https://github.com/x/y/pull/1")!))
        #expect(TerminalLink.classify("http://localhost:3000") == .open(URL(string: "http://localhost:3000")!))
        #expect(TerminalLink.classify("mailto:a@b.c") == .open(URL(string: "mailto:a@b.c")!))
    }

    @Test("Malformed web and mail links are refused")
    func malformed() {
        #expect(TerminalLink.classify("https:relative") == .deny)
        #expect(TerminalLink.classify("mailto:") == .deny)
        #expect(TerminalLink.classify("") == .deny)
        #expect(TerminalLink.classify("relative/path.txt") == .deny)
    }

    @Test("Custom schemes need confirmation")
    func customScheme() {
        #expect(TerminalLink.classify("vscode://file/tmp/x") == .confirm(URL(string: "vscode://file/tmp/x")!))
    }

    @Test("Invisible or line-breaking characters are refused")
    func unsafeCharacters() {
        #expect(TerminalLink.classify("https://exa\u{202E}mple.com") == .deny)
        #expect(TerminalLink.classify("https://example.com/\u{0007}") == .deny)
    }

    @Test("Local files open unless they could run code")
    func files() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "terminal-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let text = dir.appending(path: "notes.md")
        try "hi".write(to: text, atomically: true, encoding: .utf8)
        let script = dir.appending(path: "run.command")
        try "echo".write(to: script, atomically: true, encoding: .utf8)
        let exec = dir.appending(path: "tool")
        try "echo".write(to: exec, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exec.path)

        let resolved = text.standardizedFileURL.resolvingSymlinksInPath()
        #expect(TerminalLink.classify(text.path) == .open(resolved))
        #expect(TerminalLink.classify(text.absoluteString) == .open(resolved))
        guard case .open(let opened) = TerminalLink.classify(dir.path) else { Issue.record("directory refused"); return }
        #expect(opened.path == dir.standardizedFileURL.resolvingSymlinksInPath().path)
        #expect(TerminalLink.classify(script.path) == .deny)
        #expect(TerminalLink.classify(exec.path) == .deny)
        #expect(TerminalLink.classify(dir.appending(path: "missing.txt").path) == .deny)
        #expect(TerminalLink.classify("/Applications/Safari.app") == .deny)
        #expect(TerminalLink.classify("file://remote-host/etc/hosts") == .deny)
    }
}
