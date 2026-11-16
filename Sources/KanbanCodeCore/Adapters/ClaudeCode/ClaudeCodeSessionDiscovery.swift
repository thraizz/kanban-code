import Foundation

/// Discovers Claude Code sessions by scanning ~/.claude/projects/.
/// Merges sessions-index.json metadata with .jsonl file scanning.
///
/// Caching strategy: keeps the full result from the last scan. A project
/// directory is listed again (and its sessions-index.json read again) only
/// when its own mtime changed, i.e. files were added, removed or renamed.
/// Every pass still checks each transcript's mtime: a running session
/// appends to its file, which leaves the directory's mtime alone, and its
/// `modifiedTime` (the card's last activity) must follow those writes.
public final class ClaudeCodeSessionDiscovery: SessionDiscovery, @unchecked Sendable {
    private let claudeDir: String
    private var lastScanTime: Date?

    /// Cache: sessionId → parsed session (from all dirs combined)
    private var cachedSessions: [String: Session] = [:]
    /// Per-directory mtime, to skip listing an unchanged directory again
    private var dirMtimes: [String: Date] = [:]
    /// The .jsonl files and the index entries of each directory as last listed
    private var dirJsonlFiles: [String: [String]] = [:]
    private var dirIndexById: [String: [String: SessionIndexReader.IndexEntry]] = [:]
    /// Per-file mtime to skip re-parsing unchanged .jsonl files
    private var fileMtimes: [String: Date] = [:]
    /// Track which sessions came from which directory for eviction
    private var dirSessionIds: [String: Set<String>] = [:]
    /// Headless sessions whose project is excluded, by directory: never
    /// read again, whatever their mtime, until the exclusions change.
    private var dirSkippedIds: [String: Set<String>] = [:]
    private var headlessExclusion: PathExclusion = .none

    public init(claudeDir: String? = nil) {
        self.claudeDir = claudeDir
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects")
    }

    public func excludedHeadlessSessionIds() -> Set<String> {
        dirSkippedIds.values.reduce(into: Set<String>()) { $0.formUnion($1) }
    }

    public func setHeadlessExclusion(_ exclusion: PathExclusion) {
        guard exclusion != headlessExclusion else { return }
        headlessExclusion = exclusion
        // Rescan every directory: sessions a removed entry excluded come
        // back, and cached ones a new entry excludes go.
        dirMtimes = [:]
        dirSkippedIds = [:]
        for (id, session) in cachedSessions where isExcludedHeadless(session) {
            cachedSessions.removeValue(forKey: id)
        }
    }

    private func isExcludedHeadless(_ session: Session) -> Bool {
        session.isHeadless && headlessExclusion.matches(session.projectPath)
    }

    /// Drops a cached session whose transcript left `dirPath`. A transcript
    /// that moved to another project directory (the session entered a
    /// worktree) may already be cached at its new path, and stays.
    private func evict(_ sessionId: String, ifStoredIn dirPath: String) {
        if let path = cachedSessions[sessionId]?.jsonlPath,
           (path as NSString).deletingLastPathComponent != dirPath {
            return
        }
        cachedSessions.removeValue(forKey: sessionId)
    }

