#if !canImport(Network)
import Foundation
import Glibc

/// Non-blocking socket helpers shared by the listener and its connections.
enum RemoteSocket {
    static func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    static func setOption(_ fd: Int32, _ level: Int32, _ name: Int32, _ value: Int32 = 1) {
        var v = value
        _ = setsockopt(fd, level, name, &v, socklen_t(MemoryLayout<Int32>.size))
    }

    static var errorText: String { String(cString: strerror(errno)) }

    static var wouldBlock: Bool { errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR }
}

/// An accepted TCP socket. Reads wait on a dispatch read source; writes run
/// on a serial queue so they keep their call order.
final class SocketRemoteByteStream: RemoteByteStream, @unchecked Sendable {
    private let fd: Int32
    /// Guards every field below; the read source fires on it.
    private let queue = DispatchQueue(label: "kanban.remote.conn")
    private let sendQueue = DispatchQueue(label: "kanban.remote.conn.send")
    private var readSource: DispatchSourceRead?
    private var readArmed = false
    private var pending: CheckedContinuation<Data?, Error>?
    private var closed = false
    private var onClose: (@Sendable () -> Void)?
    private var buffer = [UInt8](repeating: 0, count: 256 * 1024)

    static let sendTimeoutMs: Int32 = 30_000

    let peer: RemotePeerAddress?

    init(fd: Int32) {
        self.fd = fd
        peer = Self.peerAddress(fd)
        RemoteSocket.setNonBlocking(fd)
        RemoteSocket.setOption(fd, Int32(IPPROTO_TCP), TCP_NODELAY)
    }

    private static func peerAddress(_ fd: Int32) -> RemotePeerAddress? {
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let ok = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(fd, $0, &length) == 0 }
        }
        guard ok else { return nil }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        var service = [CChar](repeating: 0, count: Int(NI_MAXSERV))
        let result = withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, length, &host, socklen_t(host.count), &service, socklen_t(service.count), NI_NUMERICHOST | NI_NUMERICSERV)
            }
        }
        guard result == 0 else { return nil }
        return RemotePeerAddress(host: String(cString: host), port: Int(String(cString: service)) ?? 0)
    }

    func start(onClose: @escaping @Sendable () -> Void) {
        queue.sync {
            self.onClose = onClose
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.readReady() }
            let fd = self.fd
            let sendQueue = self.sendQueue
            // Closing after the queued sends keeps a write from hitting a reused descriptor.
            source.setCancelHandler { sendQueue.async { close(fd) } }
            readSource = source
        }
    }

    func receive() async throws -> Data? {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                if self.closed {
                    cont.resume(returning: nil)
                    return
                }
                self.pending = cont
                self.readReady()
            }
        }
    }

    /// Runs on `queue`: reads into the pending receive, or arms the source.
    private func readReady() {
        guard let cont = pending else {
            disarm()
            return
        }
        let n = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
        if n > 0 {
            pending = nil
            disarm()
            cont.resume(returning: Data(buffer[0..<n]))
        } else if n == 0 {
            pending = nil
            disarm()
            cont.resume(returning: nil)
            finish()
        } else if RemoteSocket.wouldBlock {
            arm()
        } else {
            pending = nil
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            disarm()
            cont.resume(throwing: error)
            finish()
        }
    }

    private func arm() {
        guard !readArmed, let readSource else { return }
        readArmed = true
        readSource.resume()
    }

    private func disarm() {
        guard readArmed, let readSource else { return }
        readArmed = false
        readSource.suspend()
    }

    func send(_ data: Data, completion: @escaping @Sendable (Error?) -> Void) {
        let fd = self.fd
        sendQueue.async {
            completion(Self.writeAll(fd: fd, data: data))
        }
    }

    private static func writeAll(fd: Int32, data: Data) -> Error? {
        let flags = Int32(MSG_NOSIGNAL)
        return data.withUnsafeBytes { raw -> Error? in
            guard let base = raw.baseAddress else { return nil }
            var offset = 0
            while offset < raw.count {
                let n = Glibc.send(fd, base + offset, raw.count - offset, flags)
                if n > 0 {
                    offset += n
                    continue
                }
                guard n < 0, RemoteSocket.wouldBlock else {
                    return POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPIPE)
                }
                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let ready = poll(&pfd, 1, sendTimeoutMs)
                if ready == 0 { return POSIXError(.ETIMEDOUT) }
                if ready < 0, errno != EINTR { return POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            }
            return nil
        }
    }

    func cancel() {
        queue.async { self.finish() }
    }

    /// Runs on `queue`: ends the stream once.
    private func finish() {
        guard !closed else { return }
        closed = true
        _ = shutdown(fd, Int32(SHUT_RDWR))
        if let cont = pending {
            pending = nil
            cont.resume(returning: nil)
        }
        if let readSource {
            // A suspended source never runs its cancel handler.
            if !readArmed { readSource.resume() }
            readArmed = true
            readSource.cancel()
        } else {
            close(fd)
        }
        let callback = onClose
        onClose = nil
        callback?()
    }
}

final class SocketRemoteListener: RemoteListener, @unchecked Sendable {
    let port: Int
    private let fd: Int32
    private let source: DispatchSourceRead

    private init(fd: Int32, port: Int, source: DispatchSourceRead) {
        self.fd = fd
        self.port = port
        self.source = source
    }

    func cancel() {
        source.cancel()
    }

    static func listen(
        address: String,
        port: Int,
        queue: DispatchQueue,
        onAccept: @escaping @Sendable (any RemoteByteStream) -> Void
    ) throws -> SocketRemoteListener {
        let fail = { (reason: String) in RemoteControlServer.ServerError.bindFailed(address, reason) }
        let isV6 = address.contains(":")
        let fd = socket(isV6 ? AF_INET6 : AF_INET, Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0)
        guard fd >= 0 else { throw fail(RemoteSocket.errorText) }
        RemoteSocket.setOption(fd, SOL_SOCKET, SO_REUSEADDR)
        if isV6 { RemoteSocket.setOption(fd, Int32(IPPROTO_IPV6), IPV6_V6ONLY) }

        var bound: Int32
        if isV6 {
            var addr = sockaddr_in6()
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = in_port_t(UInt16(clamping: port)).bigEndian
            guard inet_pton(AF_INET6, address, &addr.sin6_addr) == 1 else {
                close(fd)
                throw fail("not an IPv6 address")
            }
            bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        } else {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(UInt16(clamping: port)).bigEndian
            guard inet_pton(AF_INET, address, &addr.sin_addr) == 1 else {
                close(fd)
                throw fail("not an IPv4 address")
            }
            bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard bound == 0, Glibc.listen(fd, 128) == 0 else {
            let reason = RemoteSocket.errorText
            close(fd)
            throw fail(reason)
        }
        RemoteSocket.setNonBlocking(fd)

        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let actualPort: Int = withUnsafeMutablePointer(to: &storage) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa -> Int in
                guard getsockname(fd, sa, &length) == 0 else { return port }
                if isV6 {
                    return sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { Int(UInt16(bigEndian: $0.pointee.sin6_port)) }
                }
                return sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { Int(UInt16(bigEndian: $0.pointee.sin_port)) }
            }
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler {
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { break }
                // Terminal children must not inherit client sockets.
                _ = fcntl(client, F_SETFD, FD_CLOEXEC)
                onAccept(SocketRemoteByteStream(fd: client))
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        return SocketRemoteListener(fd: fd, port: actualPort, source: source)
    }
}
#endif
