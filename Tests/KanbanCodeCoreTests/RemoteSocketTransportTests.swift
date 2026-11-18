#if !canImport(Network)
import Testing
import Foundation
import Glibc
@testable import KanbanCodeCore

/// The socket transport of the Linux server (Macs use Network.framework).
@Suite("Remote socket transport")
struct RemoteSocketTransportTests {
    private final class Accepted: @unchecked Sendable {
        private let lock = NSLock()
        private var streams: [any RemoteByteStream] = []
        func add(_ s: any RemoteByteStream) { lock.withLock { streams.append(s) } }
        func next(after count: Int) async throws -> any RemoteByteStream {
            for _ in 0..<200 {
                if let s = lock.withLock({ streams.count > count ? streams[count] : nil }) { return s }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw POSIXError(.ETIMEDOUT)
        }
    }

    private func connect(port: Int) -> Int32 {
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Glibc.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        #expect(ok == 0)
        return fd
    }

    /// Bytes `fd` receives within `timeoutMs`.
    private func drain(_ fd: Int32, timeoutMs: Int32) -> Data {
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, timeoutMs) > 0 else { return out }
            let n = recv(fd, &buf, buf.count, 0)
            guard n > 0 else { return out }
            out.append(contentsOf: buf[0..<n])
        }
    }

    @Test("A send on a closed connection fails instead of reaching the connection that got its descriptor")
    func sendAfterCloseDoesNotLeak() async throws {
        let accepted = Accepted()
        let listener = try await RemoteTransport.listen(
            address: "127.0.0.1", port: 0, queue: DispatchQueue(label: "test.listener")
        ) { stream in
            stream.start(onClose: {})
            accepted.add(stream)
        }
        defer { listener.cancel() }

        let clientA = connect(port: listener.port)
        let streamA = try await accepted.next(after: 0)
        streamA.cancel()
        close(clientA)
        try await Task.sleep(nanoseconds: 100_000_000)

        // The kernel hands the next connection the lowest free descriptor,
        // which is the one the first connection just gave back.
        let clientB = connect(port: listener.port)
        defer { close(clientB) }
        _ = try await accepted.next(after: 1)

        let error: Error? = await withCheckedContinuation { cont in
            streamA.send(Data("[lost tty]\r\n".utf8)) { cont.resume(returning: $0) }
        }
        #expect(error != nil)
        #expect(drain(clientB, timeoutMs: 200).isEmpty)
    }
}
#endif
