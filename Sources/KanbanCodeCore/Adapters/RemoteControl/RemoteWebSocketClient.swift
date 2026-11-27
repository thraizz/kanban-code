import Foundation
import KanbanCodeRemoteKit
import Synchronization

/// Why a WebSocket to a peer did not open.
public enum RemoteWebSocketDialError: Error, LocalizedError, Equatable {
    /// The URL cannot be dialed (no host, or a scheme this client does not speak).
    case badURL(String)
    /// No TCP connection: refused, unreachable, timed out.
    case unreachable(String)
    /// The server answered the upgrade with this status and message.
    case refused(Int, String)
    /// The server answered, but not as a WebSocket.
    case protocolError(String)

    public var errorDescription: String? {
        switch self {
        case .badURL(let url): "cannot dial \(url)"
        case .unreachable(let reason): reason
        case .refused(let status, let message): message.isEmpty ? "HTTP \(status)" : "HTTP \(status): \(message)"
        case .protocolError(let reason): reason
        }
    }
}

/// Opens a WebSocket to another master's Remote Control server over this
/// module's own transport (Network.framework on a Mac, sockets on Linux), so
/// both masters dial the same way and the bytes stay in reach for the
/// streams of `docs/peer-connections.md`. Plain `http`/`ws` only: peers
/// talk over the LAN.
enum RemoteWebSocketClient {
    /// Dials `path` (with `query`) under `baseURL` with the bearer `token`.
    /// The whole dial, TCP and upgrade, must finish within `timeout`.
    static func connect(
        baseURL: URL,
        path: String,
        query: [URLQueryItem] = [],
        token: String,
        timeout: TimeInterval = 10
    ) async throws -> RemoteWebSocket {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let host = components.host, !host.isEmpty
        else { throw RemoteWebSocketDialError.badURL(baseURL.absoluteString) }
        let scheme = components.scheme?.lowercased() ?? "http"
        guard scheme == "http" || scheme == "ws" else {
            throw RemoteWebSocketDialError.badURL("\(baseURL.absoluteString) (only http peers can be dialed)")
        }
        let bareHost = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        let port = components.port ?? 80
        var basePath = components.percentEncodedPath
        while basePath.hasSuffix("/") { basePath.removeLast() }
        components.percentEncodedPath = basePath + path
        components.queryItems = query.isEmpty ? nil : query
        let target = components.percentEncodedPath + (components.percentEncodedQuery.map { "?" + $0 } ?? "")

        let deadline = Date().addingTimeInterval(timeout)
        let stream: any RemoteByteStream
        do {
            stream = try await RemoteTransport.connect(host: bareHost, port: port, timeout: timeout)
        } catch {
            throw RemoteWebSocketDialError.unreachable((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
        let conn = RemoteConnection(stream)
        conn.start()
        let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let hostHeader = (bareHost.contains(":") ? "[\(bareHost)]" : bareHost) + (components.port.map { ":\($0)" } ?? "")
        let request = "GET \(target) HTTP/1.1\r\n"
            + "Host: \(hostHeader)\r\n"
            + "Upgrade: websocket\r\n"
            + "Connection: Upgrade\r\n"
            + "Sec-WebSocket-Key: \(key)\r\n"
            + "Sec-WebSocket-Version: 13\r\n"
            + "Authorization: Bearer \(token)\r\n\r\n"

        // The upgrade must answer before the deadline; closing the
        // connection ends the read that waits for it.
        let left = max(0.1, deadline.timeIntervalSinceNow)
        let timedOut = Mutex(false)
        let timer = Task {
            try? await Task.sleep(for: .seconds(left))
            guard !Task.isCancelled else { return }
            timedOut.withLock { $0 = true }
            conn.cancel()
        }
        defer { timer.cancel() }
        let response: (status: Int, headers: [String: String], body: Data)
        do {
            try await conn.send(Data(request.utf8))
            response = try await conn.readResponse()
        } catch {
            conn.cancel()
            if timedOut.withLock({ $0 }) {
                throw RemoteWebSocketDialError.unreachable("\(hostHeader): no answer to the upgrade within \(Int(timeout)) s")
            }
            throw RemoteWebSocketDialError.protocolError("\(hostHeader): \(error)")
        }
        guard response.status == 101 else {
            conn.cancel()
            let message = (try? JSONDecoder().decode(RemoteErrorBody.self, from: response.body))?.error
                ?? String(decoding: response.body.prefix(200), as: UTF8.self)
            throw RemoteWebSocketDialError.refused(response.status, message)
        }
        guard response.headers["sec-websocket-accept"] == RemoteWebSocketHandshake.accept(key: key) else {
            conn.cancel()
            throw RemoteWebSocketDialError.protocolError("\(hostHeader): bad Sec-WebSocket-Accept")
        }
        return RemoteWebSocket(connection: conn, role: .client)
    }
}
