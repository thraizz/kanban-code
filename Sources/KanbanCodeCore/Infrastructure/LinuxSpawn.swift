#if os(Linux)
import Foundation
import Glibc

/// Runs a command with posix_spawn and waitpid, for Linux.
///
/// Foundation's `Process` on Linux leaks a pipe and a socketpair per child
/// when several start at once (a headless master runs dozens of git, tmux
/// and rush commands concurrently), and hit the 1024 descriptor limit in
/// under a minute. Here every descriptor is created close-on-exec, the
/// child starts with no signal blocked, and the output is read until the
/// child exits: a daemon it leaves behind (a rush host) may keep the pipe
/// open forever, so its output stops counting a moment after the exit.
enum LinuxSpawn {
    /// Held from the creation of a child's pipes until it is spawned, so no
    /// other child started here inherits them before they are close-on-exec.
    private static let spawnLock = NSLock()

    /// glibc's `posix_spawn_file_actions_addclosefrom_np` (2.34 and later),
    /// which its headers only declare for `_GNU_SOURCE`; nil on an older glibc.
    private typealias AddCloseFrom = @convention(c) (UnsafeMutablePointer<posix_spawn_file_actions_t>, Int32) -> Int32
    private static let addCloseFrom: AddCloseFrom? = {
        guard let handle = dlopen(nil, RTLD_NOW),
              let symbol = dlsym(handle, "posix_spawn_file_actions_addclosefrom_np") else { return nil }
        return unsafeBitCast(symbol, to: AddCloseFrom.self)
    }()

    /// A pipe whose two ends are close-on-exec.
    private static func cloexecPipe() throws -> [Int32] {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        return fds
    }

    static func run(
        executable: String,
        arguments: [String],
        currentDirectory: String?,
        stdin: String?,
        environment: [String: String],
        timeout: TimeInterval
    ) throws -> ShellCommand.Result {
        spawnLock.lock()
        var locked = true
        defer { if locked { spawnLock.unlock() } }
        let outPipe = try cloexecPipe()
        let errPipe = try cloexecPipe()
        let inPipe = stdin != nil ? try cloexecPipe() : [-1, -1]

        var actions = posix_spawn_file_actions_t()
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if stdin != nil {
            posix_spawn_file_actions_adddup2(&actions, inPipe[0], 0)
        } else {
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        // The child keeps only 0, 1 and 2. Any other descriptor open in this
        // process at that moment (a file another thread is writing, a
        // socket) would otherwise live on in children that outlast the
        // command, such as rush hosts: descriptors pile up, and a file
        // still open for writing cannot be executed (ETXTBSY).
        _ = addCloseFrom?(&actions, 3)

        var attr = posix_spawnattr_t()
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attr, &noSignals)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for sig in [SIGPIPE, SIGTERM, SIGINT, SIGHUP, SIGCHLD] { sigaddset(&defaults, sig) }
        posix_spawnattr_setsigdefault(&attr, &defaults)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))

        // Glibc's chdir file action is not visible from Swift: a shell
        // changes directory, then becomes the command.
        let command = currentDirectory.map { ["/bin/sh", "-c", "cd \"$0\" || exit 127; exec \"$@\"", $0, executable] + arguments }
            ?? ([executable] + arguments)
        let argv = command.map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, command[0], &actions, &attr, argv, envp)
        spawnLock.unlock()
        locked = false
        close(outPipe[1])
        close(errPipe[1])
        if stdin != nil { close(inPipe[0]) }
        guard spawned == 0 else {
            close(outPipe[0])
            close(errPipe[0])
            if stdin != nil { close(inPipe[1]) }
            throw POSIXError(POSIXErrorCode(rawValue: spawned) ?? .EIO)
        }
        if let stdin {
            let bytes = Array(stdin.utf8)
            var offset = 0
            while offset < bytes.count {
                let n = bytes[offset...].withUnsafeBytes { write(inPipe[1], $0.baseAddress, $0.count) }
                if n <= 0 { break }
                offset += n
            }
            close(inPipe[1])
        }

        var out = Data()
        var err = Data()
        var open = [outPipe[0], errPipe[0]]
        var status: Int32 = 0
        var exited = false
        var exitedAt: Date?
        var timedOut = false
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 65536)

        while true {
            if !exited, waitpid(pid, &status, WNOHANG) == pid {
                exited = true
                exitedAt = Date()
            }
            if open.isEmpty, exited { break }
            // Output after the exit only comes from what the child left behind.
            if let exitedAt, Date().timeIntervalSince(exitedAt) > 1 { break }
            if !exited, Date() > deadline {
                timedOut = true
                kill(pid, SIGTERM)
                let grace = Date().addingTimeInterval(5)
                while waitpid(pid, &status, WNOHANG) != pid {
                    if Date() > grace {
                        kill(pid, SIGKILL)
                        waitpid(pid, &status, 0)
                        break
                    }
                    usleep(50_000)
                }
                break
            }
            if open.isEmpty {
                usleep(20_000)
                continue
            }
            var fds = open.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
            let ready = poll(&fds, nfds_t(fds.count), 100)
            guard ready > 0 else { continue }
            for entry in fds where entry.revents != 0 {
                let n = read(entry.fd, &buffer, buffer.count)
                if n > 0 {
                    if entry.fd == outPipe[0] { out.append(buffer, count: n) } else { err.append(buffer, count: n) }
                } else if n == 0 || (errno != EINTR && errno != EAGAIN) {
                    open.removeAll { $0 == entry.fd }
                }
            }
        }
        if !exited, !timedOut { waitpid(pid, &status, 0) }
        close(outPipe[0])
        close(errPipe[0])

        if timedOut {
            throw ShellCommandError.timedOut(command: ([executable] + arguments).joined(separator: " "), seconds: timeout)
        }
        let signal = status & 0x7f
        let exitCode: Int32 = signal == 0 ? (status >> 8) & 0xff : 128 + signal
        return ShellCommand.Result(
            exitCode: exitCode,
            stdout: String(data: out, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            stderr: String(data: err, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )
    }
}
#endif
