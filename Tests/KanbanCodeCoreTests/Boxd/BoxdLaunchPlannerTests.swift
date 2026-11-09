import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("BoxdLaunchPlanner")
struct BoxdLaunchPlannerTests {

    // MARK: - Machine name

    @Test("The machine name carries the repository and the first 8 of the card id")
    func machineName() {
        #expect(BoxdLaunchPlanner.machineName(repoName: "langwatch", cardId: "card_01ab2c3d4e5f") == "kanban-langwatch-01ab2c3d")
        #expect(BoxdLaunchPlanner.machineName(repoName: "langwatch", cardId: "01ab2c3d4e5f") == "kanban-langwatch-01ab2c3d")
    }

    @Test("The name only keeps lowercase letters, digits and dashes")
    func machineNameSanitised() {
        let name = BoxdLaunchPlanner.machineName(repoName: "LangWatch_SaaS.v2", cardId: "card_AB.cd/ef")
        #expect(name == "kanban-langwatch-saas-v2-ab-cd-ef")
        #expect(name.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "-" })
    }

    @Test("A long repository name is cut so the name stays inside the limit")
    func machineNameLength() {
        let name = BoxdLaunchPlanner.machineName(
            repoName: "a-very-long-repository-name-that-never-fits-anywhere",
            cardId: "card_0123456789"
        )
        #expect(name.count <= BoxdLaunchPlanner.maximumMachineNameLength)
        #expect(name.hasPrefix("kanban-a-very-long"))
        #expect(name.hasSuffix("-01234567"))
    }

    @Test("An empty repository name still gives a usable machine name")
    func machineNameEmptyRepo() {
        #expect(BoxdLaunchPlanner.machineName(repoName: "", cardId: "card_0123") == "kanban-repo-0123")
    }

    // MARK: - Repository name

    @Test("The repository name comes from the origin URL")
    func repoNameFromOrigin() {
        #expect(BoxdLaunchPlanner.repoName(fromOriginURL: "https://github.com/langwatch/kanban.git", fallbackFolder: "/tmp/x") == "kanban")
        #expect(BoxdLaunchPlanner.repoName(fromOriginURL: "git@github.com:langwatch/kanban.git", fallbackFolder: "/tmp/x") == "kanban")
        #expect(BoxdLaunchPlanner.repoName(fromOriginURL: "https://github.com/langwatch/kanban", fallbackFolder: "/tmp/x") == "kanban")
        #expect(BoxdLaunchPlanner.repoName(fromOriginURL: "ssh://git@github.com/langwatch/kanban.git", fallbackFolder: "/tmp/x") == "kanban")
    }

    @Test("Without an origin URL the folder name is used")
    func repoNameFallback() {
        #expect(BoxdLaunchPlanner.repoName(fromOriginURL: nil, fallbackFolder: "/Users/me/Projects/langwatch") == "langwatch")
        #expect(BoxdLaunchPlanner.repoName(fromOriginURL: "", fallbackFolder: "/Users/me/Projects/langwatch/") == "langwatch")
        #expect(BoxdLaunchPlanner.repoName(fromOriginURL: "not a url", fallbackFolder: "/Users/me/Projects/kanban") == "kanban")
    }

    @Test("A local path as origin falls back to the folder name")
    func repoNameLocalOrigin() {
        #expect(BoxdLaunchPlanner.repoName(fromOriginURL: "/srv/git/mirror.git", fallbackFolder: "/Users/me/mirror") == "mirror")
    }

    // MARK: - Templates

    @Test("Placeholders are expanded")
    func expand() {
        let result = BoxdLaunchPlanner.expand(
            template: "clone ${repo_url} into ${repo_dir} for ${repo_name}",
            values: ["repo_url": "u", "repo_dir": "d", "repo_name": "n"]
        )
        #expect(result == "clone u into d for n")
    }

    @Test("An unknown placeholder is left in place")
    func expandUnknown() {
        #expect(BoxdLaunchPlanner.expand(template: "${a}-${b}", values: ["a": "1"]) == "1-${b}")
    }

    @Test("Every occurrence of a placeholder is expanded")
    func expandRepeated() {
        #expect(BoxdLaunchPlanner.expand(template: "${a} ${a}", values: ["a": "x"]) == "x x")
    }

