import Foundation

/// Shared utility for running Homebrew commands
enum BrewHelper {

    struct InstalledPackage: Equatable {
        let token: String
        let kind: BrewPackageKind
        let installedVersion: String
        let latestVersion: String
        let isPinned: Bool
        let hasUpdate: Bool
        let needsRepair: Bool
        /// False for formulae that were only pulled in as dependencies.
        var installedOnRequest: Bool = true
    }

    private struct InstalledResponse: Decodable {
        let formulae: [Formula]?
        let casks: [Cask]?

        struct Formula: Decodable {
            let name: String
            let versions: Versions?
            let revision: Int?
            let installed: [Installed]?
            let outdated: Bool?
            let pinned: Bool?

            struct Versions: Decodable {
                let stable: String?
            }

            struct Installed: Decodable {
                let version: String?
                let installedOnRequest: Bool?

                enum CodingKeys: String, CodingKey {
                    case version
                    case installedOnRequest = "installed_on_request"
                }
            }
        }

        struct Cask: Decodable {
            let token: String
            let installed: String?
            let version: String
            let pinned: Bool?
            let outdated: Bool?
        }
    }

    /// Keeps Homebrew's output free of hints when Guava drives it.
    private static let quietEnvironment = [
        "HOMEBREW_NO_ENV_HINTS": "1",
    ]

