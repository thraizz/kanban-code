import Foundation
import Testing

@testable import KanbanCode

@Suite("GitHub issue references")
struct GitHubIssueRefTests {
    private let base = "https://github.com/langwatch/langwatch"

    @Test("Bare #123 resolves against the card's GitHub base")
    func bareIssueRef() {
        #expect(GitHubIssueRef.resolve("#123", githubBaseURL: base) == "https://github.com/langwatch/langwatch/pull/123")
        #expect(GitHubIssueRef.resolve("#123", githubBaseURL: nil) == nil)
    }

    @Test("owner/repo#123 resolves without a base")
    func qualifiedIssueRef() {
        #expect(GitHubIssueRef.resolve("langwatch/kanban-code#65", githubBaseURL: nil)
            == "https://github.com/langwatch/kanban-code/pull/65")
    }

    /// A sibling repo is usually written on its own, and used to be dead text.
    @Test("repo#123 takes the owner from the card's repo")
    func repoOnlyIssueRef() {
        #expect(GitHubIssueRef.resolve("kanban-code#6745", githubBaseURL: base)
            == "https://github.com/langwatch/kanban-code/pull/6745")
    }

    @Test("repo#123 stays plain text when there is no repo to infer from")
    func repoOnlyIssueRefWithoutBase() {
        #expect(GitHubIssueRef.resolve("scenario#41", githubBaseURL: nil) == nil)
    }

    @Test("a reference without a number is not one")
    func notANumber() {
        #expect(GitHubIssueRef.resolve("#abc", githubBaseURL: base) == nil)
        #expect(GitHubIssueRef.resolve("scenario", githubBaseURL: base) == nil)
    }

    @Test("a reference already inside a markdown link is left alone")
    func markdownPatternSkipsLinks() throws {
        let regex = try NSRegularExpression(pattern: GitHubIssueRef.markdownPattern)
        func refs(_ text: String) -> [String] {
            let ns = text as NSString
            return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
                .map { ns.substring(with: $0.range) }
        }
        #expect(refs("fixed in #123 and scenario#41") == ["#123", "scenario#41"])
        #expect(refs("see [#12](https://github.com/a/b/pull/12)").isEmpty)
    }

    @Test("the owner comes off a repo URL with or without a scheme")
    func ownerParsing() {
        #expect(GitHubIssueRef.owner(of: "https://github.com/langwatch/langwatch") == "langwatch")
        #expect(GitHubIssueRef.owner(of: "github.com/acme/widgets") == "acme")
        #expect(GitHubIssueRef.owner(of: nil) == nil)
        #expect(GitHubIssueRef.owner(of: "langwatch") == nil)
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
