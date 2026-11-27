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
    /// master polls pull requests while it is online.
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

}

// MARK: - Peers

/// Another master this one syncs cards with, from Settings > Peers.
///
/// Where the peer answers is not read from here: `PeerEndpoints` resolves
/// it (see `docs/peer-connections.md`).
public struct PeerConfig: Codable, Sendable, Equatable, Identifiable {
    /// Local id of the entry, stable across edits of the address or name.
    public var id: String
    /// The peer's machine id once known: the identity of the entry, where
    /// the addresses are only hints.
    public var machineId: String?
    public var name: String
    /// A device token the peer issued for this machine, of the `peer` scope.
    public var token: String
    /// A `terminal` scope token of the peer, for showing the terminals of
    /// its cards here. The peer token cannot open terminals.
    public var terminalToken: String?
    /// Base URLs of the peer's Remote Control server to try, newest success
    /// first, e.g. `http://192.168.178.230:7780`. Settings files from before
    /// had one `url`; it decodes as the first hint.
    public var addressHints: [String]
    public var enabled: Bool

    public init(
        id: String = KSUID.generate(prefix: "peer"),
        machineId: String? = nil,
        name: String,
        addressHints: [String],
        token: String,
        terminalToken: String? = nil,
        enabled: Bool = true
    ) {
        self.id = id
        self.machineId = machineId
        self.name = name
        self.addressHints = addressHints
        self.token = token
        self.terminalToken = terminalToken
        self.enabled = enabled
    }

    /// An entry with the one address the user typed.
    public init(
        id: String = KSUID.generate(prefix: "peer"),
        name: String,
        url: String,
        token: String,
        terminalToken: String? = nil,
        enabled: Bool = true
    ) {
        self.init(id: id, name: name, addressHints: url.isEmpty ? [] : [url], token: token,
                  terminalToken: terminalToken, enabled: enabled)
    }

    /// Puts `address` first among the hints: the peer answered there.
    /// False when it was first already.
    @discardableResult
    public mutating func promoteHint(_ address: String) -> Bool {
        guard !address.isEmpty, addressHints.first != address else { return false }
        addressHints.removeAll { $0 == address }
        addressHints.insert(address, at: 0)
        return true
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? KSUID.generate(prefix: "peer")
        machineId = (try? c.decodeIfPresent(String.self, forKey: .machineId)).flatMap { $0.isEmpty ? nil : $0 }
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        token = (try? c.decodeIfPresent(String.self, forKey: .token)) ?? ""
        terminalToken = (try? c.decodeIfPresent(String.self, forKey: .terminalToken)).flatMap { $0.isEmpty ? nil : $0 }
        let hints = ((try? c.decodeIfPresent([String].self, forKey: .addressHints)) ?? []).filter { !$0.isEmpty }
        if hints.isEmpty, let url = try? c.decodeIfPresent(String.self, forKey: .url), !url.isEmpty {
            addressHints = [url]
        } else {
            addressHints = hints
        }
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
    }

    /// Writes the hints, and the first of them as `url` too, so a build from
    /// before the hints still finds the peer in a file this one wrote.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(machineId, forKey: .machineId)
        try c.encode(name, forKey: .name)
        try c.encode(addressHints.first ?? "", forKey: .url)
        try c.encode(addressHints, forKey: .addressHints)
        try c.encode(token, forKey: .token)
        try c.encodeIfPresent(terminalToken, forKey: .terminalToken)
        try c.encode(enabled, forKey: .enabled)
    }

    private enum CodingKeys: String, CodingKey {
        case id, machineId, name, url, addressHints, token, terminalToken, enabled
    }
}

/// Which master dialed a control connection, seen from this one.
public enum PeerConnectionDirection: String, Codable, Sendable, Equatable {
    /// This master dialed the peer.
    case dialed
    /// The peer dialed this master.
    case accepted
}

/// Live state of a peer, as the sync loop last saw it.
public struct PeerStatus: Codable, Sendable, Equatable {
    /// The `PeerConfig.id` this status belongs to.
    public var peerId: String
    /// The peer's machine identity, known after its first answer.
    public var machine: MachineIdentity?
    /// The last pull answered (or failed for less than the grace).
    public var online: Bool
    /// Last successful pull.
    public var lastSeen: Date?
    public var lastError: String?
    /// The peer's Remote Control URL, to tell an ssh machine that is the
    /// same host.
    public var url: String?
    /// A control connection to the peer is up (`docs/peer-connections.md`).
    public var connected: Bool
    /// Who dialed it, while `connected`.
    public var connectedVia: PeerConnectionDirection?
    /// Why the last control connection ended, or why no dial got through.
    public var controlError: String?

    public init(
        peerId: String,
        machine: MachineIdentity? = nil,
        online: Bool = false,
        lastSeen: Date? = nil,
        lastError: String? = nil,
        url: String? = nil,
        connected: Bool = false,
        connectedVia: PeerConnectionDirection? = nil,
        controlError: String? = nil
    ) {
        self.peerId = peerId
        self.machine = machine
        self.online = online
        self.lastSeen = lastSeen
        self.lastError = lastError
        self.url = url
        self.connected = connected
        self.connectedVia = connectedVia
        self.controlError = controlError
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        peerId = try c.decode(String.self, forKey: .peerId)
        machine = try c.decodeIfPresent(MachineIdentity.self, forKey: .machine)
        online = try c.decodeIfPresent(Bool.self, forKey: .online) ?? false
        lastSeen = try c.decodeIfPresent(Date.self, forKey: .lastSeen)
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        // A status from a master before control connections has none.
        connected = try c.decodeIfPresent(Bool.self, forKey: .connected) ?? false
        connectedVia = try? c.decodeIfPresent(PeerConnectionDirection.self, forKey: .connectedVia)
        controlError = try c.decodeIfPresent(String.self, forKey: .controlError)
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
