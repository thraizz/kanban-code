import Foundation
import Testing

@testable import KanbanCodeCore

@Suite("Attention escalation policy")
struct AttentionPolicyTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let settings = AttentionPolicySettings()

    func request(card: String = "card_1", at: Date? = nil) -> AttentionRequest {
        AttentionRequest(id: "att_1", cardId: card, kind: .question, title: "Q", body: "B", createdAt: at ?? t0)
    }

    func presence(_ edit: (inout MacPresence) -> Void = { _ in }) -> MacPresence {
        var p = MacPresence(isKanbanFrontmost: false, idleSeconds: 5, reportedAt: t0)
        edit(&p)
        return p
    }

    @Test("active on the Mac elsewhere: Mac notification and a silent phone copy")
    func activeElsewhere() {
        let steps = AttentionPolicy.steps(for: request(), delivered: .init(), presence: presence(), now: t0, settings: settings)
        #expect(steps == [.postMac, .phoneSilent])
    }

    @Test("looking at the card's chat: nothing at all")
    func lookingAtIt() {
        let p = presence { $0.isKanbanFrontmost = true; $0.visibleCardId = "card_1"; $0.visibleTab = "chat" }
        #expect(AttentionPolicy.steps(for: request(), delivered: .init(), presence: p, now: t0, settings: settings).isEmpty)
    }

    @Test("Kanban in front on another card still notifies")
    func otherCard() {
        let p = presence { $0.isKanbanFrontmost = true; $0.visibleCardId = "card_2"; $0.visibleTab = "terminal" }
        #expect(AttentionPolicy.steps(for: request(), delivered: .init(), presence: p, now: t0, settings: settings) == [.postMac, .phoneSilent])
    }

    @Test("the card open on a non-session tab still notifies")
    func otherTab() {
        let p = presence { $0.isKanbanFrontmost = true; $0.visibleCardId = "card_1"; $0.visibleTab = "browser" }
        #expect(AttentionPolicy.steps(for: request(), delivered: .init(), presence: p, now: t0, settings: settings).contains(.postMac))
    }

    @Test("looking at the card after a notification removes it")
    func removeWhenLooking() {
        let p = presence { $0.isKanbanFrontmost = true; $0.visibleCardId = "card_1"; $0.visibleTab = "terminal" }
        let steps = AttentionPolicy.steps(for: request(), delivered: .init(macPosted: true), presence: p, now: t0, settings: settings)
        #expect(steps == [.removeMac])
    }

    @Test("not acted on within the delay: the phone alerts")
    func escalateAfterDelay() {
        let delivered = AttentionDeliveryState(macPosted: true, phoneSilentSent: true)
        let early = AttentionPolicy.steps(for: request(), delivered: delivered, presence: presence { $0.reportedAt = t0 + 179 }, now: t0 + 179, settings: settings)
        #expect(early.isEmpty)
        let late = AttentionPolicy.steps(for: request(), delivered: delivered, presence: presence { $0.reportedAt = t0 + 180 }, now: t0 + 180, settings: settings)
        #expect(late == [.phoneAlert])
    }

    @Test("Mac idle past two minutes: the phone alerts at once", arguments: [
        "idle", "locked", "screensaver", "lid", "display", "stale", "none",
    ])
    func awayAlertsAtOnce(reason: String) {
        var p: MacPresence? = presence()
        switch reason {
        case "idle": p?.idleSeconds = 121
        case "locked": p?.screenLocked = true
        case "screensaver": p?.screensaverActive = true
        case "lid": p?.lidClosed = true
        case "display": p?.displayAsleep = true
        case "stale": p?.reportedAt = t0 - 600
        default: p = nil
        }
        let steps = AttentionPolicy.steps(for: request(), delivered: .init(), presence: p, now: t0, settings: settings)
        #expect(steps == [.postMac, .phoneAlert])
    }

    @Test("an alert is sent once")
    func alertOnce() {
        let p = presence { $0.screenLocked = true }
        let steps = AttentionPolicy.steps(for: request(), delivered: .init(macPosted: true, phoneAlertSent: true), presence: p, now: t0, settings: settings)
        #expect(steps.isEmpty)
    }

    @Test("phone off: only the Mac")
    func phoneOff() {
        var s = settings
        s.phoneEnabled = false
        let steps = AttentionPolicy.steps(for: request(), delivered: .init(), presence: presence { $0.screenLocked = true }, now: t0, settings: s)
        #expect(steps == [.postMac])
    }

    @Test("a master without a Mac goes straight to the phone")
    func headless() {
        let steps = AttentionPolicy.steps(for: request(), delivered: .init(), presence: nil, now: t0, settings: settings, macAvailable: false)
        #expect(steps == [.phoneAlert])
    }

    @Test("a resolved request takes its Mac notification away")
    func resolved() {
        var r = request()
        r.resolvedAt = t0
        #expect(AttentionPolicy.steps(for: r, delivered: .init(macPosted: true), presence: presence(), now: t0, settings: settings) == [.removeMac])
    }
}

