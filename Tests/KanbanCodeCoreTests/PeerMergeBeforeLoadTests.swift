import Testing
import Foundation
@testable import KanbanCodeCore

private struct NoDiscovery: SessionDiscovery {
    func discoverSessions() async throws -> [Session] { [] }
    func discoverNewOrModified(since: Date) async throws -> [Session] { [] }
}

private func card(_ id: String, owner: String, counter: Int) -> Link {
    Link(
        id: id,
        name: id,
        projectPath: "/p",
        column: .waiting,
        source: .manual,
        ownerMachine: owner,
        rev: SyncStamp(counter: counter, machine: owner),
        ownerRev: SyncStamp(counter: counter, machine: owner)
    )
}

private func linksOnDisk(_ home: String) -> Set<String> {
    Set(CoordinationStore.readLinksSnapshot(basePath: home).map(\.id))
}

/// A starting master pulls its peers while it is still reading its own
/// links.json. The peer's page must be merged into the local set, never
/// written as the whole file.
@Suite("Peer pages that arrive before the local links load", .serialized)
@MainActor
struct PeerMergeBeforeLoadTests {
    private func makeStore(home: String) -> BoardStore {
        let coordination = CoordinationStore(basePath: home)
        let store = BoardStore(
            effectHandler: EffectHandler(coordinationStore: coordination,
                                         queuedPromptJournal: QueuedPromptJournal(basePath: home)),
            discovery: NoDiscovery(),
            coordinationStore: coordination
        )
        store.dispatch(.localMachineLoaded(MachineIdentity(id: "MAC", name: "mac")))
        return store
    }

    private func waitForDisk(_ home: String, toEqual expected: Set<String>) async throws {
        for _ in 0..<100 where linksOnDisk(home) != expected {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test("a peer page before the load is merged after it, and links.json keeps the local cards")
    func pageBeforeLoad() async throws {
        let home = (NSTemporaryDirectory() as NSString).appendingPathComponent("peer-before-load-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: home) }
        let local = [card("card_mac1", owner: "MAC", counter: 3), card("card_mac2", owner: "MAC", counter: 4)]
        try await CoordinationStore(basePath: home).writeLinks(local)

        let store = makeStore(home: home)
        store.dispatch(.peerLinksMerged(peer: "BOX", links: [card("card_box", owner: "BOX", counter: 9)]))

        // Nothing is merged or written while the local set is unread.
        #expect(store.state.links.isEmpty)
        try await Task.sleep(for: .milliseconds(200))
        #expect(linksOnDisk(home) == ["card_mac1", "card_mac2"])

        await store.loadSettingsAndCache()
        #expect(Set(store.state.links.keys) == ["card_mac1", "card_mac2", "card_box"])
        try await waitForDisk(home, toEqual: ["card_mac1", "card_mac2", "card_box"])
        #expect(linksOnDisk(home) == ["card_mac1", "card_mac2", "card_box"])
    }

    @Test("a peer page during the read of links.json does not replace the file")
    func pageDuringLoad() async throws {
        let home = (NSTemporaryDirectory() as NSString).appendingPathComponent("peer-during-load-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: home) }
        // A set big enough that its read takes a while.
        let local = (0..<3000).map { card("card_mac\($0)", owner: "MAC", counter: $0 + 1) }
        try await CoordinationStore(basePath: home).writeLinks(local)

        let store = makeStore(home: home)
        async let loading: Void = store.loadSettingsAndCache()
        await Task.yield()
        store.dispatch(.peerLinksMerged(peer: "BOX", links: [card("card_box", owner: "BOX", counter: 9)]))
        await loading

        let expected = Set(local.map(\.id)).union(["card_box"])
        #expect(Set(store.state.links.keys) == expected)
        try await waitForDisk(home, toEqual: expected)
        #expect(linksOnDisk(home) == expected)
    }

    @Test("no full rewrite of links.json runs before the local links load")
    func noRewriteBeforeLoad() async throws {
        let home = (NSTemporaryDirectory() as NSString).appendingPathComponent("rewrite-before-load-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: home) }
        try await CoordinationStore(basePath: home).writeLinks([card("card_mac1", owner: "MAC", counter: 1)])

        let store = makeStore(home: home)
        await store.dispatchAndWait(.gitHubIssuesUpdated(links: []))
        #expect(linksOnDisk(home) == ["card_mac1"])
        #expect(store.localLinksLoaded == false)
    }
}
