import Foundation

/// The byte stream under one accepted connection: Network.framework on Apple
/// platforms, plain sockets elsewhere.
protocol RemoteByteStream: AnyObject, Sendable {
    /// Starts delivering data. `onClose` runs once the stream failed or was
    /// cancelled.
    func start(onClose: @escaping @Sendable () -> Void)

    /// The next chunk: nil at end of stream, empty when nothing arrived yet.
    func receive() async throws -> Data?

    /// Sends bytes; sends keep the order of the calls.
    func send(_ data: Data, completion: @escaping @Sendable (Error?) -> Void)

    func cancel()

    /// The client's address, when the transport knows it.
    var peer: RemotePeerAddress? { get }
}

/// Where a connection comes from.
public struct RemotePeerAddress: Sendable, Equatable {
    public var host: String
    public var port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    /// 127.0.0.0/8 or ::1 (also as an IPv4-mapped address).
    public var isLoopback: Bool {
        let h = host.split(separator: "%").first.map(String.init) ?? host
        return h.hasPrefix("127.") || h == "::1" || h.hasPrefix("::ffff:127.") || h == "localhost"
    }
}

/// A bound TCP listener.
protocol RemoteListener: AnyObject, Sendable {
    /// The bound port, the ephemeral one when asked for port 0.
    var port: Int { get }
    func cancel()
}

enum RemoteTransport {
    /// Listens on `address:port` and hands every accepted connection to
    /// `onAccept`. Throws when the address cannot be bound.
    static func listen(
        address: String,
        port: Int,
        queue: DispatchQueue,
        onAccept: @escaping @Sendable (any RemoteByteStream) -> Void
    ) async throws -> any RemoteListener {
        #if canImport(Network)
        try await NWRemoteListener.listen(address: address, port: port, queue: queue, onAccept: onAccept)
        #else
        try SocketRemoteListener.listen(address: address, port: port, queue: queue, onAccept: onAccept)
        #endif
    }
}
