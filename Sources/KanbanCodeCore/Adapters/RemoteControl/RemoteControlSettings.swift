import Foundation
import KanbanCodeRemoteKit

/// Settings > Remote Control: the HTTP server phones and other agents use to
/// drive this Mac (docs/remote-control.md). Off until turned on.
public struct RemoteControlSettings: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var port: Int
    /// Addresses to listen on besides loopback, e.g. the LAN or WireGuard
    /// address. Empty: loopback only. `0.0.0.0` or `::` binds every
    /// interface and is never the default.
    public var bindAddresses: [String]

    public init(enabled: Bool = false, port: Int = RemoteAPI.defaultPort, bindAddresses: [String] = []) {
        self.enabled = enabled
        self.port = port
        self.bindAddresses = bindAddresses
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        let port = (try? c.decodeIfPresent(Int.self, forKey: .port)) ?? RemoteAPI.defaultPort
        self.port = (1...65535).contains(port) ? port : RemoteAPI.defaultPort
        bindAddresses = RemoteNetworkAddresses.normalized((try? c.decodeIfPresent([String].self, forKey: .bindAddresses)) ?? [])
    }

    /// The `remoteControl` block of `<home>/settings.json`, read without the
    /// settings store, so a synchronous address provider can call it.
    /// Defaults when the file or the block is missing or unreadable.
    public static func load(home: String) -> RemoteControlSettings {
        struct File: Decodable { var remoteControl: RemoteControlSettings? }
        let path = (home as NSString).appendingPathComponent("settings.json")
        guard let data = FileManager.default.contents(atPath: path),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return RemoteControlSettings() }
        return file.remoteControl ?? RemoteControlSettings()
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, port, bindAddresses
    }
}
