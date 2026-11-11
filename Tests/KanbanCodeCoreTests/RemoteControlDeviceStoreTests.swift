import Foundation
import KanbanCodeRemoteKit
import Testing

@testable import KanbanCodeCore

@Suite("Remote device store")
struct RemoteControlDeviceStoreTests {

    private static func path() -> String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent("remote-devices-\(UUID().uuidString)/devices.json")
    }

    @Test("tokens are kc_ plus 40 base62 characters")
    func tokenFormat() {
        for _ in 0..<50 {
            let token = RemoteDeviceStore.makeToken()
            #expect(token.hasPrefix("kc_"))
            #expect(token.count == 43)
            #expect(token.dropFirst(3).allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) })
        }
    }

    @Test("add, authenticate, list, revoke round trip; the file keeps only the hash")
    func roundTrip() throws {
        let path = Self.path()
        let store = RemoteDeviceStore(path: path)
        let (device, token) = try store.add(name: "iPhone", scope: .full)
        #expect(store.authenticate(token: token)?.id == device.id)
        #expect(store.authenticate(token: token + "x") == nil)
        #expect(store.list().map(\.name) == ["iPhone"])

        let raw = try String(contentsOfFile: path, encoding: .utf8)
        #expect(!raw.contains(token))
        #expect(raw.contains(RemoteDeviceStore.hash(token)))
        let json = try #require(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        let entry = try #require((json["devices"] as? [[String: Any]])?.first)
        #expect(Set(entry.keys).isSuperset(of: ["id", "name", "scope", "tokenHash", "createdAt"]))
        #expect((entry["createdAt"] as? String)?.hasSuffix("Z") == true)
        #expect((entry["tokenHash"] as? String)?.count == 64)

        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)

        #expect(try store.revoke(id: device.id))
        #expect(store.authenticate(token: token) == nil)
        #expect(try store.revoke(id: device.id) == false)
    }

    @Test("a change written by another process is picked up")
    func externalChange() throws {
        let path = Self.path()
        let app = RemoteDeviceStore(path: path)
        let cli = RemoteDeviceStore(path: path)
        #expect(app.list().isEmpty)
        let (device, token) = try cli.add(name: "openclaw", scope: .agent)
        #expect(app.authenticate(token: token)?.scope == .agent)
        try cli.revoke(id: device.id)
        #expect(app.authenticate(token: token) == nil)
    }

    @Test("reads a file written by hand in the documented format")
    func handWritten() throws {
        let path = Self.path()
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let token = "kc_" + String(repeating: "a", count: 40)
        let json = """
        {"devices":[{"id":"d1","name":"cli","scope":"agent","tokenHash":"\(RemoteDeviceStore.hash(token))","createdAt":"2026-09-26T10:00:00.000Z"}]}
        """
        try json.write(toFile: path, atomically: true, encoding: .utf8)
        let store = RemoteDeviceStore(path: path)
        let device = try #require(store.authenticate(token: token))
        #expect(device.id == "d1")
        #expect(device.lastSeenAt != nil)
    }

    @Test("lastSeenAt is written at most once a minute")
    func lastSeenThrottle() throws {
        let store = RemoteDeviceStore(path: Self.path())
        let (_, token) = try store.add(name: "iPhone", scope: .full)
        let first = try #require(store.authenticate(token: token)?.lastSeenAt)
        let second = try #require(store.authenticate(token: token)?.lastSeenAt)
        #expect(first == second)
    }

    @Test("bindable: loopback only by default, never a wildcard unless configured")
    func bindableDefaults() {
        #expect(RemoteNetworkAddresses.bindable(configured: []) == ["127.0.0.1"])
        let lan = { ["127.0.0.1", "192.168.1.20", "10.8.0.2", "fe80::1"] }
        #expect(RemoteNetworkAddresses.bindable(configured: [], local: lan) == ["127.0.0.1"])
        #expect(!RemoteNetworkAddresses.bindable(configured: ["192.168.1.20"], local: lan).contains("0.0.0.0"))
    }

    @Test("bindable: configured addresses the machine has, in order, after loopback")
    func bindableConfigured() {
        let local = { ["127.0.0.1", "192.168.1.20", "10.8.0.2", "fd00::5"] }
        #expect(RemoteNetworkAddresses.bindable(configured: ["10.8.0.2", "192.168.1.20"], local: local)
            == ["127.0.0.1", "10.8.0.2", "192.168.1.20"])
        // Not on an interface yet (VPN down): left out until it appears.
        #expect(RemoteNetworkAddresses.bindable(configured: ["10.9.9.9", "192.168.1.20"], local: local)
            == ["127.0.0.1", "192.168.1.20"])
        // Loopback, duplicates, brackets and blanks.
        #expect(RemoteNetworkAddresses.bindable(configured: [" 127.0.0.1", "[fd00::5]", "192.168.1.20", "192.168.1.20", ""], local: local)
            == ["127.0.0.1", "fd00::5", "192.168.1.20"])
        // Interface addresses of this machine: loopback is always there.
        #expect(RemoteNetworkAddresses.local().contains("127.0.0.1"))
    }

    @Test("bindable: an explicit wildcard replaces the other addresses")
    func bindableWildcard() {
        let local = { ["127.0.0.1", "192.168.1.20"] }
        #expect(RemoteNetworkAddresses.bindable(configured: ["192.168.1.20", "0.0.0.0"], local: local) == ["0.0.0.0"])
        #expect(RemoteNetworkAddresses.bindable(configured: ["::", "0.0.0.0"], local: local) == ["::", "0.0.0.0"])
    }

    @Test("bind addresses: field parsing and the pair link base URL")
    func bindAddressParsing() {
        #expect(RemoteNetworkAddresses.parse("192.168.1.20, 10.8.0.2\nfd00::5;  ,") == ["192.168.1.20", "10.8.0.2", "fd00::5"])
        #expect(RemoteNetworkAddresses.parse("") == [])
        #expect(RemoteNetworkAddresses.normalized(["fe80::1%en0", "[::1]"]) == ["fe80::1", "::1"])
        #expect(RemoteNetworkAddresses.publicBaseURL(configured: [], port: 7780) == "http://127.0.0.1:7780")
        #expect(RemoteNetworkAddresses.publicBaseURL(configured: ["0.0.0.0", "192.168.1.20"], port: 7780) == "http://192.168.1.20:7780")
        #expect(RemoteNetworkAddresses.publicBaseURL(configured: ["fd00::5", "10.8.0.2"], port: 7781) == "http://10.8.0.2:7781")
        #expect(RemoteNetworkAddresses.publicBaseURL(configured: ["fd00::5"], port: 7780) == "http://[fd00::5]:7780")
    }

    @Test("settings: remoteControl.bindAddresses round trip, default empty")
    func bindAddressSettings() throws {
        let old = try JSONDecoder().decode(RemoteControlSettings.self, from: Data(#"{"enabled":true,"port":7780}"#.utf8))
        #expect(old.bindAddresses == [])
        let bad = try JSONDecoder().decode(RemoteControlSettings.self, from: Data(#"{"bindAddresses":"nope"}"#.utf8))
        #expect(bad.bindAddresses == [])
        let value = RemoteControlSettings(enabled: true, port: 7781, bindAddresses: ["192.168.1.20", "10.8.0.2"])
        let json = try JSONEncoder().encode(value)
        #expect(String(decoding: json, as: UTF8.self).contains("bindAddresses"))
        #expect(try JSONDecoder().decode(RemoteControlSettings.self, from: json) == value)

        let home = FileManager.default.temporaryDirectory.appendingPathComponent("kc-bind-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(RemoteControlSettings.load(home: home.path) == RemoteControlSettings())
        try Data(#"{"projects":[],"remoteControl":{"enabled":true,"bindAddresses":[" 10.8.0.2 "]}}"#.utf8)
            .write(to: home.appendingPathComponent("settings.json"))
        #expect(RemoteControlSettings.load(home: home.path).bindAddresses == ["10.8.0.2"])
    }

    @Test("websocket frames: masked round trip and fragmentation of big payloads")
    func frames() {
        let payload = Data((0..<200_000).map { UInt8($0 & 0xFF) })
        let framed = RemoteWebSocket.frames(opcode: .binary, payload: payload)
        // Three 64 KiB frames with 10 byte headers, then the rest with a 4 byte header.
        #expect(framed.count == payload.count + 3 * 10 + 4)
        #expect(framed[10 + 65536] == 0x00)
        #expect(framed[0] == 0x02)
        #expect(RemoteWebSocketHandshake.accept(key: "dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    @Test("pair links percent-encode every value")
    func pairLink() throws {
        let link = RemotePairLink.make(url: "http://mac.tail.ts.net:7780/x?y=1", token: "kc_abc", name: "Rogerio’s Mac")
        #expect(link == "kanbancode://pair?url=http%3A%2F%2Fmac.tail.ts.net%3A7780%2Fx%3Fy%3D1&token=kc_abc&name=Rogerio%E2%80%99s%20Mac")
        let items = try #require(URLComponents(string: link)?.queryItems)
        #expect(items.first { $0.name == "url" }?.value == "http://mac.tail.ts.net:7780/x?y=1")
    }
}
