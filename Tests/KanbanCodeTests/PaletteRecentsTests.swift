import Foundation
import KanbanCodeCore
import Testing

@testable import KanbanCode

@Suite("Palette recents")
@MainActor
struct PaletteRecentsTests {

    private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private static func card(
        _ id: String,
        opened: TimeInterval? = nil,
        activity: TimeInterval? = nil,
        updated: TimeInterval = 0
    ) -> KanbanCodeCard {
        KanbanCodeCard(
            link: Link(
                id: id,
                updatedAt: epoch.addingTimeInterval(updated),
                lastActivity: activity.map { epoch.addingTimeInterval($0) },
                lastOpenedAt: opened.map { epoch.addingTimeInterval($0) }
            )
        )
    }

    private static func merged(
        cards: [KanbanCodeCard],
        limit: Int = 24
    ) -> [String] {
        SearchOverlay.mergedRecent(cards: cards, limit: limit).map(\.id)
    }

    @Test("the most recently opened comes first")
    func ordersByRecency() {
        let ids = Self.merged(cards: [
            Self.card("old", opened: 100),
            Self.card("newest", opened: 300),
            Self.card("middle", opened: 200),
        ])

        #expect(ids == ["newest", "middle", "old"])
    }

    /// The palette opens onto the second row, so "go back to what I was on
    /// before this" is one keystroke. That only works if a card that has never
    /// been opened sorts on when it last did something.
    @Test("a card that was never opened falls back to its activity, then its update")
    func fallsBackWhenNeverOpened() {
        let ids = Self.merged(cards: [
            Self.card("opened", opened: 100),
            Self.card("active", activity: 200, updated: 50),
            Self.card("only-updated", updated: 300),
        ])

        #expect(ids == ["only-updated", "active", "opened"])
    }

    /// The board this was written against holds a few thousand cards and shows
    /// two dozen rows, so everything below the cut is work nobody sees.
    @Test("it stops at the limit")
    func truncatesToLimit() {
        let cards = (0..<100).map { Self.card("card\($0)", opened: TimeInterval($0)) }

        let ids = Self.merged(cards: cards, limit: 3)

        #expect(ids == ["card99", "card98", "card97"])
    }

    @Test("an empty board produces no rows")
    func emptyBoard() {
        #expect(Self.merged(cards: []).isEmpty)
    }
}
