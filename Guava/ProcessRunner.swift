import Foundation

/// Outcome of running an external process.
struct ProcessResult: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let timedOut: Bool
    let wasCancelled: Bool
    let launchError: String?

    var success: Bool {
        launchError == nil && !timedOut && !wasCancelled && exitCode == 0
    }

    /// Short human-readable reason for a failed run.
    ///
    /// Starts at the first line that states an error: the cause follows it, whereas what a tool
    /// prints last is often general advice. Without such a line the last lines are used.
    var failureMessage: String {
        if let launchError { return launchError }
        if wasCancelled { return "Cancelled" }
        if timedOut { return "Timed out" }
        let detail = [stderr, stdout]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        let lines = detail.split(separator: "\n").map(String.init)
        let chosen = lines.firstIndex(where: Self.statesAnError).map { lines[$0...].prefix(4) } ?? lines.suffix(4)
        return chosen.isEmpty ? "Exited with status \(exitCode)" : chosen.joined(separator: "\n")
    }

    private static func statesAnError(_ line: String) -> Bool {
        line.range(
            of: #"\b(error|fatal|failed|failure|denied|not found|cannot|unable to)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }
}

/// Runs external processes without blocking the caller, with a timeout, task cancellation,
/// and optional line-by-line output streaming.
enum ProcessRunner {

    enum OutputStream: Sendable {
        case stdout
        case stderr
    }

    typealias LineHandler = @Sendable (String, OutputStream) -> Void

    /// Upper bound on captured output per stream; older output is dropped first.
    static let defaultCaptureLimit = 4 * 1024 * 1024

    /// For output that is parsed as a whole, where losing the beginning would corrupt it.
    static let unlimitedCapture = Int.max

    static func run(
        _ executable: String,
        _ arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        timeout: TimeInterval? = nil,
        captureLimit: Int = defaultCaptureLimit,
        onLine: LineHandler? = nil
    ) async -> ProcessResult {
        let state = RunState()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: runBlocking(
                        executable,
                        arguments,
                        environment: environment,
                        currentDirectory: currentDirectory,
                        timeout: timeout,
                        captureLimit: captureLimit,
                        onLine: onLine,
                        state: state
                    ))
                }
            }
        } onCancel: {
            state.cancel()
        }
    }

    private static func runBlocking(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String]?,
        currentDirectory: URL?,
        timeout: TimeInterval?,
        captureLimit: Int,
        onLine: LineHandler?,
        state: RunState
    ) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let outCollector = LineCollector(stream: .stdout, limit: captureLimit, onLine: onLine)
        let errCollector = LineCollector(stream: .stderr, limit: captureLimit, onLine: onLine)
        let readers = DispatchGroup()

        for (pipe, collector) in [(outPipe, outCollector), (errPipe, errCollector)] {
            readers.enter()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    if collector.markFinished() { readers.leave() }
                } else {
                    collector.append(chunk)
                }
            }
        }

        func detachReaders() {
            for (pipe, collector) in [(outPipe, outCollector), (errPipe, errCollector)] {
                pipe.fileHandleForReading.readabilityHandler = nil
                if collector.markFinished() { readers.leave() }
            }
        }

        guard state.attach(process) else {
            detachReaders()
            return ProcessResult(
                exitCode: -1, stdout: "", stderr: "", timedOut: false, wasCancelled: true, launchError: nil
            )
        }

        do {
            try process.run()
        } catch {
            detachReaders()
            return ProcessResult(
                exitCode: -1, stdout: "", stderr: "", timedOut: false, wasCancelled: false,
                launchError: "Could not run \(executable): \(error.localizedDescription)"
            )
        }

        // A cancellation that arrived after `attach` but before the process existed found
        // nothing to stop, so it has to be honoured here.
        if state.wasCancelled {
            terminateTree(process)
        }

        var timeoutItem: DispatchWorkItem?
        if let timeout {
            let item = DispatchWorkItem { state.expire() }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: item)
            timeoutItem = item
        }

        process.waitUntilExit()
        timeoutItem?.cancel()

        // A lingering grandchild can keep the pipes open, so never wait for EOF indefinitely.
        if readers.wait(timeout: .now() + 2) == .timedOut {
            detachReaders()
        }
        outCollector.flush()
        errCollector.flush()

        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: outCollector.text,
            stderr: errCollector.text,
            timedOut: state.didTimeOut,
            wasCancelled: state.wasCancelled,
            launchError: nil
        )
    }

    /// Terminates a process and the processes it started.
    fileprivate static func terminateTree(_ process: Process) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        let descendants = descendantPIDs(of: pid)
        process.terminate()
        for child in descendants {
            kill(child, SIGTERM)
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
            if process.isRunning {
                kill(pid, SIGKILL)
            }
        }
    }

    /// Process identifiers of every descendant of `root`, discovered breadth-first.
    static func descendantPIDs(of root: pid_t) -> [pid_t] {
        var result: [pid_t] = []
        var frontier: [pid_t] = [root]
        while !frontier.isEmpty, result.count < 512 {
            var next: [pid_t] = []
            for parent in frontier {
                next.append(contentsOf: childPIDs(of: parent))
            }
            result.append(contentsOf: next)
            frontier = next
        }
        return result
    }

    private static func childPIDs(of parent: pid_t) -> [pid_t] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-P", String(parent)]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Shared cancellation and timeout state for one run.
    private final class RunState: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false
        private var timedOut = false

        var wasCancelled: Bool { lock.withLock { cancelled } }
        var didTimeOut: Bool { lock.withLock { timedOut } }

        /// Registers the process. Returns false when the run was cancelled before it started.
        func attach(_ process: Process) -> Bool {
            lock.withLock {
                guard !cancelled else { return false }
                self.process = process
                return true
            }
        }

        func cancel() {
            let target: Process? = lock.withLock {
                cancelled = true
                return process
            }
            // Cancellation is delivered on the caller's thread, often the main one, and
            // finding a process's descendants takes a moment.
            if let target {
                DispatchQueue.global(qos: .userInitiated).async {
                    ProcessRunner.terminateTree(target)
                }
            }
        }

        func expire() {
            let target: Process? = lock.withLock {
                guard let process, process.isRunning else { return nil }
                timedOut = true
                return process
            }
            if let target { ProcessRunner.terminateTree(target) }
        }
    }

    /// Accumulates one output stream and reports complete lines as they arrive.
    private final class LineCollector: @unchecked Sendable {
        private let lock = NSLock()
        private let stream: OutputStream
        private let limit: Int
        private let onLine: LineHandler?
        private var captured = Data()
        private var pending = Data()
        private var finished = false

        init(stream: OutputStream, limit: Int, onLine: LineHandler?) {
            self.stream = stream
            self.limit = max(limit, 1024)
            self.onLine = onLine
        }

        var text: String {
            lock.withLock { String(decoding: captured, as: UTF8.self) }
        }

        func append(_ chunk: Data) {
            var lines: [String] = []
            lock.withLock {
                captured.append(chunk)
                if captured.count > limit {
                    captured = Data(captured.suffix(limit))
                }
                guard onLine != nil else { return }
                pending.append(chunk)
                while let newline = pending.firstIndex(of: 0x0A) {
                    lines.append(Self.decodeLine(pending[pending.startIndex..<newline]))
                    pending = Data(pending[pending.index(after: newline)...])
                }
            }
            for line in lines {
                onLine?(line, stream)
            }
        }

        /// Reports a trailing line that did not end with a newline.
        func flush() {
            let remainder: String? = lock.withLock {
                guard onLine != nil, !pending.isEmpty else { return nil }
                defer { pending = Data() }
                return Self.decodeLine(pending[...])
            }
            if let remainder { onLine?(remainder, stream) }
        }

        /// Returns true the first time it is called.
        func markFinished() -> Bool {
            lock.withLock {
                guard !finished else { return false }
                finished = true
                return true
            }
        }

        private static func decodeLine(_ data: Data) -> String {
            var line = String(decoding: data, as: UTF8.self)
            if line.hasSuffix("\r") { line.removeLast() }
            return line
        }
    }
}

