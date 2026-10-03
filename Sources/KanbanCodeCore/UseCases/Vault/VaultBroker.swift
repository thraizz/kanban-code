import Foundation
import KanbanCodeRemoteKit

/// Where the vault takes a decision to the human: an attention request on
/// the master, which the Mac and the phone show until one resolves it.
public protocol VaultApprovals: Sendable {
    func raise(_ request: AttentionRequest) async
    /// The resolution once the request was resolved, nil while open.
    func resolution(of id: String) async -> (resolution: String?, by: String)?
    /// Closes an unanswered request (timeout).
    func expire(id: String, resolution: String) async
}

/// Body of `POST /v1/vault/release`.
public struct VaultReleaseRequest: Codable, Sendable, Equatable {
    /// "run", "env", "get", "hook" (a command the Bash hook wrapped), "aws".
    public var mode: String
    public var names: [String]
    /// The command the secrets are for, as the agent wrote it.
    public var command: String?
    public var reason: String?
    public var cwd: String?
    /// What the client says its card is (KANBAN_CARD_ID); only a hint.
    public var cardId: String?
    public var sessionId: String?

    public init(mode: String, names: [String], command: String? = nil, reason: String? = nil, cwd: String? = nil,
                cardId: String? = nil, sessionId: String? = nil) {
        self.mode = mode
        self.names = names
        self.command = command
        self.reason = reason
        self.cwd = cwd
        self.cardId = cardId
        self.sessionId = sessionId
    }
}

/// Body of `PATCH /v1/vault/secrets`: one change to several secrets.
public struct VaultBatchEditRequest: Codable, Sendable, Equatable {
    public var names: [String]?
    /// Also every secret whose value starts with one of these.
    public var valuePrefixes: [String]?
    public var edit: VaultEditRequest

    public init(names: [String]? = nil, valuePrefixes: [String]? = nil, edit: VaultEditRequest) {
        self.names = names
        self.valuePrefixes = valuePrefixes
        self.edit = edit
    }
}

/// Body of `POST /v1/vault/request`: a lease for the card's whole task.
public struct VaultLeaseRequest: Codable, Sendable, Equatable {
    /// `NAME` or `NAME:scope`.
    public var names: [String]
    public var reason: String
    public var cardId: String?
    public var sessionId: String?

    public init(names: [String], reason: String, cardId: String? = nil, sessionId: String? = nil) {
        self.names = names
        self.reason = reason
        self.cardId = cardId
        self.sessionId = sessionId
    }
}

/// Body of `POST /v1/vault/secrets`.
public struct VaultAddRequest: Codable, Sendable, Equatable {
    public var name: String
    public var value: String
    public var tier: VaultTier?
    public var rules: String?
    public var tags: [String]?
    public var aws: VaultAwsRole?
    public var leasePolicy: VaultLeasePolicy?
    public var sources: [String]?
    public var label: String?
    /// Why the caller replaces a stored value, shown to the human.
    public var reason: String?

    public init(name: String, value: String, tier: VaultTier? = nil, rules: String? = nil, tags: [String]? = nil,
                aws: VaultAwsRole? = nil, leasePolicy: VaultLeasePolicy? = nil, sources: [String]? = nil,
                label: String? = nil, reason: String? = nil) {
        self.name = name
        self.value = value
        self.tier = tier
        self.rules = rules
        self.tags = tags
        self.aws = aws
        self.leasePolicy = leasePolicy
        self.sources = sources
        self.label = label
        self.reason = reason
    }
}

/// Body of `PATCH /v1/vault/secrets/{name}`.
public struct VaultEditRequest: Codable, Sendable, Equatable {
    public var tier: VaultTier?
    public var rules: String?
    public var tags: [String]?
    public var leasePolicy: VaultLeasePolicy?
    public var aws: VaultAwsRole?
    /// An empty label clears it.
    public var label: String?
    /// Why the caller wants the change, shown to the human.
    public var reason: String?

    public init(tier: VaultTier? = nil, rules: String? = nil, tags: [String]? = nil, leasePolicy: VaultLeasePolicy? = nil,
                aws: VaultAwsRole? = nil, label: String? = nil, reason: String? = nil) {
        self.tier = tier
        self.rules = rules
        self.tags = tags
        self.leasePolicy = leasePolicy
        self.aws = aws
        self.label = label
        self.reason = reason
    }

    func apply(to s: inout VaultSecret) {
        if let tier { s.tier = tier }
        if let rules { s.rules = rules }
        if let tags { s.tags = tags }
        if let leasePolicy { s.leasePolicy = leasePolicy }
        if let aws { s.aws = aws }
        if let label { s.label = label.isEmpty ? nil : label }
    }

