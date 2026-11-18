import Foundation

/// Decides which branches and PR numbers a GitHub refresh pass looks up.
///
/// The board carries hundreds of finished cards whose pull requests can never
/// change again, and looking them all up made one refresh pass take minutes
/// across a hundred repos. The scope keeps the pass to what can still move:
/// branch discovery for cards on the board, and status refresh for pull
/// requests not in a final state.
public enum PRRefreshScope {
    public struct Scope: Equatable, Sendable {
        public var branchesByRepo: [String: Set<String>]
        /// Pull requests with no URL to say where they live. The card's own
        /// repository is the only guess available for those.
        public var prNumbersByRepo: [String: Set<Int>]
        /// Pull requests routed by the repository their URL names, keyed
        /// "host/owner/name". Keeps a card's pull request in a sibling
        /// repository out of a lookup against the card's own repository.
        public var prNumbersByRepoKey: [String: Set<Int>]
        /// Repository key → a local checkout to run `gh` from. Any checkout
        /// works: the query names the repository itself.
        public var lookupDirForRepoKey: [String: String]

        public init(
            branchesByRepo: [String: Set<String>] = [:],
            prNumbersByRepo: [String: Set<Int>] = [:],
            prNumbersByRepoKey: [String: Set<Int>] = [:],
            lookupDirForRepoKey: [String: String] = [:]
        ) {
            self.branchesByRepo = branchesByRepo
            self.prNumbersByRepo = prNumbersByRepo
            self.prNumbersByRepoKey = prNumbersByRepoKey
            self.lookupDirForRepoKey = lookupDirForRepoKey
        }
    }

    /// Columns whose cards still get branch → PR discovery. Backlog cards have
    /// no PRs yet and archived cards get no new ones.
    private static let activeColumns: Set<KanbanCodeColumn> = [
        .inProgress, .waiting, .inReview, .done,
    ]

    public static func collect(links: [Link]) -> Scope {
        var scope = Scope()
        for link in links {
            guard let repoRoot = link.projectPath, !repoRoot.isEmpty else { continue }
            let isActive = activeColumns.contains(link.column)

            if isActive {
                if let branch = link.worktreeLink?.branch {
                    scope.branchesByRepo[repoRoot, default: []].insert(branch)
                }
                if let discovered = link.discoveredBranches {
                    for branch in discovered {
                        // discoveredRepos routes branches pushed to another repo
                        let effectiveRepo = link.discoveredRepos?[branch] ?? repoRoot
                        scope.branchesByRepo[effectiveRepo, default: []].insert(branch)
                    }
                }
                for (branch, repo) in link.subagentBranches ?? [:] {
                    scope.branchesByRepo[repo.isEmpty ? repoRoot : repo, default: []].insert(branch)
                }
            }

            for pr in link.prLinks {
                // Merged is final. Closed can in principle reopen, but not on
                // a card already off the board.
                if pr.status == .merged { continue }
                if !isActive && pr.status == .closed { continue }
                if let repoKey = pr.repoKey {
                    scope.prNumbersByRepoKey[repoKey, default: []].insert(pr.number)
                    if scope.lookupDirForRepoKey[repoKey] == nil {
                        scope.lookupDirForRepoKey[repoKey] = repoRoot
                    }
                } else {
                    scope.prNumbersByRepo[repoRoot, default: []].insert(pr.number)
                }
            }
        }
        return scope
    }
}
