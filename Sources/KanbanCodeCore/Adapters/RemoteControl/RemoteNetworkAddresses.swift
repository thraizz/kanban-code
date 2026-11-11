#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// Addresses the remote control server may listen on.
public enum RemoteNetworkAddresses {
    public static let loopback = "127.0.0.1"

    /// The addresses that mean "every interface". Bound only when configured
    /// explicitly.
    public static let wildcards: Set<String> = ["0.0.0.0", "::"]

    /// Loopback plus the configured addresses this machine has right now
    /// (settings `remoteControl.bindAddresses`, or `--bind` on the server).
    /// A configured address that is not on an interface yet is left out, and
    /// the server's periodic check binds it once it appears. Never a
    /// wildcard, unless one is configured: then only the wildcards, since
    /// they already cover loopback.
    public static func bindable(configured: [String], local: () -> [String] = RemoteNetworkAddresses.local) -> [String] {
        let wanted = normalized(configured)
        let wild = wanted.filter { wildcards.contains($0) }
        if !wild.isEmpty { return wild }
        guard !wanted.isEmpty else { return [loopback] }
        let present = Set(local())
        return [loopback] + wanted.filter { $0 != loopback && present.contains($0) }
    }

    /// Trims, drops brackets around IPv6 literals and an `%zone` suffix,
    /// drops empty entries and duplicates, keeps the order.
    public static func normalized(_ addresses: [String]) -> [String] {
        var seen = Set<String>()
        return addresses.compactMap { raw -> String? in
            var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.hasPrefix("["), s.hasSuffix("]") { s = String(s.dropFirst().dropLast()) }
            if let zone = s.firstIndex(of: "%") { s = String(s[..<zone]) }
            guard !s.isEmpty, seen.insert(s).inserted else { return nil }
            return s
        }
    }

    /// Splits a settings field: addresses separated by commas, spaces or
    /// line breaks.
    public static func parse(_ text: String) -> [String] {
        normalized(text.components(separatedBy: CharacterSet(charactersIn: ",;").union(.whitespacesAndNewlines)))
    }

    /// The first configured address a client can reach, as an `http` base
    /// URL; loopback when none is configured. Wildcards are skipped.
    public static func publicBaseURL(configured: [String], port: Int) -> String {
        let reachable = normalized(configured).filter { !wildcards.contains($0) }
        let address = reachable.first(where: { !$0.contains(":") }) ?? reachable.first ?? loopback
        return address.contains(":") ? "http://[\(address)]:\(port)" : "http://\(address):\(port)"
    }

    /// Every address on an interface that is up, numeric, without zone.
    public static func local() -> [String] {
        var out: [String] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            guard let sa = ifa.pointee.ifa_addr, (ifa.pointee.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }
            let family = Int32(sa.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6, let s = numeric(sa) else { continue }
            out.append(s)
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    private static func numeric(_ sa: UnsafeMutablePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        #if canImport(Darwin)
        let len = socklen_t(sa.pointee.sa_len)
        #else
        let len = socklen_t(Int32(sa.pointee.sa_family) == AF_INET6 ? MemoryLayout<sockaddr_in6>.size : MemoryLayout<sockaddr_in>.size)
        #endif
        guard getnameinfo(sa, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        let s = String(cString: host)
        // Drop a zone suffix: a configured address is written without one.
        return s.split(separator: "%").first.map(String.init)
    }
}
