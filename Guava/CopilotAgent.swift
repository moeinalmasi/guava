import Foundation

/// The GitHub Copilot CLI installed on this Mac.
struct CopilotCLI: Sendable {
    let executablePath: String
    let environment: ToolEnvironment

    static func locate(environment: ToolEnvironment = .current) -> CopilotCLI? {
        environment.which("copilot").map { CopilotCLI(executablePath: $0, environment: environment) }
    }

    func version() async -> String? {
        let result = await ProcessRunner.run(
            executablePath, ["--version"], environment: environment.environment, timeout: 60
        )
        guard result.success else { return nil }
        return DevToolUpdater.extractVersion(from: result.stdout)
    }

    /// Names of every MCP server the CLI would start, from all configuration sources.
    func configuredMCPServers() async -> [String] {
        let result = await ProcessRunner.run(
            executablePath, ["mcp", "list"], environment: environment.environment, timeout: 120
        )
        guard result.success else { return [] }
        return Self.parseMCPServerNames(result.stdout)
    }

    /// `copilot mcp list` prints servers as indented `name (type)` lines under group headings.
    static func parseMCPServerNames(_ output: String) -> [String] {
        var names: [String] = []
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            guard line.hasPrefix("  "),
                  let open = line.range(of: " (", options: .backwards),
                  line.hasSuffix(")") else { continue }
            let name = line[line.startIndex..<open.lowerBound].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, !name.contains(" "), !names.contains(name) {
                names.append(name)
            }
        }
        return names
    }
}

struct AgentRunConfiguration: Equatable, Sendable {
    var workingDirectory: URL
    var prompt: String
    var sessionName: String
    var allowComputerUse: Bool
    var model: String?
    var maxAICredits: Int?
    var timeout: TimeInterval
    /// Every MCP server configured on this Mac; all but the ones the agent needs are disabled.
    var configuredMCPServers: [String]
}

/// Something worth showing the user while an agent session runs.
enum AgentEvent: Equatable, Sendable {
    case toolStarted(tool: String, summary: String)
    case toolFinished(success: Bool)
    case message(String)
    case notice(String)
    case finished(exitCode: Int, premiumRequests: Int?)
}

struct AgentRunOutcome: Equatable, Sendable {
    let exitCode: Int32
    let timedOut: Bool
    let wasCancelled: Bool
    let finalMessage: String?
    let premiumRequests: Int?
    let failure: String?

    /// True when the session ran to its natural end. Says nothing about whether the update worked.
    var completed: Bool {
        failure == nil && !timedOut && !wasCancelled && exitCode == 0
    }
}

/// Runs the Copilot CLI as an unattended, tightly scoped update agent.
enum CopilotAgent {

    static let agentName = "guava-updater"

    /// The only tools the model can see. Names differ between model families, so this is a
    /// superset; unknown names are ignored by the CLI.
    static let baseTools = [
        "bash", "read_bash", "stop_bash", "list_bash",
        "view", "create", "edit", "apply_patch",
        "web_fetch", "web_search",
    ]

    static let computerUseTools = ["computer-use-exec_js", "computer-use-exec_js_reset"]

    static let computerUseServer = "computer-use"

    /// `web_search` is served by the built-in GitHub server, so it has to keep running. Its
    /// other tools stay hidden because they are not in the allowlist.
    static let webSearchServer = "github-mcp-server"

    /// Commands the agent may never run. Installation, privilege and security settings belong
    /// to Guava. This narrows accidents; the tool allowlist and Guava's own verification of
    /// whatever the agent stages are what the design relies on.
    static let deniedShellCommands = [
        "sudo", "su", "osascript", "installer", "brew", "mas", "softwareupdate",
        "spctl", "xattr", "csrutil", "security", "launchctl", "dscl",
    ]

    /// Read-only system folders whose tools the agent may call by full path. The CLI refuses
    /// any command that names a path outside the staging folder, and agents habitually write
    /// `/usr/bin/codesign` or `/usr/libexec/PlistBuddy`. Everything else stays off limits,
    /// notably `/Applications`, `/Volumes` and the home folder.
    static let systemToolDirectories = ["/usr/bin", "/usr/sbin", "/usr/libexec", "/bin", "/sbin"]

