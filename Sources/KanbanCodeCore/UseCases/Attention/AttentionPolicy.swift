import Foundation
import KanbanCodeRemoteKit

/// How attention requests reach Rogerio, from Settings > Notifications.
public struct AttentionPolicySettings: Sendable, Equatable {
    /// Post a notification on the Mac.
    public var macNotifications: Bool
    /// Send to the phone at all.
    public var phoneEnabled: Bool
    /// An open request alerts the phone after this long.
    public var phoneAlertDelay: TimeInterval
    /// The Mac counts as away after this long without input.
    public var idleThreshold: TimeInterval
    /// A presence report older than this is not trusted: the Mac counts as away.
    public var presenceMaxAge: TimeInterval
    /// Send a silent phone copy before the alert.
    public var phoneSilentCopy: Bool

    public init(
        macNotifications: Bool = true, phoneEnabled: Bool = true,
        phoneAlertDelay: TimeInterval = 180, idleThreshold: TimeInterval = 120,
        presenceMaxAge: TimeInterval = 90, phoneSilentCopy: Bool = true
    ) {
        self.macNotifications = macNotifications
        self.phoneEnabled = phoneEnabled
        self.phoneAlertDelay = phoneAlertDelay
        self.idleThreshold = idleThreshold
        self.presenceMaxAge = presenceMaxAge
        self.phoneSilentCopy = phoneSilentCopy
    }
}

/// What was already done for one request.
public struct AttentionDeliveryState: Sendable, Equatable, Codable {
    public var macPosted = false
    public var phoneSilentSent = false
    public var phoneAlertSent = false
    /// The detail sheet was opened in the app.
    public var shownInApp = false

    public init(macPosted: Bool = false, phoneSilentSent: Bool = false, phoneAlertSent: Bool = false, shownInApp: Bool = false) {
        self.macPosted = macPosted
        self.phoneSilentSent = phoneSilentSent
        self.phoneAlertSent = phoneAlertSent
        self.shownInApp = shownInApp
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        macPosted = try c.decodeIfPresent(Bool.self, forKey: .macPosted) ?? false
        phoneSilentSent = try c.decodeIfPresent(Bool.self, forKey: .phoneSilentSent) ?? false
        phoneAlertSent = try c.decodeIfPresent(Bool.self, forKey: .phoneAlertSent) ?? false
        shownInApp = try c.decodeIfPresent(Bool.self, forKey: .shownInApp) ?? false
    }
}

public enum AttentionDeliveryStep: Sendable, Equatable {
    case postMac
    case removeMac
    /// A copy on the phone that makes no sound (passive).
    case phoneSilent
    /// A time-sensitive push with sound.
    case phoneAlert
    /// Opens the request's detail sheet in the app, for a vault approval
    /// whose card is on screen: no card view draws vault approvals.
    case showInApp
}

/// Who gets told about an open request, and when. Pure.
public enum AttentionPolicy {
    /// The Mac is away: locked, screensaver, lid closed, display asleep, idle
    /// past the threshold, or no fresh presence report at all.
    public static func macIsAway(_ presence: MacPresence?, now: Date, settings: AttentionPolicySettings) -> Bool {
        guard let presence, now.timeIntervalSince(presence.reportedAt) <= settings.presenceMaxAge else { return true }
        return presence.screenLocked || presence.screensaverActive || presence.lidClosed || presence.displayAsleep
            || presence.idleSeconds >= settings.idleThreshold
    }

    /// Rogerio is looking at the request's card right now: Kanban in front
    /// with that card's terminal or chat open, and the Mac in use.
    public static func isLookingAt(_ request: AttentionRequest, _ presence: MacPresence?, now: Date, settings: AttentionPolicySettings) -> Bool {
        guard let presence, let cardId = request.cardId, !macIsAway(presence, now: now, settings: settings) else { return false }
        guard presence.isKanbanFrontmost, presence.visibleCardId == cardId else { return false }
        return presence.visibleTab == nil || presence.visibleTab == "terminal" || presence.visibleTab == "chat"
    }

