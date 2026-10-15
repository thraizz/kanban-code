import Foundation

/// Where a card's worktree lives, which is where git commands on it must run.
public enum WorktreePlacement: Equatable, Sendable {
    /// On this master's disk.
    case local
    /// Another master owns the card; that master runs the command.
    case ownerMaster(machineId: String)
    /// This master runs the card on an always-on ssh machine; the command
    /// goes over ssh to it.
    case sshMachine(name: String)
    /// The card runs on a boxd machine of its own: the worktree goes away
    /// with the machine, nothing to clean up.
    case disposableMachine(name: String)

    /// Decides where the worktree of `link` is, as seen by the master whose
    /// id is `localMachineId`. An owner other than this master wins over
    /// anything else: the owner decides where it runs the card.
    public static func of(link: Link, localMachineId: String, boxdSettings: BoxdSettings?) -> WorktreePlacement {
        if let owner = link.ownerMachine, !localMachineId.isEmpty, owner != localMachineId {
            return .ownerMaster(machineId: owner)
        }
        if let remote = link.remote, remote.mode == .boxd {
            if boxdSettings?.sshMachine(named: remote.machineName) != nil {
                return .sshMachine(name: remote.machineName)
            }
            return .disposableMachine(name: remote.machineName)
        }
        return .local
    }

    /// Whether the app offers to remove the worktree.
    public var offersCleanup: Bool {
        if case .disposableMachine = self { return false }
        return true
    }

    /// The worktree and repository paths on an ssh machine. The link keeps
    /// the local shape of the worktree path; on the machine it sits under
    /// the machine's checkout of the project.
    public static func remotePaths(of link: Link) -> (worktree: String, repoRoot: String)? {
        guard let local = link.worktreeLink?.path, !local.isEmpty, let remote = link.remote else { return nil }
        let name = (local as NSString).lastPathComponent
        if let repo = remote.remoteProjectPath, !repo.isEmpty {
            return ("\(repo)/.claude/worktrees/\(name)", repo)
        }
        if let cwd = remote.remoteCwd, let range = cwd.range(of: "/.claude/worktrees/") {
            return (cwd, String(cwd[..<range.lowerBound]))
        }
        return nil
    }

    /// The shell command that removes a worktree on another machine.
    public static func removeCommand(worktree: String, repoRoot: String) -> String {
        let git = "git -C \(shellQuote(repoRoot)) worktree remove"
        let path = shellQuote(worktree)
        // A session killed a moment ago still holds its lock (claude locks
        // with its own pid). Wait for that pid to exit, then override the
        // stale lock with a second force.
        return """
        out=$(\(git) --force \(path) 2>&1) && exit 0; \
        pid=$(printf '%s' "$out" | sed -n 's/.*locked working tree.*(pid \\([0-9][0-9]*\\).*/\\1/p' | head -n1); \
        if [ -n "$pid" ]; then \
        i=0; while kill -0 "$pid" 2>/dev/null && [ $i -lt 60 ]; do sleep 0.25; i=$((i+1)); done; \
        kill -0 "$pid" 2>/dev/null || { \(git) --force --force \(path) 2>&1 && exit 0; exit 1; }; \
        fi; printf '%s\\n' "$out" >&2; exit 1
        """
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

extension AppState {
    /// Where the worktree of a card lives, for this master.
    public func worktreePlacement(_ cardId: String) -> WorktreePlacement? {
        guard let link = links[cardId] else { return nil }
        return WorktreePlacement.of(link: link, localMachineId: localMachineId, boxdSettings: boxdSettings)
    }
}
