import Foundation

/// A command Guava runs on the user's behalf.
struct ToolCommand: Equatable, Sendable {
    let executable: String
    let arguments: [String]
    var environment: [String: String] = [:]

    /// The command as it would be typed, for logs.
    var displayString: String {
        ([(executable as NSString).lastPathComponent] + arguments).joined(separator: " ")
    }
}

/// How a tool reports what is currently installed.
enum VersionProbe: Equatable, Sendable {
    /// The first version-looking token in the command's output.
    case command(ToolCommand)
    /// A list of installed items: counted for display, compared in full to detect changes.
    case listing(ToolCommand, noun: String, matching: String?)
    case none
}

struct ToolVersion: Equatable, Sendable {
    let display: String
    /// Changes whenever anything the tool manages changes.
    let fingerprint: String
}

/// A quick question for a tool before its updater runs: is there anything to install?
struct PendingCheck: Equatable, Sendable {
    let command: ToolCommand
    /// Text in the command's output that means nothing is waiting.
    let nothingPendingMarker: String
    var timeout: TimeInterval = 2 * 60
}

/// A self-updating tool discovered on this Mac.
struct DevTool: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    /// Top-level dot entries in the home folder that belong to this tool.
    let dotEntries: [String]
    let versionProbe: VersionProbe
    let updateCommand: ToolCommand
    var updateTimeout: TimeInterval = 15 * 60
    /// Asked first, when the tool can say whether it has anything to install.
    var pendingCheck: PendingCheck? = nil
    /// True when the updater is started and left to finish by itself. Guava does not wait for
    /// it, so its result is not known when the run moves on.
    var finishesInBackground = false
    /// What to tell the user about an updater that carries on by itself.
    var backgroundNote: String? = nil

    /// The command that runs first, for the log.
    var firstCommand: ToolCommand {
        pendingCheck?.command ?? updateCommand
    }
}

enum ToolUpdateOutcome: Equatable, Sendable {
    case updated(from: String?, to: String?)
    case alreadyCurrent(String?)
    /// The updater ran successfully but exposes nothing to compare before and after.
    case triggered
    /// The updater was started and is finishing by itself; Guava did not wait for it.
    case runningInBackground
    case failed(String)

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }

    var summary: String {
        switch self {
        case .updated(let from?, let to?): return "Updated \(from) → \(to)"
        case .updated(_, let to?): return "Updated to \(to)"
        case .updated: return "Updated"
        case .alreadyCurrent(let version?): return "Already up to date (\(version))"
        case .alreadyCurrent: return "Already up to date"
        case .triggered: return "Updater ran"
        case .runningInBackground: return "Started; it finishes in the background"
        case .failed(let message): return "Failed: \(message)"
        }
    }
}

/// Result of scanning the home folder's dot entries.
struct DotfileScan: Sendable {
    /// Names of every top-level dot entry found.
    let entries: [String]
    let tools: [DevTool]

    /// Dot entries that belong to a detected tool.
    var claimedEntries: Set<String> {
        Set(tools.flatMap(\.dotEntries)).intersection(entries)
    }
}

/// Finds self-updating developer tools behind the dot entries of the home folder.
enum DevToolScanner {

    static let microsoftAutoUpdatePath =
        "/Library/Application Support/Microsoft/MAU2.0/Microsoft AutoUpdate.app/Contents/MacOS/msupdate"
    static let microsoftAutoUpdateID = "microsoft-autoupdate"

    static func scan(environment: ToolEnvironment = .current, includeSystemUpdaters: Bool = true) -> DotfileScan {
        let entries = dotEntries(in: environment.home)
        var tools: [DevTool] = []
        for detect in detectors {
            tools.append(contentsOf: detect(environment))
        }
        if includeSystemUpdaters {
            tools.append(contentsOf: systemUpdaters(environment))
        }
        return DotfileScan(entries: entries, tools: tools)
    }

