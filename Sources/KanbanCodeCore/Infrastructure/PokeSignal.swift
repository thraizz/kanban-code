import Foundation
import Synchronization

/// Wakes a loop that waits for its next round early: `wait(timeout:)` ends
/// at a `poke()` (one that came while nothing waited counts for the next
/// wait) or once `timeout` passed, whichever is first. One waiter at a time.
///
/// Not an `AsyncStream` raced against a sleep in a task group: cancelling a
/// task that awaits an `AsyncStream` iterator's `next()` terminates the
/// stream, so after the first timeout every later wait returned at once and
/// the loop spun (the attention mirror called its peer some 240 times a
/// second, both masters at several cores).
public final class PokeSignal: Sendable {
    private struct State {
        var pending = false
        var waiter: (id: Int, continuation: CheckedContinuation<Void, Never>)?
        var nextId = 0
    }

    private let state = Mutex(State())

    public init() {}

    /// Ends the current wait, or the next one when none waits now.
    public func poke() {
        let waiter = state.withLock { s -> CheckedContinuation<Void, Never>? in
            guard let waiter = s.waiter else {
                s.pending = true
                return nil
            }
            s.waiter = nil
            return waiter.continuation
        }
        waiter?.resume()
    }

    /// Waits until poked or until `timeout` passed.
    public func wait(timeout: Duration) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let id = state.withLock { s -> Int? in
                if s.pending {
                    s.pending = false
                    return nil
                }
                s.nextId += 1
                s.waiter = (s.nextId, continuation)
                return s.nextId
            }
            guard let id else {
                continuation.resume()
                return
            }
            Task {
                try? await Task.sleep(for: timeout)
                let waiter = self.state.withLock { s -> CheckedContinuation<Void, Never>? in
                    guard let waiter = s.waiter, waiter.id == id else { return nil }
                    s.waiter = nil
                    return waiter.continuation
                }
                waiter?.resume()
            }
        }
    }
}