/// Resolves command-line tools for a GUI app, whose inherited PATH lacks Homebrew and
/// per-user tool directories when it is launched from Finder.
struct ToolEnvironment: Sendable {
    let home: URL
    let searchPaths: [String]
    /// False when only `home`-relative directories and the inherited PATH are consulted.
    let includesSystemLocations: Bool
    private let inherited: [String: String]

    static let current = ToolEnvironment(
        home: FileManager.default.homeDirectoryForCurrentUser,
        inherited: ProcessInfo.processInfo.environment
    )

    /// - Parameter includeSystemLocations: when false only `home`-relative directories and the
    ///   inherited PATH are searched, which keeps tests independent of the host machine.
    init(home: URL, inherited: [String: String], includeSystemLocations: Bool = true) {
        self.home = home
        self.inherited = inherited
        self.includesSystemLocations = includeSystemLocations

        let userDirectories = [
            ".local/bin",
            ".bun/bin",
            ".cargo/bin",
            ".deno/bin",
            ".claude/local",
            ".claude-cli/currentVersion",
            ".lmstudio/bin",
        ].map { home.appendingPathComponent($0).path }

        var candidates = userDirectories
        if includeSystemLocations {
            candidates += ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin"]
        }
        candidates += (inherited["PATH"] ?? "").split(separator: ":").map(String.init)
        if includeSystemLocations {
            candidates += ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        }

        var seen = Set<String>()
        searchPaths = candidates.filter { path in
            guard !path.isEmpty, seen.insert(path).inserted else { return false }
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
    }

    /// Environment for child processes: the inherited one with a complete PATH.
    var environment: [String: String] {
        var result = inherited
        result["PATH"] = searchPaths.joined(separator: ":")
        result["HOME"] = home.path
        result["NO_COLOR"] = "1"
        return result
    }

    /// Absolute path of the first executable named `name` on the search path.
    func which(_ name: String) -> String? {
        for directory in searchPaths {
            let candidate = (directory as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory),
                   !isDirectory.boolValue {
                    return candidate
                }
            }
        }
        return nil
    }
}

extension String {
    /// Removes ANSI escape sequences so process output reads cleanly in a log view.
    var strippingANSI: String {
        guard contains("\u{1B}") else { return self }
        return replacingOccurrences(
            of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]",
            with: "",
            options: .regularExpression
        )
    }
}
