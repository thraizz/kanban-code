import Foundation

/// Full-text search over session files by their parsed conversation turns.
///
/// For stores without a cheaper index of their own: each file is read into
/// turns, and results stream back ranked by BM25 after every file.
public enum TranscriptSearch {
    private static let maxSnippets = 3

    public static func searchStreaming(
        query: String,
        paths: [String],
        assistantLabel: String,
        readTurns: @Sendable (String) async throws -> [ConversationTurn],
        onResult: @MainActor @Sendable ([SearchResult]) -> Void
    ) async throws {
        let searchQuery = SessionSearchQuery(query)
        guard !searchQuery.isEmpty else { return }

        struct DocInfo {
            let path: String
            let matchingTokens: [String]
            let exactMatches: Int
            let wordCount: Int
            let snippets: [String]
            let modifiedTime: Date
        }

        let fileManager = FileManager.default
        let validPaths: [(String, Date)] = paths.compactMap { path in
            guard fileManager.fileExists(atPath: path),
                  let attrs = try? fileManager.attributesOfItem(atPath: path),
                  let mtime = attrs[.modificationDate] as? Date else { return nil }
            return (path, mtime)
        }

        var docs: [DocInfo] = []
        var globalTermFreqs: [String: Int] = [:]
        var totalWordCount = 0

        for (path, mtime) in validPaths {
            try Task.checkCancellation()
            let (tokens, exactMatches, wordCount, snippets) = matchingTokens(
                in: try await readTurns(path),
                query: searchQuery,
                assistantLabel: assistantLabel
            )
            guard wordCount > 0 else { continue }
            totalWordCount += wordCount
            guard !tokens.isEmpty || exactMatches > 0 else { continue }
            if searchQuery.requiresExactMatch, exactMatches == 0 { continue }

            for term in Set(tokens) {
                globalTermFreqs[term, default: 0] += 1
            }

            docs.append(DocInfo(
                path: path,
                matchingTokens: tokens,
                exactMatches: exactMatches,
                wordCount: wordCount,
                snippets: snippets,
                modifiedTime: mtime
            ))

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
                let score = searchQuery.score(
                    termsScore: termsScore,
                    exactMatches: doc.exactMatches,
                    modifiedTime: doc.modifiedTime
                )
                if score > 0 {
                    results.append(SearchResult(sessionPath: doc.path, score: score, snippets: doc.snippets))
                }
            }
            results.sort { $0.score > $1.score }
            await onResult(results)
        }
    }

    private static func matchingTokens(
        in turns: [ConversationTurn],
        query: SessionSearchQuery,
        assistantLabel: String
    ) -> (tokens: [String], exactMatches: Int, wordCount: Int, snippets: [String]) {
        var matchingTokens: [String] = []
        var exactMatches = 0
        var wordCount = 0
        var topSnippets: [(score: Int, text: String)] = []

        for turn in turns {
            let text = ([turn.textPreview] + turn.contentBlocks.map(\.text))
                .filter { !$0.isEmpty && $0 != "(empty)" }
                .joined(separator: "\n")
            guard !text.isEmpty else { continue }

            let docTokens = BM25Scorer.tokenize(text)
            wordCount += docTokens.count
            for token in docTokens {
                if let matched = query.matchToken(token) {
                    matchingTokens.append(matched)
                }
            }

            let lower = text.lowercased()
            exactMatches += query.exactMatchCount(in: lower)
            let snippetScore = query.snippetScore(in: lower)
            if snippetScore > 0 {
                let label = turn.role == "user" ? "You" : assistantLabel
                let snippet = extractSnippet(from: text, queryTerms: query.snippetTerms, label: label)
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

    private static func extractSnippet(from text: String, queryTerms: [String], label: String) -> String {
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
                return "\(label): \(prefix)\(snippet)\(suffix)"
            }
        }
        return String(text.prefix(100))
    }
}
