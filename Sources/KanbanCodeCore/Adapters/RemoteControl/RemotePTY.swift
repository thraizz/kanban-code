#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// A child process running in its own pseudo-terminal and session, so it is
/// the terminal's foreground process group and gets SIGWINCH on resize.
final class RemotePTYProcess: @unchecked Sendable {
    enum SpawnError: Error, CustomStringConvertible {
        case emptyCommand
        case notFound(String)
        case forkFailed(Int32)

        var description: String {
            switch self {
            case .emptyCommand: "empty command"
            case .notFound(let name): "\(name) not found on PATH"
            case .forkFailed(let err): "forkpty failed: \(String(cString: strerror(err)))"
            }
        }
    }

    let pid: pid_t
    let master: Int32
    private let writeQueue = DispatchQueue(label: "kanban.remote.pty.write")
    private let lock = NSLock()
    private var exited = false
    /// Set once `terminate()` is called; later resizes are dropped.
    private var hangingUp = false
    /// Uptime of the last TIOCSWINSZ, read and written on `writeQueue`.
    private var lastResizeUptime: UInt64 = 0

    /// How long a hang-up waits after the last resize.
    ///
    /// tmux 3.8 crashes the whole server, every session on it, when a client
    /// sends a resize after it said it was exiting: `MSG_RESIZE` reaches
    /// `tty_resize` on the tty `MSG_EXITING` already closed, and writes into
    /// its freed buffer. A `tmux attach` that gets SIGWINCH and SIGHUP close
    /// together does exactly that, because libevent hands it pending signals
    /// in number order, SIGHUP (1) before SIGWINCH (28). Switching cards
    /// resizes the old terminal and then closes it, so both arrive together.
    static let resizeSettleNanos: UInt64 = 500_000_000

    private init(pid: pid_t, master: Int32) {
        self.pid = pid
        self.master = master
    }

    /// Directories searched after PATH: GUI apps start with a short PATH.
    static let extraPath = ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    static func environment(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        // A tmux client started from inside tmux refuses to attach.
        env.removeValue(forKey: "TMUX")
        env.removeValue(forKey: "TMUX_PANE")
        var path = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        for dir in extraPath where !path.contains(dir) { path.append(dir) }
        env["PATH"] = path.joined(separator: ":")
        return env
    }

    static func resolve(_ name: String, path: String) -> String? {
        if name.contains("/") { return access(name, X_OK) == 0 ? name : nil }
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if access(candidate, X_OK) == 0 { return candidate }
        }
        return nil
    }

    static func spawn(argv: [String], cols: Int, rows: Int, directory: String? = nil) throws -> RemotePTYProcess {
        guard let name = argv.first, !name.isEmpty else { throw SpawnError.emptyCommand }
        let env = environment()
        guard let executable = resolve(name, path: env["PATH"] ?? "") else { throw SpawnError.notFound(name) }

        // Everything the child touches is allocated before fork: after it only
        // async-signal-safe calls run.
        let cExecutable = strdup(executable)
        let cArgs = argv.map { strdup($0) } + [nil]
        let cEnv = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        let cDir = directory.flatMap { strdup($0) }
        defer {
            free(cExecutable)
            cArgs.forEach { free($0) }
            cEnv.forEach { free($0) }
            if let cDir { free(cDir) }
        }

        var size = winsize(ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: cols), ws_xpixel: 0, ws_ypixel: 0)
        var master: Int32 = -1
        let pid = cArgs.withUnsafeBufferPointer { argsPtr in
            cEnv.withUnsafeBufferPointer { envPtr in
                let pid = forkpty(&master, nil, nil, &size)
                if pid == 0 {
                    #if os(Linux)
                    // The fork keeps the spawning thread's mask, and dispatch
                    // threads block nearly every signal; a terminal needs them.
                    var empty = sigset_t()
                    sigemptyset(&empty)
                    sigprocmask(SIG_SETMASK, &empty, nil)
                    #endif
                    if let cDir { _ = chdir(cDir) }
                    _ = execve(cExecutable!, argsPtr.baseAddress!, envPtr.baseAddress!)
                    _exit(127)
                }
                return pid
            }
        }
        guard pid > 0 else { throw SpawnError.forkFailed(errno) }
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        return RemotePTYProcess(pid: pid, master: master)
    }

    var hasExited: Bool { lock.withLock { exited } }

    /// Reads the terminal's output on a dedicated thread until the child
    /// exits. `onData` may block (the socket's backpressure); `onExit` runs
    /// once, after the child was reaped and the pty closed.
    func startReading(onData: @escaping @Sendable (Data) -> Void, onExit: @escaping @Sendable () -> Void) {
        let master = self.master
        let pid = self.pid
        let thread = Thread { [self] in
            var buf = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let n = buf.withUnsafeMutableBytes { read(master, $0.baseAddress, $0.count) }
                if n > 0 {
                    onData(Data(buf[0..<n]))
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            lock.withLock { exited = true }
            _ = writeQueue.sync { close(master) }
            onExit()
        }
        thread.name = "kanban.remote.pty.read"
        thread.start()
    }

    func write(_ data: Data) {
        let master = self.master
        writeQueue.async { [self] in
            guard !hasExited else { return }
            data.withUnsafeBytes { raw in
                guard var p = raw.baseAddress else { return }
                var left = raw.count
                while left > 0 {
                    let n = systemWrite(master, p, left)
                    if n < 0 {
                        if errno == EINTR || errno == EAGAIN { continue }
                        return
                    }
                    left -= n
                    p = p.advanced(by: n)
                }
            }
        }
    }

    func resize(cols: Int, rows: Int) {
        let master = self.master
        writeQueue.async { [self] in
            guard !hasExited, !lock.withLock({ hangingUp }) else { return }
            var size = winsize(ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: cols), ws_xpixel: 0, ws_ypixel: 0)
            _ = ioctl(master, UInt(TIOCSWINSZ), &size)
            lastResizeUptime = DispatchTime.now().uptimeNanoseconds
        }
    }

    /// Hangs up the child's process group, then kills it if it lingers.
    ///
    /// No resize goes out once this is called, and the hang-up waits until
    /// the last one is ``resizeSettleNanos`` old (see there for why).
    func terminate() {
        guard !hasExited else { return }
        let alreadyHangingUp = lock.withLock { () -> Bool in
            defer { hangingUp = true }
            return hangingUp
        }
        guard !alreadyHangingUp else { return }
        let pid = self.pid
        // Queued behind any resize already sent, so its time is final here.
        writeQueue.async { [self] in
            let since = DispatchTime.now().uptimeNanoseconds &- lastResizeUptime
            let wait = since >= Self.resizeSettleNanos ? 0 : Self.resizeSettleNanos - since
            DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(wait))) { [self] in
                guard !hasExited else { return }
                kill(-pid, SIGHUP)
                kill(pid, SIGHUP)
                DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { [self] in
                    guard !hasExited else { return }
                    kill(-pid, SIGKILL)
                    kill(pid, SIGKILL)
                }
            }
        }
    }
}

private func systemWrite(_ fd: Int32, _ p: UnsafeRawPointer, _ count: Int) -> Int {
    #if canImport(Darwin)
    Darwin.write(fd, p, count)
    #else
    Glibc.write(fd, p, count)
    #endif
}