    var summary: String {
        var parts: [String] = []
        if let tier { parts.append("tier \(tier.rawValue)") }
        if rules != nil { parts.append("rules") }
        if tags != nil { parts.append("tags") }
        if let leasePolicy { parts.append(leasePolicy.everyUseAsks ? "every use asks" : "leases up to \(Int(leasePolicy.leaseSeconds / 3600))h") }
        if aws != nil { parts.append("AWS role") }
        if label != nil { parts.append("label") }
        return parts.joined(separator: ", ")
    }

    /// What it changes, as the headline names it: "rules", "tier"...
    var changes: [String] {
        var parts: [String] = []
        if tier != nil { parts.append("tier") }
        if rules != nil { parts.append("rules") }
        if tags != nil { parts.append("tags") }
        if leasePolicy != nil { parts.append("lease time") }
        if aws != nil { parts.append("AWS role") }
        if label != nil { parts.append("label") }
        return parts
    }

    /// The proposed values, one line each, for the detail sheet.
    var changeLines: [String] {
        var lines: [String] = []
        if let tier { lines.append("Tier: \(tier.label)") }
        if let rules { lines.append("Rules: \(rules.isEmpty ? "(none)" : rules)") }
        if let tags { lines.append("Tags: \(tags.isEmpty ? "(none)" : tags.joined(separator: ", "))") }
        if let leasePolicy {
            lines.append(leasePolicy.everyUseAsks ? "Lease time: every use asks" : "Lease time: \(AttentionCopy.duration(leasePolicy.leaseSeconds))")
        }
        if let aws { lines.append("AWS role: \(aws.roleArn ?? "none (session token)") from \(aws.sourceSecret)") }
        if let label { lines.append("Label: \(label.isEmpty ? "(derived from the name)" : label)") }
        return lines
    }
}

/// What a vault route answers: granted (with values), pending (poll
/// `GET /v1/vault/pending/{id}`), or denied.
public struct VaultResponse: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        case granted, pending, denied
    }

    public var status: Status
    public var message: String
    public var id: String?
    public var values: [String: String]?
    /// Names a hook-wrapped command went on without.
    public var skipped: [String]?
    public var credentials: AwsProcessCredentials?
    public var card: String?

    public init(status: Status, message: String, id: String? = nil, values: [String: String]? = nil,
                skipped: [String]? = nil, credentials: AwsProcessCredentials? = nil, card: String? = nil) {
        self.status = status
        self.message = message
        self.id = id
        self.values = values
        self.skipped = skipped
        self.credentials = credentials
        self.card = card
    }

    static func denied(_ message: String) -> VaultResponse { .init(status: .denied, message: message) }
}

