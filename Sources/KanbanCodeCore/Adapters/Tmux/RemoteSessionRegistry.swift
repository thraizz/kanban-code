import Foundation

/// Maps tmux session names to the remote machine that hosts them, and keeps
/// one tmux adapter per connected machine.
///
/// A name must be registered before the session is created, so the routing
/// adapter never creates a remote card's session on the local tmux server.
/// The last session list of each machine is kept, so a paused or unreachable
/// machine still reports its sessions as live.
public final class RemoteSessionRegistry: @unchecked Sendable {
    public struct MachineEntry: Sendable {
        public var state: RemoteMachineState
        /// Adapter bound to the bridge of this machine, present while connected.
        public var tmux: TmuxAdapter?
        /// rush on the machine, present while connected and when it has rush.
        public var rush: RushCliAdapter?
        /// Last sessions seen on the machine, by name.
        public var knownSessions: [String: TmuxSession]

        public init(state: RemoteMachineState, tmux: TmuxAdapter? = nil, knownSessions: [String: TmuxSession] = [:]) {
            self.state = state
            self.tmux = tmux
            self.knownSessions = knownSessions
        }
    }

    private let lock = NSLock()
    private var machines: [String: MachineEntry] = [:]
    private var machineBySession: [String: String] = [:]

    public init() {}

    // MARK: - Machines

    /// Registers or updates a machine. Passing a `tmux` adapter marks the
    /// machine connected; passing nil keeps the adapter it had.
    public func setMachine(_ name: String, state: RemoteMachineState, tmux: TmuxAdapter? = nil) {
        lock.lock(); defer { lock.unlock() }
        var entry = machines[name] ?? MachineEntry(state: state)
        entry.state = state
        if let tmux { entry.tmux = tmux }
        if !state.isConnected, case .destroyed = state {
            entry.tmux = nil
            entry.rush = nil
            entry.knownSessions = [:]
        }
        machines[name] = entry
    }

    /// Records rush on a connected machine, or nil when it has none.
    public func setRush(_ rush: RushCliAdapter?, on name: String) {
        lock.lock(); defer { lock.unlock() }
        machines[name]?.rush = rush
    }

    public func rush(for machine: String) -> RushCliAdapter? {
        lock.lock(); defer { lock.unlock() }
        return machines[machine]?.rush
    }

    /// Drops the bridge adapter of a machine and records the new state.
    public func disconnectMachine(_ name: String, state: RemoteMachineState) {
        lock.lock(); defer { lock.unlock() }
        guard var entry = machines[name] else { return }
        entry.state = state
        entry.tmux = nil
        entry.rush = nil
        machines[name] = entry
    }

    public func removeMachine(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        machines[name] = nil
        machineBySession = machineBySession.filter { $0.value != name }
    }

    public func state(of machine: String) -> RemoteMachineState? {
        lock.lock(); defer { lock.unlock() }
        return machines[machine]?.state
    }

    public func tmux(for machine: String) -> TmuxAdapter? {
        lock.lock(); defer { lock.unlock() }
        return machines[machine]?.tmux
    }

    public var machineNames: [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(machines.keys).sorted()
    }

    public var states: [String: RemoteMachineState] {
        lock.lock(); defer { lock.unlock() }
        return machines.mapValues(\.state)
    }

    // MARK: - Sessions

    public func assign(sessionName: String, to machine: String) {
        lock.lock(); defer { lock.unlock() }
        machineBySession[sessionName] = machine
        if machines[machine] == nil {
            machines[machine] = MachineEntry(state: .connecting)
        }
    }

    public func unassign(sessionName: String) {
        lock.lock(); defer { lock.unlock() }
        machineBySession[sessionName] = nil
        for (machine, var entry) in machines where entry.knownSessions[sessionName] != nil {
            entry.knownSessions[sessionName] = nil
            machines[machine] = entry
        }
    }

    public func machine(forSession sessionName: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return machineBySession[sessionName]
    }

    public func sessionNames(on machine: String) -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(machineBySession.filter { $0.value == machine }.keys)
    }

    /// Replaces the session list of a machine after a live `list-sessions`.
    /// Sessions the app assigned to the machine are also mapped to it, so a
    /// card created on the machine by name is found again after a restart.
    public func recordSessions(_ sessions: [TmuxSession], on machine: String) {
        lock.lock(); defer { lock.unlock() }
        guard var entry = machines[machine] else { return }
        entry.knownSessions = Dictionary(uniqueKeysWithValues: sessions.map { ($0.name, $0) })
        machines[machine] = entry
        for session in sessions where machineBySession[session.name] == nil {
            machineBySession[session.name] = machine
        }
    }

    public func knownSessions(on machine: String) -> [TmuxSession] {
        lock.lock(); defer { lock.unlock() }
        return Array(machines[machine]?.knownSessions.values ?? [:].values)
    }

    /// Forgets one session of a machine after `has-session` said it is gone.
    public func forgetSession(_ sessionName: String, on machine: String) {
        lock.lock(); defer { lock.unlock() }
        guard var entry = machines[machine] else { return }
        entry.knownSessions[sessionName] = nil
        machines[machine] = entry
    }

    /// Re-seeds the name → machine map from persisted links, so remote
    /// sessions route correctly after the app restarts.
    public func seed(from links: some Sequence<Link>) {
        lock.lock(); defer { lock.unlock() }
        for link in links {
            guard let remote = link.remote, link.isRemote, let tmux = link.tmuxLink else { continue }
            if machines[remote.machineName] == nil {
                let state: RemoteMachineState = remote.pausedReason.map { .paused($0) } ?? .unreachable
                machines[remote.machineName] = MachineEntry(state: state)
            }
            for name in tmux.allSessionNames {
                machineBySession[name] = remote.machineName
                if machines[remote.machineName]?.knownSessions[name] == nil {
                    machines[remote.machineName]?.knownSessions[name] = TmuxSession(
                        name: name, path: remote.remoteCwd ?? "", attached: false)
                }
            }
        }
    }
}
