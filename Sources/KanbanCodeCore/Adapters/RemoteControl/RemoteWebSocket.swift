import Foundation

/// RFC 6455 framing over an upgraded `RemoteConnection`. The server never
/// masks its frames; client frames must be masked. The server end serves
/// requests; the client end is a master dialing its peer
/// (`RemoteWebSocketClient`).
final class RemoteWebSocket: @unchecked Sendable {
    enum Message: Sendable, Equatable {
        case text(String)
        case binary(Data)
    }

    enum Role: Sendable {
        /// Sends plain frames, wants masked ones.
        case server
        /// Masks every frame it sends, takes plain ones.
        case client
    }

    enum Opcode: UInt8 {
        case continuation = 0x0
        case text = 0x1
        case binary = 0x2
        case close = 0x8
        case ping = 0x9
        case pong = 0xA
    }

    /// Outgoing payloads larger than this go out as several fragments.
    static let maxFramePayload = 64 * 1024
    static let maxMessageBytes = 16 * 1024 * 1024

    let connection: RemoteConnection
    let role: Role
    private let lock = NSLock()
    private var closeSent = false
    private var _peerClose: (code: UInt16, reason: String)?

    init(connection: RemoteConnection, role: Role = .server) {
        self.connection = connection
        self.role = role
    }

    /// The code and reason of the close frame the other end sent, once it
    /// sent one.
    var peerClose: (code: UInt16, reason: String)? {
        lock.withLock { _peerClose }
    }

    private var masks: Bool { role == .client }

    // MARK: Sending

    func sendText(_ text: String) async throws {
        try await connection.send(Self.frames(opcode: .text, payload: Data(text.utf8), masked: masks))
    }

    func sendBinary(_ data: Data) async throws {
        try await connection.send(Self.frames(opcode: .binary, payload: data, masked: masks))
    }

    func sendPing() {
        connection.sendDetached(Self.frame(fin: true, opcode: .ping, payload: Data(), mask: masks ? Self.newMask() : nil))
    }

    /// Sends a close frame (once) and ends the connection shortly after.
    func close(code: UInt16 = 1000, reason: String = "") {
        let first = lock.withLock { () -> Bool in
            if closeSent { return false }
            closeSent = true
            return true
        }
        guard first else { return }
        var payload = Data([UInt8(code >> 8), UInt8(code & 0xFF)])
        // A control frame carries at most 125 bytes; cut the reason on a
        // character boundary.
        var cut = reason
        while cut.utf8.count > 120 { cut.removeLast() }
        payload.append(Data(cut.utf8))
        let conn = connection
        conn.send(Self.frame(fin: true, opcode: .close, payload: payload, mask: masks ? Self.newMask() : nil)) { _ in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { conn.cancel() }
        }
    }

    /// One whole message split into frames of at most `maxFramePayload`,
    /// each with its own mask when `masked` (a client's frames).
    static func frames(opcode: Opcode, payload: Data, masked: Bool = false) -> Data {
        if payload.count <= maxFramePayload {
            return frame(fin: true, opcode: opcode, payload: payload, mask: masked ? newMask() : nil)
        }
        var out = Data()
        var offset = payload.startIndex
        var first = true
        while offset < payload.endIndex {
            let end = min(offset + maxFramePayload, payload.endIndex)
            let isLast = end == payload.endIndex
            out.append(frame(fin: isLast, opcode: first ? opcode : .continuation, payload: payload[offset..<end],
                             mask: masked ? newMask() : nil))
            first = false
            offset = end
        }
        return out
    }

    static func newMask() -> [UInt8] {
        (0..<4).map { _ in UInt8.random(in: 0...255) }
    }

