#if canImport(Network)
import Foundation
import Network
import Synchronization

/// An accepted Network.framework connection.
final class NWRemoteByteStream: RemoteByteStream, @unchecked Sendable {
    let nw: NWConnection
    private let queue = DispatchQueue(label: "kanban.remote.conn")

    init(_ nw: NWConnection) {
        self.nw = nw
    }

    func start(onClose: @escaping @Sendable () -> Void) {
        nw.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: onClose()
            default: break
            }
        }
        nw.start(queue: queue)
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
