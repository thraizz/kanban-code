import Foundation
@testable import KanbanCodeCore

/// A Pi session directory in a temp folder, with files in the format Pi
/// 0.99 writes.
struct PiFixture {
    let root: String
    let sessionsRoot: String

    init() throws {
        root = (NSTemporaryDirectory() as NSString).appendingPathComponent("pi-fixture-\(UUID().uuidString)")
        sessionsRoot = (root as NSString).appendingPathComponent(".pi/agent/sessions")
        try FileManager.default.createDirectory(atPath: sessionsRoot, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(atPath: root)
    }

    static let sessionId = "01a0f385-0bf4-702d-b978-176fd2135394"
    static let cwd = "/Users/me/project"

    /// Writes `lines` as a session file of `cwd` and returns its path.
    @discardableResult
    func write(
        _ lines: [String],
        sessionId: String = PiFixture.sessionId,
        cwd: String = PiFixture.cwd
    ) throws -> String {
        let dir = (sessionsRoot as NSString).appendingPathComponent(PiSessionFile.directoryName(forCwd: cwd))
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent("2026-09-30T18-12-57-981Z_\(sessionId).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    static func header(id: String = sessionId, cwd: String = cwd) -> String {
        #"{"type":"session","version":3,"id":"\#(id)","timestamp":"2026-09-30T18:12:57.981Z","cwd":"\#(cwd)"}"#
    }

    /// One exchange with a tool call, then a reply that was branched away
    /// from with `/tree`: the file holds both, the active branch is the
    /// second.
    static var branchedSession: [String] {
        [
            header(),
            #"{"type":"model_change","id":"m1","parentId":null,"timestamp":"2026-09-30T18:12:58.000Z","provider":"openrouter","modelId":"moonshotai/kimi-k2.6"}"#,
            #"{"type":"message","id":"s1","parentId":"m1","timestamp":"2026-09-30T18:12:58.001Z","message":{"role":"system","content":"","sections":{"preamble":"You are pi"},"timestamp":1790791978001}}"#,
            #"{"type":"message","id":"u1","parentId":"s1","timestamp":"2026-09-30T18:12:58.002Z","message":{"role":"user","content":[{"type":"text","text":"Push the branch"}],"timestamp":1790791978002}}"#,
            #"{"type":"message","id":"a1","parentId":"u1","timestamp":"2026-09-30T18:12:59.000Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"I will push it."},{"type":"toolCall","id":"functions.bash:0","name":"bash","arguments":{"command":"git push -u origin feat/pi-support","timeout":null}}],"api":"openai-completions","provider":"openrouter","model":"moonshotai/kimi-k2.6","stopReason":"toolUse","timestamp":1790791979000}}"#,
            #"{"type":"message","id":"r1","parentId":"a1","timestamp":"2026-09-30T18:13:00.000Z","message":{"role":"toolResult","toolCallId":"functions.bash:0","toolName":"bash","content":[{"type":"text","text":"pushed\n"}],"isError":false,"timestamp":1790791980000}}"#,
            #"{"type":"message","id":"a2","parentId":"r1","timestamp":"2026-09-30T18:13:01.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Pushed."}],"api":"openai-completions","provider":"openrouter","model":"moonshotai/kimi-k2.6","stopReason":"stop","timestamp":1790791981000}}"#,
            #"{"type":"message","id":"u2","parentId":"a2","timestamp":"2026-09-30T18:13:02.000Z","message":{"role":"user","content":"Abandoned question","timestamp":1790791982000}}"#,
            #"{"type":"message","id":"a3","parentId":"u2","timestamp":"2026-09-30T18:13:03.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Abandoned answer"}],"model":"moonshotai/kimi-k2.6","stopReason":"stop","timestamp":1790791983000}}"#,
            #"{"type":"session_info","id":"n1","parentId":"a3","timestamp":"2026-09-30T18:13:04.000Z","name":"Pi support"}"#,
            #"{"type":"message","id":"u3","parentId":"a2","timestamp":"2026-09-30T18:13:05.000Z","message":{"role":"user","content":[{"type":"text","text":"Second question"},{"type":"image","data":"AAAA","mimeType":"image/png"}],"timestamp":1790791985000}}"#,
            #"{"type":"message","id":"a4","parentId":"u3","timestamp":"2026-09-30T18:13:06.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Second answer"}],"model":"moonshotai/kimi-k2.6","stopReason":"stop","timestamp":1790791986000}}"#,
        ]
    }
}
