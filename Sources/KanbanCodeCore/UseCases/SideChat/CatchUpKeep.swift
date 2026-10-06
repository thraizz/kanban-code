import Foundation
import KanbanCodeRemoteKit

/// A card's last finished catch-up, kept so asking again with nothing new
/// in the session shows it at once instead of running the model again.
public struct KeptCatchUp: Codable, Sendable, Equatable {
    public var sessionId: String
    /// Transcript offset of the last message the catch-up covers.
    public var covered: Int
    /// The finished run.
    public var run: RemoteSideChatRun
    /// What was asked afterwards in the same side chat, oldest first.
    public var followUps: [RemoteSideChatExchange]

    public init(sessionId: String, covered: Int, run: RemoteSideChatRun, followUps: [RemoteSideChatExchange] = []) {
        self.sessionId = sessionId
        self.covered = covered
        self.run = run
        self.followUps = followUps
    }

    /// The last message a catch-up over this scope covers: the last one in
    /// its index, or the human's own when nothing came after it. -1 for a
    /// session with no message.
    public static func covered(since: RemoteSideChatSince?, refs: [RemoteSideChatRef]) -> Int {
        refs.last?.offset ?? since?.offset ?? -1
    }

    /// Whether this catch-up still says all there is: the same session,
    /// and no message after the last one it covers.
    public func isCurrent(sessionId: String, covered: Int) -> Bool {
        self.sessionId == sessionId && self.covered == covered && run.state == .done
    }

    /// The run as a new request gets it: marked reopened, with its follow-ups.
    public var reopenedRun: RemoteSideChatRun {
        var run = run
        run.reopened = true
        run.followUps = followUps.isEmpty ? nil : followUps
        return run
    }
}

/// The kept catch-ups, one file per card at
/// `~/.kanban-code/side-chat/<cardId>.json`.
public final class CatchUpKeep: @unchecked Sendable {
    private let directory: String
    private let lock = NSLock()
    /// Follow-ups kept with a catch-up; older ones leave.
    static let followUpLimit = 30

    public init(kanbanHome: String? = nil) {
        let home = kanbanHome ?? (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code")
        self.directory = (home as NSString).appendingPathComponent("side-chat")
    }

    private func path(_ cardId: String) -> String {
        let safe = String(cardId.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "_" })
        return (directory as NSString).appendingPathComponent(safe + ".json")
    }

    public func read(cardId: String) -> KeptCatchUp? {
        lock.lock()
        defer { lock.unlock() }
        return readLocked(cardId)
    }

    private func readLocked(_ cardId: String) -> KeptCatchUp? {
        guard let data = FileManager.default.contents(atPath: path(cardId)) else { return nil }
        return try? JSONDecoder.remote.decode(KeptCatchUp.self, from: data)
    }

    private func writeLocked(_ cardId: String, _ kept: KeptCatchUp) {
        guard let data = try? JSONEncoder.remote.encode(kept) else { return }
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: path(cardId)), options: .atomic)
    }

    /// Keeps a finished catch-up in place of the card's earlier one.
    public func keep(cardId: String, _ kept: KeptCatchUp) {
        guard kept.run.state == .done, kept.run.kind == .catchup else { return }
        lock.lock()
        defer { lock.unlock() }
        writeLocked(cardId, kept)
    }

    /// Adds a follow-up to the card's kept catch-up, when it is still the
    /// one the follow-up was asked about.
    public func addFollowUp(cardId: String, catchUpId: String, _ exchange: RemoteSideChatExchange) {
        lock.lock()
        defer { lock.unlock() }
        guard var kept = readLocked(cardId), kept.run.id == catchUpId else { return }
        kept.followUps.append(exchange)
        if kept.followUps.count > Self.followUpLimit {
            kept.followUps.removeFirst(kept.followUps.count - Self.followUpLimit)
        }
        writeLocked(cardId, kept)
    }

    public func remove(cardId: String) {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(atPath: path(cardId))
    }
}