    static func arguments(for configuration: AgentRunConfiguration) -> [String] {
        var tools = baseTools
        var retainedServers: Set<String> = [webSearchServer]
        if configuration.allowComputerUse {
            tools += computerUseTools
            retainedServers.insert(computerUseServer)
        }

        var arguments = [
            "-C", configuration.workingDirectory.path,
            "--trust-folder",
            "--agent", agentName,
            "-p", configuration.prompt,
            "--available-tools",
        ]
        arguments += tools
        arguments += ["--allow-all-tools", "--allow-all-urls", "--deny-tool"]
        arguments += deniedShellCommands.map { "shell(\($0):*)" }
        for directory in systemToolDirectories {
            arguments += ["--add-dir", directory]
        }
        arguments += ["--no-custom-instructions", "--no-ask-user", "--sync-session=off"]

        for server in configuration.configuredMCPServers where !retainedServers.contains(server) {
            arguments += ["--disable-mcp-server", server]
        }
        if !configuration.allowComputerUse, !configuration.configuredMCPServers.contains(computerUseServer) {
            arguments += ["--disable-mcp-server", computerUseServer]
        }

        if let model = configuration.model?.trimmingCharacters(in: .whitespaces), !model.isEmpty {
            arguments += ["--model", model]
        }
        if let credits = configuration.maxAICredits {
            // The CLI rejects limits below 30.
            arguments += ["--max-ai-credits", String(max(credits, 30))]
        }
        arguments += ["--output-format", "json", "-n", configuration.sessionName]
        return arguments
    }

    /// Turn one line of the CLI's JSONL output into something worth showing, if it is.
    static func parseEvent(_ line: String) -> AgentEvent? {
        guard line.hasPrefix("{"),
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            return nil
        }
        let payload = object["data"] as? [String: Any] ?? [:]

        switch type {
        case "tool.execution_start":
            guard let tool = payload["toolName"] as? String else { return nil }
            let arguments = payload["arguments"] as? [String: Any] ?? [:]
            return .toolStarted(tool: tool, summary: summarize(tool: tool, arguments: arguments))

        case "tool.execution_complete":
            return .toolFinished(success: payload["success"] as? Bool ?? false)

        case "assistant.message":
            guard let content = payload["content"] as? String else { return nil }
            let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : .message(text)

        case "session.error", "session.warning":
            guard let message = payload["message"] as? String, !message.isEmpty else { return nil }
            return .notice(message)

        case "result":
            let usage = object["usage"] as? [String: Any]
            return .finished(
                exitCode: object["exitCode"] as? Int ?? 0,
                premiumRequests: usage?["premiumRequests"] as? Int
            )

        default:
            return nil
        }
    }

    /// A one-line description of a tool call.
    static func summarize(tool: String, arguments: [String: Any]) -> String {
        func firstLine(_ key: String) -> String? {
            (arguments[key] as? String)?
                .split(whereSeparator: \.isNewline)
                .first
                .map { String($0).trimmingCharacters(in: .whitespaces) }
        }
        let text: String
        switch tool {
        case "bash":
            text = firstLine("command") ?? ""
        case "web_fetch":
            text = firstLine("url") ?? ""
        case "web_search":
            text = firstLine("query") ?? ""
        case "view", "create", "edit":
            text = firstLine("path") ?? ""
        case "computer-use-exec_js":
            text = firstLine("code") ?? ""
        default:
            text = ""
        }
        return text.count > 160 ? String(text.prefix(160)) + "…" : text
    }

    static func run(
        cli: CopilotCLI,
        configuration: AgentRunConfiguration,
        onEvent: (@Sendable (AgentEvent) -> Void)? = nil
    ) async -> AgentRunOutcome {
        let state = SessionState()
        let result = await ProcessRunner.run(
            cli.executablePath,
            arguments(for: configuration),
            environment: cli.environment.environment,
            currentDirectory: configuration.workingDirectory,
            timeout: configuration.timeout,
            captureLimit: 256 * 1024
        ) { line, stream in
            guard stream == .stdout, let event = parseEvent(line) else { return }
            state.record(event)
            onEvent?(event)
        }

        var failure = result.launchError
        if failure == nil, !result.timedOut, !result.wasCancelled, result.exitCode != 0 {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).strippingANSI
            failure = detail.isEmpty
                ? "The Copilot CLI exited with status \(result.exitCode)"
                : String(detail.suffix(600))
        }

        return AgentRunOutcome(
            exitCode: result.exitCode,
            timedOut: result.timedOut,
            wasCancelled: result.wasCancelled,
            finalMessage: state.lastMessage,
            premiumRequests: state.premiumRequests,
            failure: failure
        )
    }

    private final class SessionState: @unchecked Sendable {
        private let lock = NSLock()
        private var message: String?
        private var requests: Int?

        var lastMessage: String? { lock.withLock { message } }
        var premiumRequests: Int? { lock.withLock { requests } }

        func record(_ event: AgentEvent) {
            lock.withLock {
                switch event {
                case .message(let text): message = text
                case .finished(_, let premiumRequests): requests = premiumRequests
                default: break
                }
            }
        }
    }
}
