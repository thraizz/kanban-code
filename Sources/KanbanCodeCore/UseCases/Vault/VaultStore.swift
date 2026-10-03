#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// Where the vault's age identity lives: the Keychain on the Mac, a 0600
/// file on a headless master.
public protocol VaultKeyProvider: Sendable {
    func loadIdentity() throws -> Age.Identity?
    func saveIdentity(_ identity: Age.Identity) throws
}

/// The identity in a file only its owner reads (0600).
public struct FileVaultKeyProvider: VaultKeyProvider {
    public let path: String

    public init(path: String) {
        self.path = path
    }

    public func loadIdentity() throws -> Age.Identity? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try Age.Identity(text: String(decoding: data, as: UTF8.self))
    }

    public func saveIdentity(_ identity: Age.Identity) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let text = "# Kanban Code vault identity. Recovery: age -d -i <this file> vault.age\n# public key: \(identity.recipient.text)\n\(identity.text)\n"
        try VaultFiles.writeAtomically(Data(text.utf8), to: path, mode: 0o600)
    }
}

/// An identity held in memory, for tests.
public final class MemoryVaultKeyProvider: VaultKeyProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var identity: Age.Identity?

    public init(_ identity: Age.Identity? = nil) {
        self.identity = identity
    }

    public func loadIdentity() throws -> Age.Identity? {
        lock.withLock { identity }
    }

    public func saveIdentity(_ identity: Age.Identity) throws {
        lock.withLock { self.identity = identity }
    }
}

/// `vault.age` holds the document plus an HMAC keyed from the identity.
/// Anyone with the public key can write an age file; only a holder of the
/// identity can write one a replica merges.
enum VaultSeal {
    private struct Sealed: Codable {
        var doc: String
        var auth: String
    }

    static func authKey(_ identity: Age.Identity) -> SymmetricKey {
        Age.hkdf(ikm: identity.rawKey, salt: Data("kanban-code-vault".utf8), info: "document-auth")
    }

    static func seal(_ docJSON: Data, identity: Age.Identity) throws -> Data {
        let mac = HMAC<SHA256>.authenticationCode(for: docJSON, using: authKey(identity))
        let wrapper = Sealed(doc: docJSON.base64EncodedString(), auth: Data(mac).base64EncodedString())
        return try Age.encrypt(try JSONEncoder().encode(wrapper), to: [identity.recipient])
    }

    static func open(_ file: Data, identity: Age.Identity) throws -> VaultDocument {
        let plain = try Age.decrypt(file, with: identity)
        let wrapper = try JSONDecoder().decode(Sealed.self, from: plain)
        guard let doc = Data(base64Encoded: wrapper.doc), let auth = Data(base64Encoded: wrapper.auth),
              HMAC<SHA256>.isValidAuthenticationCode(auth, authenticating: doc, using: authKey(identity))
        else { throw VaultError.invalid("the vault file was not written by a holder of the vault key") }
        return try JSONDecoder.vault.decode(VaultDocument.self, from: doc)
    }
}