@Suite("Attention center")
struct AttentionCenterTests {
    final class Recorder: MacAttentionNotifier, PhonePushSender, @unchecked Sendable {
        let lock = NSLock()
        var events: [String] = []
        func record(_ e: String) { lock.withLock { events.append(e) } }
        func post(_ request: AttentionRequest, cardName: String?) async { record("mac+\(request.id)") }
        func remove(id: String) async { record("mac-\(id)") }
        func send(_ request: AttentionRequest, cardName: String?, level: PhonePushLevel) async throws { record("phone:\(level.rawValue):\(request.id)") }
        func withdraw(_ request: AttentionRequest) async { record("phone-\(request.id)") }
    }

    final class Clock: @unchecked Sendable {
        let lock = NSLock()
        var value: Date
        init(_ value: Date) { self.value = value }
        var now: Date { lock.withLock { value } }
        func advance(_ s: TimeInterval) { lock.withLock { value += s } }
    }

    @Test("deliver, escalate on the clock, withdraw everywhere")
    func lifecycle() async {
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        let clock = Clock(t0)
        let recorder = Recorder()
        let center = AttentionCenter(
            mac: recorder, phone: recorder,
            localPresence: { MacPresence(idleSeconds: 1, reportedAt: clock.now) },
            now: { clock.now })
        let request = AttentionRequest(id: "att_x", cardId: "c", kind: .question, title: "Q", body: "B", createdAt: t0)
        await center.deliver(request)
        #expect(recorder.events == ["mac+att_x", "phone:passive:att_x"])
        clock.advance(181)
        await center.evaluateAll()
        #expect(recorder.events.last == "phone:timeSensitive:att_x")
        var resolved = request
        resolved.resolvedAt = clock.now
        await center.withdraw(resolved)
        #expect(recorder.events.suffix(2) == ["mac-att_x", "phone-att_x"])
    }

    @Test("after a restart a request raised again is not delivered twice, and one settled meanwhile is taken down")
    func restart() async {
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        let clock = Clock(t0)
        let file = (NSTemporaryDirectory() as NSString).appendingPathComponent("attention-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(atPath: file) }
        let presence: @Sendable () async -> MacPresence? = { MacPresence(idleSeconds: 1, reportedAt: clock.now) }
        let first = Recorder()
        let before = AttentionCenter(mac: first, phone: first, localPresence: presence, now: { clock.now }, stateFile: file)
        let kept = AttentionRequest(id: "att_kept", cardId: "c", kind: .question, title: "Q", body: "B", createdAt: t0)
        let settled = AttentionRequest(id: "att_settled", cardId: "c", kind: .question, title: "Q", body: "B", createdAt: t0)
        await before.deliver(kept)
        await before.deliver(settled)
        #expect(first.events.count == 4)

        clock.advance(30)
        let second = Recorder()
        let after = AttentionCenter(mac: second, phone: second, localPresence: presence, now: { clock.now }, stateFile: file, restoreGrace: 60)
        await after.deliver(kept)
        #expect(second.events.isEmpty)
        clock.advance(151)
        await after.evaluateAll()
        #expect(second.events == ["phone:timeSensitive:att_kept", "mac-att_settled"])
    }

    @Test("a request another master owns never goes to the phone from here")
    func mirroredSkipsPhone() async {
        let recorder = Recorder()
        let center = AttentionCenter(
            mac: recorder, phone: recorder, localPresence: { nil }, localMachineId: { "mac-id" })
        var request = AttentionRequest(id: "att_y", cardId: "c", kind: .question, title: "Q", body: "B")
        request.machineId = "box-id"
        await center.deliver(request)
        #expect(recorder.events == ["mac+att_y"])
    }
}
