import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("PromptPreview")
struct PromptPreviewTests {
    let longPrompt = "Label this case\n" + String(repeating: "case data 0123456789 ", count: 50_000) + "end"

    func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "kanban-code-prompt-preview-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    func roundTrip(_ link: Link) throws -> Link {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(Link.self, from: encoder().encode(link))
    }

    func writeTranscript(_ dir: String, prompt: String) throws -> String {
        let path = (dir as NSString).appendingPathComponent("s1.jsonl")
        let user: [String: Any] = ["type": "user", "sessionId": "s1", "message": ["content": prompt], "cwd": "/p"]
        let assistant: [String: Any] = ["type": "assistant", "sessionId": "s1", "message": ["content": [["type": "text", "text": "ok"]]]]
        let lines = try [user, assistant].map { String(data: try JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! }
        try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    @Test("A discovered session card keeps a short preview after decoding")
    func discoveredTrims() throws {
        let link = Link(column: .allSessions, source: .discovered, promptBody: longPrompt,
                        sessionLink: SessionLink(sessionId: "s1"), headless: true)
        let decoded = try roundTrip(link)
        let body = try #require(decoded.promptBody)
        #expect(PromptPreview.isPreview(body))
        #expect(body.count == PromptPreview.discoveredLimit + PromptPreview.marker.count)
        #expect(body.hasPrefix("Label this case"))
        #expect(decoded.displayTitle.hasPrefix("Label this case"))
        // Decoding again leaves the preview alone.
        #expect(try roundTrip(decoded).promptBody == body)
    }

    @Test("A backlog card keeps its whole prompt and launches with it")
    func backlogKeepsFullPrompt() throws {
        let link = Link(column: .backlog, source: .manual, promptBody: longPrompt)
        let decoded = try roundTrip(link)
        #expect(decoded.promptBody == longPrompt)
        #expect(PromptBuilder.buildPrompt(card: decoded) == longPrompt)
    }

    @Test("A launched manual card keeps prompts under the user cap whole")
    func manualUnderCap() throws {
        let prompt = String(repeating: "a", count: 10_000)
        let link = Link(column: .inProgress, source: .manual, promptBody: prompt, sessionLink: SessionLink(sessionId: "s1"))
        #expect(try roundTrip(link).promptBody == prompt)
        let huge = Link(column: .inProgress, source: .manual, promptBody: longPrompt, sessionLink: SessionLink(sessionId: "s1"))
        #expect(try roundTrip(huge).promptBody?.count == PromptPreview.userLimit + PromptPreview.marker.count)
    }

    @Test("The whole prompt of a preview is read back from the transcript")
    func fullPromptFromTranscript() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = try writeTranscript(dir, prompt: longPrompt)

        let metadata = try await JsonlParser.extractMetadata(from: path)
        let preview = try #require(metadata?.firstPrompt)
        #expect(PromptPreview.isPreview(preview))

        let link = Link(column: .done, source: .discovered, promptBody: preview,
                        sessionLink: SessionLink(sessionId: "s1", sessionPath: path))
        #expect(await PromptPreview.fullPrompt(for: link) == longPrompt)

        let noTranscript = Link(column: .done, source: .discovered, promptBody: preview,
                                sessionLink: SessionLink(sessionId: "s1", sessionPath: dir + "/missing.jsonl"))
        #expect(await PromptPreview.fullPrompt(for: noTranscript) == PromptPreview.stripMarker(preview))
    }

    @Test("Loading links.json trims once, backs up the old file and keeps sync stamps")
    func storeMigration() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let stamp = SyncStamp(counter: 7, machine: "m1")
        let big = Link(id: "big", column: .allSessions, source: .discovered, promptBody: longPrompt,
                       sessionLink: SessionLink(sessionId: "s1"), headless: true,
                       rev: stamp, fieldRevs: ["promptBody": stamp])
        let backlog = Link(id: "todo", column: .backlog, source: .manual, promptBody: longPrompt)
        struct Container: Encodable { let links: [Link] }
        let file = (dir as NSString).appendingPathComponent("links.json")
        try encoder().encode(Container(links: [big, backlog])).write(to: URL(fileURLWithPath: file))
        let sizeBefore = try FileManager.default.attributesOfItem(atPath: file)[.size] as! Int

        let store = CoordinationStore(basePath: dir)
        let links = try await store.readLinks()
        let loadedBig = try #require(links.first { $0.id == "big" })
        #expect(PromptPreview.isPreview(try #require(loadedBig.promptBody)))
        #expect(loadedBig.rev == stamp)
        #expect(loadedBig.fieldRevs == ["promptBody": stamp])
        #expect(links.first { $0.id == "todo" }?.promptBody == longPrompt)

        let sizeAfter = try FileManager.default.attributesOfItem(atPath: file)[.size] as! Int
        #expect(sizeAfter < sizeBefore)
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.contains(".pre-promptbody-") }
        #expect(backups.count == 1)

        // A second load finds nothing to trim and writes no new backup.
        _ = try await store.readLinks()
        let again = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.contains(".pre-promptbody-") }
        #expect(again.count == 1)
    }

    @Test("links.json written before previews decodes")
    func oldFileDecodes() throws {
        let json = #"{"links":[{"id":"old","column":"done","source":"discovered","sessionId":"s1","promptBody":"hello","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","manualOverrides":{},"manuallyArchived":false}]}"#
        struct Container: Decodable { let links: [Link] }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        let links = try d.decode(Container.self, from: Data(json.utf8)).links
        #expect(links.first?.promptBody == "hello")
        #expect(links.first?.sessionLink?.sessionId == "s1")
    }

    @Test("A peer version with a whole prompt merges without a new stamp")
    func peerMergeStaysQuiet() throws {
        let stamp = SyncStamp(counter: 3, machine: "peer")
        let local = try roundTrip(Link(id: "c", column: .done, source: .discovered, promptBody: longPrompt,
                                       sessionLink: SessionLink(sessionId: "s1"), ownerMachine: "peer",
                                       rev: stamp, fieldRevs: ["promptBody": stamp]))
        let incoming = try roundTrip(Link(id: "c", column: .done, source: .discovered, promptBody: longPrompt,
                                          sessionLink: SessionLink(sessionId: "s1"), ownerMachine: "peer",
                                          rev: stamp, fieldRevs: ["promptBody": stamp]))
        let merged = LinkSync.merge(local: local, incoming: incoming, from: "peer", localMachine: "me", now: .now)
        #expect(merged == local)
    }
}
