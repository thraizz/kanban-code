import Foundation

/// Runs shell commands and returns their output.
public enum ShellCommand {

    public struct Result: Sendable {
        public let exitCode: Int32
        public let stdout: String
        public let stderr: String

        public var succeeded: Bool { exitCode == 0 }

        public init(exitCode: Int32, stdout: String, stderr: String) {
            self.exitCode = exitCode
            self.stdout = stdout
            self.stderr = stderr
        }
    }

    /// Cached user login-shell environment, resolved once on first use.
    /// .app bundles get a minimal environment (TMPDIR=/var/folders/..., PATH=/usr/bin:/bin)
    /// which causes tmux socket mismatches, missing binaries, etc. We resolve the real
    /// environment from the user's login shell and inject it into every subprocess.
    private static let userEnvironment: [String: String] = {
        // The user's shell environment: interactive too, since tools such as
        // nvm only add themselves to PATH in ~/.zshrc. A login-only dump
        // stands in when the interactive one fails or takes too long.
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let env = dumpEnvironment(shell: shell, arguments: ["-l", "-i", "-c", "env"])
            ?? dumpEnvironment(shell: shell, arguments: ["-l", "-c", "env"])
        return env ?? ProcessInfo.processInfo.environment
    }()

    private static func dumpEnvironment(shell: String, arguments: [String], timeout: TimeInterval = 8) -> [String: String]? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shell)
        proc.arguments = arguments
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice
        defer { try? pipe.fileHandleForReading.close() }
        do {
            try proc.runUnmasked()
        } catch {
            return nil
        }
        let deadline = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        deadline.cancel()
        guard proc.terminationStatus == 0, let output = String(data: data, encoding: .utf8) else { return nil }
        var env: [String: String] = [:]
        for line in output.components(separatedBy: "\n") {
            guard let eq = line.firstIndex(of: "="), eq != line.startIndex else { continue }
            let key = String(line[..<eq])
            guard key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { continue }
            env[key] = String(line[line.index(after: eq)...])
        }
        return env["PATH"] == nil ? nil : env
    }

    /// The login-shell environment every subprocess of the app gets.
    public static var loginEnvironment: [String: String] { userEnvironment }

    /// Background queue for blocking process I/O — never touches the main thread.
    private static let processQueue = DispatchQueue(label: "kanban.shell", qos: .userInitiated, attributes: .concurrent)

    /// Separate from `processQueue` so pipe readers can never be starved by the
    /// waiters they are supposed to release.
    private static let drainQueue = DispatchQueue(label: "kanban.shell.drain", qos: .userInitiated, attributes: .concurrent)

    /// Collects a pipe's bytes from a reader thread for the waiter to pick up.
    private final class OutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func store(_ bytes: Data) {
            lock.lock()
            data = bytes
            lock.unlock()
        }

        var value: Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }

    /// Run a command and capture its output. All blocking I/O runs on a background
    /// dispatch queue so the Swift cooperative thread pool (and main thread) stays free.
    public static func run(
        _ executable: String,
        arguments: [String] = [],
        currentDirectory: String? = nil,
        stdin: String? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval = 300
    ) async throws -> Result {
        let env = environment ?? userEnvironment
        return try await withCheckedThrowingContinuation { continuation in
            processQueue.async {
                #if os(Linux)
                do {
                    continuation.resume(returning: try LinuxSpawn.run(
                        executable: executable, arguments: arguments, currentDirectory: currentDirectory,
                        stdin: stdin, environment: env, timeout: timeout))
                } catch {
                    continuation.resume(throwing: error)
                }
                return
                #else
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.environment = env

                if let dir = currentDirectory {
                    process.currentDirectoryURL = URL(fileURLWithPath: dir)
                }

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                var stdinPipe: Pipe?
                if let stdin, let data = stdin.data(using: .utf8) {
                    let pipe = Pipe()
                    stdinPipe = pipe
                    process.standardInput = pipe
                    pipe.fileHandleForWriting.write(data)
                    pipe.fileHandleForWriting.closeFile()
                }

                // Foundation hands the child its ends of these pipes and closes
                // its own copies of those. The read ends are ours, and leaving
                // them to close when the `Pipe` is deallocated makes the
                // descriptors' lifetime a question of when the object happens to
                // be released, which is not something a scarce process-wide
                // resource can be left to depend on: the same shape leaks two
                // descriptors per call in a standalone binary, and the running
                // app was holding hundreds whose far end was long gone.
                //
                // The cost of getting it wrong lands outside this app. The
                // kernel caps how much buffer memory all pipes on a machine may
                // use, and past roughly half that cap XNU quietly gives every
                // newly created pipe a 512 byte buffer instead of 16KB.
                // Unrelated programs that write more than that to a pipe before
                // anything reads it then block forever.
                func closePipes() {
                    try? stdoutPipe.fileHandleForReading.close()
                    try? stderrPipe.fileHandleForReading.close()
                    try? stdinPipe?.fileHandleForReading.close()
                }

                do {
                    try process.runUnmasked()
                } catch {
                    closePipes()
                    continuation.resume(throwing: error)
                    return
                }

                // Drain both pipes before waiting, and drain them concurrently:
                // reading stdout to EOF first deadlocks whenever the child fills
                // the ~64KB stderr buffer, because it then blocks writing and
                // never closes stdout.
                let stdoutBuffer = OutputBuffer()
                let stderrBuffer = OutputBuffer()
                let drained = DispatchGroup()
                for (pipe, buffer) in [(stdoutPipe, stdoutBuffer), (stderrPipe, stderrBuffer)] {
                    drained.enter()
                    drainQueue.async {
                        // The timeout path closes these handles while this
                        // reader can still be blocked on them: a timed-out
                        // child's own children keep the write end open past
                        // the grace wait. read(upToCount:) reports that close
                        // as a thrown error; readDataToEndOfFile raises an
                        // ObjC exception no Swift catch can stop, which
                        // aborts the whole app.
                        let handle = pipe.fileHandleForReading
                        var collected = Data()
                        while let chunk = try? handle.read(upToCount: 65536), !chunk.isEmpty {
                            collected.append(chunk)
                        }
                        buffer.store(collected)
                        drained.leave()
                    }
                }

                // A child that never exits would otherwise strand this call, and
                // with it whatever the app was doing: a launch whose prompt never
                // gets submitted, a pane that never refreshes.
                if drained.wait(timeout: .now() + timeout) == .timedOut {
                    process.terminate()
                    _ = drained.wait(timeout: .now() + 5)
                    // Foundation collects the child on its own, but only once
                    // something waits on it.
                    process.waitUntilExit()
                    closePipes()
                    continuation.resume(throwing: ShellCommandError.timedOut(
                        command: ([executable] + arguments).joined(separator: " "),
                        seconds: timeout
                    ))
                    return
                }

                process.waitUntilExit()
                closePipes()

                let result = Result(
                    exitCode: process.terminationStatus,
                    stdout: String(data: stdoutBuffer.value, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                    stderr: String(data: stderrBuffer.value, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                )
                continuation.resume(returning: result)
                #endif
            }
        }
    }

    /// Check if a command is available on the system.
    public static func isAvailable(_ command: String) async -> Bool {
        findExecutable(command) != nil
    }

    /// Resolve a command name to an absolute path by checking common locations
    /// plus the user's login-shell PATH (which includes nvm, volta, fnm, etc.).
    /// macOS .app bundles have a minimal PATH (/usr/bin:/bin:/usr/sbin:/sbin),
    /// so Homebrew and other tools aren't found via `env` or `which`.
    /// Returns nil if the command isn't found anywhere.
    public static func findExecutable(_ command: String) -> String? {
        let home = NSHomeDirectory()
        var searchPaths = [
            "\(home)/.claude/local",   // Claude Code managed install
            "\(home)/.local/bin",      // XDG local bin / claude installer
            "\(home)/go/bin",          // go install (rush)
            "\(home)/.opencode/bin",   // OpenCode install script
            "\(home)/.pi/agent/bin",   // Pi managed install
            "/opt/homebrew/bin",       // Homebrew (Apple Silicon)
            "/usr/local/bin",          // Homebrew (Intel) / npm global
            "/usr/bin",                // System binaries
            "/bin",                    // Core system binaries
        ]

        // Also search the user's real PATH (resolved from login shell).
        // This picks up nvm, volta, fnm, and other version-managed installs.
        if let userPath = userEnvironment["PATH"] {
            for dir in userPath.components(separatedBy: ":") where !dir.isEmpty {
                if !searchPaths.contains(dir) {
                    searchPaths.append(dir)
                }
            }
        }

        for dir in searchPaths {
            let path = "\(dir)/\(command)"
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }
}

public enum ShellCommandError: Error, LocalizedError {
    case timedOut(command: String, seconds: TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .timedOut(let command, let seconds):
            "`\(command)` did not finish within \(Int(seconds))s and was terminated"
        }
    }
}
