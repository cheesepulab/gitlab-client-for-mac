import Foundation

public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let timedOut: Bool

    public var succeeded: Bool { exitCode == 0 && !timedOut }
    public var combinedOutput: String {
        [stdout, stderr].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

public enum OutputLine: Sendable, Equatable {
    case stdout(String)
    case stderr(String)

    public var text: String {
        switch self {
        case .stdout(let text), .stderr(let text): return text
        }
    }
}

public enum ProcessError: Error, LocalizedError, Sendable {
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let detail): return "Couldn't start \(detail)"
        }
    }
}

/// The only place the app launches processes (git, ssh, AI CLIs). Output is read while the
/// process runs, a timeout terminates it, and cancelling the calling task terminates it too.
public enum ProcessRunner {
    public static func run(
        _ executable: String,
        _ arguments: [String] = [],
        in directory: URL? = nil,
        environment: [String: String]? = nil,
        timeout: Duration = .seconds(120),
        onLine: (@Sendable (OutputLine) -> Void)? = nil
    ) async throws -> ProcessResult {
        let box = ProcessBox(onLine: onLine)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
                do {
                    try box.start(executable: executable, arguments: arguments, directory: directory,
                                  environment: environment, timeout: timeout) { result in
                        continuation.resume(returning: result)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            box.terminate()
        }
    }
}

/// Owns one `Process` and the output it produces. All mutable state is guarded by `lock`.
private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private let onLine: (@Sendable (OutputLine) -> Void)?
    private var stdoutData = Data()
    private var stderrData = Data()
    private var stdoutPending = Data()
    private var stderrPending = Data()
    private var stdoutClosed = false
    private var stderrClosed = false
    private var exited = false
    private var finished = false
    private var timedOut = false
    private var cancelled = false
    private var completion: (@Sendable (ProcessResult) -> Void)?

    init(onLine: (@Sendable (OutputLine) -> Void)?) {
        self.onLine = onLine
    }

    func start(executable: String, arguments: [String], directory: URL?, environment: [String: String]?,
               timeout: Duration, completion: @escaping @Sendable (ProcessResult) -> Void) throws {
        lock.lock()
        if cancelled {
            lock.unlock()
            throw CancellationError()
        }
        self.completion = completion
        lock.unlock()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = directory }
        if let environment { process.environment = environment }
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { [self] _ in
            lock.lock()
            exited = true
            lock.unlock()
            finishIfDone()
            // A child that inherited the pipes can keep them open; don't wait for it forever.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in finish() }
        }

        do {
            try process.run()
        } catch {
            throw ProcessError.launchFailed("\((executable as NSString).lastPathComponent): \(error.localizedDescription)")
        }

        outPipe.fileHandleForReading.readabilityHandler = { [self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                closeStream(isStdout: true)
            } else {
                append(data, isStdout: true)
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                closeStream(isStdout: false)
            } else {
                append(data, isStdout: false)
            }
        }

        let comps = timeout.components
        let seconds = Double(comps.seconds) + Double(comps.attoseconds) * 1e-18
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [self] in
            lock.lock()
            let running = !exited
            if running { timedOut = true }
            lock.unlock()
            if running { terminate() }
        }
    }

    func terminate() {
        lock.lock()
        cancelled = true
        let running = process.isRunning
        let pid = process.processIdentifier
        lock.unlock()
        guard running else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [self] in
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    private func append(_ data: Data, isStdout: Bool) {
        var lines: [String] = []
        lock.lock()
        if isStdout {
            stdoutData.append(data)
            if onLine != nil { stdoutPending.append(data); lines = Self.takeLines(&stdoutPending) }
        } else {
            stderrData.append(data)
            if onLine != nil { stderrPending.append(data); lines = Self.takeLines(&stderrPending) }
        }
        lock.unlock()
        for line in lines { onLine?(isStdout ? .stdout(line) : .stderr(line)) }
    }

    private func closeStream(isStdout: Bool) {
        var rest: String?
        lock.lock()
        if isStdout {
            stdoutClosed = true
            if !stdoutPending.isEmpty { rest = String(decoding: stdoutPending, as: UTF8.self); stdoutPending.removeAll() }
        } else {
            stderrClosed = true
            if !stderrPending.isEmpty { rest = String(decoding: stderrPending, as: UTF8.self); stderrPending.removeAll() }
        }
        lock.unlock()
        if let rest, !rest.isEmpty { onLine?(isStdout ? .stdout(rest) : .stderr(rest)) }
        finishIfDone()
    }

    /// Splits off complete lines. Git progress uses carriage returns, so both end a line.
    private static func takeLines(_ buffer: inout Data) -> [String] {
        var lines: [String] = []
        while let index = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let line = buffer[buffer.startIndex..<index]
            lines.append(String(decoding: line, as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...index)
        }
        return lines.filter { !$0.isEmpty }
    }

    private func finishIfDone() {
        lock.lock()
        let done = exited && stdoutClosed && stderrClosed
        lock.unlock()
        if done { finish() }
    }

    private func finish() {
        lock.lock()
        guard exited, !finished else { lock.unlock(); return }
        finished = true
        let result = ProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self),
            timedOut: timedOut
        )
        let completion = self.completion
        self.completion = nil
        lock.unlock()
        completion?(result)
    }
}

/// GUI apps don't get the login shell's PATH, so tools like git and claude are found through it.
public actor ShellEnvironment {
    public static let shared = ShellEnvironment()

    private var loginPath: String?
    private static let fallbackPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    public init() {}

    public func path() async -> String {
        if let loginPath { return loginPath }
        var parts: [String] = []
        if let output = await Self.loginShell(#"printf '__P__%s__E__' "$PATH""#) {
            parts = output.split(separator: ":").map(String.init)
        }
        for extra in Self.fallbackPath.split(separator: ":").map(String.init) where !parts.contains(extra) {
            parts.append(extra)
        }
        let joined = parts.joined(separator: ":")
        loginPath = joined
        return joined
    }

    /// Environment for git and the AI CLIs: the login PATH, and nothing that could wait for input.
    public func environment(adding extra: [String: String] = [:]) async -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = await path()
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes -o ConnectTimeout=15"
        env["GIT_EDITOR"] = "true"
        env["GIT_SEQUENCE_EDITOR"] = "true"
        env["GIT_MERGE_AUTOEDIT"] = "no"
        env["LC_ALL"] = "en_US.UTF-8"
        env.merge(extra) { _, new in new }
        return env
    }

    /// Absolute path of a command as the user's login shell sees it, or nil.
    public func which(_ name: String) async -> String? {
        guard name.range(of: "^[A-Za-z0-9._+-]+$", options: .regularExpression) != nil else { return nil }
        guard let path = await Self.loginShell("printf '__P__%s__E__' \"$(command -v \(name))\"") else { return nil }
        return path.hasPrefix("/") ? path : nil
    }

    /// Runs a snippet in a login shell and returns what it printed between the markers, so
    /// greetings printed by the user's profile don't leak into the result.
    private static func loginShell(_ script: String) async -> String? {
        guard let result = try? await ProcessRunner.run("/bin/zsh", ["-lc", script], timeout: .seconds(10)) else { return nil }
        guard let start = result.stdout.range(of: "__P__"), let end = result.stdout.range(of: "__E__", range: start.upperBound..<result.stdout.endIndex) else {
            return nil
        }
        let value = String(result.stdout[start.upperBound..<end.lowerBound])
        return value.isEmpty ? nil : value
    }
}