    /// Names of the top-level entries in `home` that start with a dot.
    static func dotEntries(in home: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        return names
            .filter { $0.hasPrefix(".") && $0 != "." && $0 != ".." }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    // MARK: - Detectors

    private typealias Detector = (ToolEnvironment) -> [DevTool]

    private static var detectors: [Detector] {
        [
            ohMyZsh,
            ohMyZshCustomRepositories,
            bun,
            rustup,
            deno,
            claudeCode,
            copilotCLI,
            vsCodeExtensions,
            uvTools,
            pipx,
            ghExtensions,
        ]
    }

    private static func ohMyZsh(_ env: ToolEnvironment) -> [DevTool] {
        let root = env.home.appendingPathComponent(".oh-my-zsh")
        let script = root.appendingPathComponent("tools/upgrade.sh")
        guard exists(script), let zsh = firstExecutable(["/bin/zsh"], env, name: "zsh") else { return [] }
        return [DevTool(
            id: "oh-my-zsh",
            name: "Oh My Zsh",
            dotEntries: [".oh-my-zsh"],
            versionProbe: gitRevisionProbe(root, env),
            updateCommand: ToolCommand(
                executable: zsh,
                arguments: ["-f", script.path],
                environment: ["ZSH": root.path]
            )
        )]
    }

    /// Third-party plugins and themes cloned into Oh My Zsh's custom folder.
    private static func ohMyZshCustomRepositories(_ env: ToolEnvironment) -> [DevTool] {
        guard let git = gitPath(env) else { return [] }
        let custom = env.home.appendingPathComponent(".oh-my-zsh/custom")
        var tools: [DevTool] = []
        for folder in ["plugins", "themes"] {
            let directory = custom.appendingPathComponent(folder)
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
            for name in names {
                let repository = directory.appendingPathComponent(name)
                guard exists(repository.appendingPathComponent(".git")) else { continue }
                tools.append(DevTool(
                    id: "omz-custom:\(folder)/\(name)",
                    name: name,
                    dotEntries: [".oh-my-zsh"],
                    versionProbe: gitRevisionProbe(repository, env),
                    updateCommand: ToolCommand(
                        executable: git,
                        arguments: ["-C", repository.path, "pull", "--ff-only", "--quiet"]
                    ),
                    updateTimeout: 5 * 60
                ))
            }
        }
        return tools
    }

    private static func bun(_ env: ToolEnvironment) -> [DevTool] {
        let binary = env.home.appendingPathComponent(".bun/bin/bun").path
        guard isExecutable(binary) else { return [] }
        return [DevTool(
            id: "bun",
            name: "Bun",
            dotEntries: [".bun"],
            versionProbe: .command(ToolCommand(executable: binary, arguments: ["--version"])),
            updateCommand: ToolCommand(executable: binary, arguments: ["upgrade"])
        )]
    }

    private static func rustup(_ env: ToolEnvironment) -> [DevTool] {
        let binary = env.home.appendingPathComponent(".cargo/bin/rustup").path
        guard isExecutable(binary) else { return [] }
        // `rustup update` updates the toolchains as well as itself, so the compiler's version,
        // not rustup's own, shows whether anything changed.
        let compiler = env.home.appendingPathComponent(".cargo/bin/rustc").path
        return [DevTool(
            id: "rustup",
            name: "Rust toolchains",
            dotEntries: [".cargo", ".rustup"],
            versionProbe: .command(ToolCommand(
                executable: isExecutable(compiler) ? compiler : binary, arguments: ["--version"]
            )),
            updateCommand: ToolCommand(executable: binary, arguments: ["update"]),
            updateTimeout: 30 * 60
        )]
    }

    private static func deno(_ env: ToolEnvironment) -> [DevTool] {
        let binary = env.home.appendingPathComponent(".deno/bin/deno").path
        guard isExecutable(binary) else { return [] }
        return [DevTool(
            id: "deno",
            name: "Deno",
            dotEntries: [".deno"],
            versionProbe: .command(ToolCommand(executable: binary, arguments: ["--version"])),
            updateCommand: ToolCommand(executable: binary, arguments: ["upgrade"])
        )]
    }

    private static func claudeCode(_ env: ToolEnvironment) -> [DevTool] {
        let candidates = [
            env.home.appendingPathComponent(".claude-cli/currentVersion/claude").path,
            env.home.appendingPathComponent(".claude/local/claude").path,
        ]
        guard let binary = firstExecutable(candidates, env, name: "claude") else { return [] }
        return [DevTool(
            id: "claude-code",
            name: "Claude Code",
            dotEntries: [".claude", ".claude-cli", ".claude.json"],
            versionProbe: .command(ToolCommand(executable: binary, arguments: ["--version"])),
            updateCommand: ToolCommand(executable: binary, arguments: ["update"])
        )]
    }

    private static func copilotCLI(_ env: ToolEnvironment) -> [DevTool] {
        guard exists(env.home.appendingPathComponent(".copilot")),
              let binary = env.which("copilot") else { return [] }
        return [DevTool(
            id: "copilot-cli",
            name: "GitHub Copilot CLI",
            dotEntries: [".copilot"],
            versionProbe: .command(ToolCommand(executable: binary, arguments: ["--version"])),
            updateCommand: ToolCommand(executable: binary, arguments: ["update"])
        )]
    }

    private static func vsCodeExtensions(_ env: ToolEnvironment) -> [DevTool] {
        guard exists(env.home.appendingPathComponent(".vscode/extensions")) else { return [] }
        let bundled = "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
        let candidates = env.includesSystemLocations ? [bundled] : []
        guard let code = env.which("code") ?? candidates.first(where: isExecutable) else { return [] }
        return [DevTool(
            id: "vscode-extensions",
            name: "VS Code extensions",
            dotEntries: [".vscode"],
            versionProbe: .listing(
                ToolCommand(executable: code, arguments: ["--list-extensions", "--show-versions"]),
                noun: "extension",
                matching: "@"
            ),
            updateCommand: ToolCommand(executable: code, arguments: ["--update-extensions"])
        )]
    }

    // npm's global packages are deliberately not among the tools. `npm update -g` moves every
    // package to its newest release, new major versions and prereleases included, and links
    // every command again. On a registry that lags behind, that has replaced a working npm
    // with one the registry could not serve and left a command-line tool without the build
    // for this Mac. Nothing an unattended run should risk.

    private static func uvTools(_ env: ToolEnvironment) -> [DevTool] {
        let directory = env.home.appendingPathComponent(".local/share/uv/tools")
        guard hasContents(directory), let uv = env.which("uv") else { return [] }
        return [DevTool(
            id: "uv-tools",
            name: "uv tools",
            dotEntries: [".local"],
            versionProbe: .listing(
                ToolCommand(executable: uv, arguments: ["tool", "list"]),
                noun: "tool",
                matching: " v"
            ),
            updateCommand: ToolCommand(executable: uv, arguments: ["tool", "upgrade", "--all"])
        )]
    }

    private static func pipx(_ env: ToolEnvironment) -> [DevTool] {
        let hasState = exists(env.home.appendingPathComponent(".local/pipx"))
            || exists(env.home.appendingPathComponent(".local/share/pipx"))
        guard hasState, let pipx = env.which("pipx") else { return [] }
        return [DevTool(
            id: "pipx",
            name: "pipx applications",
            dotEntries: [".local"],
            versionProbe: .listing(
                ToolCommand(executable: pipx, arguments: ["list", "--short"]),
                noun: "application",
                matching: nil
            ),
            updateCommand: ToolCommand(executable: pipx, arguments: ["upgrade-all"])
        )]
    }

    private static func ghExtensions(_ env: ToolEnvironment) -> [DevTool] {
        let directory = env.home.appendingPathComponent(".local/share/gh/extensions")
        guard hasContents(directory), let gh = env.which("gh") else { return [] }
        return [DevTool(
            id: "gh-extensions",
            name: "GitHub CLI extensions",
            dotEntries: [".local"],
            versionProbe: .listing(
                ToolCommand(executable: gh, arguments: ["extension", "list"]),
                noun: "extension",
                matching: nil
            ),
            updateCommand: ToolCommand(executable: gh, arguments: ["extension", "upgrade", "--all"])
        )]
    }

    /// Vendor updaters that are not tied to a dot entry but update many apps at once.
    private static func systemUpdaters(_ env: ToolEnvironment) -> [DevTool] {
        var tools: [DevTool] = []

        if isExecutable(microsoftAutoUpdatePath) {
            tools.append(microsoftAutoUpdate())
        }

        if let mas = env.which("mas") {
            tools.append(DevTool(
                id: "mas",
                name: "Mac App Store",
                dotEntries: [],
                versionProbe: .listing(
                    ToolCommand(executable: mas, arguments: ["outdated"]),
                    noun: "pending update",
                    matching: nil
                ),
                updateCommand: ToolCommand(executable: mas, arguments: ["upgrade"]),
                updateTimeout: 2 * 60 * 60
            ))
        }

        return tools
    }

    /// Microsoft AutoUpdate, driven through its command-line tool.
    ///
    /// `msupdate --install` is not something to wait for: with nothing to install it can
    /// still sit in silence for ten minutes, the length of the updater's session, whatever
    /// `--wait` says. `--list` answers in about ten seconds. So Guava asks first, and when
    /// something is pending it starts the installation and moves on. The updater downloads
    /// and installs by itself and, since `--terminate` is not passed, leaves open apps alone
    /// until they are closed.
    static func microsoftAutoUpdate(msupdate: String = microsoftAutoUpdatePath) -> DevTool {
        let contents = ((msupdate as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        return DevTool(
            id: microsoftAutoUpdateID,
            name: "Microsoft AutoUpdate",
            dotEntries: [],
            versionProbe: .command(ToolCommand(
                executable: "/usr/bin/defaults",
                arguments: ["read", contents + "/Info", "CFBundleShortVersionString"]
            )),
            updateCommand: ToolCommand(executable: msupdate, arguments: ["--install"]),
            updateTimeout: 60,
            pendingCheck: PendingCheck(
                command: ToolCommand(executable: msupdate, arguments: ["--list"]),
                nothingPendingMarker: "No updates available"
            ),
            finishesInBackground: true,
            backgroundNote: "Installing in the background; open Microsoft apps are updated once you close them"
        )
    }

    // MARK: - Helpers

    private static func gitPath(_ env: ToolEnvironment) -> String? {
        firstExecutable(env.includesSystemLocations ? ["/usr/bin/git"] : [], env, name: "git")
    }

    private static func gitRevisionProbe(_ repository: URL, _ env: ToolEnvironment) -> VersionProbe {
        guard let git = gitPath(env) else { return .none }
        return .command(ToolCommand(
            executable: git,
            arguments: ["-C", repository.path, "rev-parse", "--short", "HEAD"]
        ))
    }

    private static func firstExecutable(_ candidates: [String], _ env: ToolEnvironment, name: String) -> String? {
        candidates.first(where: isExecutable) ?? env.which(name)
    }

    private static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private static func isExecutable(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }

    private static func hasContents(_ directory: URL) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.contains { !$0.hasPrefix(".") }
    }
}

/// Reads versions and runs the updaters of detected tools.
enum DevToolUpdater {

    static func version(of tool: DevTool, environment: ToolEnvironment = .current) async -> ToolVersion? {
        switch tool.versionProbe {
        case .none:
            return nil
        case .command(let command):
            let result = await run(command, environment: environment, timeout: 60)
            guard result.success else { return nil }
            let output = result.stdout.isEmpty ? result.stderr : result.stdout
            guard let version = extractVersion(from: output) else { return nil }
            return ToolVersion(display: version, fingerprint: version)
        case .listing(let command, let noun, let matching):
            let result = await run(command, environment: environment, timeout: 120)
            guard result.success else { return nil }
            let lines = result.stdout
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { line in
                    guard !line.isEmpty else { return false }
                    guard let matching else { return true }
                    return line.contains(matching)
                }
            let display = "\(lines.count) \(noun)\(lines.count == 1 ? "" : "s")"
            return ToolVersion(display: display, fingerprint: lines.sorted().joined(separator: "\n"))
        }
    }

    static func update(
        _ tool: DevTool,
        environment: ToolEnvironment = .current,
        onLine: ProcessRunner.LineHandler? = nil
    ) async -> ToolUpdateOutcome {
        if let check = tool.pendingCheck {
            // Not sent to the log: such a tool redraws one status line in place, which reads as
            // noise there. What it found is reported through the outcome instead.
            let result = await run(check.command, environment: environment, timeout: check.timeout)
            guard result.success else {
                return .failed(readable(result.failureMessage))
            }
            if (result.stdout + result.stderr).contains(check.nothingPendingMarker) {
                return .alreadyCurrent(nil)
            }
        }

        if tool.finishesInBackground {
            let started = await startDetached(tool.updateCommand, environment: environment, timeout: tool.updateTimeout)
            return started.success ? .runningInBackground : .failed(readable(started.failureMessage))
        }

        let before = await version(of: tool, environment: environment)
        let result = await run(
            tool.updateCommand,
            environment: environment,
            timeout: tool.updateTimeout,
            onLine: onLine
        )
        guard result.success else {
            return .failed(readable(result.failureMessage))
        }
        let after = await version(of: tool, environment: environment)

        guard let after else {
            // A tool that answered before its update and does not answer after it has been
            // left unusable by that update. Saying "its updater ran" would hide that.
            return before == nil
                ? .triggered
                : .failed("Its updater finished, but the tool no longer runs when asked for its version")
        }
        guard let before else { return .updated(from: nil, to: after.display) }
        if before.fingerprint == after.fingerprint {
            return .alreadyCurrent(after.display)
        }
        // A listing keeps the same count when only versions inside it changed.
        return before.display == after.display
            ? .updated(from: nil, to: after.display)
            : .updated(from: before.display, to: after.display)
    }

    /// Start a command and leave it running by itself.
    ///
    /// The shell puts it in the background with nothing attached and returns at once, so the
    /// command no longer depends on Guava: it is not waited for, and it carries on if the run is
    /// stopped or Guava quits.
    private static func startDetached(
        _ command: ToolCommand,
        environment: ToolEnvironment,
        timeout: TimeInterval
    ) async -> ProcessResult {
        guard FileManager.default.isExecutableFile(atPath: command.executable) else {
            return ProcessResult(
                exitCode: -1, stdout: "", stderr: "", timedOut: false, wasCancelled: false,
                launchError: "Could not run \(command.executable): it is not there"
            )
        }
        return await run(
            ToolCommand(
                executable: "/bin/sh",
                arguments: ["-c", #""$@" </dev/null >/dev/null 2>&1 &"#, "sh", command.executable] + command.arguments,
                environment: command.environment
            ),
            environment: environment,
            timeout: timeout
        )
    }

    /// A failure message without the escape codes and carriage returns of a redrawn status line.
    private static func readable(_ message: String) -> String {
        message.strippingANSI
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The first token that looks like a version number, or the first line when none does
    /// (a git revision, for example).
    static func extractVersion(from output: String) -> String? {
        guard let firstLine = output
            .split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }) else {
            return nil
        }
        if let range = firstLine.range(
            of: #"\d+(\.\d+)+([-+][0-9A-Za-z][0-9A-Za-z.-]*)?"#,
            options: .regularExpression
        ) {
            var version = String(firstLine[range])
            while let last = version.last, last == "." || last == "-" {
                version.removeLast()
            }
            return version
        }
        return String(firstLine.prefix(40))
    }

    private static func run(
        _ command: ToolCommand,
        environment: ToolEnvironment,
        timeout: TimeInterval,
        onLine: ProcessRunner.LineHandler? = nil
    ) async -> ProcessResult {
        var processEnvironment = environment.environment
        processEnvironment.merge(command.environment) { _, new in new }
        return await ProcessRunner.run(
            command.executable,
            command.arguments,
            environment: processEnvironment,
            currentDirectory: environment.home,
            timeout: timeout,
            onLine: onLine
        )
    }
}

/// Reads which applications Microsoft AutoUpdate keeps up to date.
enum MicrosoftAutoUpdate {

    /// Paths of the applications registered with Microsoft AutoUpdate, or an empty set when
    /// it is not installed.
    static func managedApplicationPaths() async -> Set<String> {
        let path = DevToolScanner.microsoftAutoUpdatePath
        guard FileManager.default.isExecutableFile(atPath: path) else { return [] }
        let result = await ProcessRunner.run(path, ["--config", "--format", "plist"], timeout: 60)
        guard result.success else { return [] }
        return Set(parseRegisteredApplications(from: result.stdout))
    }

    /// `msupdate` wraps its property list in progress text, so the plist is cut out first.
    static func parseRegisteredApplications(from output: String) -> [String] {
        guard let start = output.range(of: "<?xml"),
              let end = output.range(of: "</plist>", options: .backwards),
              start.lowerBound < end.upperBound,
              let data = String(output[start.lowerBound..<end.upperBound]).data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let registered = plist["RegisteredApplications"] as? [String: Any] else {
            return []
        }
        return registered.keys.sorted()
    }
}
