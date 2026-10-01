import Foundation
import Darwin

/// Utility for executing shell commands
enum ShellExecutor {

    /// Default timeout for shell commands (10 seconds).
    /// Prevents hung processes from blocking the GCD thread pool indefinitely,
    /// which is the primary cause of the app becoming unresponsive.
    private static let defaultTimeout: TimeInterval = 10
    private static let widgetOutputLimit = 512 * 1024

    /// Shared PATH prefix prepended to every child process.
    private static let pathPrefix = "/usr/local/bin:/opt/homebrew/bin"

    /// Build an environment dictionary with a reliable PATH.
    static func shellEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if let existing = env["PATH"] {
            env["PATH"] = "\(pathPrefix):\(existing)"
        } else {
            env["PATH"] = "\(pathPrefix):/usr/bin:/bin"
        }
        return env
    }

    private static func makeProcess(command: String, stdout: Any?, stderr: Any?) -> Process {
        makeProcess(executable: "/bin/zsh", arguments: ["-c", command], stdout: stdout, stderr: stderr)
    }

    private static func makeProcess(executable: String, arguments: [String], stdout: Any?, stderr: Any?) -> Process {
        let process = Process()
        process.standardOutput = stdout
        process.standardError = stderr
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = shellEnvironment()
        return process
    }

    private static func scheduleTimeoutWatchdog(for process: Process, timeout: TimeInterval) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler {
            if process.isRunning {
                process.terminate()  // SIGTERM
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
        }
        timer.resume()
        return timer
    }

    /// Drains a pipe on its own queue, starting immediately.
    ///
    /// A pipe holds about 64KB. Waiting for the process to exit before reading deadlocks any
    /// script that writes more than that: the child blocks on write, the parent blocks on
    /// `waitUntilExit()`, and only the timeout watchdog breaks the tie - after which the output
    /// is silently truncated to the buffer size. Reading concurrently is what makes a script
    /// with a lot to say work at all.
    private final class PipeDrain {
        private let group = DispatchGroup()
        private var data = Data()
        private(set) var failure: String?

        init(_ pipe: Pipe, byteLimit: Int? = nil, deadline: DispatchTime? = nil) {
            group.enter()
            DispatchQueue.global(qos: .utility).async { [self] in
                defer { group.leave() }
                if let byteLimit, let deadline {
                    drainBounded(pipe.fileHandleForReading, byteLimit: byteLimit, deadline: deadline)
                } else {
                    data = pipe.fileHandleForReading.readDataToEndOfFile()
                }
            }
        }

        // Widget reads retain a bounded prefix and discard the rest while draining.
        // Nonblocking reads enforce the deadline even if a descendant holds the write end;
        // only this worker closes the read end.
        private func drainBounded(_ handle: FileHandle, byteLimit: Int, deadline: DispatchTime) {
            defer { try? handle.close() }
            let fd = handle.fileDescriptor
            let flags = fcntl(fd, F_GETFL, 0)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                failure = "Could not prepare script output pipe."
                return
            }
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while DispatchTime.now() < deadline {
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                // Poll for at most 100 ms; continuous output must also check the deadline before each read.
                let now = DispatchTime.now()
                guard now < deadline else { break }
                let remaining = deadline.uptimeNanoseconds - now.uptimeNanoseconds
                let ready = poll(&descriptor, 1, Int32(min(100, max(1, remaining / 1_000_000))))
                if ready < 0 {
                    if errno == EINTR { continue }
                    failure = failure ?? "Could not read script output pipe."
                    return
                }
                if ready == 0 { continue }
                while DispatchTime.now() < deadline {
                    let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                    if count == 0 { return } // POLLHUP can still carry unread bytes before EOF.
                    if count < 0 {
                        if errno == EINTR { continue }
                        if errno == EAGAIN || errno == EWOULDBLOCK { break }
                        failure = failure ?? "Could not read script output pipe."
                        return
                    }
                    let available = byteLimit - data.count
                    data.append(contentsOf: buffer.prefix(min(count, available)))
                    if count > available {
                        failure = failure ?? "Output exceeds the \(byteLimit / 1024) KiB limit."
                    }
                }
            }
            failure = failure ?? "Script output pipe did not close before the deadline."
        }

        /// Waits for EOF, or for the widget's bounded reader to reach its deadline.
        func string() -> String {
            group.wait()
            return String(data: data, encoding: .utf8) ?? ""
        }
    }

    /// Execute a shell command and return the output.
    ///
    /// A per-command `timeout` (seconds) prevents runaway processes from
    /// exhausting the cooperative thread pool.  The process is killed with
    /// SIGTERM (then SIGKILL) when the deadline expires.
    @discardableResult
    static func run(_ command: String, timeout: TimeInterval = defaultTimeout) async throws -> String {
        let pipe = Pipe()
        return try await run(makeProcess(command: command, stdout: pipe, stderr: pipe), pipe: pipe, timeout: timeout)
    }

    /// Execute structured arguments literally, returning only stdout on success.
    @discardableResult
    static func run(executable: String, arguments: [String], timeout: TimeInterval = defaultTimeout) async throws -> String {
        var path = (executable as NSString).expandingTildeInPath
        if !path.contains("/") {
            let candidates = (shellEnvironment()["PATH"] ?? "").split(separator: ":", omittingEmptySubsequences: false)
            guard let resolved = candidates.map({ URL(fileURLWithPath: String($0)).appendingPathComponent(path).path })
                .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT),
                              userInfo: [NSLocalizedDescriptionKey: "Executable not found: \(executable)"])
            }
            path = resolved
        }
        let pipe = Pipe()
        let stderrPipe = Pipe()
        let process = makeProcess(executable: path, arguments: arguments, stdout: pipe, stderr: stderrPipe)
        return try await run(process, pipe: pipe, stderrPipe: stderrPipe, timeout: timeout, checkExit: true)
    }

    private static func run(_ process: Process, pipe: Pipe, stderrPipe: Pipe? = nil, timeout: TimeInterval, checkExit: Bool = false) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                let output = PipeDrain(pipe)
                let errorOutput = stderrPipe.map { PipeDrain($0) }
                let timer = scheduleTimeoutWatchdog(for: process, timeout: timeout)
                defer { timer.cancel() }

                process.waitUntilExit()
                let result = output.string()
                let diagnostics = errorOutput?.string() ?? ""
                if checkExit && process.terminationStatus != 0 {
                    continuation.resume(throwing: NSError(
                        domain: "ShellExecutor", code: Int(process.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: "\(process.executableURL!.lastPathComponent) exited with status \(process.terminationStatus): \(result)\(diagnostics)"]))
                } else {
                    continuation.resume(returning: result)
                }
            }
        }
    }

    /// The result of running a custom widget script.
    struct WidgetRunResult {
        /// Raw stdout output from the script.
        let stdout: String
        /// Raw stderr output from the script (empty on success).
        let stderr: String
        /// Process exit code. 0 means success.
        let exitCode: Int32
        /// Capture failure, independent of the script's own exit code.
        var executionError: String? = nil

        var succeeded: Bool { exitCode == 0 && executionError == nil }
    }

    /// Run a widget script with stdout and stderr captured separately.
    ///
    /// Unlike `run(_:)`, this method never throws. Errors (process launch
    /// failures, non-zero exit codes) are encoded in the returned result so
    /// widgets can display them without crashing the bar.
    static func runWidget(_ command: String, timeout: TimeInterval = defaultTimeout) async -> WidgetRunResult {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                let process = makeProcess(command: command, stdout: stdoutPipe, stderr: stderrPipe)

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: WidgetRunResult(
                        stdout: "",
                        stderr: "Could not start script: \(error.localizedDescription)",
                        exitCode: -1
                    ))
                    return
                }

                // Include the watchdog's existing one-second SIGKILL grace period.
                let deadline = DispatchTime.now() + timeout + 1
                let outDrain = PipeDrain(stdoutPipe, byteLimit: widgetOutputLimit, deadline: deadline)
                let errDrain = PipeDrain(stderrPipe, byteLimit: widgetOutputLimit, deadline: deadline)
                let timer = scheduleTimeoutWatchdog(for: process, timeout: timeout)
                defer { timer.cancel() }

                process.waitUntilExit()
                let stdout = outDrain.string()
                let stderr = errDrain.string()
                let executionError = outDrain.failure.map { "stdout: \($0)" }
                    ?? errDrain.failure.map { "stderr: \($0)" }

                continuation.resume(returning: WidgetRunResult(
                    stdout: stdout,
                    stderr: stderr,
                    exitCode: process.terminationStatus,
                    executionError: executionError
                ))
            }
        }
    }

    /// Execute a shell command synchronously (use sparingly – never on the main thread).
    @discardableResult
    static func runSync(_ command: String, timeout: TimeInterval = defaultTimeout) -> String {
        let pipe = Pipe()
        let process = makeProcess(command: command, stdout: pipe, stderr: pipe)

        do {
            try process.run()
        } catch {
            return ""
        }

        let output = PipeDrain(pipe)
        let timer = scheduleTimeoutWatchdog(for: process, timeout: timeout)
        defer { timer.cancel() }

        process.waitUntilExit()
        return output.string()
    }
}