    /// XORs `data` with the 4-byte `mask`, eight bytes at a time: a peer's
    /// streams carry whole transcripts through masked client frames.
    static func applyMask(_ mask: [UInt8], to data: inout Data) {
        guard mask.count == 4 else { return }
        data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            let count = raw.count
            var word: UInt64 = 0
            withUnsafeMutableBytes(of: &word) { w in
                for i in 0..<8 { w[i] = mask[i & 3] }
            }
            var i = 0
            while i + 8 <= count {
                let value = (base + i).loadUnaligned(as: UInt64.self)
                (base + i).storeBytes(of: value ^ word, as: UInt64.self)
                i += 8
            }
            let bytes = raw.bindMemory(to: UInt8.self)
            while i < count {
                bytes[i] ^= mask[i & 3]
                i += 1
            }
        }
    }

    static func frame(fin: Bool, opcode: Opcode, payload: Data, mask: [UInt8]? = nil) -> Data {
        var out = Data()
        out.append((fin ? 0x80 : 0) | opcode.rawValue)
        let maskBit: UInt8 = mask == nil ? 0 : 0x80
        let n = payload.count
        if n < 126 {
            out.append(maskBit | UInt8(n))
        } else if n <= 0xFFFF {
            out.append(maskBit | 126)
            out.append(UInt8(n >> 8))
            out.append(UInt8(n & 0xFF))
        } else {
            out.append(maskBit | 127)
            for shift in stride(from: 56, through: 0, by: -8) {
                out.append(UInt8((UInt64(n) >> UInt64(shift)) & 0xFF))
            }
        }
        if let mask {
            out.append(contentsOf: mask)
            var masked = Data(payload)
            applyMask(mask, to: &masked)
            out.append(masked)
        } else {
            out.append(payload)
        }
        return out
    }

    // MARK: Receiving

    /// The next data message. Answers pings and closes on its own; returns
    /// nil when the peer closed.
    func receive() async throws -> Message? {
        var messageOpcode: Opcode?
        var message = Data()
        while true {
            let head = try await connection.read(exactly: 2)
            let fin = head[0] & 0x80 != 0
            guard head[0] & 0x70 == 0 else { throw RemoteHTTPError.malformed("reserved bits set") }
            guard let opcode = Opcode(rawValue: head[0] & 0x0F) else { throw RemoteHTTPError.malformed("unknown opcode") }
            let masked = head[1] & 0x80 != 0
            var length = UInt64(head[1] & 0x7F)
            if length == 126 {
                let ext = try await connection.read(exactly: 2)
                length = UInt64(ext[0]) << 8 | UInt64(ext[1])
            } else if length == 127 {
                let ext = try await connection.read(exactly: 8)
                length = ext.reduce(0) { $0 << 8 | UInt64($1) }
            }
            guard length <= UInt64(Self.maxMessageBytes) else { throw RemoteHTTPError.tooLarge }
            guard masked || role == .client else { throw RemoteHTTPError.malformed("client frames must be masked") }
            let mask = masked ? [UInt8](try await connection.read(exactly: 4)) : nil
            var payload = try await connection.read(exactly: Int(length))
            if let mask { Self.applyMask(mask, to: &payload) }

            switch opcode {
            case .ping:
                connection.sendDetached(Self.frame(fin: true, opcode: .pong, payload: payload, mask: masks ? Self.newMask() : nil))
            case .pong:
                break
            case .close:
                var code: UInt16 = 1005
                var reason = ""
                if payload.count >= 2 {
                    code = UInt16(payload[payload.startIndex]) << 8 | UInt16(payload[payload.startIndex + 1])
                    reason = String(decoding: payload.dropFirst(2), as: UTF8.self)
                }
                lock.withLock { _peerClose = (code, reason) }
                close(code: code == 1005 ? 1000 : code)
                return nil
            case .text, .binary:
                guard messageOpcode == nil else { throw RemoteHTTPError.malformed("new message inside a fragmented one") }
                messageOpcode = opcode
                message = payload
            case .continuation:
                guard messageOpcode != nil else { throw RemoteHTTPError.malformed("continuation without a message") }
                message.append(payload)
            }
            guard message.count <= Self.maxMessageBytes else { throw RemoteHTTPError.tooLarge }
            if fin, let kind = messageOpcode, opcode == .text || opcode == .binary || opcode == .continuation {
                return kind == .text ? .text(String(decoding: message, as: UTF8.self)) : .binary(message)
            }
        }
    }
}
