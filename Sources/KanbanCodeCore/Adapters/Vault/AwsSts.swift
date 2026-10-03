#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Long-lived AWS keys as a vault secret stores them.
public struct AwsAccessKey: Codable, Sendable, Equatable {
    public var accessKeyId: String
    public var secretAccessKey: String

    public init(accessKeyId: String, secretAccessKey: String) {
        self.accessKeyId = accessKeyId
        self.secretAccessKey = secretAccessKey
    }
}

/// What `credential_process` prints (Version 1).
public struct AwsProcessCredentials: Codable, Sendable, Equatable {
    public var Version: Int
    public var AccessKeyId: String
    public var SecretAccessKey: String
    public var SessionToken: String
    public var Expiration: String
}

/// STS AssumeRole / GetSessionToken over the query API, signed with SigV4.
public struct AwsSts: Sendable {
    public var endpoint: URL
    public var region: String
    public var session: URLSession

    public init(region: String = "us-east-1", session: URLSession = .shared) {
        self.region = region
        endpoint = region == "us-east-1"
            ? URL(string: "https://sts.amazonaws.com/")!
            : URL(string: "https://sts.\(region).amazonaws.com/")!
        self.session = session
    }

    public enum StsError: Error, CustomStringConvertible {
        case http(Int, String)
        case unreadable

        public var description: String {
            switch self {
            case .http(let status, let message): "STS answered HTTP \(status): \(message)"
            case .unreadable: "STS answered something unreadable"
            }
        }
    }

    public func credentials(key: AwsAccessKey, role: VaultAwsRole, sessionName: String) async throws -> AwsProcessCredentials {
        var params: [(String, String)] = [("Version", "2011-06-15")]
        if let arn = role.roleArn, !arn.isEmpty {
            params.append(("Action", "AssumeRole"))
            params.append(("RoleArn", arn))
            params.append(("RoleSessionName", Self.sessionName(sessionName)))
            params.append(("DurationSeconds", String(min(max(role.durationSeconds, 900), 3600))))
            for (i, policy) in role.policyArns.enumerated() {
                params.append(("PolicyArns.member.\(i + 1).arn", policy))
            }
        } else {
            params.append(("Action", "GetSessionToken"))
            params.append(("DurationSeconds", String(max(role.durationSeconds, 900))))
        }
        let body = Self.formEncode(params)
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        let signed = Self.sign(
            method: "POST", url: endpoint, body: Data(body.utf8),
            headers: ["content-type": "application/x-www-form-urlencoded; charset=utf-8"],
            key: key, region: region, service: "sts", date: Date()
        )
        for (name, value) in signed where name != "host" { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let text = String(decoding: data, as: UTF8.self)
        guard status == 200 else {
            throw StsError.http(status, Self.tag("Message", in: text) ?? String(text.prefix(300)))
        }
        guard let id = Self.tag("AccessKeyId", in: text),
              let secret = Self.tag("SecretAccessKey", in: text),
              let token = Self.tag("SessionToken", in: text),
              let expiration = Self.tag("Expiration", in: text)
        else { throw StsError.unreadable }
        return AwsProcessCredentials(Version: 1, AccessKeyId: id, SecretAccessKey: secret, SessionToken: token, Expiration: expiration)
    }

    static func sessionName(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "=,.@-_"))
        let cleaned = String(raw.unicodeScalars.map { allowed.contains($0) && $0.isASCII ? Character($0) : "-" })
        let trimmed = String(cleaned.prefix(64))
        return trimmed.count >= 2 ? trimmed : "kanban-vault"
    }

    static func tag(_ name: String, in xml: String) -> String? {
        guard let open = xml.range(of: "<\(name)>"),
              let close = xml.range(of: "</\(name)>", range: open.upperBound..<xml.endIndex) else { return nil }
        return String(xml[open.upperBound..<close.lowerBound])
    }

    static func formEncode(_ params: [(String, String)]) -> String {
        params.map { "\(uriEncode($0.0))=\(uriEncode($0.1))" }.joined(separator: "&")
    }

    static func uriEncode(_ s: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        return s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }

    static func hex(_ data: some Sequence<UInt8>) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// SigV4 headers (`host`, `x-amz-date`, `authorization`, plus the given
    /// ones) for a request with no query string.
    static func sign(method: String, url: URL, body: Data, headers: [String: String], key: AwsAccessKey,
                     region: String, service: String, date: Date) -> [String: String] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let amzDate = formatter.string(from: date)
        let day = String(amzDate.prefix(8))

        var all = headers
        all["host"] = url.host ?? ""
        all["x-amz-date"] = amzDate
        let names = all.keys.map { $0.lowercased() }.sorted()
        let canonicalHeaders = names.map { "\($0):\(all[$0]!.trimmingCharacters(in: .whitespaces))\n" }.joined()
        let signedHeaders = names.joined(separator: ";")
        let payloadHash = hex(SHA256.hash(data: body))
        let path = url.path.isEmpty ? "/" : url.path
        let canonical = [method, path, "", canonicalHeaders, signedHeaders, payloadHash].joined(separator: "\n")
        let scope = "\(day)/\(region)/\(service)/aws4_request"
        let toSign = ["AWS4-HMAC-SHA256", amzDate, scope, hex(SHA256.hash(data: Data(canonical.utf8)))].joined(separator: "\n")

        func hmac(_ key: Data, _ text: String) -> Data {
            Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: SymmetricKey(data: key)))
        }
        let kDate = hmac(Data("AWS4\(key.secretAccessKey)".utf8), day)
        let kSigning = hmac(hmac(hmac(kDate, region), service), "aws4_request")
        let signature = hex(hmac(kSigning, toSign))
        all["authorization"] = "AWS4-HMAC-SHA256 Credential=\(key.accessKeyId)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
        return all
    }
}
