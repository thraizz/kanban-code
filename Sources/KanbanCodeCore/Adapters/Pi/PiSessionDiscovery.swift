import Foundation

/// Discovers Pi sessions by scanning `~/.pi/agent/sessions/*/*.jsonl`.
///
/// A file is parsed again only when its modification time changed.
public final class PiSessionDiscovery: SessionDiscovery, @unchecked Sendable {
    private let sessionsRoot: String
    private var cachedSessions: [String: Session] = [:]
    private var fileMtimes: [String: Date] = [:]

    public init(sessionsRoot: String? = nil) {
        self.sessionsRoot = sessionsRoot ?? PiSessionFile.sessionsRoot()
    }

    public func discoverSessions() async throws -> [Session] {
        let fileManager = FileManager.default
        let files = PiSessionFile.sessionFiles(root: sessionsRoot)
        let seenFiles = Set(files)

        for removedPath in Set(fileMtimes.keys).subtracting(seenFiles) {
            fileMtimes.removeValue(forKey: removedPath)
            cachedSessions = cachedSessions.filter { $0.value.jsonlPath != removedPath }
        }

        for filePath in files {
            guard let attrs = try? fileManager.attributesOfItem(atPath: filePath),
                  let mtime = attrs[.modificationDate] as? Date else { continue }
            if fileMtimes[filePath] == mtime { continue }
            fileMtimes[filePath] = mtime

            guard let metadata = try? PiSessionFile.metadata(from: filePath),
                  metadata.messageCount > 0 else { continue }
            cachedSessions[metadata.sessionId] = Session(
                id: metadata.sessionId,
                name: metadata.name,
                firstPrompt: metadata.firstPrompt,
                projectPath: metadata.projectPath,
                gitBranch: nil,
                messageCount: metadata.messageCount,
                modifiedTime: mtime,
                jsonlPath: filePath,
                assistant: .pi
            )
        }

        return cachedSessions.values.sorted { $0.modifiedTime > $1.modifiedTime }
    }

    public func discoverNewOrModified(since: Date) async throws -> [Session] {
        try await discoverSessions()
    }
}