    /// Locate the brew executable
    static var brewPath: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .first { FileManager.default.fileExists(atPath: $0) }
    }
    
    /// Run a Homebrew command and return stdout
    static func run(_ arguments: [String]) async -> String {
        let result = await runWithOutput(arguments)
        return result.success ? result.output : ""
    }

    /// Run a Homebrew command and capture stdout and stderr.
    ///
    /// Nothing is cut from the output: these answers are parsed whole, and the JSON describing
    /// several hundred installed packages runs to megabytes.
    static func runWithOutput(_ arguments: [String]) async -> (success: Bool, output: String, error: String) {
        let result = await runProcess(arguments, captureLimit: ProcessRunner.unlimitedCapture)
        if let launchError = result.launchError {
            return (false, "", launchError)
        }
        return (result.success, result.stdout, result.stderr)
    }

    /// Run a Homebrew command with a timeout and optional live output.
    static func runProcess(
        _ arguments: [String],
        timeout: TimeInterval? = nil,
        environment extra: [String: String] = [:],
        captureLimit: Int = ProcessRunner.defaultCaptureLimit,
        onLine: ProcessRunner.LineHandler? = nil
    ) async -> ProcessResult {
        guard let path = brewPath else {
            return ProcessResult(
                exitCode: -1, stdout: "", stderr: "", timedOut: false, wasCancelled: false,
                launchError: "Homebrew not found"
            )
        }
        var environment = ToolEnvironment.current.environment
        environment.merge(quietEnvironment) { _, new in new }
        environment.merge(extra) { _, new in new }
        return await ProcessRunner.run(
            path, arguments, environment: environment, timeout: timeout,
            captureLimit: captureLimit, onLine: onLine
        )
    }

    /// Refresh Homebrew and its package definitions.
    static func update(onLine: ProcessRunner.LineHandler? = nil) async -> ProcessResult {
        await runProcess(["update"], timeout: 10 * 60, onLine: onLine)
    }

    /// Upgrade every outdated, unpinned formula and cask in one pass.
    static func upgradeAll(onLine: ProcessRunner.LineHandler? = nil) async -> ProcessResult {
        await runProcess(
            ["upgrade"],
            timeout: 2 * 60 * 60,
            environment: ["HOMEBREW_NO_AUTO_UPDATE": "1"],
            onLine: onLine
        )
    }

    /// Delete old versions and every cached download, including those for current versions.
    static func cleanup(onLine: ProcessRunner.LineHandler? = nil) async -> ProcessResult {
        await runProcess(["cleanup", "--prune=all", "-s"], timeout: 15 * 60, onLine: onLine)
    }

    /// The space `brew cleanup` reports having freed, in bytes.
    ///
    /// It prints a line such as "This operation has freed approximately 939.2MB of disk space."
    static func parseFreedBytes(from output: String) -> Int64? {
        guard let marker = output.range(of: "freed approximately ") else { return nil }
        let token = output[marker.upperBound...].prefix { !$0.isWhitespace }
        let number = token.prefix { $0.isNumber || $0 == "." }
        let unit = token.dropFirst(number.count).uppercased()
        let multipliers: [String: Double] = [
            "B": 1, "KB": 1024, "MB": 1_048_576, "GB": 1_073_741_824, "TB": 1_099_511_627_776,
        ]
        guard let value = Double(number), let multiplier = multipliers[unit] else { return nil }
        return Int64(value * multiplier)
    }

    /// Homebrew's download cache directory.
    static func cacheDirectory() async -> URL? {
        let result = await runProcess(["--cache"], timeout: 60)
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.success, path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Run a Homebrew command and return (success, stderr)
    static func runWithStatus(_ arguments: [String]) async -> (success: Bool, error: String) {
        let result = await runWithOutput(arguments)
        return (result.success, result.error)
    }

    /// Decode `brew info --json=v2 --installed` into formulae and casks.
    static func parseInstalled(json data: Data) throws -> [InstalledPackage] {
        let response = try JSONDecoder().decode(InstalledResponse.self, from: data)

        let formulae = (response.formulae ?? []).map { formula -> InstalledPackage in
            let newest = formula.installed?.last
            // Homebrew writes a rebuilt formula as "1.2.3_1"; without the suffix an outdated
            // package can appear to have the same version installed and available.
            var stable = formula.versions?.stable
            if let version = stable, let revision = formula.revision, revision > 0 {
                stable = "\(version)_\(revision)"
            }
            return InstalledPackage(
                token: formula.name,
                kind: .formula,
                installedVersion: newest?.version ?? "Unknown",
                latestVersion: stable ?? newest?.version ?? "Unknown",
                isPinned: formula.pinned ?? false,
                hasUpdate: formula.outdated ?? false,
                needsRepair: false,
                installedOnRequest: formula.installed?.contains { $0.installedOnRequest == true } ?? false
            )
        }

        let casks = (response.casks ?? []).map {
            InstalledPackage(
                token: $0.token,
                kind: .cask,
                installedVersion: $0.installed ?? "Unknown",
                latestVersion: $0.version,
                isPinned: $0.pinned ?? false,
                hasUpdate: $0.outdated ?? false,
                needsRepair: $0.installed == nil
            )
        }

        return formulae + casks
    }

    /// Return Homebrew itself and every installed formula and cask.
    static func installedPackages() async -> (packages: [InstalledPackage], error: String?) {
        var packages: [InstalledPackage] = []

        let versionResult = await runWithOutput(["--version"])
        if versionResult.success,
           let versionLine = versionResult.output.components(separatedBy: .newlines).first {
            let version = versionLine.replacingOccurrences(of: "Homebrew ", with: "")
            packages.append(
                InstalledPackage(
                    token: "Homebrew",
                    kind: .homebrew,
                    installedVersion: version,
                    latestVersion: version,
                    isPinned: false,
                    hasUpdate: false,
                    needsRepair: false
                )
            )
        }

        let result = await runWithOutput(["info", "--json=v2", "--installed"])
        guard result.success else {
            let message = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
            return (packages, message.isEmpty ? "Unable to load installed Homebrew packages" : message)
        }

        guard let data = result.output.data(using: .utf8) else {
            return (packages, "Homebrew returned invalid package information")
        }

        do {
            packages.append(contentsOf: try parseInstalled(json: data))
        } catch {
            return (packages, "Unable to read installed Homebrew packages: \(error.localizedDescription)")
        }

        let kindOrder: [BrewPackageKind: Int] = [.homebrew: 0, .cask: 1, .formula: 2]
        return (
            packages.sorted {
                let leftOrder = kindOrder[$0.kind] ?? 3
                let rightOrder = kindOrder[$1.kind] ?? 3
                return leftOrder == rightOrder
                    ? $0.token.localizedCaseInsensitiveCompare($1.token) == .orderedAscending
                    : leftOrder < rightOrder
            },
            nil
        )
    }

    static func requiresInteractiveAuthentication(_ error: String) -> Bool {
        let message = error.lowercased()
        return [
            "sudo",
            "password",
            "authentication",
            "authorization",
            "not logged in",
            "credentials",
            "a terminal is required",
            "tty",
        ].contains { message.contains($0) }
    }
}
