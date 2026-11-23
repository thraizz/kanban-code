import Foundation

/// One-shot, idempotent bootstrap: ensures the repo's global skills
/// (`kanban-code`, `transfer-to-kanban`) are symlinked into
/// `~/.claude/skills/<name>` so newly-launched Claude sessions pick them up.
///
/// Called on app launch. Side-effects are all best-effort — failures are logged,
/// not fatal.
public enum ChatBootstrap {

    /// The skills in the repo's `.claude/skills` that every Claude session
    /// gets, not only those started in this repo.
    static let globalSkills = ["kanban-code", "transfer-to-kanban"]

    public static func run(repoRoot: String? = nil) {
        for name in globalSkills {
            ensureSkillSymlink(name: name, repoRoot: repoRoot)
        }
    }

    private static func ensureSkillSymlink(name: String, repoRoot: String?) {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let skillsDir = (home as NSString).appendingPathComponent(".claude/skills")
        let link = (skillsDir as NSString).appendingPathComponent(name)

        // If the link already resolves to a readable SKILL.md we're done.
        if fm.fileExists(atPath: (link as NSString).appendingPathComponent("SKILL.md")) {
            return
        }

        // Find source. Priority:
        //   1. Explicit argument.
        //   2. Env var KANBAN_CODE_REPO.
        //   3. Walk up from bundle path looking for Package.swift.
        let src = locateRepoRoot(override: repoRoot)
            .map { (($0 as NSString).appendingPathComponent(".claude/skills/\(name)")) }

        guard let src, fm.fileExists(atPath: src) else {
            KanbanCodeLog.info("bootstrap", "\(name) skill source not found; skipping symlink")
            return
        }

        do {
            try fm.createDirectory(atPath: skillsDir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: link) {
                try fm.removeItem(atPath: link)
            }
            try fm.createSymbolicLink(atPath: link, withDestinationPath: src)
            KanbanCodeLog.info("bootstrap", "Linked \(name) skill → \(src)")
        } catch {
            KanbanCodeLog.warn("bootstrap", "ensureSkillSymlink failed: \(error)")
        }
    }

    private static func locateRepoRoot(override: String?) -> String? {
        if let override, FileManager.default.fileExists(atPath: override) {
            return override
        }
        if let env = ProcessInfo.processInfo.environment["KANBAN_CODE_REPO"],
           FileManager.default.fileExists(atPath: env) {
            return env
        }
        // Walk up from the app bundle looking for Package.swift.
        var path = Bundle.main.bundlePath
        for _ in 0..<8 {
            let candidate = (path as NSString).appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: candidate) { return path }
            let parent = (path as NSString).deletingLastPathComponent
            if parent == path { break }
            path = parent
        }
        // Fallback: check ~/Projects/kanban (common location — CLAUDE.md references it)
        let fallback = (NSHomeDirectory() as NSString).appendingPathComponent("Projects/kanban")
        if FileManager.default.fileExists(atPath: (fallback as NSString).appendingPathComponent("Package.swift")) {
            return fallback
        }
        return nil
    }
}
