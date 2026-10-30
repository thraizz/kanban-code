import Foundation
import SwiftTerm
import Testing

@testable import KanbanCode

@Suite("Terminal URL detector")
struct TerminalURLDetectorTests {
    private func detect(_ text: String, clickOn fragment: String, base: String? = nil) -> TerminalURLDetector.Detection? {
        guard let range = text.range(of: fragment) else {
            Issue.record("fragment not in text: \(fragment)")
            return nil
        }
        let col = text.distance(from: text.startIndex, to: range.lowerBound)
        return TerminalURLDetector.detect(in: text, col: col, githubBaseURL: base)
    }

    @Test("Trailing comma is not part of the URL")
    func trailingComma() {
        let text = "The plan is live: https://nexus.langwatch.ai/wiki/langy-launch-content, with the umbrella story"
        let hit = detect(text, clickOn: "nexus.langwatch.ai")
        #expect(hit?.url == "https://nexus.langwatch.ai/wiki/langy-launch-content")
    }

    @Test("Trailing period is not part of the URL")
    func trailingPeriod() {
        let text = "The PR is up: https://github.com/langwatch/langwatch-saas/pull/769. I'll watch it"
        let hit = detect(text, clickOn: "github.com")
        #expect(hit?.url == "https://github.com/langwatch/langwatch-saas/pull/769")
    }

    @Test("Multiple trailing punctuation characters are stripped")
    func trailingEllipsis() {
        let text = "loading https://example.com/page..."
        let hit = detect(text, clickOn: "example.com")
        #expect(hit?.url == "https://example.com/page")
    }

    @Test("Clicking the trailing comma itself is not a link hit")
    func clickOnComma() {
        let text = "see https://example.com/page, more"
        let hit = detect(text, clickOn: ", more")
        #expect(hit == nil)
    }

    @Test("Interior dots and URL characters survive")
    func interiorPreserved() {
        let text = "docs at https://example.com/a.b/c?x=1&y=2#frag end"
        let hit = detect(text, clickOn: "example.com")
        #expect(hit?.url == "https://example.com/a.b/c?x=1&y=2#frag")
    }

    @Test("Highlight range matches the trimmed URL")
    func highlightRangeTrimmed() {
        let text = "x https://example.com/foo, y"
        guard let hit = detect(text, clickOn: "example.com") else { return }
        let ns = text as NSString
        let highlighted = ns.substring(with: NSRange(location: hit.colStart, length: hit.colEnd - hit.colStart + 1))
        #expect(highlighted == "https://example.com/foo")
    }

    @Test("Bare #123 resolves against the card's GitHub base")
    func bareIssueRef() {
        let text = "fixed in #123 today"
        let hit = detect(text, clickOn: "#123", base: "https://github.com/langwatch/langwatch")
        #expect(hit?.url == "https://github.com/langwatch/langwatch/pull/123")
    }

    @Test("owner/repo#123 resolves without a base")
    func qualifiedIssueRef() {
        let text = "see langwatch/kanban-code#65 for details"
        let hit = detect(text, clickOn: "#65")
        #expect(hit?.url == "https://github.com/langwatch/kanban-code/pull/65")
    }

    /// A sibling repo is usually written on its own, and used to be dead text.
    @Test("repo#123 takes the owner from the card's repo")
    func repoOnlyIssueRef() {
        let text = "Fix is up: kanban-code#6745."
        let hit = detect(text, clickOn: "kanban-code#6745", base: "https://github.com/langwatch/langwatch")
        #expect(hit?.url == "https://github.com/langwatch/kanban-code/pull/6745")
        // The whole reference highlights, not just the number.
        #expect(hit?.colStart == 11)
        #expect(hit?.colEnd == 26)
    }

    @Test("clicking the repo name of repo#123 is a hit too")
    func repoOnlyIssueRefClickedOnName() {
        let text = "shipped scenario#41 today"
        let hit = detect(text, clickOn: "scenario", base: "https://github.com/langwatch/langwatch")
        #expect(hit?.url == "https://github.com/langwatch/scenario/pull/41")
    }

    @Test("repo#123 stays plain text when there is no repo to infer from")
    func repoOnlyIssueRefWithoutBase() {
        let text = "shipped scenario#41 today"
        #expect(detect(text, clickOn: "scenario") == nil)
    }

