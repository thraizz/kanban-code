import Foundation
import KanbanCodeRemoteKit

/// The agent sync routes of the Remote Control server (Settings > Sync),
/// for full-scope devices and peer masters only: they read and run things in the home folder.
///
///   GET  /v1/sync/state                  config, mirror manifests, git origins
///   GET  /v1/sync/file?entry=&path=      one file, home folder marked
///   POST /v1/sync/changed?machine=&what= a peer changed something: pull it
///   POST /v1/optmem/run                  run a forwarded memo command on the home
enum RemoteSyncRoutes {
    static func handle(
        method: String,
        rest: [String],
        query: [String: String],
        body: Data,
        device: RemoteDevice,
        engine: AgentSyncEngine
    ) async -> RemoteHTTPResponse? {
        guard rest.first == "sync" || rest == ["optmem", "run"] else { return nil }
        guard device.scope.actsForOwner else {
            return .error(403, "the \(device.scope.rawValue) scope cannot sync the agent setup")
        }
        switch rest {
        case ["sync", "state"]:
            guard method == "GET" else { return .error(405, "use GET") }
            return .json(await engine.state())

        case ["sync", "file"]:
            guard method == "GET" else { return .error(405, "use GET") }
            guard let entry = query["entry"], let path = query["path"] else {
                return .error(400, "entry and path are required")
            }
            guard let data = await engine.file(entryId: entry, path: path) else {
                return .error(404, "no file \(path) in \(entry)")
            }
            return RemoteHTTPResponse(status: 200, headers: [("Content-Type", "application/octet-stream")], body: data)

        case ["sync", "changed"]:
            guard method == "POST" else { return .error(405, "use POST") }
            await engine.poke(machineId: query["machine"], what: query["what"])
            return .noContent

        case ["optmem", "run"]:
            guard method == "POST" else { return .error(405, "use POST") }
            guard let request = try? JSONDecoder().decode(OptmemRunRequest.self, from: body) else {
                return .error(400, "body must be {\"id\", \"argv\": [...], \"date\"}")
            }
            switch await engine.optmemRun(request) {
            case .success(let result):
                return .json(result)
            case .failure(.http(let status, let message)):
                return .error(status, message)
            case .failure(let error):
                return .error(500, error.localizedDescription)
            }

        default:
            return .error(404, "no route for /v1/\(rest.joined(separator: "/"))")
        }
    }
}
