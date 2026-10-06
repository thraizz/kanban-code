import Foundation
import Testing

@testable import KanbanCodeCore

@Suite("Where a card's worktree lives")
struct WorktreePlacementTests {
    let ssh = BoxdSettings(sshMachines: [SshMachine(name: "box", target: "root@box")])

    private func link(owner: String? = nil, remote: RemoteLink? = nil) -> Link {
        var link = Link(id: "card_1", projectPath: "/Users/me/Projects/acme",
                        worktreeLink: WorktreeLink(path: "/Users/me/Projects/acme/.claude/worktrees/fix-bug", branch: "fix-bug"))
        link.ownerMachine = owner
        link.remote = remote
        return link
    }

    @Test("a card this master owns and runs here is local")
    func local() {
        #expect(WorktreePlacement.of(link: link(), localMachineId: "mac", boxdSettings: ssh) == .local)
        #expect(WorktreePlacement.of(link: link(owner: "mac"), localMachineId: "mac", boxdSettings: ssh) == .local)
        // Before the identity loads every card reads as this master's.
        #expect(WorktreePlacement.of(link: link(owner: "box-id"), localMachineId: "", boxdSettings: nil) == .local)
    }

    @Test("a card another master owns goes to that master, wherever it runs")
    func ownerMaster() {
        #expect(WorktreePlacement.of(link: link(owner: "box-id"), localMachineId: "mac", boxdSettings: nil)
            == .ownerMaster(machineId: "box-id"))
        let onSsh = link(owner: "box-id", remote: RemoteLink(mode: .boxd, machineName: "box"))
        #expect(WorktreePlacement.of(link: onSsh, localMachineId: "mac", boxdSettings: ssh) == .ownerMaster(machineId: "box-id"))
    }

    @Test("a card this master runs on an ssh machine runs git there")
    func sshMachine() {
        let card = link(owner: "mac", remote: RemoteLink(mode: .boxd, machineName: "box", remoteProjectPath: "/root/Projects/acme"))
        let placement = WorktreePlacement.of(link: card, localMachineId: "mac", boxdSettings: ssh)
        #expect(placement == .sshMachine(name: "box"))
        #expect(placement.offersCleanup)
        let paths = WorktreePlacement.remotePaths(of: card)
        #expect(paths?.worktree == "/root/Projects/acme/.claude/worktrees/fix-bug")
        #expect(paths?.repoRoot == "/root/Projects/acme")
        #expect(WorktreePlacement.removeCommand(worktree: "/r/it's", repoRoot: "/r")
            == "git -C '/r' worktree remove --force '/r/it'\\''s'")
    }

    @Test("a card on its own boxd machine offers no cleanup")
    func disposable() {
        let card = link(remote: RemoteLink(mode: .boxd, machineName: "kanban-acme-1234"))
        let placement = WorktreePlacement.of(link: card, localMachineId: "mac", boxdSettings: ssh)
        #expect(placement == .disposableMachine(name: "kanban-acme-1234"))
        #expect(!placement.offersCleanup)
    }

    @Test("a mutagen card keeps the local flow")
    func mutagen() {
        let card = link(remote: RemoteLink(mode: .mutagen, machineName: "host"))
        #expect(WorktreePlacement.of(link: card, localMachineId: "mac", boxdSettings: ssh) == .local)
    }
}
