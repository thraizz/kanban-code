import Foundation
import KanbanCodeRemoteKit

/// The vault routes of the Remote Control server (docs/vault.md):
///
///   POST   /v1/vault/release           secrets for a command: granted, pending or denied
///   GET    /v1/vault/pending/{id}      the outcome of a pending request
///   POST   /v1/vault/request           a card lease, with a reason
///   POST   /v1/vault/aws               short-lived AWS credentials for a profile
///   GET    /v1/vault/secrets           names, tiers and rules, never values
///   POST   /v1/vault/secrets           add a secret (replacing one asks the human)
///   PATCH  /v1/vault/secrets           one change to several secrets, in one approval
///   PATCH  /v1/vault/secrets/{name}    tier, rules, tags (asks the human)
///   DELETE /v1/vault/secrets/{name}    (asks the human)
///   GET    /v1/vault/log               the audit log, newest first
///   GET    /v1/vault/leases            active leases
///   GET    /v1/vault/status
///   GET    /v1/vault/replica           the encrypted file (full scope, for peer masters)
///   POST   /v1/vault/replica           merge a peer's encrypted file (full scope)
///
/// Loopback callers need no token: the master finds the calling process
/// and the card session it runs in. Callers over the network are never
/// inside a card session, so everything they ask goes to the human.
enum RemoteVaultRoutes {
    static func handle(
        method: String,
        rest: [String],
        query: [String: String],
        body: Data,
        device: RemoteDevice?,
        peer: RemotePeerAddress?,
        serverPort: Int,
        vault: VaultService
    ) async -> RemoteHTTPResponse? {
        guard rest.first == "vault" else { return nil }
        let path = Array(rest.dropFirst())
        let loopback = peer?.isLoopback ?? false

        func caller(claimedCard: String?, sessionId: String?) async -> VaultCaller {
            guard loopback, let peer else {
                return VaultCaller(claimedCardId: claimedCard, sessionId: sessionId, remoteDevice: device?.name ?? "unknown")
            }
            return await vault.resolver.resolve(clientPort: peer.port, serverPort: serverPort, claimedCardId: claimedCard, sessionId: sessionId)
        }

        func respond(_ r: VaultResponse) -> RemoteHTTPResponse {
            switch r.status {
            case .granted: return .json(r)
            case .pending: return .json(r, status: 202)
            case .denied: return .json(r, status: 403)
            }
        }

        func decode<T: Decodable>(_ type: T.Type) -> T? {
            try? JSONDecoder.vault.decode(type, from: body)
        }

        switch (method, path.first, path.count) {
        case ("POST", "release", 1):
            guard let req = decode(VaultReleaseRequest.self) else {
                return .error(400, "body must be {\"mode\", \"names\": [...], \"command\", \"reason\", \"cwd\", \"cardId\"}")
            }
            let who = await caller(claimedCard: req.cardId, sessionId: req.sessionId)
            return respond(await vault.broker.release(req, caller: who))

        case ("GET", "pending", 2):
            return respond(await vault.broker.poll(id: path[1]))

        case ("POST", "request", 1):
            guard let req = decode(VaultLeaseRequest.self), !req.reason.isEmpty else {
                return .error(400, "body must be {\"names\": [...], \"reason\": \"...\"}")
            }
            let who = await caller(claimedCard: req.cardId, sessionId: req.sessionId)
            return respond(await vault.broker.requestLease(req, caller: who))

        case ("POST", "aws", 1):
            guard var req = decode(VaultReleaseRequest.self), let profile = req.names.first else {
                return .error(400, "body must be {\"names\": [\"<profile>\"], \"command\"}")
            }
            req.mode = "aws"
            req.names = [profile.hasPrefix("aws:") ? profile : "aws:\(profile)"]
            let who = await caller(claimedCard: req.cardId, sessionId: req.sessionId)
            return respond(await vault.broker.release(req, caller: who))

        case ("GET", "secrets", 1):
            do {
                return .json(try await vault.store.list())
            } catch {
                return .error(423, "\(error)")
            }

        case ("POST", "secrets", 1):
            guard let req = decode(VaultAddRequest.self) else {
                return .error(400, "body must be {\"name\", \"value\", \"tier\", \"rules\", \"tags\"}")
            }
            let who = await caller(claimedCard: query["card"], sessionId: nil)
            let r = await vault.broker.add(req, caller: who, trusted: false)
            await vault.replica?.poke()
            return respond(r)

        case ("PATCH", "secrets", 1):
            guard let req = decode(VaultBatchEditRequest.self) else {
                return .error(400, "body must be {\"names\": [...], \"valuePrefixes\": [...], \"edit\": {\"tier\", \"leasePolicy\", \"reason\"}}")
            }
            let who = await caller(claimedCard: query["card"], sessionId: nil)
            return respond(await vault.broker.editMany(req, caller: who, trusted: false))

        case ("PATCH", "secrets", 2):
            guard let req = decode(VaultEditRequest.self) else {
                return .error(400, "body must be {\"tier\", \"rules\", \"tags\", \"leasePolicy\"}")
            }
            let who = await caller(claimedCard: query["card"], sessionId: nil)
            return respond(await vault.broker.edit(path[1], req, caller: who, trusted: false))

        case ("DELETE", "secrets", 2):
            let who = await caller(claimedCard: query["card"], sessionId: nil)
            return respond(await vault.broker.delete(path[1], caller: who, trusted: false, reason: query["reason"]))

        case ("GET", "log", 1):
            let limit = min(max(Int(query["limit"] ?? "") ?? 100, 1), 2000)
            return .json(await vault.store.log(limit: limit, cardId: query["card"], secret: query["secret"]))

        case ("GET", "leases", 1):
            return .json(await vault.store.activeLeases(cardId: query["card"]))

        case ("GET", "status", 1):
            let count = (try? await vault.store.list().count) ?? 0
            let identity = await vault.store.currentIdentity()
            let who = await caller(claimedCard: query["card"], sessionId: nil)
            return .json(VaultStatus(unlocked: identity != nil, recipient: identity?.recipient.text, secrets: count,
                                     machine: vault.broker.machine, caller: who.insideCard ? who.cardId : nil))

        case (_, "replica", 1):
            guard let device, device.scope == .full else {
                return .error(403, "the replica is for peer masters with a full-scope token")
            }
            if method == "GET" {
                return .json(VaultReplicaBody(blob: await vault.store.encryptedBlob()?.base64EncodedString()))
            }
            guard method == "POST", let req = try? JSONDecoder().decode(VaultReplicaBody.self, from: body),
                  let blob = req.blob.flatMap({ Data(base64Encoded: $0) }) else {
                return .error(400, "body must be {\"blob\": \"<base64>\"}")
            }
            do {
                let result = try await vault.store.mergeReplica(blob)
                return .json(["changed": result.changedHere, "youAreBehind": result.otherIsBehind])
            } catch {
                return .error(422, "\(error)")
            }

        default:
            return .error(404, "no vault route \(method) /v1/\(rest.joined(separator: "/"))")
        }
    }
}
