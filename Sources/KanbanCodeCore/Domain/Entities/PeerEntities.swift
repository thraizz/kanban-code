import Foundation

// MARK: - Sync stamp

/// A Lamport stamp: a counter every machine keeps ahead of every stamp it
/// has seen, plus the machine that wrote it. Stamps order totally: counter
/// first, machine id to break a tie, so every machine picks the same winner.
public struct SyncStamp: Codable, Sendable, Equatable, Hashable, Comparable {
    public var counter: Int
    public var machine: String

    public init(counter: Int, machine: String) {
        self.counter = counter
        self.machine = machine
    }

    public static func < (lhs: SyncStamp, rhs: SyncStamp) -> Bool {
        if lhs.counter != rhs.counter { return lhs.counter < rhs.counter }
        return lhs.machine < rhs.machine
    }
}

extension Optional where Wrapped == SyncStamp {
    /// A missing stamp is older than any stamp.
    static func isNewer(_ lhs: SyncStamp?, than rhs: SyncStamp?) -> Bool {
        switch (lhs, rhs) {
        case (nil, _): return false
        case (.some, nil): return true
        case let (.some(a), .some(b)): return a > b
        }
    }
}

// MARK: - Machine identity

/// This master's identity among its peers. Created once per machine and
/// kept in `~/.kanban-code/machine.json`.
public struct MachineIdentity: Codable, Sendable, Equatable, Hashable {
    public var id: String
    public var name: String
    /// Set by a master that runs all the time (`kanban-code-server`). Such a
    /// master is the channels home and polls pull requests while it is online.
    public var alwaysOn: Bool?

    public init(id: String = KSUID.generate(prefix: "machine"), name: String, alwaysOn: Bool? = nil) {
        self.id = id
        self.name = name
        self.alwaysOn = alwaysOn
    }
}

/// Which master does the work only one of them should do.
public enum MasterRoles {
    /// The master that polls GitHub for the pull requests of every card:
    /// an always-on master when one is online, else the one with the lowest
    /// machine id among the masters online. Both sides compute the same
    /// answer from what they see, and when they see each other differently
    /// the worst case is both polling.
    public static func prPollingLeader(local: MachineIdentity, peers: [PeerStatus]) -> String {
        let candidates = [local] + peers.filter(\.online).compactMap(\.machine)
        return candidates.min { a, b in
            let aOn = a.alwaysOn == true, bOn = b.alwaysOn == true
            if aOn != bOn { return aOn }
            return a.id < b.id
        }!.id
    }

    /// The master that keeps channels and direct messages: an always-on
    /// peer, online or not, when this master is not always-on itself; nil
    /// when that is this master. Channel data lives in one place, so a home
    /// that is offline makes channel writes fail rather than fork.
    public static func channelsHome(local: MachineIdentity, peers: [PeerStatus]) -> PeerStatus? {
        guard local.alwaysOn != true else { return nil }
        return peers
            .filter { $0.machine?.alwaysOn == true }
            .min { ($0.machine?.id ?? "") < ($1.machine?.id ?? "") }
    }
}

// MARK: - Peers

/// Another master this one syncs cards with, from Settings > Peers.
public struct PeerConfig: Codable, Sendable, Equatable, Identifiable {
    /// Local id of the entry, stable across edits of the URL or name.
    public var id: String
    public var name: String
    /// Base URL of the peer's Remote Control server, e.g. `http://100.114.220.85:7780`.
    public var url: String
    /// A device token the peer issued for this machine, of the `peer` scope.
    public var token: String
    /// A `terminal` scope token of the peer, for showing the terminals of
    /// its cards here. The peer token cannot open terminals.
    public var terminalToken: String?
    public var enabled: Bool

    public init(
        id: String = KSUID.generate(prefix: "peer"),
        name: String,
        url: String,
        token: String,
        terminalToken: String? = nil,
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.token = token
        self.terminalToken = terminalToken
        self.enabled = enabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? KSUID.generate(prefix: "peer")
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        url = (try? c.decodeIfPresent(String.self, forKey: .url)) ?? ""
        token = (try? c.decodeIfPresent(String.self, forKey: .token)) ?? ""
        terminalToken = (try? c.decodeIfPresent(String.self, forKey: .terminalToken)).flatMap { $0.isEmpty ? nil : $0 }
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, url, token, terminalToken, enabled
    }
}

/// Live state of a peer, as the sync loop last saw it.
public struct PeerStatus: Codable, Sendable, Equatable {
    /// The `PeerConfig.id` this status belongs to.
    public var peerId: String
    /// The peer's machine identity, known after its first answer.
    public var machine: MachineIdentity?
    public var online: Bool
    /// Last successful pull.
    public var lastSeen: Date?
    public var lastError: String?
    /// The peer's Remote Control URL, to tell an ssh machine that is the
    /// same host.
    public var url: String?

    public init(
        peerId: String,
        machine: MachineIdentity? = nil,
        online: Bool = false,
        lastSeen: Date? = nil,
        lastError: String? = nil,
        url: String? = nil
    ) {
        self.peerId = peerId
        self.machine = machine
        self.online = online
        self.lastSeen = lastSeen
        self.lastError = lastError
        self.url = url
    }
}

// MARK: - Wire format

/// Body of `GET /v1/links`: the cards (and tombstones) that changed on the
/// serving master after `since`.
///
/// `seq` is a change counter local to the serving process, not a stamp:
/// every link the server changes (by a local edit or a merge) gets the next
/// value. `epoch` names the process; when it differs from the epoch the
/// client sent, the counter restarted and the page is full.
public struct LinksPage: Codable, Sendable, Equatable {
    public var machine: MachineIdentity
    public var epoch: String
    public var seq: Int
    /// True when the page carries every served link, not a delta.
    public var full: Bool
    public var links: [Link]
    /// GitHub repository ("host/owner/name") of each project path the
    /// serving master's cards use, so a master that has no checkout of a
    /// repository can still look up its pull requests.
    public var repoSlugs: [String: String]?

    public init(machine: MachineIdentity, epoch: String, seq: Int, full: Bool, links: [Link], repoSlugs: [String: String]? = nil) {
        self.machine = machine
        self.epoch = epoch
        self.seq = seq
        self.full = full
        self.links = links
        self.repoSlugs = repoSlugs
    }
}