    /// The lookbehind is what keeps a fragment in a URL from reading as one.
    @Test("a URL fragment is not a reference")
    func urlFragmentIsNotARef() {
        let text = "docs at https://example.com/a#5 end"
        let hit = detect(text, clickOn: "example.com", base: "https://github.com/langwatch/langwatch")
        #expect(hit?.url == "https://example.com/a#5")
    }

    @Test("the owner comes off a repo URL with or without a scheme")
    func ownerParsing() {
        #expect(TerminalURLDetector.owner(of: "https://github.com/langwatch/langwatch") == "langwatch")
        #expect(TerminalURLDetector.owner(of: "github.com/acme/widgets") == "acme")
        #expect(TerminalURLDetector.owner(of: nil) == nil)
        #expect(TerminalURLDetector.owner(of: "langwatch") == nil)
    }
}

@Suite("Terminal hyperlinks")
struct TerminalHyperlinkTests {

    /// A row where every cell of `label` carries `payload`, as a terminal marks
    /// the cells an OSC 8 sequence covers.
    private func row(_ text: String, label: String, payload: String)
        -> (cols: Int, start: Int, end: Int, payloadAt: (Int) -> String?)
    {
        let start = text.distance(from: text.startIndex, to: text.range(of: label)!.lowerBound)
        let end = start + label.count
        return (text.count, start, end, { $0 >= start && $0 < end ? payload : nil })
    }

    @Test("the URL is the half of the payload after the first semicolon")
    func payloadURL() {
        #expect(TerminalURLDetector.hyperlinkURL(from: ";https://example.com/a") == "https://example.com/a")
        #expect(
            TerminalURLDetector.hyperlinkURL(from: "id=7:x=2;https://example.com/a")
                == "https://example.com/a")
    }

    @Test("a URL keeps semicolons of its own")
    func payloadURLWithSemicolons() {
        #expect(
            TerminalURLDetector.hyperlinkURL(from: "id=7;https://example.com/a?b=1;c=2")
                == "https://example.com/a?b=1;c=2")
    }

    @Test("a payload with no URL in it is not a link")
    func payloadWithoutURL() {
        #expect(TerminalURLDetector.hyperlinkURL(from: "id=7") == nil)
        #expect(TerminalURLDetector.hyperlinkURL(from: "id=7;") == nil)
        #expect(TerminalURLDetector.hyperlinkURL(from: "") == nil)
    }

    @Test("a label that looks like nothing still resolves to its destination")
    func labelIsNotAURL() {
        let text = "The ADR is at realtime-voice-gateway-adr for you to comment on."
        let label = row(
            text, label: "realtime-voice-gateway-adr",
            payload: ";https://nexus.langwatch.ai/wiki/realtime-voice-gateway-adr")

        let hit = TerminalURLDetector.hyperlink(
            cols: label.cols, col: label.start + 4, payloadAt: label.payloadAt)

        #expect(hit?.url == "https://nexus.langwatch.ai/wiki/realtime-voice-gateway-adr")
        #expect(hit?.colStart == label.start)
        #expect(hit?.colEnd == label.end - 1)
    }

    @Test("a cell outside the label carries no link")
    func outsideTheLabel() {
        let text = "The ADR is at realtime-voice-gateway-adr for you"
        let label = row(text, label: "realtime-voice-gateway-adr", payload: ";https://example.com/a")

        #expect(
            TerminalURLDetector.hyperlink(
                cols: label.cols, col: label.start - 1, payloadAt: label.payloadAt) == nil)
        #expect(
            TerminalURLDetector.hyperlink(
                cols: label.cols, col: label.end, payloadAt: label.payloadAt) == nil)
    }

    @Test("two links side by side stay apart")
    func adjacentLinks() {
        // "aaabbb": one link over the first three columns, another over the next.
        let payloadAt: (Int) -> String? = { $0 < 3 ? ";https://a.example" : ";https://b.example" }

        let first = TerminalURLDetector.hyperlink(cols: 6, col: 1, payloadAt: payloadAt)
        let second = TerminalURLDetector.hyperlink(cols: 6, col: 4, payloadAt: payloadAt)

        #expect(first?.url == "https://a.example")
        #expect(first?.colStart == 0)
        #expect(first?.colEnd == 2)
        #expect(second?.url == "https://b.example")
        #expect(second?.colStart == 3)
        #expect(second?.colEnd == 5)
    }

    @Test("a link running to either edge of the row stops there")
    func linkAtTheEdges() {
        let hit = TerminalURLDetector.hyperlink(cols: 4, col: 0, payloadAt: { _ in ";https://a.example" })

        #expect(hit?.colStart == 0)
        #expect(hit?.colEnd == 3)
    }

    @Test("a column off the end of the row is not a link")
    func outOfBounds() {
        let payloadAt: (Int) -> String? = { _ in ";https://a.example" }

        #expect(TerminalURLDetector.hyperlink(cols: 4, col: 4, payloadAt: payloadAt) == nil)
        #expect(TerminalURLDetector.hyperlink(cols: 4, col: -1, payloadAt: payloadAt) == nil)
    }
}

