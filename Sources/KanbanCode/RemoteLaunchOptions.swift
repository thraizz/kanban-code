import Foundation
import KanbanCodeCore

/// What the launch dialogs need to offer the "run remotely" row.
struct RemoteLaunchOptions {
    var mode: RemoteMode
    /// Mutagen settings, when that mode is configured.
    var mutagen: RemoteSettings?
    /// Boxd settings, when that mode is active.
    var boxd: BoxdSettings?
    /// Machine the card already has.
    var cardMachine: String?
    /// The peer master that owns the card (or takes it over), by the name
    /// the machine choices give it. A resume runs there unless another
    /// place is picked, which moves the card.
    var ownerMachine: String?
    var cardMachineState: RemoteMachineState?
    /// Where the last session of the card ran, when it ran at all. A card
    /// that was moved to the Mac must not offer its machine again by
    /// itself: the choice of the last run is the one that is offered.
    var lastRunRemote: Bool?
    /// Other machines in the org the user may pick.
    var availableMachines: [String] = []
    /// True when the boxd CLI is installed.
    var boxdAvailable: Bool = true
    /// The ssh machines and peer masters, one entry per machine
    /// (`AppState.machineChoices`).
    var machines: [MachineChoice] = []

    /// Machines that run a master of their own.
    var masterMachines: [MachineChoice] { machines.filter { $0.master != nil } }

    /// `machines`, plus the complete ssh machines it does not list yet.
    var allMachines: [MachineChoice] {
        var out = machines
        for ssh in sshMachines where !out.contains(where: { $0.name == ssh.name }) {
            out.append(MachineChoice(name: ssh.name, sshMachine: ssh))
        }
        return out
    }

    /// Always-on machines reached over ssh.
    var sshMachines: [SshMachine] {
        (boxd?.sshMachines ?? []).filter(\.isComplete)
    }

    /// Whether a project path can run remotely at all in the active mode.
    func canRunRemotely(projectPath: String?) -> Bool {
        switch mode {
        case .ssh:
            return boxd != nil && (!sshMachines.isEmpty || cardMachine != nil || !masterMachines.isEmpty)
        case .boxd:
            return boxd != nil && (boxdAvailable || cardMachine != nil || !masterMachines.isEmpty)
        case .mutagen:
            guard let mutagen, let projectPath else { return false }
            return projectPath.hasPrefix(mutagen.localPath)
        }
    }

    /// Per-project default of the "run remotely" toggle. The ssh and boxd
    /// modes share it: both run the card on a machine.
    static func defaultRunRemotely(mode: RemoteMode, projectPath: String) -> Bool {
        switch mode {
        case .ssh, .boxd:
            return UserDefaults.standard.object(forKey: "runOnBoxd_\(projectPath)") as? Bool ?? false
        case .mutagen:
            return UserDefaults.standard.object(forKey: "runRemotely_\(projectPath)") as? Bool ?? true
        }
    }

    /// State of the "run remotely" box when a dialog opens. The last run of
    /// the card wins, then the machine of the card, then the project.
    static func initialRunRemotely(
        lastRunRemote: Bool?, cardMachine: String?, ownerMachine: String? = nil, mode: RemoteMode, projectPath: String
    ) -> Bool {
        if ownerMachine != nil { return true }
        if let lastRunRemote { return lastRunRemote }
        if cardMachine != nil { return true }
        return defaultRunRemotely(mode: mode, projectPath: projectPath)
    }

    /// Machine picked last time for a project, when the pick was a machine
    /// that already exists (an ssh machine or a named boxd machine).
    static func defaultMachineChoice(projectPath: String) -> BoxdMachineChoice {
        guard let name = UserDefaults.standard.string(forKey: "runOnMachine_\(projectPath)"), !name.isEmpty else {
            return .newMachine
        }
        return .existing(name)
    }

    static func rememberMachineChoice(_ choice: BoxdMachineChoice, projectPath: String) {
        UserDefaults.standard.set(choice.machineName ?? "", forKey: "runOnMachine_\(projectPath)")
    }

    /// The machine a dialog opens with: the machine of the card, then the
    /// last pick for the project when it is still offered, then the first
    /// ssh machine in the ssh mode (or without the boxd CLI), else a new
    /// boxd machine.
    func initialMachineChoice(projectPath: String) -> BoxdMachineChoice {
        if let ownerMachine { return .existing(ownerMachine) }
        if let cardMachine { return .existing(cardMachine) }
        let remembered = Self.defaultMachineChoice(projectPath: projectPath)
        let offered = RunTargetOption.options(for: self).map(\.target)
        if offered.contains(.machine(remembered)) { return remembered }
        if mode == .ssh, let first = allMachines.first { return .existing(first.name) }
        if !boxdAvailable, let first = sshMachines.first?.name ?? masterMachines.first?.name { return .existing(first) }
        return .newMachine
    }

