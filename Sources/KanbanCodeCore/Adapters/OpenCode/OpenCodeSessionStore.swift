import Foundation

/// Implements SessionStore over OpenCode's SQLite database.
///
/// Session paths are the virtual paths of `OpenCodeDatabase`. The store only
/// reads: forking and truncating a session means writing OpenCode's database,
/// which only OpenCode itself may do (it forks with `--session <id> --fork`
/// and reverts through its own server API).
public final class OpenCodeSessionStore: SessionStore, @unchecked Sendable {
    private let database: OpenCodeDatabase

    public init(database: OpenCodeDatabase = OpenCodeDatabase()) {
        self.database = database
    }

    public enum StoreError: Error, LocalizedError {
        case notOpenCodeSession(String)
        case unsupported(String)

        public var errorDescription: String? {
            switch self {
            case .notOpenCodeSession(let path): "Not an OpenCode session: \(path)"
            case .unsupported(let operation): "OpenCode sessions do not support \(operation) from Kanban Code yet"
            }
        }
    }

    public func readTranscript(sessionPath: String) async throws -> [ConversationTurn] {
        let sessionId = try Self.sessionId(sessionPath)
        guard try database.session(id: sessionId) != nil else {
            throw SessionStoreError.fileNotFound(sessionPath)
        }
        return OpenCodeTranscript.turns(
            messages: try database.messages(sessionId: sessionId),
            parts: try database.parts(sessionId: sessionId)
        )
    }

    public func forkSession(sessionPath: String, targetDirectory: String?) async throws -> String {
        throw StoreError.unsupported("forking")
    }

    public func truncateSession(sessionPath: String, afterTurn: ConversationTurn) async throws {
        throw StoreError.unsupported("restoring to a turn")
    }

    public func searchSessions(query: String, paths: [String]) async throws -> [SearchResult] {
        let box = ResultBox()
        try await searchSessionsStreaming(query: query, paths: paths) { results in
            box.results = results
        }
        return box.results
    }

    public func searchSessionsStreaming(
        query: String,
        paths: [String],
        onResult: @MainActor @Sendable ([SearchResult]) -> Void
    ) async throws {
        let searchQuery = SessionSearchQuery(query)
        guard !searchQuery.isEmpty else { return }

        // Score only the parts that contain a query term: reading whole
        // transcripts to search them means reading hundreds of MB of tool
        // output, and a part without any term adds nothing but its length.
        let requested = Dictionary(
            paths.compactMap { path in OpenCodeDatabase.sessionId(fromVirtualPath: path).map { ($0, path) } },
            uniquingKeysWith: { first, _ in first }
        )
        guard !requested.isEmpty else { return }
        var textsBySession: [String: [String]] = [:]
        for term in Set(searchQuery.snippetTerms) where !term.isEmpty {
            try Task.checkCancellation()
            for part in try database.parts(containing: term) where requested[part.sessionId] != nil {
                if let text = Self.searchableText(of: part) {
                    textsBySession[part.sessionId, default: []].append(text)
                }
            }
        }
        let ids = Array(textsBySession.keys)
        let modified = try database.lastActivity(sessionIds: ids)

        struct DocInfo {
            let path: String
            let matchingTokens: [String]
            let exactMatches: Int
            let wordCount: Int
            let snippets: [String]
            let modifiedTime: Date
        }
        var docs: [DocInfo] = []
        var globalTermFreqs: [String: Int] = [:]
        var totalWordCount = 0

        for id in ids {
            guard let path = requested[id], let texts = textsBySession[id] else { continue }
            // A part matched by two terms is listed twice; count it once.
            var seen = Set<String>()
            let (tokens, exactMatches, wordCount, snippets) = Self.matchingTokens(
                in: texts.filter { seen.insert($0).inserted }, query: searchQuery)
            guard wordCount > 0 else { continue }
            totalWordCount += wordCount
            guard !tokens.isEmpty || exactMatches > 0 else { continue }
            if searchQuery.requiresExactMatch, exactMatches == 0 { continue }
            for term in Set(tokens) { globalTermFreqs[term, default: 0] += 1 }
            docs.append(DocInfo(
                path: path, matchingTokens: tokens, exactMatches: exactMatches,
                wordCount: wordCount, snippets: snippets, modifiedTime: modified[id] ?? .distantPast
            ))
        }

        let avgDocLength = Double(totalWordCount) / max(Double(docs.count), 1.0)
        var results: [SearchResult] = []
        for doc in docs {
            let termsScore = searchQuery.terms.isEmpty ? 0 : BM25Scorer.score(
                terms: searchQuery.terms,
                documentTokens: doc.matchingTokens,
                avgDocLength: avgDocLength,
                docCount: docs.count,
                docFreqs: globalTermFreqs,
                recencyBoost: BM25Scorer.recencyBoost(modifiedTime: doc.modifiedTime)
            )
            let score = searchQuery.score(termsScore: termsScore, exactMatches: doc.exactMatches, modifiedTime: doc.modifiedTime)
            if score > 0 {
                results.append(SearchResult(sessionPath: doc.path, score: score, snippets: doc.snippets))
            }
        }
        results.sort { $0.score > $1.score }
        await onResult(results)
    }