    @Test("The folder template resolves against the home of the machine")
    func remoteProjectPath() {
        #expect(
            BoxdLaunchPlanner.remoteProjectPath(folderTemplate: "~/${repo_name}", repoName: "langwatch", remoteHome: "/home/boxd")
                == "/home/boxd/langwatch"
        )
        #expect(
            BoxdLaunchPlanner.remoteProjectPath(folderTemplate: "~/code/${repo_name}/", repoName: "kanban", remoteHome: "/home/boxd/")
                == "/home/boxd/code/kanban"
        )
        #expect(
            BoxdLaunchPlanner.remoteProjectPath(folderTemplate: "/srv/${repo_name}", repoName: "kanban", remoteHome: "/home/boxd")
                == "/srv/kanban"
        )
        #expect(
            BoxdLaunchPlanner.remoteProjectPath(folderTemplate: "${repo_name}", repoName: "kanban", remoteHome: "/home/boxd")
                == "/home/boxd/kanban"
        )
        #expect(
            BoxdLaunchPlanner.remoteProjectPath(folderTemplate: "~", repoName: "kanban", remoteHome: "/home/boxd")
                == "/home/boxd"
        )
    }

    @Test("An empty folder template falls back to the repository name")
    func remoteProjectPathEmpty() {
        #expect(
            BoxdLaunchPlanner.remoteProjectPath(folderTemplate: "  ", repoName: "kanban", remoteHome: "/home/boxd")
                == "/home/boxd/kanban"
        )
    }

    @Test("The default init command is filled in with the card values")
    func initScript() {
        let script = BoxdLaunchPlanner.initScript(
            template: BoxdSettings.defaultInitCommand,
            repoDir: "/home/boxd/langwatch",
            repoURL: "git@github.com:langwatch/langwatch.git",
            repoName: "langwatch",
            branch: "feat/boxd"
        )
        #expect(script.contains(#"git -C "/home/boxd/langwatch" fetch --prune origin"#))
        #expect(script.contains(#"git clone "git@github.com:langwatch/langwatch.git" "/home/boxd/langwatch""#))
        #expect(!script.contains("${"))
    }

    @Test("The branch is available to a custom init command")
    func initScriptBranch() {
        let script = BoxdLaunchPlanner.initScript(
            template: "git checkout ${branch} # ${repo_name}",
            repoDir: "/d", repoURL: "u", repoName: "kanban", branch: "main"
        )
        #expect(script == "git checkout main # kanban")
    }

    // MARK: - Mappings

    @Test("Mappings come in the project, kanban home, home order")
    func mappings() {
        let mappings = BoxdLaunchPlanner.mappings(
            localProjectPath: "/Users/me/Projects/langwatch",
            remoteProjectPath: "/home/boxd/langwatch",
            localHome: "/Users/me",
            remoteHome: "/home/boxd",
            localKanbanHome: "/Users/me/.kanban-code",
            remoteKanbanHome: "/home/boxd/.kanban-code"
        )
        #expect(mappings.count == 3)
        #expect(mappings[0] == PathMapping(from: "/home/boxd/langwatch", to: "/Users/me/Projects/langwatch"))
        #expect(mappings[1] == PathMapping(from: "/home/boxd/.kanban-code", to: "/Users/me/.kanban-code"))
        #expect(mappings[2] == PathMapping(from: "/home/boxd", to: "/Users/me"))
    }

    @Test("The mappings drive the transcript rewriter")
    func mappingsFeedRewriter() {
        let rewriter = TranscriptPathRewriter(BoxdLaunchPlanner.mappings(
            localProjectPath: "/Users/me/Projects/langwatch",
            remoteProjectPath: "/home/boxd/langwatch",
            localHome: "/Users/me",
            remoteHome: "/home/boxd",
            localKanbanHome: "/Users/me/.kanban-code",
            remoteKanbanHome: "/home/boxd/.kanban-code"
        ))
        #expect(rewriter.mapPath("/home/boxd/langwatch/.claude/worktrees/a") == "/Users/me/Projects/langwatch/.claude/worktrees/a")
        #expect(rewriter.mapPath("/home/boxd/.kanban-code/hook-events.jsonl") == "/Users/me/.kanban-code/hook-events.jsonl")
        #expect(rewriter.mapPath("/home/boxd/other") == "/Users/me/other")
    }

    // MARK: - Glob matching

    @Test("**/ matches zero or more directories")
    func globAnyDepth() {
        #expect(BoxdLaunchPlanner.matches(glob: "**/.env", path: ".env"))
        #expect(BoxdLaunchPlanner.matches(glob: "**/.env", path: "platform/app/.env"))
        #expect(!BoxdLaunchPlanner.matches(glob: "**/.env", path: "platform/app/.env.local"))
        #expect(!BoxdLaunchPlanner.matches(glob: "**/.env", path: "env"))
    }

    @Test("* stays inside one segment")
    func globSingleSegment() {
        #expect(BoxdLaunchPlanner.matches(glob: "*.env", path: "prod.env"))
        #expect(!BoxdLaunchPlanner.matches(glob: "*.env", path: "config/prod.env"))
        #expect(BoxdLaunchPlanner.matches(glob: "config/*.yaml", path: "config/app.yaml"))
        #expect(!BoxdLaunchPlanner.matches(glob: "config/*.yaml", path: "config/nested/app.yaml"))
        #expect(BoxdLaunchPlanner.matches(glob: "**/*.env", path: "a/b/prod.env"))
    }

    @Test("? matches exactly one character")
    func globSingleCharacter() {
        #expect(BoxdLaunchPlanner.matches(glob: ".env.?", path: ".env.a"))
        #expect(!BoxdLaunchPlanner.matches(glob: ".env.?", path: ".env.ab"))
    }

    @Test("An exact path matches itself")
    func globExact() {
        #expect(BoxdLaunchPlanner.matches(glob: "apps/web/.env", path: "apps/web/.env"))
        #expect(BoxdLaunchPlanner.matches(glob: "./apps/web/.env", path: "apps/web/.env"))
        #expect(!BoxdLaunchPlanner.matches(glob: "apps/web/.env", path: "apps/api/.env"))
    }

    // MARK: - Files to copy

    @Test("copyMatches walks the project and skips .git and node_modules")
    func copyMatches() async throws {
        let root = NSTemporaryDirectory() + "kanban-copy-\(UUID().uuidString)"
        let fileManager = FileManager.default
        defer { try? fileManager.removeItem(atPath: root) }

        for directory in ["", "platform/app", "node_modules/pkg", ".git", "config"] {
            try fileManager.createDirectory(atPath: (root as NSString).appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        for file in [".env", "platform/app/.env", "node_modules/pkg/.env", ".git/.env", "config/app.yaml", "README.md"] {
            try "x".write(toFile: (root as NSString).appendingPathComponent(file), atomically: true, encoding: .utf8)
        }

        let matched = await BoxdLaunchPlanner.copyMatches(globs: ["**/.env"], projectRoot: root)
        #expect(matched == [".env", "platform/app/.env"])

        let several = await BoxdLaunchPlanner.copyMatches(globs: ["**/.env", "config/*.yaml"], projectRoot: root)
        #expect(several == [".env", "config/app.yaml", "platform/app/.env"])
    }

    @Test("Blank and commented glob lines are ignored")
    func copyMatchesEmptyGlobs() async throws {
        let root = NSTemporaryDirectory() + "kanban-copy-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try "x".write(toFile: (root as NSString).appendingPathComponent(".env"), atomically: true, encoding: .utf8)

        #expect(await BoxdLaunchPlanner.copyMatches(globs: [], projectRoot: root).isEmpty)
        #expect(await BoxdLaunchPlanner.copyMatches(globs: ["  ", "# a comment"], projectRoot: root).isEmpty)
    }

    @Test("A project root that does not exist matches nothing")
    func copyMatchesMissingRoot() async {
        #expect(await BoxdLaunchPlanner.copyMatches(globs: ["**/.env"], projectRoot: "/nowhere/at/all").isEmpty)
    }

    @Test("In a repository the candidates come from git: ignored and untracked files, not tracked ones or ignored folders")
    func copyMatchesUsesGit() async throws {
        let root = NSTemporaryDirectory() + "kanban-copy-git-\(UUID().uuidString)"
        let fileManager = FileManager.default
        defer { try? fileManager.removeItem(atPath: root) }
        for directory in ["", "app", "node_modules/pkg", "fresh/sub"] {
            try fileManager.createDirectory(atPath: (root as NSString).appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        for file in [".env", "app/.env", "node_modules/pkg/.env", "fresh/sub/.env", "fresh/note.txt", "tracked.env", ".gitignore"] {
            try "x".write(toFile: (root as NSString).appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        try ".env\nnode_modules/\n".write(toFile: root + "/.gitignore", atomically: true, encoding: .utf8)
        for arguments in [["init", "-q"], ["add", "tracked.env", ".gitignore"], ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "x"]] {
            let result = try await ShellCommand.run("/usr/bin/git", arguments: ["-C", root] + arguments)
            #expect(result.succeeded, "git \(arguments) failed: \(result.stderr)")
        }

        let candidates = await BoxdLaunchPlanner.gitUntrackedAndIgnored(root: root)
        // An untracked folder is walked, an ignored one is not.
        #expect(candidates?.sorted() == [".env", "app/.env", "fresh/note.txt", "fresh/sub/.env"])
        let matched = await BoxdLaunchPlanner.copyMatches(globs: ["**/*.env", "**/.env"], projectRoot: root)
        #expect(matched == [".env", "app/.env", "fresh/sub/.env"])
    }

    // MARK: - Managed machine names

    @Test("Only kanban- machines with a plain name count as managed")
    func managedMachineName() {
        #expect(BoxdLaunchPlanner.isManagedMachineName("kanban-langwatch-3icygdab"))
        #expect(BoxdLaunchPlanner.isManagedMachineName(BoxdLaunchPlanner.machineName(repoName: "kanban-code", cardId: "card_e2e1234567")))
        #expect(!BoxdLaunchPlanner.isManagedMachineName("good-wolf"))
        #expect(!BoxdLaunchPlanner.isManagedMachineName("kanban-"))
        #expect(!BoxdLaunchPlanner.isManagedMachineName("kanban-with space"))
        #expect(!BoxdLaunchPlanner.isManagedMachineName(""))
    }

    // MARK: - Worktree name

    @Test("An unnamed worktree gets a name that is one branch-safe path component")
    func randomWorktreeNameShape() {
        let names = (0..<20).map { _ in BoxdLaunchPlanner.randomWorktreeName() }
        for name in names {
            #expect(!name.isEmpty)
            #expect(!name.contains("/"))
            #expect(name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
        }
        #expect(Set(names).count > 1)
    }

    // MARK: - Resume decision

    @Test("A live tmux session is only attached to")
    func resumeAttaches() {
        #expect(BoxdLaunchPlanner.resumeDecision(tmuxAlive: true, localTranscriptLines: 10, remoteTranscriptLines: 0) == .attach)
        #expect(BoxdLaunchPlanner.resumeDecision(tmuxAlive: true, localTranscriptLines: 0, remoteTranscriptLines: 99) == .attach)
    }

    @Test("A local transcript with more lines is pushed first")
    func resumePushes() {
        #expect(BoxdLaunchPlanner.resumeDecision(tmuxAlive: false, localTranscriptLines: 200, remoteTranscriptLines: 100) == .pushThenResume)
    }

    @Test("A machine with the same lines resumes as it is, whatever the byte sizes")
    func resumePlain() {
        #expect(BoxdLaunchPlanner.resumeDecision(tmuxAlive: false, localTranscriptLines: 100, remoteTranscriptLines: 100) == .resume)
        #expect(BoxdLaunchPlanner.resumeDecision(tmuxAlive: false, localTranscriptLines: 0, remoteTranscriptLines: 100) == .resume)
    }

    @Test("The prefix of a transcript hashes exactly its first lines")
    func transcriptPrefix() throws {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("kanban-prefix-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(atPath: path) }
        try "{\"a\":1}\n{\"b\":2}\n{\"c\":3}\n".write(toFile: path, atomically: true, encoding: .utf8)

        let prefix = BoxdLaunchPlanner.transcriptPrefix(fileAt: path, lineCount: 2)

        // The bytes of the first two lines, and the digest `sha256sum` gives
        // for them on the machine.
        #expect(prefix?.bytes == 16)
        #expect(prefix?.sha256 == "3881dc2ee848fe04d776737c86afbc783e482e7c5be6431d3aab36fa8fa2c928")
        #expect(BoxdLaunchPlanner.transcriptPrefix(fileAt: path, lineCount: 9) == nil)
        #expect(BoxdLaunchPlanner.transcriptPrefix(fileAt: path, lineCount: 0) == nil)
    }

    @Test("The line count reads the file in blocks and counts newlines")
    func lineCount() throws {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("kanban-lines-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(atPath: path) }
        try "{}\n{}\n{\"partial\":true}".write(toFile: path, atomically: true, encoding: .utf8)

        #expect(BoxdLaunchPlanner.lineCount(ofFileAt: path) == 2)
        #expect(BoxdLaunchPlanner.lineCount(ofFileAt: path + ".missing") == 0)
    }

    @Test("The watchdog parks on stale transcripts and spares attached terminals")
    func watchdogScript() {
        let script = BoxdLaunchPlanner.watchdogScript(remoteHome: "/home/boxd", idleSeconds: 1800)

        #expect(script.contains("IDLE=1800"))
        #expect(script.contains("/home/boxd/.claude/projects"))
        #expect(script.contains("/home/boxd/.codex/sessions"))
        #expect(script.contains("hook-events.jsonl"))
        #expect(script.contains("watchdog-grace"))
        #expect(script.contains("tmux list-clients"))
        #expect(script.contains("tmux kill-server"))
        #expect(script.contains("auto-suspend.timeout 60"))
        #expect(script.contains("auto-hibernate.timeout 300"))
        // A parked tick must make zero traffic, or its own calls keep the
        // machine awake after a stray wake.
        #expect(script.contains("[ -f \"$KC/watchdog-parked\" ] && exit 0"))
        #expect(script.contains("touch \"$KC/watchdog-parked\""))
    }

    @Test("The watchdog installer restores the timers and wires the cron tick")
    func watchdogStartScript() {
        let script = BoxdLaunchPlanner.watchdogStartScript(remoteHome: "/home/boxd", idleSeconds: 2400)

        #expect(script.contains("touch \"$KC/watchdog-grace\""))
        #expect(script.contains("rm -f \"$KC/watchdog-parked\""))
        #expect(script.contains("auto-suspend.timeout 2400"))
        #expect(script.contains("auto-hibernate.timeout 14400"))
        #expect(script.contains("IDLE=2400"))
        #expect(script.contains("| crontab -"))
        #expect(script.contains("*/5 * * * * /bin/sh $KC/kanban-watchdog.sh"))
        // The heredoc terminator has to sit alone at line start.
        #expect(script.contains("\nKANBAN_WATCHDOG\n"))
    }

    @Test("Both watchdog scripts parse under sh")
    func watchdogScriptsParse() throws {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("kanban-watchdog-gen")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let files = [
            (dir + "/install.sh", BoxdLaunchPlanner.watchdogStartScript(remoteHome: "/home/boxd", idleSeconds: 1800)),
            (dir + "/check.sh", BoxdLaunchPlanner.watchdogScript(remoteHome: "/home/boxd", idleSeconds: 1800)),
        ]
        for (path, script) in files {
            try script.write(toFile: path, atomically: true, encoding: .utf8)
            let sh = Process()
            sh.executableURL = URL(fileURLWithPath: "/bin/sh")
            sh.arguments = ["-n", path]
            try sh.run()
            sh.waitUntilExit()
            #expect(sh.terminationStatus == 0, "sh -n failed for \(path)")
        }
    }

    @Test("A folder on the machine maps to its mirror here")
    func localPathOfRemote() {
        #expect(BoxdLaunchPlanner.localPath(ofRemote: "/root/Projects/app", remoteRoot: "/root/Projects/app", localRoot: "/Users/me/app") == "/Users/me/app")
        #expect(BoxdLaunchPlanner.localPath(ofRemote: "/root/Projects/app/.claude/worktrees/x", remoteRoot: "/root/Projects/app/", localRoot: "/Users/me/app") == "/Users/me/app/.claude/worktrees/x")
        #expect(BoxdLaunchPlanner.localPath(ofRemote: "/root/Projects/apple", remoteRoot: "/root/Projects/app", localRoot: "/Users/me/app") == "/root/Projects/apple")
    }
}