/// The tests feed a real `Terminal`. SwiftTerm keeps the OSC 8 payloads in a
/// global atom table with no lock, so two terminals that parse a hyperlink at
/// the same time can crash the process. They run one after the other.
@Suite("Terminal hyperlink parsing", .serialized)
struct TerminalHyperlinkFeedTests {

    /// A terminal that answers nothing, which is all a parsing test needs.
    private final class Mute: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    @Test("an OSC 8 sequence read off the wire resolves back to its URL")
    func readsAFedHyperlink() {
        let terminal = Terminal(delegate: Mute())
        let open = "\u{1b}]8;;https://example.com/adr\u{1b}\\"
        let close = "\u{1b}]8;;\u{1b}\\"
        terminal.feed(text: "The ADR is at \(open)the ADR\(close) for you\n")

        let line = terminal.getLine(row: 0)
        let hit = TerminalURLDetector.hyperlink(
            cols: terminal.cols, col: 16, payloadAt: { line?[$0].getPayload() as? String })

        #expect(hit?.url == "https://example.com/adr")
        #expect(hit?.colStart == 14)
        #expect(hit?.colEnd == 20)
    }

    @Test("text outside the sequence carries no link")
    func plainTextIsNotALink() {
        let terminal = Terminal(delegate: Mute())
        let open = "\u{1b}]8;;https://example.com/adr\u{1b}\\"
        terminal.feed(text: "The ADR is at \(open)the ADR\u{1b}]8;;\u{1b}\\ for you\n")

        let line = terminal.getLine(row: 0)
        let hit = TerminalURLDetector.hyperlink(
            cols: terminal.cols, col: 2, payloadAt: { line?[$0].getPayload() as? String })

        #expect(hit == nil)
    }
}

@MainActor
@Suite("tmux attach command")
struct TmuxAttachScriptTests {

    @Test("the client tells tmux it understands hyperlinks")
    func asksForHyperlinks() {
        let script = TerminalCache.attachScript(tmux: "/opt/tmux", session: "claude-1")

        #expect(script.contains("'/opt/tmux' -T hyperlinks attach-session -t 'claude-1'"))
    }

    @Test("a tmux that does not know the flag still attaches")
    func fallsBackToAPlainAttach() {
        let script = TerminalCache.attachScript(tmux: "/opt/tmux", session: "claude-1")

        #expect(script.contains("'/opt/tmux' -T hyperlinks -V >/dev/null 2>&1"))
        #expect(script.contains("else '/opt/tmux' attach-session -t 'claude-1'"))
    }

    /// A detach (`prefix d`, `tmux detach-client`) ends the client with
    /// status 0 while the session goes on. The terminal attaches again
    /// instead of going dead.
    @Test("a detach attaches again, a session that is gone ends the terminal")
    func reattachesAfterDetach() {
        let script = TerminalCache.attachScript(tmux: "/opt/tmux", session: "claude-1")

        #expect(!script.contains("exec "))
        #expect(script.contains(" while '/opt/tmux' has-session -t 'claude-1' 2>/dev/null; do"))
        #expect(script.contains("fi; r=$?; \(TerminalCache.holdClause(session: "claude-1")); [ $r -eq 0 ] && '/opt/tmux' has-session -t 'claude-1' 2>/dev/null || break;"
            + " echo 'Detached, reattaching.'; sleep 1; done; echo 'Session ended.'"))
    }

    @Test("a quote in the session name cannot break out of the command")
    func escapesTheSessionName() {
        let script = TerminalCache.attachScript(tmux: "/opt/tmux", session: "a'; rm -rf /; '")

        #expect(!script.contains("a'; rm"))
        #expect(script.contains("'a'\\''; rm -rf /; '\\'''"))
    }
}
