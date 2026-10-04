import Foundation
import Synchronization
import Testing
import KanbanCodeRemoteKit

@testable import KanbanCodeCore

@Suite("Kept catch-up")
struct CatchUpKeepTests {
    private func home() -> String {
        let path = NSTemporaryDirectory() + "catchup-keep-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    private func run(_ id: String = "side_1", state: RemoteSideChatRun.State = .done) -> RemoteSideChatRun {
        RemoteSideChatRun(
            id: id, cardId: "card_1", kind: .catchup, state: state,
            text: #"{"section":"status","text":"Done.","refs":["m2"]}"#,
            since: RemoteSideChatSince(text: "do it", at: Date(timeIntervalSince1970: 1_800_000_000), offset: 100),
            refs: [RemoteSideChatRef(ref: "m1", offset: 100, role: "you", preview: "do it"),
                   RemoteSideChatRef(ref: "m2", offset: 480, role: "assistant", preview: "done")],
            finishedAt: Date(timeIntervalSince1970: 1_800_000_060))
    }

    @Test func aCatchUpCoversUpToTheLastMessageOfItsIndex() {
        let since = RemoteSideChatSince(text: "do it", offset: 100)
        let refs = [RemoteSideChatRef(ref: "m1", offset: 100, role: "you", preview: ""),
                    RemoteSideChatRef(ref: "m2", offset: 480, role: "assistant", preview: "")]
        #expect(KeptCatchUp.covered(since: since, refs: refs) == 480)
        // Nothing after his message yet: it is the last one.
        #expect(KeptCatchUp.covered(since: since, refs: []) == 100)
        #expect(KeptCatchUp.covered(since: nil, refs: []) == -1)
    }

    @Test func itIsCurrentWhileTheSessionHasNoMessageAfterIt() {
        let kept = KeptCatchUp(sessionId: "s1", covered: 480, run: run())
        #expect(kept.isCurrent(sessionId: "s1", covered: 480))
        // The agent wrote again.
        #expect(!kept.isCurrent(sessionId: "s1", covered: 900))
        // The card moved to another session.
        #expect(!kept.isCurrent(sessionId: "s2", covered: 480))
        let failed = KeptCatchUp(sessionId: "s1", covered: 480, run: run(state: .failed))
        #expect(!failed.isCurrent(sessionId: "s1", covered: 480))
    }

    @Test func itSurvivesARestartWithItsFollowUps() throws {
        let home = home()
        let keep = CatchUpKeep(kanbanHome: home)
        #expect(keep.read(cardId: "card_1") == nil)
        keep.keep(cardId: "card_1", KeptCatchUp(sessionId: "s1", covered: 480, run: run()))
        keep.addFollowUp(cardId: "card_1", catchUpId: "side_1", RemoteSideChatExchange(question: "what is left?", answer: "Nothing."))
        // A follow-up of another catch-up is not this one's.
        keep.addFollowUp(cardId: "card_1", catchUpId: "side_other", RemoteSideChatExchange(question: "x", answer: "y"))

        let again = CatchUpKeep(kanbanHome: home)
        let kept = try #require(again.read(cardId: "card_1"))
        #expect(kept.run == run())
        #expect(kept.followUps == [RemoteSideChatExchange(question: "what is left?", answer: "Nothing.")])
        #expect(FileManager.default.fileExists(atPath: home + "/side-chat/card_1.json"))

        let reopened = kept.reopenedRun
        #expect(reopened.reopened == true)
        #expect(reopened.state == .done)
        #expect(reopened.id == "side_1")
        #expect(reopened.followUps?.count == 1)
        #expect(reopened.refs?.count == 2)
    }

    @Test func aNewCatchUpReplacesTheKeptOneAndItsFollowUps() throws {
        let keep = CatchUpKeep(kanbanHome: home())
        keep.keep(cardId: "card_1", KeptCatchUp(sessionId: "s1", covered: 480, run: run()))
        keep.addFollowUp(cardId: "card_1", catchUpId: "side_1", RemoteSideChatExchange(question: "q", answer: "a"))
        keep.keep(cardId: "card_1", KeptCatchUp(sessionId: "s1", covered: 900, run: run("side_2")))
        let kept = try #require(keep.read(cardId: "card_1"))
        #expect(kept.run.id == "side_2")
        #expect(kept.followUps.isEmpty)
        #expect(kept.reopenedRun.followUps == nil)
    }

    @Test func onlyAFinishedCatchUpIsKept() {
        let keep = CatchUpKeep(kanbanHome: home())
        keep.keep(cardId: "card_1", KeptCatchUp(sessionId: "s1", covered: 480, run: run(state: .failed)))
        #expect(keep.read(cardId: "card_1") == nil)
        var btw = run()
        btw.kind = .btw
        keep.keep(cardId: "card_1", KeptCatchUp(sessionId: "s1", covered: 480, run: btw))
        #expect(keep.read(cardId: "card_1") == nil)
    }

    @Test func theFollowUpsKeptAreCapped() throws {
        let keep = CatchUpKeep(kanbanHome: home())
        keep.keep(cardId: "card_1", KeptCatchUp(sessionId: "s1", covered: 480, run: run()))
        for n in 0..<(CatchUpKeep.followUpLimit + 5) {
            keep.addFollowUp(cardId: "card_1", catchUpId: "side_1", RemoteSideChatExchange(question: "q\(n)", answer: "a"))
        }
        let kept = try #require(keep.read(cardId: "card_1"))
        #expect(kept.followUps.count == CatchUpKeep.followUpLimit)
        #expect(kept.followUps.first?.question == "q5")
    }

    /// A runner that answers at once.
    private struct InstantRunner: SideChatRunning {
        var answer: String?
        func run(id: String, _ job: SideChatJob, onText: @escaping @Sendable (String) -> Void) async throws -> String {
            guard let answer else { throw SideChatFailed("no login") }
            return answer
        }
        func cancel(id: String) async {}
    }

    @Test func theServiceHandsOverARunThatEndedWithAnAnswer() async throws {
        let done = Mutex<[RemoteSideChatRun]>([])
        let service = SideChatService(runner: InstantRunner(answer: "All good."))
        let job = SideChatJob(sessionId: "s1", cwd: "/tmp", prompt: "p")
        let started = await service.start(cardId: "card_1", kind: .catchup, job: job) { run in done.withLock { $0.append(run) } }
        for _ in 0..<200 where done.withLock({ $0.isEmpty }) { try await Task.sleep(for: .milliseconds(5)) }
        let run = try #require(done.withLock { $0.first })
        #expect(run.id == started.id)
        #expect(run.state == .done)
        #expect(run.text == "All good.")
        #expect(run.finishedAt != nil)

        // A run that failed is not handed over.
        let failing = SideChatService(runner: InstantRunner(answer: nil))
        let failed = await failing.start(cardId: "card_1", kind: .catchup, job: job) { run in done.withLock { $0.append(run) } }
        for _ in 0..<200 {
            if await failing.run(id: failed.id)?.state == .failed { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await failing.run(id: failed.id)?.state == .failed)
        #expect(done.withLock { $0.count } == 1)
    }
}