    public func discoverSessions() async throws -> [Session] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: claudeDir) else { return [] }

        let projectDirs = try fileManager.contentsOfDirectory(atPath: claudeDir)
        var seenDirs: Set<String> = []

        for dirName in projectDirs {
            let dirPath = (claudeDir as NSString).appendingPathComponent(dirName)
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: dirPath, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            seenDirs.insert(dirName)

            // An unchanged directory mtime means no file was added or
            // removed: reuse the listing and the index. Appending to a
            // transcript does not touch the directory, so the files are
            // still checked one by one below.
            let dirAttrs = try? fileManager.attributesOfItem(atPath: dirPath)
            let dirMtime = dirAttrs?[.modificationDate] as? Date
            let jsonlFiles: [String]
            let indexById: [String: SessionIndexReader.IndexEntry]
            if let dirMtime, dirMtimes[dirName] == dirMtime, let files = dirJsonlFiles[dirName] {
                jsonlFiles = files
                indexById = dirIndexById[dirName] ?? [:]
            } else {
                dirMtimes[dirName] = dirMtime
                let indexPath = (dirPath as NSString).appendingPathComponent("sessions-index.json")
                let indexEntries = (try? SessionIndexReader.readIndex(at: indexPath, directoryName: dirName)) ?? []
                var byId: [String: SessionIndexReader.IndexEntry] = [:]
                for entry in indexEntries {
                    byId[entry.sessionId] = entry
                }
                let contents = (try? fileManager.contentsOfDirectory(atPath: dirPath)) ?? []
                jsonlFiles = contents.filter { $0.hasSuffix(".jsonl") }
                indexById = byId
                dirJsonlFiles[dirName] = jsonlFiles
                dirIndexById[dirName] = byId
            }

            var dirSessions: Set<String> = []
            var skipped = dirSkippedIds[dirName] ?? []
            let mayBeExcluded = headlessExclusion.mayMatchClaudeProjectDir(dirName)

            for jsonlFile in jsonlFiles {
                let filePath = (dirPath as NSString).appendingPathComponent(jsonlFile)
                let sessionId = jsonlFile.replacingOccurrences(of: ".jsonl", with: "")
                if skipped.contains(sessionId) {
                    dirSessions.insert(sessionId)
                    continue
                }
                dirSessions.insert(sessionId)

                guard let attrs = try? fileManager.attributesOfItem(atPath: filePath),
                      let mtime = attrs[.modificationDate] as? Date else {
                    continue
                }

                // Skip if file mtime unchanged and we have a cached session
                if let cachedMtime = fileMtimes[filePath],
                   mtime == cachedMtime,
                   cachedSessions[sessionId] != nil {
                    // Still merge index data in case index was updated
                    if let entry = indexById[sessionId], var session = cachedSessions[sessionId] {
                        if session.name == nil { session.name = entry.summary }
                        if session.projectPath == nil { session.projectPath = entry.projectPath }
                        cachedSessions[sessionId] = session
                    }
                    continue
                }
                if mayBeExcluded, cachedSessions[sessionId] == nil,
                   let launch = try? await JsonlParser.extractLaunchContext(from: filePath),
                   Session.isHeadless(entrypoint: launch.entrypoint),
                   headlessExclusion.matches(indexById[sessionId]?.projectPath
                       ?? launch.cwd ?? JsonlParser.decodeDirectoryName(dirName)) {
                    skipped.insert(sessionId)
                    fileMtimes.removeValue(forKey: filePath)
                    continue
                }
                fileMtimes[filePath] = mtime

                // Parse .jsonl for metadata
                let indexEntry = indexById[sessionId]
                if let metadata = try? await JsonlParser.extractMetadata(from: filePath) {
                    var session = Session(id: sessionId)
                    session.name = indexEntry?.summary
                    session.projectPath = indexEntry?.projectPath
                    session.jsonlPath = filePath
                    session.modifiedTime = JsonlParser.writeTime(of: filePath, mtime: mtime)
                    session.messageCount = metadata.messageCount
                    session.entrypoint = metadata.entrypoint

                    if session.firstPrompt == nil {
                        session.firstPrompt = metadata.firstPrompt
                    }
                    if session.projectPath == nil {
                        session.projectPath = metadata.projectPath
                            ?? JsonlParser.decodeDirectoryName(dirName)
                    }
                    if session.gitBranch == nil {
                        session.gitBranch = metadata.gitBranch
                    }

                    if isExcludedHeadless(session) {
                        skipped.insert(sessionId)
                        cachedSessions.removeValue(forKey: sessionId)
                        fileMtimes.removeValue(forKey: filePath)
                        continue
                    }
                    cachedSessions[sessionId] = session
                } else if let entry = indexEntry {
                    // File couldn't parse but we have index data
                    if var session = cachedSessions[sessionId] ?? Session(id: sessionId) as Session? {
                        session.name = session.name ?? entry.summary
                        session.projectPath = session.projectPath ?? entry.projectPath
                        session.jsonlPath = filePath
                        session.modifiedTime = JsonlParser.writeTime(of: filePath, mtime: mtime)
                        cachedSessions[sessionId] = session
                    }
                }
            }

            // Evict sessions from this dir that no longer exist
            if let oldIds = dirSessionIds[dirName] {
                for removedId in oldIds.subtracting(dirSessions) {
                    evict(removedId, ifStoredIn: dirPath)
                }
            }
            dirSessionIds[dirName] = dirSessions
            skipped.formIntersection(dirSessions)
            dirSkippedIds[dirName] = skipped.isEmpty ? nil : skipped
        }

        // Evict entire directories that were removed
        for removedDir in Set(dirMtimes.keys).subtracting(seenDirs) {
            dirMtimes.removeValue(forKey: removedDir)
            dirJsonlFiles.removeValue(forKey: removedDir)
            dirIndexById.removeValue(forKey: removedDir)
            dirSkippedIds.removeValue(forKey: removedDir)
            if let ids = dirSessionIds.removeValue(forKey: removedDir) {
                let dirPath = (claudeDir as NSString).appendingPathComponent(removedDir)
                for id in ids { evict(id, ifStoredIn: dirPath) }
            }
        }

        let sessions = cachedSessions.values
            .filter { $0.messageCount > 0 }
            .sorted { $0.modifiedTime > $1.modifiedTime }

        lastScanTime = Date()
        return Array(sessions)
    }

    public func discoverNewOrModified(since: Date) async throws -> [Session] {
        return try await discoverSessions()
    }
}
