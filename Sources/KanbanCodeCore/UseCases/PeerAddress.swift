import Foundation

/// The hosts of peer addresses: where a request or a connection came from,
/// as a URL can name it.
public enum PeerAddress {
    /// The host of a request's source, as a URL host can name it; nil for
    /// one that names no other machine (loopback, a tunnel through ssh, a
    /// stream through a control connection) or that a URL cannot carry (a
    /// link-local address with its zone).
    public static func usableHost(_ raw: String) -> String? {
        var host = raw.trimmingCharacters(in: .whitespaces)
        guard !host.hasPrefix(RemotePeerAddress.tunnelPrefix) else { return nil }
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        // An IPv4 client of a dual-stack socket.
        if host.lowercased().hasPrefix("::ffff:"), host.dropFirst(7).contains(".") {
            host = String(host.dropFirst(7))
        }
        let lower = host.lowercased()
        guard !host.isEmpty, !host.contains("%"), !host.contains("/"),
              lower != "localhost", lower != "::1", !lower.hasPrefix("127."),
              !lower.hasPrefix("fe80:"), host != "0.0.0.0", host != "::"
        else { return nil }
        return host
    }

    /// The host `url` names, without the brackets of an IPv6 one.
    public static func host(of url: String) -> String? {
        guard let host = URLComponents(string: url)?.host else { return nil }
        if host.hasPrefix("[") && host.hasSuffix("]") { return String(host.dropFirst().dropLast()) }
        return host
    }
}

extension SettingsStore {
    /// Saves an entry made for a peer that paired over its control
    /// connection: in place of the entry of the same machine, if there is
    /// one (its token is replaced), else after the others. False when
    /// nothing changed.
    @discardableResult
    public func savePairedPeer(_ entry: PeerConfig) throws -> Bool {
        var settings = try read()
        if let index = settings.peers.firstIndex(where: { $0.id == entry.id || ($0.machineId != nil && $0.machineId == entry.machineId) }) {
            var peer = settings.peers[index]
            peer.token = entry.token
            peer.machineId = entry.machineId
            guard peer != settings.peers[index] else { return false }
            settings.peers[index] = peer
        } else {
            settings.peers.append(entry)
        }
        try write(settings)
        return true
    }

    /// Notes the device this master issued for the peer `peerId` over a
    /// control connection, so the next one issued revokes it.
    @discardableResult
    public func setPeerIssuedDevice(peerId: String, deviceId: String) throws -> Bool {
        var settings = try read()
        guard let index = settings.peers.firstIndex(where: { $0.id == peerId }),
              settings.peers[index].issuedDeviceId != deviceId
        else { return false }
        settings.peers[index].issuedDeviceId = deviceId
        try write(settings)
        return true
    }

    /// Saves what a control connection taught about the peer `peerId`: the
    /// machine it is and its address hints, newest success first. False
    /// when there is no such peer or nothing changed.
    @discardableResult
    public func learnPeer(peerId: String, machineId: String, hints: [String]) throws -> Bool {
        var settings = try read()
        guard let index = settings.peers.firstIndex(where: { $0.id == peerId }) else { return false }
        var peer = settings.peers[index]
        peer.machineId = machineId
        if !hints.isEmpty { peer.addressHints = hints }
        guard peer != settings.peers[index] else { return false }
        settings.peers[index] = peer
        try write(settings)
        return true
    }
}

/// Issues the peer-scope token a peer master asks for on a control
/// connection this master dialed (`docs/peer-connections.md`, "Pairing on
/// one side"): a device of this master's Remote Control server, one per
/// peer entry. The one issued before for the entry is revoked: the peer
/// asks again only once it lost its entry, and with it that token.
public struct PeerTokenIssuer: Sendable {
    private let devices: RemoteDeviceStore
    private let settings: SettingsStore

    public init(devices: RemoteDeviceStore, settings: SettingsStore) {
        self.devices = devices
        self.settings = settings
    }

    public func issue(for peer: PeerConfig, machine: MachineIdentity) async -> String? {
        let saved = (try? await settings.read())?.peers.first { $0.id == peer.id }
        let previous = saved?.issuedDeviceId ?? peer.issuedDeviceId
        guard let (device, token) = try? devices.add(name: "\(machine.name) (peer master)", scope: .peer) else { return nil }
        if let previous, previous != device.id, (try? devices.revoke(id: previous)) == true {
            KanbanCodeLog.info("peer", "revoked the token issued to \(machine.name) before")
        }
        _ = try? await settings.setPeerIssuedDevice(peerId: peer.id, deviceId: device.id)
        return token
    }
}
