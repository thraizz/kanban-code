import Foundation
import Testing

@testable import KanbanCodeCore

@Suite("Copies of other masters' transcripts made before a launch are read again")
struct PeerTranscriptCopiesTests {
    private func sandbox() throws -> String {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("peer-copies-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeCopy(directory: String, machineId: String, sessionId: String) throws -> String {
        let path = PeerTranscriptMirror.mirrorPath(directory: directory, machineId: machineId, sessionId: sessionId)
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try "{}\n".write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    @Test("an archived card another master owns finds its copy; local cards, known paths and missing copies do not")
    func findsCopies() throws {
        let dir = try sandbox()
        let archived = try writeCopy(directory: dir, machineId: "machine_box", sessionId: "s-archived")
        _ = try writeCopy(directory: dir, machineId: "machine_box", sessionId: "s-known")
        _ = try writeCopy(directory: dir, machineId: "machine_mac", sessionId: "s-local")
        let links = [
            Link(id: "card_archived", column: .allSessions, manuallyArchived: true,
                 sessionLink: SessionLink(sessionId: "s-archived", sessionPath: "/home/aron/.claude/projects/x/s-archived.jsonl"),
                 ownerMachine: "machine_box"),
            Link(id: "card_known", sessionLink: SessionLink(sessionId: "s-known"), ownerMachine: "machine_box"),
            Link(id: "card_local", sessionLink: SessionLink(sessionId: "s-local"), ownerMachine: "machine_mac"),
            Link(id: "card_nocopy", sessionLink: SessionLink(sessionId: "s-none"), ownerMachine: "machine_box"),
        ]
        let found = PeerTranscriptMirror.existingCopies(
            links: links, localMachineId: "machine_mac", known: ["s-known": "/elsewhere"], directory: dir)
        #expect(found == ["s-archived": archived])
    }

    @Test("found copies point the card's chat at them, without replacing a path already known")
    func reducerUsesCopies() {
        var state = AppState()
        state.localMachineId = "machine_mac"
        state.links["card_a"] = Link(
            id: "card_a", column: .allSessions, manuallyArchived: true,
            sessionLink: SessionLink(sessionId: "s-a", sessionPath: "/home/aron/.claude/projects/x/s-a.jsonl"),
            ownerMachine: "machine_box")
        state.peerTranscriptPaths["s-b"] = "/mirror/live-b.jsonl"
        _ = Reducer.reduce(state: &state, action: .peerTranscriptCopiesFound(
            paths: ["s-a": "/mirror/s-a.jsonl", "s-b": "/mirror/stale-b.jsonl"]))
        #expect(state.peerTranscriptPaths == ["s-a": "/mirror/s-a.jsonl", "s-b": "/mirror/live-b.jsonl"])
        let card = state.cards.first { $0.id == "card_a" }
        #expect(card?.link.sessionLink?.sessionPath == "/mirror/s-a.jsonl")
    }
}