/// Decides every release of the vault: the policy, Jev, leases, the
/// human, the audit log. Shared by the Mac app and the headless server.
public actor VaultBroker {
    public let store: VaultStore
    public let jev: (any JevJudging)?
    public let approvals: (any VaultApprovals)?
    public let machine: String
    public let cardTitle: @Sendable (String) async -> String?
    /// A card's recent prompts for Jev, nil when its transcript is not here.
    public let cardPrompts: @Sendable (String) async -> CardPrompts?
    public let sts: @Sendable (AwsAccessKey, VaultAwsRole, String) async throws -> AwsProcessCredentials
    /// How long a hook-wrapped command reuses Jev's allow for the same card.
    public var hookReuse: TimeInterval = 10 * 60
    public var approvalTimeout: TimeInterval = VaultPolicy.approvalTimeout
    public var pollInterval: TimeInterval = 1

    struct LeaseWant: Codable, Sendable {
        var name: String
        var scope: String?
    }

    enum PendingAction: Codable, Sendable {
        case release(VaultReleaseRequest, [String])
        case lease([LeaseWant], reason: String)
        case add(VaultAddRequest)
        case edit([String], VaultEditRequest)
        case delete(String)
    }

    private struct Pending: Sendable {
        var action: PendingAction
        var caller: VaultCaller
        var result: VaultResponse?
        var createdAt: Date
        var everyUseAsks: Bool
        var request: AttentionRequest
    }

    /// An open request as `pending.age` keeps it, so a restart of the
    /// master asks again and the caller's poll still finds it.
    struct SavedPending: Codable, Sendable {
        var id: String
        var action: PendingAction
        var caller: VaultCaller
        var createdAt: Date
        var everyUseAsks: Bool
        var request: AttentionRequest
    }

    private var pending: [String: Pending] = [:]
    private var hookAllows: [String: Date] = [:]
    private var restoring: Task<Void, Never>?

    public init(
        store: VaultStore,
        jev: (any JevJudging)?,
        approvals: (any VaultApprovals)?,
        machine: String,
        cardTitle: @escaping @Sendable (String) async -> String? = { _ in nil },
        cardPrompts: @escaping @Sendable (String) async -> CardPrompts? = { _ in nil },
        sts: @escaping @Sendable (AwsAccessKey, VaultAwsRole, String) async throws -> AwsProcessCredentials = { key, role, name in
            try await AwsSts(region: "us-east-1").credentials(key: key, role: role, sessionName: name)
        }
    ) {
        self.store = store
        self.jev = jev
        self.approvals = approvals
        self.machine = machine
        self.cardTitle = cardTitle
        self.cardPrompts = cardPrompts
        self.sts = sts
    }

    public func configure(approvalTimeout: TimeInterval? = nil, pollInterval: TimeInterval? = nil) {
        if let approvalTimeout { self.approvalTimeout = approvalTimeout }
        if let pollInterval { self.pollInterval = pollInterval }
    }

    // MARK: - Release

    public func release(_ req: VaultReleaseRequest, caller: VaultCaller, now: Date = Date()) async -> VaultResponse {
        let hook = req.mode == "hook"
        guard !req.names.isEmpty else { return .denied("name at least one secret") }
        var secrets: [VaultSecret] = []
        do {
            for name in req.names {
                guard let s = try await store.secret(name) else {
                    return .denied("no secret named \(name) in the vault (add it: kv add \(name))")
                }
                secrets.append(s)
            }
        } catch {
            return .denied("the vault is locked on this machine: \(error)")
        }

        var allowed: [(VaultSecret, VaultDecider, String)] = []
        var asks: [(VaultSecret, String)] = []
        var denies: [(VaultSecret, String)] = []
        var judged: [VaultSecret] = []
        for s in secrets {
            if req.mode == "get" && (s.tier == .ask || s.leasePolicy.everyUseAsks) {
                denies.append((s, "kv get never prints a secret that asks; use kv run"))
                continue
            }
            if req.mode != "aws" && s.aws != nil {
                denies.append((s, "\(s.name) is an AWS profile: use kv aws"))
                continue
            }
            let verdict = await verdict(for: s, req: req, caller: caller, now: now)
            switch verdict {
            case .allow(let by, let why): allowed.append((s, by, why))
            case .ask(let why): asks.append((s, why))
            case .deny(let why): denies.append((s, why))
            case .consultJev: judged.append(s)
            }
        }
        for (s, answer) in await judge(judged, req: req, caller: caller) {
            switch answer {
            case .allow(let by, let why):
                allowed.append((s, by, why))
                if req.mode == "hook" { hookAllows["\(caller.cardId ?? "")|\(s.name)"] = now }
            case .ask(let why): asks.append((s, why))
            case .deny(let why): denies.append((s, why))
            case .consultJev: asks.append((s, "Jev was not consulted"))
            }
        }

        // A hook-wrapped command goes on without what it was not given:
        // that is a skip, not a refusal of anything the agent asked for.
        for (s, why) in denies {
            await audit(s, req: req, caller: caller, outcome: hook ? .skipped : .denied,
                        decider: why.hasPrefix("Jev") ? .jev : .rule, detail: why)
        }

        if hook {
            for (s, why) in asks {
                await audit(s, req: req, caller: caller, outcome: .skipped, decider: .rule, detail: why)
            }
            var values: [String: String] = [:]
            for (s, by, why) in allowed {
                values[s.name] = s.value
                await audit(s, req: req, caller: caller, outcome: .allowed, decider: by, detail: why)
            }
            let skipped = (asks.map(\.0.name) + denies.map(\.0.name)).sorted()
            let message = skipped.isEmpty ? "released" : "went on without \(skipped.joined(separator: ", ")) (kv request \(skipped.joined(separator: " ")) --reason \"...\" to ask for them)"
            return VaultResponse(status: .granted, message: message, values: values, skipped: skipped, card: caller.cardId)
        }

        if !denies.isEmpty {
            // Jev's verdict carries no explanation: the rules it read are the why.
            let lines = denies.map { s, why in
                why.hasPrefix("Jev") && !s.rules.isEmpty ? "\(s.name): \(why). Its rules: \(s.rules)" : "\(s.name): \(why)"
            }.joined(separator: "\n  ")
            return .denied("denied:\n  \(lines)")
        }
        if asks.isEmpty {
            return await grant(allowed.map { ($0.0, $0.1, $0.2) }, req: req, caller: caller, now: now)
        }
        return await ask(
            action: .release(req, asks.map(\.0.name)),
            secrets: asks.map(\.0), whys: asks.map(\.1), caller: caller,
            command: req.command, reason: req.reason, now: now
        )
    }

    private func verdict(for s: VaultSecret, req: VaultReleaseRequest, caller: VaultCaller, now: Date) async -> VaultVerdict {
        let lease = caller.cardId.flatMap { _ in caller.insideCard ? caller.cardId : nil }
        var hasLease = false
        if let card = lease { hasLease = await store.activeLease(cardId: card, secret: s.name, now: now) != nil }
        let reuseKey = "\(caller.cardId ?? "")|\(s.name)"
        let reusing = req.mode == "hook" && caller.insideCard && (hookAllows[reuseKey].map { now.timeIntervalSince($0) < hookReuse } ?? false)
        let input = VaultDecisionInput(
            tier: s.tier, everyUseAsks: s.leasePolicy.everyUseAsks, insideCard: caller.insideCard,
            // Hook-wrapped commands load the env on every Bash call: that
            // volume is ambient, so it neither counts nor trips the limit.
            hasLease: hasLease, recentReleases: req.mode == "hook" ? 0 : await store.recentReleases(s.name, now: now)
        )
        let first = VaultPolicy.decide(input)
        guard first == .consultJev else { return first }
        if reusing { return .allow(.jev, "reused Jev's allow for this card") }
        return .consultJev
    }

    /// Asks Jev about every judged secret at once.
    private func judge(_ secrets: [VaultSecret], req: VaultReleaseRequest, caller: VaultCaller) async -> [(VaultSecret, VaultVerdict)] {
        guard !secrets.isEmpty else { return [] }
        guard let jev else { return secrets.map { ($0, VaultPolicy.afterJev(nil)) } }
        let title: String? = if let card = caller.cardId { await principalTitle(card) } else { nil }
        // Only a session the master matched to a card is read: a claimed id
        // must not borrow another card's prompts.
        var prompts: CardPrompts?
        if let card = caller.cardId, caller.insideCard, VaultCaller.openClawAgent(principal: card) == nil {
            prompts = await cardPrompts(card)
        }
        return await withTaskGroup(of: (Int, VaultVerdict).self) { group in
            for (i, s) in secrets.enumerated() {
                let question = JevReleaseQuestion(
                    secret: s.name, rules: s.rules, command: req.command ?? "(no command given)",
                    reason: req.reason, cardTitle: title, cwd: req.cwd, prompts: prompts
                )
                let subject = "\(s.name) for \(caller.cardId ?? "outside")"
                let evidence = prompts.map { "\($0.typed.count + $0.earlier.count) prompts entered in the card, \($0.delivered.count) from other senders" }
                    ?? "no card transcript"
                group.addTask {
                    let verdict = await jev.judge(question)
                    let answer = verdict.map { "\($0.choice.rawValue) \(Int(($0.confidence * 100).rounded()))%" } ?? "no answer"
                    KanbanCodeLog.info("vault", "Jev on \(subject): \(answer) (\(evidence))")
                    return (i, VaultPolicy.afterJev(verdict))
                }
            }
            var out = [(VaultSecret, VaultVerdict)?](repeating: nil, count: secrets.count)
            for await (i, verdict) in group { out[i] = (secrets[i], verdict) }
            return out.compactMap { $0 }
        }
    }

    private func grant(_ allowed: [(VaultSecret, VaultDecider, String)], req: VaultReleaseRequest, caller: VaultCaller,
                       now: Date, requestId: String? = nil) async -> VaultResponse {
        var values: [String: String] = [:]
        for (s, by, why) in allowed {
            await store.recordRelease(s.name, now: now)
            await audit(s, req: req, caller: caller, outcome: .allowed, decider: by, detail: why, requestId: requestId)
            values[s.name] = s.value
        }
        if req.mode == "aws" {
            guard let s = allowed.first?.0, let role = s.aws else { return .denied("not an AWS profile") }
            do {
                guard let source = try await store.secret(role.sourceSecret) else {
                    return .denied("the AWS key \(role.sourceSecret) is not in the vault")
                }
                let key = try JSONDecoder().decode(AwsAccessKey.self, from: Data(source.value.utf8))
                let session = "kanban-\(caller.cardId ?? "outside")"
                let credentials = try await sts(key, role, session)
                return VaultResponse(status: .granted, message: "released", id: requestId, credentials: credentials, card: caller.cardId)
            } catch {
                return .denied("STS failed: \(error)")
            }
        }
        return VaultResponse(status: .granted, message: "released", id: requestId, values: values, card: caller.cardId)
    }

    /// A card's title, or "OpenClaw agent <id>" for an OpenClaw principal.
    private func principalTitle(_ id: String) async -> String? {
        if let agent = VaultCaller.openClawAgent(principal: id) { return "OpenClaw agent \(agent)" }
        return await cardTitle(id)
    }

    // MARK: - Leases

    public func requestLease(_ req: VaultLeaseRequest, caller: VaultCaller, now: Date = Date()) async -> VaultResponse {
        guard let card = caller.cardId, caller.insideCard else {
            return .denied("leases are for card sessions: run kv request from inside a Kanban card")
        }
        var wanted: [LeaseWant] = []
        var secrets: [VaultSecret] = []
        for raw in req.names {
            let (name, scope) = Self.splitScope(raw)
            guard let s = (try? await store.secret(name)) ?? nil else {
                return .denied("no secret named \(name) in the vault")
            }
            if s.tier == .never { return .denied("\(name) is never released") }
            if s.leasePolicy.everyUseAsks { return .denied("every use of \(name) asks; no lease is possible, use kv run") }
            if await store.activeLease(cardId: card, secret: name, now: now) == nil {
                wanted.append(LeaseWant(name: name, scope: scope))
                secrets.append(s)
            }
        }
        guard !wanted.isEmpty else {
            return VaultResponse(status: .granted, message: "the card already holds leases on all of them", card: card)
        }
        return await ask(
            action: .lease(wanted, reason: req.reason), secrets: secrets,
            whys: secrets.map { _ in "lease for the card's task" }, caller: caller,
            command: nil, reason: req.reason, now: now, leaseOnly: true
        )
    }

    public static func splitScope(_ raw: String) -> (String, String?) {
        // AWS profile names carry colons themselves (aws:lw-prod:read):
        // only a trailing ":scope" after a known secret splits.
        guard let colon = raw.lastIndex(of: ":"), !raw.hasPrefix("aws:") else { return (raw, nil) }
        let scope = String(raw[raw.index(after: colon)...])
        return scope.isEmpty ? (raw, nil) : (String(raw[..<colon]), scope)
    }

    // MARK: - Admin

    /// Adds a secret. A new name is added at once; replacing a value
    /// someone else stored needs the human unless `trusted`.
    public func add(_ req: VaultAddRequest, caller: VaultCaller, trusted: Bool, now: Date = Date()) async -> VaultResponse {
        guard VaultSecret.isValidName(req.name) else {
            return .denied("secret names use letters, digits and _ - . / : only")
        }
        let existing = (try? await store.secret(req.name)) ?? nil
        if existing != nil && !trusted {
            return await ask(action: .add(req), secrets: [existing!], whys: ["replacing a stored value always asks"], caller: caller,
                             command: nil, reason: req.reason, now: now, leaseOnly: false, admin: true)
        }
        return await apply(.add(req), caller: caller, now: now)
    }

    public func edit(_ name: String, _ req: VaultEditRequest, caller: VaultCaller, trusted: Bool, now: Date = Date()) async -> VaultResponse {
        guard let s = (try? await store.secret(name)) ?? nil else { return .denied("no secret named \(name)") }
        if !trusted {
            return await ask(action: .edit([name], req), secrets: [s], whys: ["changing a secret always asks"], caller: caller,
                             command: nil, reason: req.reason, now: now, leaseOnly: false, admin: true)
        }
        return await apply(.edit([name], req), caller: caller, now: now)
    }

    /// The same change to several secrets, in one approval: the names given
    /// plus every secret whose value starts with one of `valuePrefixes`
    /// (matched here on the master; values never leave it).
    public func editMany(_ request: VaultBatchEditRequest, caller: VaultCaller, trusted: Bool, now: Date = Date()) async -> VaultResponse {
        var wanted = Set(request.names ?? [])
        let prefixes = (request.valuePrefixes ?? []).filter { !$0.isEmpty }
        var secrets: [VaultSecret] = []
        do {
            if !prefixes.isEmpty {
                for info in try await store.list() {
                    if let s = try await store.secret(info.name), prefixes.contains(where: { s.value.hasPrefix($0) }) {
                        wanted.insert(s.name)
                    }
                }
            }
            for name in wanted.sorted() {
                guard let s = try await store.secret(name) else { return .denied("no secret named \(name)") }
                secrets.append(s)
            }
        } catch {
            return .denied("the vault is locked on this machine: \(error)")
        }
        guard !secrets.isEmpty else { return .denied("no secret matches") }
        let names = secrets.map(\.name)
        if !trusted {
            return await ask(action: .edit(names, request.edit), secrets: secrets,
                             whys: secrets.map { _ in "changing a secret always asks" }, caller: caller,
                             command: nil, reason: request.edit.reason, now: now, leaseOnly: false, admin: true)
        }
        return await apply(.edit(names, request.edit), caller: caller, now: now)
    }

    public func delete(_ name: String, caller: VaultCaller, trusted: Bool, reason: String? = nil, now: Date = Date()) async -> VaultResponse {
        guard let s = (try? await store.secret(name)) ?? nil else { return .denied("no secret named \(name)") }
        if !trusted {
            return await ask(action: .delete(name), secrets: [s], whys: ["deleting a secret always asks"], caller: caller,
                             command: nil, reason: reason, now: now, leaseOnly: false, admin: true)
        }
        return await apply(.delete(name), caller: caller, now: now)
    }

    private func apply(_ action: PendingAction, caller: VaultCaller, now: Date, by: VaultDecider = .rule, requestId: String? = nil) async -> VaultResponse {
        do {
            switch action {
            case .add(let req):
                let existing = try await store.secret(req.name)
                let secret = VaultSecret(
                    name: req.name, value: req.value,
                    tier: req.tier ?? existing?.tier ?? .judged,
                    rules: req.rules ?? existing?.rules ?? "",
                    leasePolicy: req.leasePolicy ?? existing?.leasePolicy ?? .standard,
                    tags: req.tags ?? existing?.tags ?? [],
                    aws: req.aws ?? existing?.aws,
                    sources: Array(Set((existing?.sources ?? []) + (req.sources ?? []))).sorted(),
                    createdAt: existing?.createdAt ?? now,
                    label: req.label.flatMap { $0.isEmpty ? nil : $0 } ?? existing?.label
                )
                try await store.upsert(secret, now: now)
                await store.append(VaultAuditEntry(at: now, machine: machine, cardId: caller.cardId, sessionId: caller.sessionId,
                                                   secret: req.name, tier: secret.tier, outcome: .allowed, decider: by,
                                                   action: existing == nil ? "add" : "replace", requestId: requestId))
                return VaultResponse(status: .granted, message: existing == nil ? "added \(req.name)" : "replaced \(req.name)", id: requestId)
            case .edit(let names, let req):
                for name in names {
                    try await store.update(name, now: now) { req.apply(to: &$0) }
                    await store.append(VaultAuditEntry(at: now, machine: machine, cardId: caller.cardId, sessionId: caller.sessionId,
                                                       secret: name, tier: req.tier, outcome: .allowed, decider: by,
                                                       action: "edit", detail: req.summary, requestId: requestId))
                }
                return VaultResponse(status: .granted, message: "changed \(names.joined(separator: ", ")): \(req.summary)", id: requestId)
            case .delete(let name):
                try await store.delete(name, now: now)
                await store.append(VaultAuditEntry(at: now, machine: machine, cardId: caller.cardId, sessionId: caller.sessionId,
                                                   secret: name, tier: nil, outcome: .allowed, decider: by,
                                                   action: "delete", requestId: requestId))
                return VaultResponse(status: .granted, message: "deleted \(name)", id: requestId)
            case .release, .lease:
                return .denied("not an admin action")
            }
        } catch {
            return .denied("\(error)")
        }
    }

    // MARK: - Asking the human

    private func ask(action: PendingAction, secrets: [VaultSecret], whys: [String], caller: VaultCaller,
                     command: String?, reason: String?, now: Date, leaseOnly: Bool = false, admin: Bool = false) async -> VaultResponse {
        guard let approvals else {
            return .denied("needs a human approval, and this master cannot ask for one")
        }
        let id = KSUID.generate(prefix: "vault")
        let everyUse = secrets.contains { $0.leasePolicy.everyUseAsks }
        var options = VaultPolicy.approvalOptions(everyUseAsks: everyUse || admin, insideCard: caller.insideCard)
        if leaseOnly { options = [AttentionRequest.vaultApprovalOptions[0], AttentionRequest.vaultApprovalOptions[2]] }
        let title: String? = if let card = caller.cardId { await principalTitle(card) } else { nil }
        let details = approvalDetails(action: action, secrets: secrets, whys: whys, caller: caller, title: title,
                                      command: command, reason: reason, options: options)
        let request = AttentionRequest(
            id: id,
            cardId: caller.openClawAgent == nil ? caller.cardId : nil,
            kind: .vaultApproval,
            title: AttentionCopy.vaultHeadline(details),
            body: AttentionCopy.vaultBody(details),
            options: options,
            createdAt: now,
            requiresBiometry: admin || secrets.contains { $0.tier >= .ask },
            sessionId: caller.sessionId,
            vault: details
        )
        pending[id] = Pending(action: action, caller: caller, result: nil, createdAt: now, everyUseAsks: everyUse, request: request)
        await persist()
        for (s, why) in zip(secrets, whys) {
            await store.append(VaultAuditEntry(at: now, machine: machine, cardId: caller.cardId, sessionId: caller.sessionId,
                                               secret: s.name, tier: s.tier, outcome: .asked, decider: .rule,
                                               action: actionName(action), command: command, reason: reason, detail: why, requestId: id))
        }
        await approvals.raise(request)
        Task { await self.waitForHuman(id: id) }
        var waitingOn = caller.insideCard
            ? "Waiting for Rogerio's approval on his phone or Mac (\(caller.openClawAgent == nil ? "card " : "")\(title ?? caller.cardId ?? "?"))"
            : "Waiting for Rogerio's approval on his phone or Mac (this process is not in a Kanban card session)"
        waitingOn += ", up to \(Int(approvalTimeout / 60)) minutes"
        if AttentionCopy.usableReason(reason) == nil {
            waitingOn += ". He sees no reason from you; next time: \(AttentionCopy.reasonGuidance)"
        }
        return VaultResponse(status: .pending, message: waitingOn, id: id, card: caller.cardId)
    }

    /// What the detail sheet shows for a request about to be raised.
    private func approvalDetails(action: PendingAction, secrets: [VaultSecret], whys: [String], caller: VaultCaller,
                                 title: String?, command: String?, reason: String?, options: [String]) -> VaultApprovalDetails {
        var kind: VaultApprovalDetails.Action
        var mode: String?
        var cwd: String?
        var changes: [String] = []
        var changeLines: [String] = []
        switch action {
        case .release(let req, _):
            kind = req.mode == "aws" ? .aws : .use
            mode = req.mode
            cwd = req.cwd
        case .lease:
            kind = .lease
        case .add:
            kind = .replace
        case .edit(_, let req):
            kind = .edit
            changes = req.changes
            changeLines = req.changeLines
        case .delete:
            kind = .delete
        }
        let origin: VaultApprovalDetails.Origin =
            caller.openClawAgent != nil ? .openClaw : (caller.insideCard ? .card : .outside)
        let offersLease = options.contains(AttentionRequest.vaultApprovalOptions[0])
        return VaultApprovalDetails(
            action: kind,
            origin: origin,
            principal: caller.openClawAgent ?? (caller.insideCard ? (title ?? caller.cardId) : nil),
            secrets: secrets.map {
                .init(name: $0.name, label: $0.displayLabel, tier: $0.tier.label, everyUseAsks: $0.leasePolicy.everyUseAsks)
            },
            mode: mode,
            changes: changes,
            changeLines: changeLines,
            whys: Array(Set(whys)).sorted(),
            command: command.map { String($0.prefix(2000)) },
            cwd: cwd,
            reason: reason,
            leaseSeconds: offersLease ? secrets.map(\.leasePolicy.leaseSeconds).min() : nil,
            claimedCardId: caller.insideCard ? nil : caller.claimedCardId,
            remoteDevice: caller.remoteDevice,
            ancestry: caller.ancestry
        )
    }

    private func actionName(_ action: PendingAction) -> String {
        switch action {
        case .release(let req, _): req.mode
        case .lease: "lease"
        case .add: "replace"
        case .edit: "edit"
        case .delete: "delete"
        }
    }

    private func waitForHuman(id: String) async {
        guard let approvals, let started = pending[id]?.createdAt else { return }
        while Date().timeIntervalSince(started) < approvalTimeout {
            if let answer = await approvals.resolution(of: id) {
                await settle(id: id, approval: VaultPolicy.approval(from: answer.resolution), by: answer.by)
                return
            }
            try? await Task.sleep(for: .seconds(pollInterval))
        }
        await approvals.expire(id: id, resolution: "Deny")
        await settle(id: id, approval: .deny, by: "timeout")
    }

    private func settle(id: String, approval: VaultPolicy.Approval, by: String) async {
        guard let p = pending[id], p.result == nil else { return }
        let now = Date()
        let result: VaultResponse
        switch (approval, p.action) {
        case (.deny, _):
            let timedOut = by == "timeout"
            let message = timedOut
                ? "No answer in \(Int(approvalTimeout / 60)) minutes, so it was denied. Ask again with a reason: kv request NAME --reason \"...\""
                : "Rogerio denied it."
            for name in names(of: p.action) {
                await store.append(VaultAuditEntry(at: now, machine: machine, cardId: p.caller.cardId, sessionId: p.caller.sessionId,
                                                   secret: name, tier: nil, outcome: .denied, decider: timedOut ? .timeout : .human,
                                                   action: actionName(p.action), detail: "by \(by)", requestId: id))
            }
            result = VaultResponse(status: .denied, message: message, id: id, card: p.caller.cardId)

        case (let approved, .release(let req, let asked)):
            if approved == .lease, let card = p.caller.cardId, p.caller.insideCard, !p.everyUseAsks {
                for name in asked {
                    let policy = ((try? await store.secret(name)) ?? nil)?.leasePolicy ?? .standard
                    try? await store.grantLease(VaultLease(cardId: card, secret: name, reason: req.reason, grantedAt: now,
                                                           expiresAt: now.addingTimeInterval(policy.leaseSeconds), grantedBy: "human:\(by)"))
                }
            }
            var allowed: [(VaultSecret, VaultDecider, String)] = []
            for name in req.names {
                guard let s = (try? await store.secret(name)) ?? nil else { continue }
                let decider: VaultDecider = asked.contains(name) ? .human : .tier
                allowed.append((s, decider, asked.contains(name) ? "approved by \(by)" : "allowed with the request"))
            }
            result = await grant(allowed, req: req, caller: p.caller, now: now, requestId: id)

        case (_, .lease(let wanted, let reason)):
            guard let card = p.caller.cardId else {
                result = .denied("no card to lease to")
                break
            }
            for want in wanted {
                let (name, scope) = (want.name, want.scope)
                let policy = ((try? await store.secret(name)) ?? nil)?.leasePolicy ?? .standard
                try? await store.grantLease(VaultLease(cardId: card, secret: name, scope: scope, reason: reason, grantedAt: now,
                                                       expiresAt: now.addingTimeInterval(policy.leaseSeconds), grantedBy: "human:\(by)"))
                await store.append(VaultAuditEntry(at: now, machine: machine, cardId: card, sessionId: p.caller.sessionId,
                                                   secret: name, tier: nil, outcome: .allowed, decider: .human,
                                                   action: "lease", reason: reason, detail: "by \(by)", requestId: id))
            }
            result = VaultResponse(status: .granted, message: "leased \(wanted.map(\.name).joined(separator: ", ")) to the card", id: id, card: card)

        case (_, let action):
            result = await apply(action, caller: p.caller, now: now, by: .human, requestId: id)
        }
        pending[id]?.result = result
        await persist()
        // Unclaimed results go after a while; values do not linger.
        Task {
            try? await Task.sleep(for: .seconds(120))
            self.forget(id)
        }
    }

    /// Writes the open requests to `pending.age`. Settled ones are left
    /// out: a result can carry secret values, and its caller polls it
    /// within a second or two.
    private func persist() async {
        let open = pending.filter { $0.value.result == nil }.map { id, p in
            SavedPending(id: id, action: p.action, caller: p.caller, createdAt: p.createdAt,
                         everyUseAsks: p.everyUseAsks, request: p.request)
        }.sorted { $0.createdAt < $1.createdAt }
        do {
            try await store.savePending(open.isEmpty ? nil : try JSONEncoder.vault.encode(open))
        } catch {
            KanbanCodeLog.warn("vault", "could not save the open vault requests: \(error)")
        }
    }

    /// Picks up the requests that were open when the master stopped: raises
    /// their attention requests again and waits for the answer, from the
    /// original creation time, so the timeout is the same as without the
    /// restart. Runs once; a poll waits for it, so a caller polling right
    /// after the master came back still finds its request.
    public func restore() async {
        if restoring == nil { restoring = Task { await self.restoreSaved() } }
        await restoring?.value
    }

    private func restoreSaved() async {
        guard let approvals, let data = await store.loadPending() else { return }
        let saved: [SavedPending]
        do {
            saved = try JSONDecoder.vault.decode([SavedPending].self, from: data)
        } catch {
            KanbanCodeLog.warn("vault", "could not read the open vault requests: \(error)")
            return
        }
        var restored = 0
        for s in saved where pending[s.id] == nil {
            pending[s.id] = Pending(action: s.action, caller: s.caller, result: nil, createdAt: s.createdAt,
                                    everyUseAsks: s.everyUseAsks, request: s.request)
            await approvals.raise(s.request)
            let id = s.id
            Task { await self.waitForHuman(id: id) }
            restored += 1
        }
        if restored > 0 { KanbanCodeLog.info("vault", "restored \(restored) open vault request(s)") }
    }

    private func forget(_ id: String) {
        pending[id] = nil
    }

    private func names(of action: PendingAction) -> [String] {
        switch action {
        case .release(_, let asked): asked
        case .lease(let wanted, _): wanted.map(\.name)
        case .add(let req): [req.name]
        case .edit(let names, _): names
        case .delete(let name): [name]
        }
    }

    /// The result of a pending request: still pending, or its outcome
    /// (handed out once, then forgotten).
    public func poll(id: String) async -> VaultResponse {
        await restore()
        guard let p = pending[id] else {
            return VaultResponse(status: .denied, message: "no pending vault request \(id) (it expired or was already answered)", id: id)
        }
        guard let result = p.result else {
            return VaultResponse(status: .pending, message: "still waiting for Rogerio's approval", id: id, card: p.caller.cardId)
        }
        pending[id] = nil
        return result
    }

    // MARK: - Audit

    private func audit(_ s: VaultSecret, req: VaultReleaseRequest, caller: VaultCaller, outcome: VaultOutcome,
                       decider: VaultDecider, detail: String?, requestId: String? = nil) async {
        await store.append(VaultAuditEntry(
            at: Date(), machine: machine, cardId: caller.cardId ?? caller.claimedCardId.map { "unverified:\($0)" },
            sessionId: caller.sessionId ?? req.sessionId, secret: s.name, tier: s.tier, outcome: outcome, decider: decider,
            action: req.mode, command: req.command.map { String($0.prefix(2000)) }, reason: req.reason, detail: detail,
            requestId: requestId
        ))
    }
}