enum VaultFiles {
    static func writeAtomically(_ data: Data, to path: String, mode: Int) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let tmp = dir + "/.\((path as NSString).lastPathComponent).\(UUID().uuidString).tmp"
        guard FileManager.default.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: mode]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(tmp, path) == 0 else {
            unlink(tmp)
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

public enum VaultError: Error, Equatable, CustomStringConvertible {
    case locked(String)
    case notFound(String)
    case invalid(String)

    public var description: String {
        switch self {
        case .locked(let why), .notFound(let why), .invalid(let why): why
        }
    }
}

/// The vault of one master, under `<kanban home>/vault/`:
///
///   vault.age     the secrets, age-encrypted to the vault identity
///   leases.json   card leases (names and dates, no values)
///   audit.jsonl   append-only release log of this machine
///
/// Every master holding the identity can open the same `vault.age`; the
/// replicas converge with `VaultDocument.merged`.
public actor VaultStore {
    public let directory: String
    public let keys: any VaultKeyProvider
    private var document: VaultDocument?
    private var identity: Age.Identity?
    private var leases: [VaultLease]?
    private var rate = VaultRateCounter()

    public init(directory: String, keys: any VaultKeyProvider) {
        self.directory = directory
        self.keys = keys
    }

    public static func defaultDirectory(kanbanHome: String) -> String {
        (kanbanHome as NSString).appendingPathComponent("vault")
    }

    var vaultPath: String { directory + "/vault.age" }
    var leasesPath: String { directory + "/leases.json" }
    var auditPath: String { directory + "/audit.jsonl" }
    var pendingPath: String { directory + "/pending.age" }

    // MARK: - Identity

    /// Creates the identity when the vault has none yet and no vault file
    /// exists (a file without its key must not be overwritten).
    @discardableResult
    public func ensureIdentity() throws -> Age.Identity {
        if let identity { return identity }
        if let loaded = try keys.loadIdentity() {
            identity = loaded
            return loaded
        }
        guard !FileManager.default.fileExists(atPath: vaultPath) else {
            throw VaultError.locked("vault.age exists but this machine has no vault key: import it first")
        }
        let fresh = Age.Identity.generate()
        try keys.saveIdentity(fresh)
        identity = fresh
        return fresh
    }

    /// The identity, or nil when this machine has none (it then keeps the
    /// encrypted replica without opening it).
    public func currentIdentity() -> Age.Identity? {
        if let identity { return identity }
        identity = try? keys.loadIdentity()
        return identity
    }

    public func importIdentity(_ new: Age.Identity) throws {
        if FileManager.default.fileExists(atPath: vaultPath), let data = FileManager.default.contents(atPath: vaultPath) {
            _ = try Age.decrypt(data, with: new)
        }
        try keys.saveIdentity(new)
        identity = new
        document = nil
    }

    public var isUnlocked: Bool { currentIdentity() != nil }

    // MARK: - Document

    func load() throws -> VaultDocument {
        if let document { return document }
        guard let data = FileManager.default.contents(atPath: vaultPath) else {
            let empty = VaultDocument()
            document = empty
            return empty
        }
        guard let identity = currentIdentity() else {
            throw VaultError.locked("this machine has no vault key")
        }
        let decoded = try VaultSeal.open(data, identity: identity)
        document = decoded
        return decoded
    }

    private func save(_ doc: VaultDocument) throws {
        let identity = try ensureIdentity()
        let plain = try JSONEncoder.vault.encode(doc)
        let sealed = try VaultSeal.seal(plain, identity: identity)
        try VaultFiles.writeAtomically(sealed, to: vaultPath, mode: 0o600)
        // What is on disk, dates at the file's millisecond precision.
        document = try JSONDecoder.vault.decode(VaultDocument.self, from: plain)
    }

    public func list() throws -> [VaultSecretInfo] {
        try load().live.map(\.info)
    }

    public func secret(_ name: String) throws -> VaultSecret? {
        guard let s = try load().secrets[name], s.deletedAt == nil else { return nil }
        return s
    }

    /// Adds or replaces a secret; `updatedAt` is stamped now.
    public func upsert(_ secret: VaultSecret, now: Date = Date()) throws {
        guard VaultSecret.isValidName(secret.name) else {
            throw VaultError.invalid("secret names use letters, digits and _ - . / : (got \(secret.name))")
        }
        var doc = try load()
        var s = secret
        if let existing = doc.secrets[s.name], existing.deletedAt == nil {
            s.createdAt = existing.createdAt
        }
        s.updatedAt = max(now, (doc.secrets[s.name]?.updatedAt ?? .distantPast).addingTimeInterval(0.001))
        s.deletedAt = nil
        doc.secrets[s.name] = s
        try save(doc)
    }

    /// Edits what a secret is without touching its value.
    public func update(_ name: String, now: Date = Date(), _ edit: (inout VaultSecret) -> Void) throws {
        guard var s = try secret(name) else { throw VaultError.notFound("no secret \(name)") }
        edit(&s)
        s.name = name
        try upsert(s, now: now)
    }

    public func delete(_ name: String, now: Date = Date()) throws {
        var doc = try load()
        guard var s = doc.secrets[name], s.deletedAt == nil else { throw VaultError.notFound("no secret \(name)") }
        s.value = ""
        s.deletedAt = now
        s.updatedAt = max(now, s.updatedAt.addingTimeInterval(0.001))
        doc.secrets[name] = s
        try save(doc)
    }

    // MARK: - Replica

    /// The encrypted file as it is on disk, for a replica.
    public func encryptedBlob() -> Data? {
        FileManager.default.contents(atPath: vaultPath)
    }

    /// Merges another replica's file into this one. Returns whether this
    /// vault changed, and whether the other side lacks something this one has.
    @discardableResult
    public func mergeReplica(_ blob: Data) throws -> (changedHere: Bool, otherIsBehind: Bool) {
        guard let identity = currentIdentity() else {
            // Without the key the newest blob is kept as is, still encrypted.
            if FileManager.default.contents(atPath: vaultPath) != blob {
                try VaultFiles.writeAtomically(blob, to: vaultPath, mode: 0o600)
                return (true, false)
            }
            return (false, false)
        }
        let theirs = try VaultSeal.open(blob, identity: identity)
        let mine = try load()
        let merged = mine.merged(with: theirs)
        let changed = merged != mine
        if changed { try save(merged) }
        return (changed, theirs.merged(with: merged) != theirs)
    }

    // MARK: - Leases

    private func loadLeases() -> [VaultLease] {
        if let leases { return leases }
        let loaded = FileManager.default.contents(atPath: leasesPath)
            .flatMap { try? JSONDecoder.vault.decode([VaultLease].self, from: $0) } ?? []
        leases = loaded
        return loaded
    }

    private func saveLeases(_ list: [VaultLease]) throws {
        leases = list
        try VaultFiles.writeAtomically(try JSONEncoder.vault.encode(list), to: leasesPath, mode: 0o600)
    }

    public func activeLease(cardId: String, secret: String, now: Date = Date()) -> VaultLease? {
        loadLeases().first { $0.cardId == cardId && $0.secret == secret && $0.isActive(at: now) }
    }

    public func activeLeases(cardId: String? = nil, now: Date = Date()) -> [VaultLease] {
        loadLeases().filter { $0.isActive(at: now) && (cardId == nil || $0.cardId == cardId) }
            .sorted { $0.grantedAt > $1.grantedAt }
    }

    public func grantLease(_ lease: VaultLease) throws {
        let now = Date()
        var list = loadLeases().filter { $0.isActive(at: now) && !($0.cardId == lease.cardId && $0.secret == lease.secret) }
        var capped = lease
        capped.expiresAt = min(lease.expiresAt, lease.grantedAt.addingTimeInterval(VaultLeasePolicy.maximumLease))
        list.append(capped)
        try saveLeases(list)
    }

    public func revokeLease(id: String) throws {
        try saveLeases(loadLeases().filter { $0.id != id })
    }

    // MARK: - Open requests

    /// Stores the broker's open requests, age-encrypted to the vault
    /// identity (an add carries the new value); nil removes the file.
    public func savePending(_ json: Data?) throws {
        guard let json else {
            unlink(pendingPath)
            return
        }
        let identity = try ensureIdentity()
        try VaultFiles.writeAtomically(try Age.encrypt(json, to: [identity.recipient]), to: pendingPath, mode: 0o600)
    }

    public func loadPending() -> Data? {
        guard let data = FileManager.default.contents(atPath: pendingPath), let identity = currentIdentity() else { return nil }
        return try? Age.decrypt(data, with: identity)
    }

    // MARK: - Rate

    public func recentReleases(_ secret: String, now: Date = Date()) -> Int {
        rate.count(secret, now: now)
    }

    public func recordRelease(_ secret: String, now: Date = Date()) {
        rate.record(secret, at: now)
    }

    // MARK: - Audit

    public func append(_ entry: VaultAuditEntry) {
        guard var line = try? JSONEncoder.vaultLine.encode(entry) else { return }
        line.append(0x0A)
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !FileManager.default.fileExists(atPath: auditPath) {
            FileManager.default.createFile(atPath: auditPath, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = FileHandle(forWritingAtPath: auditPath) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }

    /// Newest first.
    public func log(limit: Int = 200, cardId: String? = nil, secret: String? = nil) -> [VaultAuditEntry] {
        guard let data = FileManager.default.contents(atPath: auditPath) else { return [] }
        var out: [VaultAuditEntry] = []
        for line in data.split(separator: 0x0A).reversed() {
            guard let entry = try? JSONDecoder.vault.decode(VaultAuditEntry.self, from: Data(line)) else { continue }
            if let cardId, entry.cardId != cardId { continue }
            if let secret, entry.secret != secret { continue }
            out.append(entry)
            if out.count >= limit { break }
        }
        return out
    }
}

extension JSONEncoder {
    static var vault: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(VaultDates.format(date))
        }
        e.outputFormatting = [.sortedKeys]
        return e
    }

    static var vaultLine: JSONEncoder { vault }
}

extension JSONDecoder {
    static var vault: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let text = try c.decode(String.self)
            guard let date = VaultDates.parse(text) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "bad date \(text)")
            }
            return date
        }
        return d
    }
}

/// ISO 8601 with milliseconds, the format of the remote API.
enum VaultDates {
    static func format(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    static func parse(_ text: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: text) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: text)
    }
}
