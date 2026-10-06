import Foundation
import KanbanCodeRemoteKit
import Testing

@testable import KanbanCodeCore

@Suite("The machines a remote task can run on")
struct RemoteMachinesTests {
    @Test("this master comes first, then the other masters and the plain ssh machines")
    func listing() {
        let state = AppState()
        state.localMachineId = "machine_box"
        state.localMachineName = "rchaves-platform"
        state.localMachineAlwaysOn = true
        state.boxdSettings = BoxdSettings(sshMachines: [SshMachine(name: "gpu", target: "root@10.0.0.9")])
        state.peerStatuses["peer_mac"] = PeerStatus(
            peerId: "peer_mac", machine: MachineIdentity(id: "machine_mac", name: "studio"), online: false,
            url: "http://10.0.0.20:7780")
        #expect(state.remoteMachines == [
            RemoteMachineEntry(id: "machine_box", name: "rchaves-platform", kind: .this, online: true, alwaysOn: true),
            RemoteMachineEntry(name: "gpu", kind: .ssh),
            RemoteMachineEntry(id: "machine_mac", name: "studio", kind: .master, online: false),
        ])
    }

    @Test("GET /v1/machines answers the host's list to an agent token")
    func route() async throws {
        let f = try await RemoteServerFixture()
        defer { f.shutdown() }
        let (status, data) = try await f.request("GET", "/v1/machines", token: f.agentToken)
        #expect(status == 200)
        let list = try JSONDecoder.remote.decode(RemoteMachineList.self, from: data)
        #expect(list.machines.map(\.name) == ["rchaves-platform", "studio"])
        #expect(list.machines.first?.kind == .this)
    }
}
