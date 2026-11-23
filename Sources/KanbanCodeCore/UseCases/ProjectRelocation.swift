import Foundation

/// A project's folder moved (`~/dev/ava.golf` → `~/dev/avagolf.com`): the
/// project's path is its identity and every card names it in `projectPath`,
/// so all of them are rewritten together.
public enum ProjectRelocation {

    /// `path` after the move, when it is `oldPath` itself or lies under it;
    /// nil when the move does not touch it.
    public static func relocate(_ path: String, from oldPath: String, to newPath: String) -> String? {
        let old = trimmed(oldPath)
        let new = trimmed(newPath)
        guard old != new else { return nil }
        if path == old || path == old + "/" { return new }
        let prefix = old + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return new + "/" + path.dropFirst(prefix.count)
    }

    /// The project at its new path, every other setting kept.
    public static func relocate(_ project: Project, to newPath: String) -> Project {
        var moved = Project(
            path: trimmed(newPath),
            name: project.name,
            repoRoot: project.repoRoot.map { relocate($0, from: project.path, to: newPath) ?? $0 },
            visible: project.visible,
            githubFilter: project.githubFilter,
            promptTemplate: project.promptTemplate,
            githubIssuePromptTemplate: project.githubIssuePromptTemplate
        )
        moved.color = project.color
        return moved
    }

    /// The card with every path under the old project folder moved to the
    /// new one, or nil when the card has none.
    public static func relocate(_ link: Link, from oldPath: String, to newPath: String) -> Link? {
        var link = link
        var changed = false
        func move(_ path: String) -> String {
            guard let moved = relocate(path, from: oldPath, to: newPath) else { return path }
            changed = true
            return moved
        }
        if let path = link.projectPath { link.projectPath = move(path) }
        if let path = link.worktreeLink?.path { link.worktreeLink?.path = move(path) }
        if let repos = link.discoveredRepos { link.discoveredRepos = repos.mapValues(move) }
        if let repos = link.subagentBranches { link.subagentBranches = repos.mapValues(move) }
        return changed ? link : nil
    }

    /// Whether the card's Claude transcript is filed under the old project
    /// folder (`~/.claude/projects/-Users-me-dev-ava-golf/<id>.jsonl`), so a
    /// resume from the new folder would not find it until it moves.
    public static func transcriptNeedsMove(_ link: Link, from oldPath: String) -> Bool {
        guard let sessionPath = link.sessionLink?.sessionPath else { return false }
        let dir = ((sessionPath as NSString).deletingLastPathComponent as NSString).lastPathComponent
        return dir == claudeProjectDirName(trimmed(oldPath))
    }

    /// Claude Code's folder name for a project path, without resolving
    /// symlinks: the old folder is usually gone by now.
    static func claudeProjectDirName(_ path: String) -> String {
        path.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
    }

    private static func trimmed(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
