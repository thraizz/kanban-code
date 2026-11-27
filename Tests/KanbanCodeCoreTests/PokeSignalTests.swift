import Foundation
import Testing
@testable import KanbanCodeCore

@Suite("Poke signal")
struct PokeSignalTests {
    private func took(_ body: () async -> Void) async -> Duration {
        let clock = ContinuousClock()
        let start = clock.now
        await body()
        return clock.now - start
    }

    @Test("every wait without a poke lasts its timeout, the ones after a timeout too")
    func timeoutsDoNotSpin() async {
        let signal = PokeSignal()
        for round in 0..<4 {
            let waited = await took { await signal.wait(timeout: .milliseconds(100)) }
            #expect(waited >= .milliseconds(90), "round \(round) took \(waited)")
            #expect(waited < .seconds(1), "round \(round) took \(waited)")
        }
    }

    @Test("a poke ends the wait at once; one while nothing waits ends the next wait, once")
    func pokes() async throws {
        let signal = PokeSignal()
        let waiter = Task { await took { await signal.wait(timeout: .seconds(10)) } }
        try await Task.sleep(for: .milliseconds(100))
        signal.poke()
        #expect(await waiter.value < .seconds(1))

        signal.poke()
        signal.poke()
        #expect(await took { await signal.wait(timeout: .seconds(10)) } < .milliseconds(200))
        #expect(await took { await signal.wait(timeout: .milliseconds(100)) } >= .milliseconds(90))
    }

    @Test("a poke after a timeout ended the wait is kept for the next one, not lost")
    func pokeAfterTimeout() async {
        let signal = PokeSignal()
        await signal.wait(timeout: .milliseconds(20))
        signal.poke()
        #expect(await took { await signal.wait(timeout: .seconds(10)) } < .milliseconds(200))
    }
}
