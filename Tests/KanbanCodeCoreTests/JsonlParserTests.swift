import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("JsonlParser")
struct JsonlParserTests {
    func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "kanban-code-jsonl-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    func cleanup(_ dir: String) {
        try? FileManager.default.removeItem(atPath: dir)
    }

    func writeJsonl(_ dir: String, _ name: String, _ lines: [String]) throws -> String {
        let path = (dir as NSString).appendingPathComponent(name)
        try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    @Test("Extracts metadata from a simple session")
    func simpleSession() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let path = try writeJsonl(dir, "abc-123.jsonl", [
            #"{"type":"user","sessionId":"abc-123","message":{"content":"Fix the login bug"},"cwd":"/Users/test/project","timestamp":"2026-01-01T00:00:00Z"}"#,
            #"{"type":"assistant","sessionId":"abc-123","message":{"content":[{"type":"text","text":"I'll fix that."}]}}"#,
        ])

        let metadata = try await JsonlParser.extractMetadata(from: path)
        #expect(metadata != nil)
        #expect(metadata?.sessionId == "abc-123")
        #expect(metadata?.firstPrompt == "Fix the login bug")
        #expect(metadata?.projectPath == "/Users/test/project")
        #expect(metadata?.messageCount == 2)
    }

    @Test("Handles content block array format")
    func contentBlocks() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let path = try writeJsonl(dir, "block-1.jsonl", [
            #"{"type":"user","sessionId":"block-1","message":{"content":[{"type":"text","text":"Hello world"}]},"cwd":"/test"}"#,
        ])

        let metadata = try await JsonlParser.extractMetadata(from: path)
        #expect(metadata?.firstPrompt == "Hello world")
    }

    @Test("Skips file-history-snapshot lines")
    func skipsNonMessageLines() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let path = try writeJsonl(dir, "skip-1.jsonl", [
            #"{"type":"file-history-snapshot","data":"lots of stuff"}"#,
            #"{"type":"user","sessionId":"skip-1","message":{"content":"The real message"},"cwd":"/test"}"#,
        ])

        let metadata = try await JsonlParser.extractMetadata(from: path)
        #expect(metadata != nil)
        #expect(metadata?.firstPrompt == "The real message")
        #expect(metadata?.messageCount == 1)
    }

    @Test("Returns nil for empty file")
    func emptyFile() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let path = try writeJsonl(dir, "empty.jsonl", [""])
        let metadata = try await JsonlParser.extractMetadata(from: path)
        #expect(metadata == nil)
    }

    @Test("Returns nil for file with only system lines")
    func systemOnly() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let path = try writeJsonl(dir, "sys.jsonl", [
            #"{"type":"file-history-snapshot","data":"stuff"}"#,
            #"{"type":"progress","data":"loading"}"#,
        ])

        let metadata = try await JsonlParser.extractMetadata(from: path)
        #expect(metadata == nil)
    }

    @Test("Returns nil for nonexistent file")
    func nonexistent() async throws {
        let metadata = try await JsonlParser.extractMetadata(from: "/nonexistent/path.jsonl")
        #expect(metadata == nil)
    }

    @Test("Decode directory name to path")
    func decodeDirectoryName() {
        let decoded = JsonlParser.decodeDirectoryName("-Users-rchaves-Projects-remote-langwatch")
        #expect(decoded == "/Users/rchaves/Projects/remote/langwatch")
    }

    @Test("Decode directory name preserves root slash")
    func decodeDirectoryNameRoot() {
        let decoded = JsonlParser.decodeDirectoryName("-home-ubuntu-Projects")
        #expect(decoded == "/home/ubuntu/Projects")
    }

    // MARK: - Metadata filtering

    @Test("Skips isMeta caveat messages for first prompt")
    func skipsCaveatForPrompt() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let path = try writeJsonl(dir, "meta-1.jsonl", [
            #"{"type":"user","isMeta":true,"sessionId":"m1","message":{"content":"<local-command-caveat>wrapped</local-command-caveat>"},"cwd":"/test"}"#,
            #"{"type":"user","sessionId":"m1","message":{"content":"The real prompt"},"cwd":"/test"}"#,
            #"{"type":"assistant","sessionId":"m1","message":{"content":[{"type":"text","text":"OK"}]}}"#,
        ])

        let metadata = try await JsonlParser.extractMetadata(from: path)
        #expect(metadata?.firstPrompt == "The real prompt")
    }

    @Test("Skips command-name messages for first prompt")
    func skipsCommandForPrompt() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let path = try writeJsonl(dir, "meta-2.jsonl", [
            #"{"type":"user","sessionId":"m2","message":{"content":"<command-name>/clear</command-name><command-message></command-message><command-args></command-args>"},"cwd":"/test"}"#,
            #"{"type":"user","sessionId":"m2","message":{"content":"Fix the bug"},"cwd":"/test"}"#,
            #"{"type":"assistant","sessionId":"m2","message":{"content":[{"type":"text","text":"OK"}]}}"#,
        ])

        let metadata = try await JsonlParser.extractMetadata(from: path)
        #expect(metadata?.firstPrompt == "Fix the bug")
    }

    @Test("Skips local-command-stdout messages for first prompt")
    func skipsStdoutForPrompt() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let path = try writeJsonl(dir, "meta-3.jsonl", [
            #"{"type":"user","sessionId":"m3","message":{"content":"<local-command-stdout>some output</local-command-stdout>"},"cwd":"/test"}"#,
            #"{"type":"user","sessionId":"m3","message":{"content":"Do something"},"cwd":"/test"}"#,
        ])

        let metadata = try await JsonlParser.extractMetadata(from: path)
        #expect(metadata?.firstPrompt == "Do something")
    }

    @Test("stripMetadataTags removes known tags")
    func stripTags() {
        let text = "<command-name>/clear</command-name><command-message>msg</command-message>real text"
        let stripped = JsonlParser.stripMetadataTags(text)
        #expect(stripped == "real text")
    }

    @Test("parseLocalCommand extracts command name")
    func parseCommand() {
        let text = "<command-name>/clear</command-name><command-message></command-message><command-args></command-args>"
        let command = JsonlParser.parseLocalCommand(text)
        #expect(command == "/clear")
    }

    @Test("parseLocalCommandStdout extracts output")
    func parseStdout() {
        let text = "<local-command-stdout>hello world</local-command-stdout>"
        let stdout = JsonlParser.parseLocalCommandStdout(text)
        #expect(stdout == "hello world")
    }

    @Test("parseLocalCommandStdout drops the terminal's escape codes")
    func parseStdoutStripsAnsi() {
        let text =
            "<local-command-stdout>Set model to \u{1B}[1mOpus 5\u{1B}[22m and saved</local-command-stdout>"
        let stdout = JsonlParser.parseLocalCommandStdout(text)
        #expect(stdout == "Set model to Opus 5 and saved")
    }

    @Test("isCaveatMessage detects isMeta flag")
    func caveatDetection() {
        let caveat: [String: Any] = ["type": "user", "isMeta": true, "message": ["content": "test"]]
        #expect(JsonlParser.isCaveatMessage(caveat) == true)

        let normal: [String: Any] = ["type": "user", "message": ["content": "test"]]
        #expect(JsonlParser.isCaveatMessage(normal) == false)
    }

    @Test("The last write is found when the tail window starts inside a multi-byte character")
    func lastWrittenAtWithSplitCharacter() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        // "ü" is two bytes. The first line ends in them, so a window of the
        // last line, the newline, `"}` and an odd number of bytes starts on
        // the second byte of one.
        let last = #"{"type":"system","subtype":"away_summary","timestamp":"2026-11-16T12:13:55.705Z"}"#
        let path = try writeJsonl(dir, "s.jsonl", [
            #"{"type":"user","timestamp":"2026-11-16T12:00:00.000Z","note":"üüüüüüüüüü"}"#,
            last,
        ])
        let window = UInt64(last.utf8.count + 1 + 2 + 1)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expected = formatter.date(from: "2026-11-16T12:13:55.705Z")
        let starts = (0..<4).map { JsonlParser.lastWrittenAt(path, tailBytes: window + UInt64($0)) }
        #expect(starts.allSatisfy { $0 == expected })
    }

    @Test("The tail is read to the end of the file, not one block of it")
    func tailTextReadsToTheEnd() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        // Far more than one read() block in front of the last line.
        var lines = (0..<2000).map { #"{"type":"assistant","n":\#($0),"timestamp":"2026-11-16T10:00:00.000Z"}"# }
        lines.append(#"{"type":"system","subtype":"away_summary","timestamp":"2026-11-16T12:13:55.705Z"}"#)
        let path = try writeJsonl(dir, "big.jsonl", lines)

        let handle = try #require(FileHandle(forReadingAtPath: path))
        defer { try? handle.close() }
        let tail = handle.tailText(maxBytes: 64 * 1024)
        #expect(tail.utf8.count == 64 * 1024)
        #expect(tail.hasSuffix(lines.last!))
    }
}