    /// What to do now for an open request, given what was already done.
    public static func steps(
        for request: AttentionRequest, delivered: AttentionDeliveryState, presence: MacPresence?,
        now: Date, settings: AttentionPolicySettings, macAvailable: Bool = true
    ) -> [AttentionDeliveryStep] {
        guard request.isOpen else {
            return delivered.macPosted ? [.removeMac] : []
        }
        if isLookingAt(request, presence, now: now, settings: settings) {
            var steps: [AttentionDeliveryStep] = delivered.macPosted ? [.removeMac] : []
            // The chat and the terminal show questions, plans and permission
            // prompts; a vault approval only exists in the sheet.
            if request.kind == .vaultApproval {
                if macAvailable, !delivered.shownInApp {
                    steps.append(.showInApp)
                }
                // A sheet left unanswered past the delay still reaches the
                // phone: being in front of the card is no answer.
                if settings.phoneEnabled, !delivered.phoneAlertSent,
                   now.timeIntervalSince(request.createdAt) >= settings.phoneAlertDelay {
                    steps.append(.phoneAlert)
                }
            }
            return steps
        }
        let away = macIsAway(presence, now: now, settings: settings)
        // The open sheet takes focus from the card, so the card no longer
        // counts as looked at; the sheet still shows the request.
        let sheetOnScreen = delivered.shownInApp && !away && presence?.isKanbanFrontmost == true
        var steps: [AttentionDeliveryStep] = []
        if macAvailable, settings.macNotifications, !delivered.macPosted, !sheetOnScreen {
            steps.append(.postMac)
        }
        guard settings.phoneEnabled else { return steps }
        let waited = now.timeIntervalSince(request.createdAt) >= settings.phoneAlertDelay
        if !delivered.phoneAlertSent, waited || away {
            steps.append(.phoneAlert)
        } else if settings.phoneSilentCopy, !delivered.phoneSilentSent, !delivered.phoneAlertSent {
            steps.append(.phoneSilent)
        }
        return steps
    }

    /// Why `steps` chose what it did, in a few words, for the log.
    public static func explain(
        _ request: AttentionRequest, presence: MacPresence?, now: Date,
        settings: AttentionPolicySettings, macAvailable: Bool
    ) -> String {
        guard request.isOpen else { return "resolved" }
        if isLookingAt(request, presence, now: now, settings: settings) {
            if request.kind == .vaultApproval {
                let alertAt = ISO8601DateFormatter().string(from: request.createdAt.addingTimeInterval(settings.phoneAlertDelay))
                let phone = settings.phoneEnabled ? "phone alert at \(alertAt) if still open" : "phone off"
                return "Rogerio is looking at card \(request.cardId ?? "?"), detail sheet in the app instead of a Mac notification; \(phone)"
            }
            return "Rogerio is looking at card \(request.cardId ?? "?"), which shows it, no notification"
        }
        let where_: String
        if presence == nil {
            where_ = "no presence report (counts as away)"
        } else if macIsAway(presence, now: now, settings: settings) {
            where_ = "Mac away"
        } else {
            where_ = "Mac in use"
        }
        let mac = !macAvailable ? "no Mac notifier" : settings.macNotifications ? "Mac on" : "Mac notifications off in Settings"
        let phone: String
        if !settings.phoneEnabled {
            phone = "phone off"
        } else {
            let alertAt = request.createdAt.addingTimeInterval(settings.phoneAlertDelay)
            let silent = settings.phoneSilentCopy ? "silent copy first" : "no silent copy"
            phone = "phone on (\(silent), alert at \(ISO8601DateFormatter().string(from: alertAt)) or when away)"
        }
        return "\(where_); \(mac); \(phone)"
    }

    /// When the request next needs a look, for a timer: the phone alert
    /// deadline, or nil when nothing is left to escalate.
    public static func nextCheck(for request: AttentionRequest, delivered: AttentionDeliveryState, settings: AttentionPolicySettings) -> Date? {
        guard request.isOpen, settings.phoneEnabled, !delivered.phoneAlertSent else { return nil }
        return request.createdAt.addingTimeInterval(settings.phoneAlertDelay)
    }
}

/// Attention requests waiting for the app's detail sheet, one at a time.
public enum AttentionSheetQueue {
    /// `queue` with `id` at the end, unless it is shown or already waits.
    public static func adding(_ id: String, to queue: [String], shown: String?) -> [String] {
        id == shown || queue.contains(id) ? queue : queue + [id]
    }

    /// The request the sheet shows now: the shown one while it is open, else
    /// the next open one that waits. A sheet never stays on a request that
    /// was answered elsewhere, withdrawn or dropped from the state.
    public static func current(shown: String?, waiting: inout [String], isOpen: (String) -> Bool) -> String? {
        if let shown, isOpen(shown) { return shown }
        return popNext(&waiting, isOpen: isOpen)
    }

    /// How many open requests wait behind the shown one.
    public static func waitingCount(_ queue: [String], isOpen: (String) -> Bool) -> Int {
        queue.filter(isOpen).count
    }

    /// Takes the first waiting request that is still open; drops the
    /// settled ones before it.
    public static func popNext(_ queue: inout [String], isOpen: (String) -> Bool) -> String? {
        while !queue.isEmpty {
            let id = queue.removeFirst()
            if isOpen(id) { return id }
        }
        return nil
    }
}
