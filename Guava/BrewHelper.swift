import Foundation

/// Shared utility for running Homebrew commands
enum BrewHelper {

    private final class OutputBuffer: @unchecked Sendable {
        var data = Data()
    }

    struct InstalledPackage {
        let token: String
        let kind: BrewPackageKind
        let installedVersion: String
        let latestVersion: String
        let isPinned: Bool
        let hasUpdate: Bool
        let needsRepair: Bool
    }

    private struct InstalledResponse: Decodable {
        let casks: [Cask]

        struct Cask: Decodable {
            let token: String
            let installed: String?
            let version: String
            let pinned: Bool
            let outdated: Bool
        }
    }

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
    static func runWithOutput(_ arguments: [String]) async -> (success: Bool, output: String, error: String) {
        guard let path = brewPath else {
            return (false, "", "Homebrew not found")
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let outPipe = Pipe()
                let errPipe = Pipe()

                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                process.standardOutput = outPipe
                process.standardError = errPipe

                do {
                    try process.run()

                    let readGroup = DispatchGroup()
                    let outputBuffer = OutputBuffer()
                    let errorBuffer = OutputBuffer()

                    readGroup.enter()
                    DispatchQueue.global(qos: .utility).async {
                        outputBuffer.data = outPipe.fileHandleForReading.readDataToEndOfFile()
                        readGroup.leave()
                    }

                    readGroup.enter()
                    DispatchQueue.global(qos: .utility).async {
                        errorBuffer.data = errPipe.fileHandleForReading.readDataToEndOfFile()
                        readGroup.leave()
                    }

                    process.waitUntilExit()
                    readGroup.wait()
                    let output = String(
                        data: outputBuffer.data,
                        encoding: .utf8
                    ) ?? ""
                    let error = String(
                        data: errorBuffer.data,
                        encoding: .utf8
                    ) ?? ""
                    continuation.resume(returning: (process.terminationStatus == 0, output, error))
                } catch {
                    continuation.resume(returning: (false, "", error.localizedDescription))
                }
            }
        }
    }

    /// Run a Homebrew command and return (success, stderr)
    static func runWithStatus(_ arguments: [String]) async -> (success: Bool, error: String) {
        let result = await runWithOutput(arguments)
        return (result.success, result.error)
    }

    /// Return Homebrew itself and all explicitly installed casks.
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

        let listResult = await runWithOutput(["list", "--cask"])
        guard listResult.success else {
            let message = listResult.error.trimmingCharacters(in: .whitespacesAndNewlines)
            return (packages, message.isEmpty ? "Unable to list installed Homebrew casks" : message)
        }

        let caskTokens = listResult.output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if !caskTokens.isEmpty {
            let result = await runWithOutput(["info", "--cask", "--json=v2"] + caskTokens)
            guard result.success else {
                let message = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
                return (packages, message.isEmpty ? "Unable to load installed Homebrew casks" : message)
            }

            guard let data = result.output.data(using: .utf8) else {
                return (packages, "Homebrew returned invalid cask information")
            }

            do {
                let response = try JSONDecoder().decode(InstalledResponse.self, from: data)
                packages.append(contentsOf: response.casks.map {
                    InstalledPackage(
                        token: $0.token,
                        kind: .cask,
                        installedVersion: $0.installed ?? "Unknown",
                        latestVersion: $0.version,
                        isPinned: $0.pinned,
                        hasUpdate: $0.outdated,
                        needsRepair: $0.installed == nil
                    )
                })
            } catch {
                return (packages, "Unable to read installed Homebrew casks: \(error.localizedDescription)")
            }
        }

        let kindOrder: [BrewPackageKind: Int] = [.homebrew: 0, .cask: 1]
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
            "az login",
            "azure login",
            "credentials",
            "a terminal is required",
            "tty",
        ].contains { message.contains($0) }
    }

    static func requiresAzureLogin(_ error: String) -> Bool {
        let message = error.lowercased()
        return message.contains("az login") ||
            message.contains("azure login") ||
            message.contains("azure authentication")
    }

    /// Open Terminal so Homebrew or Azure CLI can request credentials interactively.
    static func openInteractiveUpgrade(tokens: [String], kind: BrewPackageKind, includeAzureLogin: Bool, reinstall: Bool) {
        guard let path = brewPath, !tokens.isEmpty else { return }

        var upgradeArguments = [reinstall ? "reinstall" : "upgrade"]
        if kind == .cask {
            upgradeArguments.append("--cask")
        }
        upgradeArguments.append(contentsOf: tokens)
        let upgradeCommand = ([path] + upgradeArguments)
            .map(shellQuoted)
            .joined(separator: " ")
        let command = includeAzureLogin
            ? "az login && \(upgradeCommand)"
            : upgradeCommand
        let escapedCommand = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            do script "\(escapedCommand)"
        end tell
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }

    private static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
