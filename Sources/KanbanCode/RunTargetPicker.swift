import SwiftUI
import KanbanCodeCore

/// The "Run on" row of the launch dialogs in the ssh and boxd modes: this
/// Mac, then the machines of the mode (see `RunTargetOption.options`).
struct RunTargetPicker: View {
    let remote: RemoteLaunchOptions
    @Binding var runRemotely: Bool
    @Binding var machineChoice: BoxdMachineChoice
    @State private var reachability: [String: Bool] = [:]

    var body: some View { usageTrackedBody.trackUsage("view", "RunTargetPicker") }

    @ViewBuilder private var usageTrackedBody: some View {
        Picker("Run on", selection: selection) {
            ForEach(RunTargetOption.options(for: remote, reachability: reachability)) { option in
                Text(option.label).tag(option.target)
            }
        }
        .font(.app(.callout))
        .task(id: remote.sshMachines) {
            await probe()
        }
        if runRemotely, let name = machineChoice.machineName,
           remote.masterMachines.contains(where: { $0.name == name }) {
            Label("\(name) runs Kanban Code itself: the card moves there and keeps going while this Mac is off.",
                  systemImage: "info.circle")
                .font(.app(.caption2))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 20)
        }
    }

    private var selection: Binding<RunTarget> {
        Binding(
            get: { runRemotely ? .machine(machineChoice) : .mac },
            set: { target in
                switch target {
                case .mac:
                    runRemotely = false
                case .machine(let choice):
                    machineChoice = choice
                    runRemotely = true
                }
            }
        )
    }

    private func probe() async {
        guard remote.mode == .ssh else { return }
        await withTaskGroup(of: (String, Bool).self) { group in
            for machine in remote.sshMachines where !remote.masterMachines.contains(where: { $0.name == machine.name }) {
                group.addTask { (machine.name, await SshHostPort.isReachable(target: machine.target)) }
            }
            for await (name, reachable) in group {
                reachability[name] = reachable
            }
        }
    }
}
