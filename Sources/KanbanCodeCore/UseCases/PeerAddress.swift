import Foundation

/// The address a peer master answers at, when it moved: a laptop that is on
/// Wi-Fi one hour and on a dock's Ethernet the next gets another LAN address,
/// and the peers that know it by the old one stop reaching it. It keeps
/// fetching from them, though, and its requests come from the new address.
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

    /// `url` with its host replaced by `host`, keeping scheme, port and path.
    public static func replacingHost(of url: String, with host: String) -> String? {
        guard var components = URLComponents(string: url), components.host != nil else { return nil }
        if host.contains(":") {
            components.percentEncodedHost = "[\(host)]"
        } else {
            components.host = host
        }
        return components.string
    }

    /// The host `url` names, without the brackets of an IPv6 one.
    public static func host(of url: String) -> String? {
        guard let host = URLComponents(string: url)?.host else { return nil }
        if host.hasPrefix("[") && host.hasSuffix("]") { return String(host.dropFirst().dropLast()) }
        return host
    }
}

extension SettingsStore {
    /// Saves `address` as the first address hint of the peer `peerId`: it
    /// answers there now. False when there is no such peer or that hint is
    /// first already.
    @discardableResult
    public func promotePeerAddress(peerId: String, address: String) throws -> Bool {
        var settings = try read()
        guard let index = settings.peers.firstIndex(where: { $0.id == peerId }),
              settings.peers[index].promoteHint(address)
        else { return false }
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
