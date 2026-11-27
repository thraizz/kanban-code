#if canImport(Network)
import Foundation
import Network
import Synchronization

/// A Network.framework connection: accepted by a listener, or dialed with
/// `connect`.
final class NWRemoteByteStream: RemoteByteStream, @unchecked Sendable {
    let nw: NWConnection
    private let queue = DispatchQueue(label: "kanban.remote.conn")
    /// A dialed connection is started (and ready) before `start` is called.
    private let started: Bool

    init(_ nw: NWConnection, started: Bool = false) {
        self.nw = nw
        self.started = started
    }

    func start(onClose: @escaping @Sendable () -> Void) {
        nw.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: onClose()
            default: break
            }
        }
        if started {
            // It may have ended between opening and now.
            queue.async { [nw] in
                switch nw.state {
                case .failed, .cancelled: onClose()
                default: break
                }
            }
        } else {
            nw.start(queue: queue)
        }
    }

    /// Opens a TCP connection to `host:port`. A refused or unreachable
    /// address fails at once rather than waiting for the network to change,
    /// which is what Network.framework would do.
    static func connect(host: String, port: Int, timeout: TimeInterval) async throws -> NWRemoteByteStream {
        // A local port the system picked can still be in TIME_WAIT towards
        // the same address (many short dials to one peer): try another.
        var attempt = 0
        while true {
            attempt += 1
            do {
                return try await connectOnce(host: host, port: port, timeout: timeout)
            } catch let error as AddressInUse {
                if attempt >= 3 { throw RemoteConnectError(error.message) }
            }
        }
    }

    private struct AddressInUse: Error {
        let message: String
    }

    private static func connectOnce(host: String, port: Int, timeout: TimeInterval) async throws -> NWRemoteByteStream {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
            throw RemoteConnectError("bad port \(port)")
        }
        let nw = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let stream = NWRemoteByteStream(nw, started: true)
        let done = Mutex(false)
        let target = "\(host):\(port)"
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    let finish: @Sendable (Result<Void, Error>) -> Void = { result in
                        let first = done.withLock { finished -> Bool in
                            if finished { return false }
                            finished = true
                            return true
                        }
                        if first { cont.resume(with: result) }
                    }
                    nw.stateUpdateHandler = { state in
                        switch state {
                        case .ready: finish(.success(()))
                        case .failed(let error), .waiting(let error):
                            if case .posix(.EADDRINUSE) = error {
                                finish(.failure(AddressInUse(message: Self.describe(error, target: target))))
                            } else {
                                finish(.failure(RemoteConnectError(Self.describe(error, target: target))))
                            }
                        case .cancelled: finish(.failure(RemoteConnectError("\(target): cancelled")))
                        default: break
                        }
                    }
                    nw.start(queue: stream.queue)
                    stream.queue.asyncAfter(deadline: .now() + timeout) {
                        finish(.failure(RemoteConnectError("\(target): no answer within \(Int(timeout)) s")))
                    }
                }
            } onCancel: {
                nw.cancel()
            }
        } catch {
            nw.stateUpdateHandler = nil
            nw.cancel()
            throw error
        }
        nw.stateUpdateHandler = nil
        return stream
    }

    private static func describe(_ error: NWError, target: String) -> String {
        switch error {
        case .posix(let code): "\(target): \(String(cString: strerror(code.rawValue)).lowercased())"
        default: "\(target): \(error.localizedDescription)"
        }
    }

    func receive() async throws -> Data? {
        try await withCheckedThrowingContinuation { cont in
            nw.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    cont.resume(returning: data)
                } else if let error {
                    cont.resume(throwing: error)
                } else if isComplete {
                    cont.resume(returning: nil)
                } else {
                    cont.resume(returning: Data())
                }
            }
        }
    }

    func send(_ data: Data, completion: @escaping @Sendable (Error?) -> Void) {
        nw.send(content: data, completion: .contentProcessed { error in completion(error) })
    }

    func cancel() {
        nw.cancel()
    }

    var peer: RemotePeerAddress? {
        guard case .hostPort(let host, let port) = nw.endpoint else { return nil }
        let text: String
        switch host {
        case .ipv4(let a): text = "\(a)"
        case .ipv6(let a): text = "\(a)"
        case .name(let n, _): text = n
        @unknown default: text = "\(host)"
        }
        return RemotePeerAddress(host: text, port: Int(port.rawValue))
    }
}

final class NWRemoteListener: RemoteListener, @unchecked Sendable {
    let listener: NWListener

    private init(_ listener: NWListener) {
        self.listener = listener
    }

    var port: Int { Int(listener.port?.rawValue ?? 0) }

    func cancel() {
        listener.cancel()
    }

    static func listen(
        address: String,
        port: Int,
        queue: DispatchQueue,
        onAccept: @escaping @Sendable (any RemoteByteStream) -> Void
    ) async throws -> NWRemoteListener {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host(address),
            port: NWEndpoint.Port(rawValue: UInt16(clamping: port)) ?? .any
        )
        let listener: NWListener
        do {
            listener = try NWListener(using: params)
        } catch {
            throw RemoteControlServer.ServerError.bindFailed(address, "\(error)")
        }
        listener.newConnectionHandler = { nw in
            onAccept(NWRemoteByteStream(nw))
        }
        let resumed = Mutex(false)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                let result: Result<Void, Error>?
                switch state {
                case .ready: result = .success(())
                case .failed(let error): result = .failure(RemoteControlServer.ServerError.bindFailed(address, "\(error)"))
                case .cancelled: result = .failure(RemoteControlServer.ServerError.bindFailed(address, "cancelled"))
                case .waiting(let error): result = .failure(RemoteControlServer.ServerError.bindFailed(address, "\(error)"))
                default: result = nil
                }
                guard let result else { return }
                let first = resumed.withLock { done -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                if first {
                    if case .failure = result { listener.cancel() }
                    cont.resume(with: result)
                }
            }
            listener.start(queue: queue)
        }
        return NWRemoteListener(listener)
    }
}
#endif