    /// The text of a part a search looks at: what was said, and a tool's name,
    /// input and (the start of) its output.
    static func searchableText(of part: OpenCodeDatabase.SearchPart) -> String? {
        switch part.type {
        case "text":
            return part.synthetic ? nil : part.text
        case "reasoning":
            return part.text
        case "tool":
            var pieces = [part.tool ?? ""]
            if let input = part.input.flatMap(OpenCodeTranscript.jsonObject) {
                pieces += input.values.compactMap { $0 as? String }
            }
            if let output = part.output { pieces.append(output) }
            return pieces.joined(separator: "\n")
        default:
            return nil
        }
    }

    // MARK: - Branches

    /// Branches the session created or pushed, from its bash tool calls. Same
    /// patterns as the Claude and Codex transcript scans.
    public static func extractPushedBranches(
        sessionPath: String,
        database: OpenCodeDatabase = OpenCodeDatabase()
    ) throws -> [JsonlParser.DiscoveredBranch] {
        let sessionId = try sessionId(sessionPath)
        let pushRegex = /git\s+push\s+(?:-[^\s]+\s+)*(?:origin|upstream)\s+(\S+)/
        let checkoutBranchRegex = /git\s+checkout\s+-[bB]\s+(\S+)/
        let switchCreateRegex = /git\s+switch\s+(?:-c|--create)\s+(\S+)/
        let worktreeAddRegex = /git\s+worktree\s+add\s+(?:[^\s;|&]+\s+)*?-b\s+(\S+)/
        var branches = Set<JsonlParser.DiscoveredBranch>()

        for part in try database.parts(sessionId: sessionId) where part.data.contains("git") {
            guard let object = OpenCodeTranscript.jsonObject(part.data),
                  object["type"] as? String == "tool",
                  object["tool"] as? String == "bash",
                  let input = (object["state"] as? [String: Any])?["input"] as? [String: Any],
                  let command = input["command"] as? String else { continue }
            let repoPath = input["workdir"] as? String

            func addBranch(_ branch: String) {
                // HEAD pushes the current branch — the name isn't in the command.
                if branch != "main" && branch != "master" && branch != "HEAD" && !branch.hasPrefix("-") {
                    branches.insert(JsonlParser.DiscoveredBranch(branch: branch, repoPath: repoPath))
                }
            }
            for match in command.matches(of: pushRegex) { addBranch(String(match.output.1)) }
            for match in command.matches(of: checkoutBranchRegex) { addBranch(String(match.output.1)) }
            for match in command.matches(of: switchCreateRegex) { addBranch(String(match.output.1)) }
            for match in command.matches(of: worktreeAddRegex) { addBranch(String(match.output.1)) }
        }
        return Array(branches).sorted { $0.branch < $1.branch }
    }

    // MARK: - Helpers

    private static func sessionId(_ path: String) throws -> String {
        guard let id = OpenCodeDatabase.sessionId(fromVirtualPath: path) else {
            throw StoreError.notOpenCodeSession(path)
        }
        return id
    }

    private static let maxSnippets = 3

    private static func matchingTokens(
        in texts: [String],
        query: SessionSearchQuery
    ) -> (tokens: [String], exactMatches: Int, wordCount: Int, snippets: [String]) {
        var matchingTokens: [String] = []
        var exactMatches = 0
        var wordCount = 0
        var topSnippets: [(score: Int, text: String)] = []

        for text in texts where !text.isEmpty {
            let docTokens = BM25Scorer.tokenize(text)
            wordCount += docTokens.count
            for token in docTokens {
                if let matched = query.matchToken(token) { matchingTokens.append(matched) }
            }

            let lower = text.lowercased()
            exactMatches += query.exactMatchCount(in: lower)
            let snippetScore = query.snippetScore(in: lower)
            if snippetScore > 0 {
                let snippet = extractSnippet(from: text, queryTerms: query.snippetTerms)
                if topSnippets.count < maxSnippets {
                    topSnippets.append((snippetScore, snippet))
                    topSnippets.sort { $0.score > $1.score }
                } else if snippetScore > topSnippets.last!.score {
                    topSnippets[topSnippets.count - 1] = (snippetScore, snippet)
                    topSnippets.sort { $0.score > $1.score }
                }
            }
        }
        return (matchingTokens, exactMatches, wordCount, topSnippets.map(\.text))
    }

    private static func extractSnippet(from text: String, queryTerms: [String]) -> String {
        let lower = text.lowercased()
        for term in queryTerms {
            if let range = lower.range(of: term) {
                let idx = lower.distance(from: lower.startIndex, to: range.lowerBound)
                let start = max(0, idx - 40)
                let end = min(text.count, idx + term.count + 60)
                let startIdx = text.index(text.startIndex, offsetBy: start)
                let endIdx = text.index(text.startIndex, offsetBy: end)
                let prefix = start > 0 ? "..." : ""
                let suffix = end < text.count ? "..." : ""
                let snippet = text[startIdx..<endIdx].replacingOccurrences(of: "\n", with: " ")
                return "\(prefix)\(snippet)\(suffix)"
            }
        }
        return String(text.prefix(100))
    }

    private final class ResultBox: @unchecked Sendable {
        var results: [SearchResult] = []
    }
}