    /// Where a launch from the remote API runs. `machine` is "mac", the
    /// name of a machine, or nil for the defaults a dialog would open with.
    static func remoteMachineChoice(
        _ machine: String?, options: RemoteLaunchOptions, projectPath: String
    ) -> (runRemotely: Bool, machine: BoxdMachineChoice?) {
        let canRun = options.canRunRemotely(projectPath: projectPath)
        if let machine, !machine.isEmpty {
            if machine.lowercased() == "mac" || !canRun { return (false, nil) }
            return (true, options.mode.runsOnMachines ? .existing(machine) : nil)
        }
        let remote = canRun && defaultRunRemotely(mode: options.mode, projectPath: projectPath)
        guard remote else { return (false, nil) }
        return (true, options.mode.runsOnMachines ? options.initialMachineChoice(projectPath: projectPath) : nil)
    }

    static func rememberRunRemotely(_ value: Bool, mode: RemoteMode, projectPath: String) {
        switch mode {
        case .ssh, .boxd:
            UserDefaults.standard.set(value, forKey: "runOnBoxd_\(projectPath)")
        case .mutagen:
            UserDefaults.standard.set(value, forKey: "runRemotely_\(projectPath)")
        }
    }
}

/// Where a launch runs: this Mac or one of the machines.
enum RunTarget: Hashable {
    case mac
    case machine(BoxdMachineChoice)
}

/// One entry of the "Run on" picker.
struct RunTargetOption: Identifiable, Equatable {
    let target: RunTarget
    let label: String
    /// Name of the ssh machine behind the option, for its reachability.
    var sshMachine: String?
    var id: RunTarget { target }

    /// The entries in order: this Mac, then the machines of the mode. The
    /// ssh mode offers the ssh machines with whether they answer; the boxd
    /// mode offers the machine of the card, a new machine and the other
    /// machines of the org. A card on a machine the mode does not list
    /// still gets its machine offered, last.
    static func options(for remote: RemoteLaunchOptions, reachability: [String: Bool] = [:]) -> [RunTargetOption] {
        var options = [RunTargetOption(target: .mac, label: "This Mac")]
        let sshNames = Set(remote.sshMachines.map(\.name))
        switch remote.mode {
        case .ssh:
            // One entry per machine: an ssh machine that runs a master of its
            // own is that master, and a paired master without ssh is listed too.
            for machine in remote.allMachines {
                let state: String
                if machine.master != nil {
                    state = machine.masterOnline ? "online" : "offline"
                } else {
                    switch reachability[machine.name] {
                    case .some(true): state = "online"
                    case .some(false): state = "offline"
                    case .none: state = "checking"
                    }
                }
                options.append(RunTargetOption(
                    target: .machine(.existing(machine.name)),
                    label: "\(machine.name) (\(state))",
                    sshMachine: machine.master == nil ? machine.sshMachine?.name : nil))
            }
        case .boxd:
            for machine in remote.masterMachines {
                options.append(RunTargetOption(
                    target: .machine(.existing(machine.name)),
                    label: "\(machine.name) (\(machine.masterOnline ? "online" : "offline"))"))
            }
            guard remote.boxdAvailable else { break }
            let masterNames = Set(remote.masterMachines.map(\.name))
            if let machine = remote.cardMachine, !sshNames.contains(machine), !masterNames.contains(machine) {
                var label = "boxd: \(machine)"
                if let state = remote.cardMachineState { label += " (\(state.label))" }
                options.append(RunTargetOption(target: .machine(.existing(machine)), label: label))
            }
            let snapshot = remote.boxd?.snapshotName ?? BoxdSettings.defaultSnapshotName
            options.append(RunTargetOption(target: .machine(.newMachine), label: "boxd: new machine from snapshot \(snapshot)"))
            for name in remote.availableMachines where name != remote.cardMachine && !sshNames.contains(name) && !masterNames.contains(name) {
                options.append(RunTargetOption(target: .machine(.existing(name)), label: "boxd: \(name)"))
            }
        case .mutagen:
            break
        }
        if let machine = remote.cardMachine, !options.contains(where: { $0.target == .machine(.existing(machine)) }) {
            var label = machine
            if let state = remote.cardMachineState { label += " (\(state.label))" }
            options.append(RunTargetOption(target: .machine(.existing(machine)), label: label))
        }
        return options
    }
}
