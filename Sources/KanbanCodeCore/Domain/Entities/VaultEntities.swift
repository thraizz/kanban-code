import Foundation
import KanbanCodeRemoteKit

/// How a vault secret is released (see docs/vault.md).
public enum VaultTier: String, Codable, Sendable, CaseIterable, Comparable {
    /// Released to any card session, logged.
    case open
    /// Jev reads the command and the reason against the secret's rules:
    /// allow, ask the human, or deny.
    case judged
    /// The human approves on the Mac or the phone.
    case ask
    /// Never released.
    case never

    public static func < (a: VaultTier, b: VaultTier) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }

    public var label: String {
        switch self {
        case .open: "Open"
        case .judged: "Judged by Jev"
        case .ask: "Always ask"
        case .never: "Never"
        }
    }
}

/// How long an approval for a card lasts, or that every use asks.
public struct VaultLeasePolicy: Codable, Sendable, Equatable, Hashable {
    public static let maximumLease: TimeInterval = 2 * 24 * 3600

    /// Seconds a card lease lasts, capped at two days.
    public var leaseSeconds: TimeInterval
    /// No leases: each release asks.
    public var everyUseAsks: Bool

    public init(leaseSeconds: TimeInterval = VaultLeasePolicy.maximumLease, everyUseAsks: Bool = false) {
        self.leaseSeconds = min(max(leaseSeconds, 60), Self.maximumLease)
        self.everyUseAsks = everyUseAsks
    }

    public static let standard = VaultLeasePolicy()
    public static let everyUse = VaultLeasePolicy(everyUseAsks: true)
}

/// An AWS profile the vault serves as short-lived credentials: STS
/// AssumeRole (or GetSessionToken without a role) with the long-lived key
/// in `sourceSecret`, whose value is `{"accessKeyId","secretAccessKey"}`.
public struct VaultAwsRole: Codable, Sendable, Equatable, Hashable {
    public var sourceSecret: String
    public var roleArn: String?
    /// Session policies narrowing the role, e.g. ReadOnlyAccess.
    public var policyArns: [String]
    public var durationSeconds: Int
    public var region: String?

    public init(sourceSecret: String, roleArn: String?, policyArns: [String] = [], durationSeconds: Int = 3600, region: String? = nil) {
        self.sourceSecret = sourceSecret
        self.roleArn = roleArn
        self.policyArns = policyArns
        self.durationSeconds = durationSeconds
        self.region = region
    }
}

/// One secret in the vault. The value never leaves the master except in a
/// release; every listing uses `VaultSecretInfo`.
public struct VaultSecret: Codable, Sendable, Equatable {
    public var name: String
    public var value: String
    public var tier: VaultTier
    /// Plain-language rules Jev reads for judged releases, e.g. "only for
    /// deploys of the docs site; never to print or copy it".
    public var rules: String
    public var leasePolicy: VaultLeasePolicy
    public var tags: [String]
    public var aws: VaultAwsRole?
    /// Where it was imported from (paths, never values).
    public var sources: [String]
    public var createdAt: Date
    public var updatedAt: Date
    /// Set when deleted: the tombstone wins merges until it is older.
    public var deletedAt: Date?
    /// How approvals name it to the human, e.g. "Slack user token"; when
    /// nil, a label derived from the name.
    public var label: String?

    public init(
        name: String,
        value: String,
        tier: VaultTier,
        rules: String = "",
        leasePolicy: VaultLeasePolicy = .standard,
        tags: [String] = [],
        aws: VaultAwsRole? = nil,
        sources: [String] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil,
        label: String? = nil
    ) {
        self.name = name
        self.value = value
        self.tier = tier
        self.rules = rules
        self.leasePolicy = leasePolicy
        self.tags = tags
        self.aws = aws
        self.sources = sources
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.label = label
    }

    public var info: VaultSecretInfo {
        VaultSecretInfo(
            name: name, tier: tier, rules: rules, leasePolicy: leasePolicy, tags: tags, aws: aws,
            sources: sources, createdAt: createdAt, updatedAt: updatedAt, hasValue: !value.isEmpty,
            label: label
        )
    }

    /// The label approvals show: its own, or one derived from the name.
    public var displayLabel: String { AttentionCopy.secretLabel(name: name, label: label) }

    /// Secret names: letters, digits, `_ - . / :`, at most 128 characters.
    public static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 128 else { return false }
        return name.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || "_-./:".unicodeScalars.contains($0)
        }
    }
}

/// A secret as listings show it: everything but the value.
public struct VaultSecretInfo: Codable, Sendable, Equatable {
    public var name: String
    public var tier: VaultTier
    public var rules: String
    public var leasePolicy: VaultLeasePolicy
    public var tags: [String]
    public var aws: VaultAwsRole?
    public var sources: [String]
    public var createdAt: Date
    public var updatedAt: Date
    public var hasValue: Bool
    public var label: String? = nil
}

