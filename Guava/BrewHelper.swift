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
        /// For a formula: whether its files are linked into Homebrew's prefix, which is what
        /// puts its commands on the PATH.
        var isLinked: Bool = true
        /// True for a formula that is meant to be linked and is not. Formulae that Homebrew
        /// never links ("keg-only") do not count.
        var isMissingLinks: Bool = false
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
            let linkedKeg: String?
            let kegOnly: Bool?

            enum CodingKeys: String, CodingKey {
                case name, versions, revision, installed, outdated, pinned
                case linkedKeg = "linked_keg"
                case kegOnly = "keg_only"
            }

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

    /// The old versions `brew cleanup` says it could not delete.
    ///
    /// It ends with "Could not cleanup old kegs! Fix your permissions on:" and then one folder
    /// to a line.
    static func parseUnremovableKegs(_ output: String) -> [String] {
        var paths: [String] = []
        var isListing = false
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.contains("Could not cleanup old kegs") {
                isListing = true
            } else if isListing, line.hasPrefix("/") {
                paths.append(line)
            } else {
                isListing = false
            }
        }
        return paths
    }

    /// Whether `path` is an old version of a formula that can be moved out of Homebrew's way:
    /// a folder of the user's own, exactly two levels into the Cellar, of a formula whose
    /// version in use is another one.
    static func isSupersededKeg(_ path: String, prefix: URL) -> Bool {
        let components = (path as NSString).pathComponents
        guard components.count > 2 else { return false }
        let (formula, version) = (components[components.count - 2], components[components.count - 1])
        // Where the path really leads has to be that version's own folder in the Cellar. A
        // path with ".." in it, or one that is a link, names something else altogether.
        guard let cellar = resolve(prefix.appendingPathComponent("Cellar").path).path,
              let keg = resolve(path).path,
              keg == "\(cellar)/\(formula)/\(version)",
              let attributes = try? FileManager.default.attributesOfItem(atPath: keg),
              attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { return false }
        // "opt/<formula>" leads to the version in use.
        let inUse = prefix.appendingPathComponent("opt").appendingPathComponent(formula).path
        guard let current = resolve(inUse).path else { return false }
        return current != keg
    }

    /// Moves the old versions that Homebrew could not delete to the Trash, and returns those
    /// it moved.
    ///
    /// Homebrew deletes an old version file by file, and cannot once some of the files in it
    /// belong to another user, as they do after a formula's Python has been run with `sudo`.
    /// It then says so at the end of every cleanup. The folder itself is still the user's, so
    /// it can be moved away whole.
    static func trashUnremovableKegs(_ paths: [String], prefix: URL) -> [String] {
        paths.filter { path in
            isSupersededKeg(path, prefix: prefix)
                && (try? FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)) != nil
        }
    }

    /// Homebrew's download cache directory.
    static func cacheDirectory() async -> URL? {
        let result = await runProcess(["--cache"], timeout: 60)
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.success, path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    // MARK: - Links

    /// What became of an attempt to link a formula that was installed without its links.
    enum RelinkOutcome: Equatable {
        /// Linked. `replaced` names the stale links that had been in the way.
        case linked(replaced: [String])
        /// Files that are not the formula's to remove are where its links belong.
        case blocked(String)
        /// Nothing is in the way, so the formula is taken to be unlinked on purpose.
        case leftAlone
    }

    /// The folder Homebrew links its packages into.
    static func prefix() async -> URL? {
        let result = await runProcess(["--prefix"], timeout: 60)
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.success, path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Links a formula that is installed but not linked.
    ///
    /// Homebrew gives up on linking a formula when a file it did not put there is where one of
    /// the formula's links belongs, and the formula's commands then drop off the PATH. This
    /// happens to `node` once npm has reinstalled itself, because npm's own `bin/npm` link is
    /// then in the way. A link in the way is removed here only when nothing is lost by it: it
    /// leads nowhere, or to the very file the formula's own link leads to. Anything else is
    /// left where it is.
    ///
    /// - Parameter wasLinked: true when the formula was linked until the upgrade just made.
    ///   Only then is it linked when nothing at all is in the way; otherwise someone may have
    ///   unlinked it on purpose.
    static func relink(
        _ formula: String,
        wasLinked: Bool,
        onLine: ProcessRunner.LineHandler? = nil
    ) async -> RelinkOutcome {
        // Nothing is started once the run has been stopped.
        guard !Task.isCancelled else { return .leftAlone }
        var failure = "Homebrew could not link it"
        if wasLinked {
            let attempt = await runProcess(["link", formula], timeout: 5 * 60, onLine: onLine)
            if attempt.success { return .linked(replaced: []) }
            failure = attempt.failureMessage
        }

        // Homebrew lists what it would have to remove without touching anything.
        let listing = await runProcess(["link", "--overwrite", "--dry-run", formula], timeout: 5 * 60)
        let conflicts = listing.success ? parseLinkConflicts(listing.stdout) : []
        guard !conflicts.isEmpty else {
            return wasLinked ? .blocked(failure) : .leftAlone
        }
        guard let prefix = await prefix() else { return .blocked(failure) }
        let stale = staleLinks(among: conflicts, prefix: prefix, formula: formula)
        guard stale.count == conflicts.count else {
            let others = conflicts.filter { !stale.contains($0) }
            let shown = others.prefix(3).joined(separator: ", ")
            return .blocked("in the way: " + (others.count > 3 ? "\(shown) and \(others.count - 3) more" : shown))
        }
        guard !Task.isCancelled else { return .leftAlone }

        // Once a link has been taken away, a Stop must not come between that and Homebrew
        // putting its own in its place, so this part runs to its end whatever happens.
        return await Task {
            var removed: [(path: String, destination: String)] = []
            for path in stale {
                // `unlink` removes a link or a file and nothing else: never a folder.
                guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path),
                      unlink(path) == 0 else { continue }
                removed.append((path, destination))
                onLine?("Removed the stale link \(path)", .stdout)
            }

            let attempt = await runProcess(["link", formula], timeout: 5 * 60, onLine: onLine)
            if attempt.success { return .linked(replaced: removed.map(\.path)) }

            // Those links still led somewhere, so they go back where they were.
            for link in removed where (try? FileManager.default.attributesOfItem(atPath: link.path)) == nil {
                try? FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: link.destination)
            }
            return .blocked(attempt.failureMessage)
        }.value
    }

    /// The paths `brew link --overwrite --dry-run` says it would remove.
    ///
    /// It prints them under "Would remove:", one to a line, a symbolic link followed by
    /// " -> " and where it leads.
    static func parseLinkConflicts(_ output: String) -> [String] {
        var paths: [String] = []
        var isListing = false
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Would remove:") {
                isListing = true
            } else if isListing, line.hasPrefix("/") {
                paths.append(line.components(separatedBy: " -> ").first ?? line)
            } else {
                isListing = false
            }
        }
        return paths
    }

    /// The paths among `conflicts` that are symbolic links nothing would miss: each leads
    /// nowhere, or to the same file as the formula's own entry at that place.
    static func staleLinks(among conflicts: [String], prefix: URL, formula: String) -> [String] {
        let keg = prefix.appendingPathComponent("opt").appendingPathComponent(formula)
        let root = prefix.path.hasSuffix("/") ? prefix.path : prefix.path + "/"
        return conflicts.filter { path in
            guard path.hasPrefix(root),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  attributes[.type] as? FileAttributeType == .typeSymbolicLink else { return false }
            let destination = resolve(path)
            // A link that cannot be followed for another reason may well lead somewhere.
            guard let target = destination.path else { return destination.leadsNowhere }
            let own = keg.appendingPathComponent(String(path.dropFirst(root.count))).path
            return resolve(own).path == target
        }
    }

    /// Where a path leads once every symbolic link on the way is followed, and whether it
    /// leads to something that is not there.
    private static func resolve(_ path: String) -> (path: String?, leadsNowhere: Bool) {
        path.withCString { pointer in
            guard let resolved = realpath(pointer, nil) else { return (nil, errno == ENOENT) }
            defer { free(resolved) }
            return (String(cString: resolved), false)
        }
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
            let isLinked = formula.linkedKeg != nil
            return InstalledPackage(
                token: formula.name,
                kind: .formula,
                installedVersion: newest?.version ?? "Unknown",
                latestVersion: stable ?? newest?.version ?? "Unknown",
                isPinned: formula.pinned ?? false,
                hasUpdate: formula.outdated ?? false,
                needsRepair: false,
                installedOnRequest: formula.installed?.contains { $0.installedOnRequest == true } ?? false,
                isLinked: isLinked,
                // Only when Homebrew says outright that the formula is one it links.
                isMissingLinks: !isLinked && formula.kegOnly == false && newest != nil
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
