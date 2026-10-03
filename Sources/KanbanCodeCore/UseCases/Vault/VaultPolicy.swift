import Foundation

/// What the decision engine knows about one release of one secret.
public struct VaultDecisionInput: Sendable, Equatable {
    public var tier: VaultTier
    public var everyUseAsks: Bool
    /// The caller runs inside a card session the master verified.
    public var insideCard: Bool
    /// The card holds an active lease on the secret.
    public var hasLease: Bool
    /// Releases of this secret in the rate window, this one excluded.
    public var recentReleases: Int

    public init(tier: VaultTier, everyUseAsks: Bool = false, insideCard: Bool, hasLease: Bool = false, recentReleases: Int = 0) {
        self.tier = tier
        self.everyUseAsks = everyUseAsks
        self.insideCard = insideCard
        self.hasLease = hasLease
        self.recentReleases = recentReleases
    }
}

public enum VaultVerdict: Sendable, Equatable {
    case allow(VaultDecider, String)
    /// The human decides; the text says why it came to them.
    case ask(String)
    case deny(String)
    /// The secret is judged: ask Jev, then `VaultPolicy.afterJev`.
    case consultJev
}

/// Jev's answer to "release this secret to this command?".
public struct JevVerdict: Sendable, Equatable {
    public enum Choice: String, Sendable, CaseIterable {
        case allow, ask, deny
    }

    public var choice: Choice
    /// Probability of the chosen option, 0...1.
    public var confidence: Double

    public init(choice: Choice, confidence: Double) {
        self.choice = choice
        self.confidence = confidence
    }
}

/// The release rules of the vault, as pure functions:
///
/// 1. tier never: deny.
/// 2. not inside a verified card session: ask, whatever the tier.
/// 3. more than `rateLimit` releases of the secret in the window: ask.
/// 4. an active card lease (and the secret allows leases): allow.
/// 5. tier open: allow. judged: Jev. ask: the human.
public enum VaultPolicy {
    public static let rateLimit = 20
    public static let rateWindow: TimeInterval = 5 * 60
    /// Jev must be at least this sure to allow on its own.
    public static let jevAllowConfidence = 0.6
    /// How long the human has to answer before the request is denied.
    public static let approvalTimeout: TimeInterval = 60 * 60

    public static func decide(_ input: VaultDecisionInput, rateLimit: Int = VaultPolicy.rateLimit) -> VaultVerdict {
        if input.tier == .never {
            return .deny("this secret is never released")
        }
        if !input.insideCard {
            return .ask("the request does not come from a Kanban card session")
        }
        if input.recentReleases >= rateLimit {
            return .ask("released \(input.recentReleases) times in the last \(Int(rateWindow / 60)) minutes")
        }
        if input.hasLease && !input.everyUseAsks {
            return .allow(.lease, "the card holds a lease")
        }
        switch input.tier {
        case .open: return .allow(.tier, "open tier")
        case .judged: return .consultJev
        case .ask: return .ask(input.everyUseAsks ? "every use of this secret asks" : "this secret always asks")
        case .never: return .deny("this secret is never released")
        }
    }

    /// Turns Jev's answer into a verdict. No answer (Jev unreachable, an
    /// error, a timeout) goes to the human: the vault never allows on a
    /// failure.
    public static func afterJev(_ verdict: JevVerdict?) -> VaultVerdict {
        guard let verdict else { return .ask("Jev could not be reached") }
        switch verdict.choice {
        case .allow:
            if verdict.confidence >= jevAllowConfidence {
                return .allow(.jev, "Jev allowed (\(percent(verdict.confidence)))")
            }
            return .ask("Jev was unsure (\(percent(verdict.confidence)) allow)")
        case .ask:
            return .ask("Jev asked for a human (\(percent(verdict.confidence)))")
        case .deny:
            return .deny("Jev denied it against the secret's rules (\(percent(verdict.confidence)))")
        }
    }

    /// The options the human gets: no card lease for secrets that ask on
    /// every use, nor for callers outside a card.
    public static func approvalOptions(everyUseAsks: Bool, insideCard: Bool) -> [String] {
        let all = AttentionRequest.vaultApprovalOptions
        if everyUseAsks || !insideCard { return Array(all.dropFirst()) }
        return all
    }

    public enum Approval: Equatable, Sendable {
        case lease
        case once
        case deny
    }

    /// Reads the human's resolution; anything unrecognised denies.
    public static func approval(from resolution: String?) -> Approval {
        guard let resolution else { return .deny }
        let options = AttentionRequest.vaultApprovalOptions
        if resolution == options[0] { return .lease }
        if resolution == options[1] { return .once }
        let lower = resolution.lowercased()
        if lower.hasPrefix("approve for") || lower == "lease" { return .lease }
        if lower.hasPrefix("approve") || lower == "once" || lower == "allow" { return .once }
        return .deny
    }

    private static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

/// Releases per secret in a sliding window, in memory.
public struct VaultRateCounter: Sendable {
    private var events: [String: [Date]] = [:]
    public let window: TimeInterval

    public init(window: TimeInterval = VaultPolicy.rateWindow) {
        self.window = window
    }

    public func count(_ secret: String, now: Date) -> Int {
        (events[secret] ?? []).filter { now.timeIntervalSince($0) < window }.count
    }

    public mutating func record(_ secret: String, at now: Date) {
        var list = (events[secret] ?? []).filter { now.timeIntervalSince($0) < window }
        list.append(now)
        events[secret] = list
    }
}