/// The decrypted contents of `vault.age`.
public struct VaultDocument: Codable, Sendable, Equatable {
    public var version: Int
    /// By name, tombstones included.
    public var secrets: [String: VaultSecret]

    public init(version: Int = 1, secrets: [String: VaultSecret] = [:]) {
        self.version = version
        self.secrets = secrets
    }

    public var live: [VaultSecret] {
        secrets.values.filter { $0.deletedAt == nil }.sorted { $0.name < $1.name }
    }

    /// Per name, the newer edit wins (a delete is an edit); on a tie the
    /// receiver's copy stays, so merging is idempotent.
    public func merged(with other: VaultDocument) -> VaultDocument {
        var out = self
        for (name, theirs) in other.secrets {
            if let mine = out.secrets[name], mine.updatedAt >= theirs.updatedAt { continue }
            out.secrets[name] = theirs
        }
        return out
    }
}

/// An approval for one card to use a secret until `expiresAt`.
public struct VaultLease: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var cardId: String
    public var secret: String
    public var scope: String?
    public var reason: String?
    public var grantedAt: Date
    public var expiresAt: Date
    /// "human:<device>" for approvals.
    public var grantedBy: String

    public init(id: String = KSUID.generate(prefix: "lease"), cardId: String, secret: String, scope: String? = nil,
                reason: String? = nil, grantedAt: Date = Date(), expiresAt: Date, grantedBy: String) {
        self.id = id
        self.cardId = cardId
        self.secret = secret
        self.scope = scope
        self.reason = reason
        self.grantedAt = grantedAt
        self.expiresAt = expiresAt
        self.grantedBy = grantedBy
    }

    public func isActive(at now: Date) -> Bool { expiresAt > now }
}

/// Who decided a release.
public enum VaultDecider: String, Codable, Sendable {
    case lease
    case tier
    case jev
    case human
    case rule
    case timeout
}

public enum VaultOutcome: String, Codable, Sendable {
    case allowed
    case denied
    /// Waiting on the human.
    case asked
    /// A hook-wrapped command went on without a secret that needs approval.
    case skipped
}

/// One line of the append-only audit log (`vault/audit.jsonl`).
public struct VaultAuditEntry: Codable, Sendable, Equatable {
    public var at: Date
    public var machine: String
    public var cardId: String?
    public var sessionId: String?
    public var secret: String
    public var tier: VaultTier?
    public var outcome: VaultOutcome
    public var decider: VaultDecider
    /// What the release was for: "run", "env", "get", "aws", "lease", "add", "edit".
    public var action: String
    public var command: String?
    public var reason: String?
    /// Why it was decided so (Jev's choice, the rule that fired).
    public var detail: String?
    public var requestId: String?

    public init(at: Date = Date(), machine: String, cardId: String?, sessionId: String? = nil, secret: String,
                tier: VaultTier?, outcome: VaultOutcome, decider: VaultDecider, action: String,
                command: String? = nil, reason: String? = nil, detail: String? = nil, requestId: String? = nil) {
        self.at = at
        self.machine = machine
        self.cardId = cardId
        self.sessionId = sessionId
        self.secret = secret
        self.tier = tier
        self.outcome = outcome
        self.decider = decider
        self.action = action
        self.command = command
        self.reason = reason
        self.detail = detail
        self.requestId = requestId
    }
}

/// The process asking for a secret, as the master verified it.
public struct VaultCaller: Codable, Sendable, Equatable {
    /// The card whose session the process runs in, when the master found
    /// it in the process ancestry (a tmux pane or a rush-hosted
    /// assistant of that card).
    public var cardId: String?
    /// The card the client claimed (KANBAN_CARD_ID), shown to the human
    /// when it could not be verified.
    public var claimedCardId: String?
    public var sessionId: String?
    public var pid: Int?
    /// Executable names from the caller up to launchd/init.
    public var ancestry: [String]
    /// Not on loopback: a device over the tailnet.
    public var remoteDevice: String?

    public init(cardId: String? = nil, claimedCardId: String? = nil, sessionId: String? = nil, pid: Int? = nil,
                ancestry: [String] = [], remoteDevice: String? = nil) {
        self.cardId = cardId
        self.claimedCardId = claimedCardId
        self.sessionId = sessionId
        self.pid = pid
        self.ancestry = ancestry
        self.remoteDevice = remoteDevice
    }

    public var insideCard: Bool { cardId != nil && remoteDevice == nil }

    /// The OpenClaw agent behind `cardId` when the caller is an OpenClaw
    /// agent rather than a card ("openclaw:<agent>"). Those get the tiers
    /// and leases of a card session under that id.
    public var openClawAgent: String? { cardId.flatMap(VaultCaller.openClawAgent(principal:)) }

    public static let openClawPrefix = "openclaw:"

    public static func openClawPrincipal(agent: String) -> String { openClawPrefix + agent }

    public static func openClawAgent(principal: String) -> String? {
        principal.hasPrefix(openClawPrefix) ? String(principal.dropFirst(openClawPrefix.count)) : nil
    }
}
