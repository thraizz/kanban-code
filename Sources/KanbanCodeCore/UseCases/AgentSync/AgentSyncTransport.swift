import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import KanbanCodeRemoteKit

/// A peer master as the agent sync sees it.
public struct SyncPeer: Sendable, Equatable {
    public var machine: MachineIdentity
    /// Where the peer answers, from `PeerEndpoints` when the round began.
    public var baseURL: URL
    public var token: String
    public var online: Bool

    public init(machine: MachineIdentity, baseURL: URL, token: String, online: Bool) {
        self.machine = machine
        self.baseURL = baseURL
        self.token = token
        self.online = online
    }

    /// Whether `name` (a machine name or id, any case) names this peer.
    public func matches(_ name: String) -> Bool {
        machine.id == name || machine.name.lowercased() == name.lowercased()
    }
}

public enum SyncTransportError: Error, LocalizedError, Equatable {
    case badURL(String)
    case http(Int, String)

    public var errorDescription: String? {
        switch self {
        case .badURL(let url): "bad peer URL \(url)"
        case .http(let status, let body): "HTTP \(status): \(body)"
        }
    }
}

/// The sync routes of a peer's Remote Control API.
public protocol SyncTransport: Sendable {
    func state(peer: SyncPeer) async throws -> SyncStateResponse
    func file(peer: SyncPeer, entryId: String, path: String) async throws -> Data
    func notify(peer: SyncPeer, machineId: String, what: String) async
    func optmemRun(peer: SyncPeer, request: OptmemRunRequest) async throws -> OptmemRunResult
}

public struct HTTPSyncTransport: SyncTransport {
    private let session: URLSession

    public init(timeout: TimeInterval = 20) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 6
        session = URLSession(configuration: config)
    }

    static func url(_ base: String, _ path: String, _ query: [String: String] = [:]) -> URL? {
        var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard var components = URLComponents(string: trimmed + path),
              components.scheme != nil, components.host != nil
        else { return nil }
        if !query.isEmpty {
            components.queryItems = query.keys.sorted().map { URLQueryItem(name: $0, value: query[$0]) }
        }
        return components.url
    }

    private func send(_ base: URL, _ path: String, token: String, query: [String: String] = [:],
                      method: String = "GET", body: Data? = nil, timeout: TimeInterval = 20) async throws -> Data {
        guard let url = Self.url(base.absoluteString, path, query) else { throw SyncTransportError.badURL(base.absoluteString) }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw SyncTransportError.http(status, String(decoding: data.prefix(300), as: UTF8.self))
        }
        return data
    }

    public func state(peer: SyncPeer) async throws -> SyncStateResponse {
        let data = try await send(peer.baseURL, "/v1/sync/state", token: peer.token)
        return try JSONDecoder.remote.decode(SyncStateResponse.self, from: data)
    }

    public func file(peer: SyncPeer, entryId: String, path: String) async throws -> Data {
        try await send(peer.baseURL, "/v1/sync/file", token: peer.token, query: ["entry": entryId, "path": path], timeout: 60)
    }

    public func notify(peer: SyncPeer, machineId: String, what: String) async {
        _ = try? await send(peer.baseURL, "/v1/sync/changed", token: peer.token,
                            query: ["machine": machineId, "what": what], method: "POST", timeout: 5)
    }

    public func optmemRun(peer: SyncPeer, request: OptmemRunRequest) async throws -> OptmemRunResult {
        let body = try JSONEncoder().encode(request)
        let data = try await send(peer.baseURL, "/v1/optmem/run", token: peer.token, method: "POST", body: body, timeout: 30)
        return try JSONDecoder().decode(OptmemRunResult.self, from: data)
    }
}

extension PeerSync {
    /// The peers that answered at least once and have an address, for the
    /// agent sync.
    public func syncPeers() -> [SyncPeer] {
        configuredPeers().compactMap { peer in
            guard peer.enabled, let status = status(of: peer.id), let machine = status.machine,
                  let endpoint = endpoints.endpoint(forPeer: peer.id)
            else { return nil }
            return SyncPeer(machine: machine, baseURL: endpoint.baseURL, token: endpoint.token, online: status.online)
        }
    }
}
