import Foundation

/// What `codesign` reports about a signed bundle.
struct CodeSignature: Equatable, Sendable {
    let identifier: String?
    /// Validated Developer Team ID, or nil for ad-hoc, unsigned, and Apple platform code.
    let teamIdentifier: String?
    let authorities: [String]
    let isAdHoc: Bool
}

/// What `pkgutil --check-signature` reports about an installer package.
struct PackageSignature: Equatable, Sendable {
    /// True when Apple issued the signing certificate for distribution outside the App Store.
    let isDeveloperSigned: Bool
    let isNotarized: Bool
    let teamIdentifier: String?
}

/// Who signed an installed application, as far as checking an update against it goes.
enum InstalledSignature: Equatable, Sendable {
    /// Signed by a developer team. An update has to come from the same team.
    case developer(String)
    /// Unsigned or ad-hoc signed: there is no developer to hold an update to.
    case noDeveloper
    /// `codesign` could not be asked, so nothing is known either way.
    case unreadable(String)
}

/// The identity a replacement must match before it may be installed.
struct ExpectedApp: Equatable, Sendable {
    let name: String
    let bundleIdentifier: String?
    let teamIdentifier: String?
    let installedVersion: String
}

struct VerificationPolicy: Equatable, Sendable {
    /// Require Gatekeeper to accept the payload (notarized Developer ID or App Store).
    var requireGatekeeper = true
    /// Require the staged version to be newer than the installed one.
    var requireNewerVersion = true

    static let strict = VerificationPolicy()
}

enum PayloadKind: String, Codable, Sendable {
    case app
    case pkg
}

struct VerifiedPayload: Equatable, Sendable {
    let url: URL
    let kind: PayloadKind
    /// Nil for installer packages, which only reveal their version once installed, and for a
    /// bundle that declares none.
    let version: String?
    let teamIdentifier: String?
    /// The bundle identifier the payload carries. Nil for installer packages.
    var bundleIdentifier: String? = nil
}

enum VerificationFailure: Error, Equatable, Sendable {
    case notAnAppBundle
    case notAPackage
    case unreadableInfo
    case bundleIdentifierMismatch(expected: String, found: String?)
    case notNewer(installed: String, staged: String)
    case wrongArchitecture
    case requiresNewerSystem(required: String, host: String)
    case invalidSignature(String)
    case teamMismatch(expected: String, found: String?)
    case noDeveloperToCompare
    case gatekeeperRejected(String)

    var message: String {
        switch self {
        case .notAnAppBundle:
            return "The download is not an application bundle"
        case .notAPackage:
            return "The download is not an installer package"
        case .unreadableInfo:
            return "The application's Info.plist could not be read"
        case .bundleIdentifierMismatch(let expected, let found):
            return "Wrong application: expected \(expected), found \(found ?? "no bundle identifier")"
        case .notNewer(let installed, let staged):
            return "The download (\(staged)) is not newer than the installed version (\(installed))"
        case .wrongArchitecture:
            return "The download does not run on this Mac's processor"
        case .requiresNewerSystem(let required, let host):
            return "The download needs macOS \(required) or later, and this Mac runs \(host)"
        case .invalidSignature(let detail):
            return "The code signature is not valid: \(detail)"
        case .teamMismatch(let expected, let found):
            return "Signed by a different developer: expected team \(expected), found \(found ?? "none")"
        case .noDeveloperToCompare:
            return "The installed copy is not signed by an identified developer, "
                + "so there is nothing to check an installer package against"
        case .gatekeeperRejected(let detail):
            return "Gatekeeper rejected the download: \(detail)"
        }
    }
}

/// Wrappers around the system's code-signing tools.
enum CodeSignVerifier {

    enum AssessmentKind: String {
        case execute
        case install
    }

    /// Team IDs are ten upper-case letters or digits. Anything else is discarded so that a
    /// value read from a signature can never smuggle text into a requirement or a shell.
    static func validatedTeamIdentifier(_ value: String?) -> String? {
        guard let value, value.count == 10,
              value.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) else {
            return nil
        }
        return value
    }

    /// A code requirement that only code signed by `team` with an Apple-issued certificate meets.
    ///
    /// The certificate chain must lead to Apple and the signing certificate must belong to the
    /// team, so a self-signed copy that merely claims the same team does not pass. Mac App Store
    /// copies never satisfy it, because Apple signs those with its own certificate; that is fine
    /// here, since they are updated by the App Store and never reach this check.
    static func teamRequirement(_ team: String) -> String {
        "=anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }

    /// Parse the output of `codesign --display --verbose=2`.
    static func parseSignature(_ output: String) -> CodeSignature {
        var identifier: String?
        var team: String?
        var authorities: [String] = []
        var isAdHoc = false

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<separator])
            let value = String(line[line.index(after: separator)...])
            switch key {
            case "Identifier": identifier = value
            case "TeamIdentifier": team = validatedTeamIdentifier(value)
            case "Authority": authorities.append(value)
            case "Signature": if value == "adhoc" { isAdHoc = true }
            default: break
            }
        }

        return CodeSignature(
            identifier: identifier,
            teamIdentifier: team,
            authorities: authorities,
            isAdHoc: isAdHoc
        )
    }

    /// Parse the output of `pkgutil --check-signature`.
    static func parsePackageSignature(_ output: String) -> PackageSignature {
        let isDeveloperSigned = output.contains("signed by a developer certificate issued by Apple")
        let isNotarized = output.contains("Notarization: trusted by the Apple notary service")

        var team: String?
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // The leaf certificate is listed first: "1. Developer ID Installer: Name (TEAMID)".
            guard line.hasPrefix("1."), line.hasSuffix(")"),
                  let open = line.lastIndex(of: "(") else { continue }
            team = validatedTeamIdentifier(String(line[line.index(after: open)..<line.index(before: line.endIndex)]))
            break
        }

        return PackageSignature(isDeveloperSigned: isDeveloperSigned, isNotarized: isNotarized, teamIdentifier: team)
    }

    /// The signature of the code at `path`, or nil when it is not signed at all.
    static func signature(of path: String) async -> CodeSignature? {
        let result = await ProcessRunner.run(
            "/usr/bin/codesign", ["--display", "--verbose=2", path], timeout: 120
        )
        guard result.success else { return nil }
        return parseSignature(result.stderr + "\n" + result.stdout)
    }

    /// Who signed an installed application, told apart from not being able to find out.
    static func installedSignature(of path: String) async -> InstalledSignature {
        let result = await ProcessRunner.run(
            "/usr/bin/codesign", ["--display", "--verbose=2", path], timeout: 120
        )
        return interpretInstalledSignature(result)
    }

    static func interpretInstalledSignature(_ result: ProcessResult) -> InstalledSignature {
        let output = result.stderr + "\n" + result.stdout
        if result.success {
            return parseSignature(output).teamIdentifier.map(InstalledSignature.developer) ?? .noDeveloper
        }
        let ranToTheEnd = result.launchError == nil && !result.timedOut && !result.wasCancelled
        if ranToTheEnd, output.contains("code object is not signed at all") {
            return .noDeveloper
        }
        return .unreadable(result.failureMessage)
    }

    /// Check that the code on disk is intact and, optionally, that `team` signed it.
    static func verify(_ path: String, deep: Bool = true, teamIdentifier: String? = nil) async -> ProcessResult {
        var arguments = ["--verify", "--strict"]
        if deep { arguments.append("--deep") }
        if let team = validatedTeamIdentifier(teamIdentifier) {
            arguments += ["-R", teamRequirement(team)]
        }
        arguments.append(path)
        return await ProcessRunner.run("/usr/bin/codesign", arguments, timeout: 15 * 60)
    }

    /// Ask Gatekeeper whether it would let this app run or this package install.
    static func gatekeeperAssessment(_ path: String, kind: AssessmentKind) async -> (accepted: Bool, detail: String) {
        let result = await ProcessRunner.run(
            "/usr/sbin/spctl", ["--assess", "--type", kind.rawValue, "--verbose=4", path], timeout: 15 * 60
        )
        let detail = (result.stderr + "\n" + result.stdout)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { $0.replacingOccurrences(of: path + ": ", with: "") }
            .joined(separator: "; ")
        return (result.success, detail.isEmpty ? result.failureMessage : detail)
    }

    static func packageSignature(of path: String) async -> PackageSignature? {
        let result = await ProcessRunner.run(
            "/usr/sbin/pkgutil", ["--check-signature", path], timeout: 5 * 60
        )
        guard result.success else { return nil }
        return parsePackageSignature(result.stdout)
    }
}

/// Decides whether a staged download may replace an installed application.
enum PayloadVerifier {

    static func verifyApp(
        at url: URL,
        expected: ExpectedApp,
        policy: VerificationPolicy = .strict,
        hostArchitecture: String = HostPlatform.architecture,
        hostSystemVersion: String = HostPlatform.macOSVersionString
    ) async -> Result<VerifiedPayload, VerificationFailure> {
        guard url.pathExtension.lowercased() == "app", isRealDirectory(url) else {
            return .failure(.notAnAppBundle)
        }

        let plistURL = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return .failure(.unreadableInfo)
        }

        let stagedIdentifier = plist["CFBundleIdentifier"] as? String
        if let expectedIdentifier = expected.bundleIdentifier {
            guard let stagedIdentifier,
                  stagedIdentifier.caseInsensitiveCompare(expectedIdentifier) == .orderedSame else {
                return .failure(.bundleIdentifierMismatch(expected: expectedIdentifier, found: stagedIdentifier))
            }
        }

        let declaredVersion = (plist["CFBundleShortVersionString"] as? String)
            ?? (plist["CFBundleVersion"] as? String)
        let stagedVersion = declaredVersion ?? "Unknown"
        if policy.requireNewerVersion {
            let installed = VersionChecker.cleanVersion(expected.installedVersion)
            let staged = VersionChecker.cleanVersion(stagedVersion)
            guard VersionChecker.compareVersions(installed, staged) == .orderedAscending else {
                return .failure(.notNewer(installed: expected.installedVersion, staged: stagedVersion))
            }
        }

        guard runs(on: hostArchitecture, architectures: Bundle(url: url)?.executableArchitectures) else {
            return .failure(.wrongArchitecture)
        }

        // Replacing an app that works with a build this macOS refuses to open is not an update.
        if let minimum = (plist["LSMinimumSystemVersion"] as? String)?.trimmingCharacters(in: .whitespaces),
           !minimum.isEmpty,
           VersionChecker.compareVersions(hostSystemVersion, minimum) == .orderedAscending {
            return .failure(.requiresNewerSystem(required: minimum, host: hostSystemVersion))
        }

        let integrity = await CodeSignVerifier.verify(url.path)
        guard integrity.success else {
            return .failure(.invalidSignature(integrity.failureMessage))
        }

        let stagedTeam = await CodeSignVerifier.signature(of: url.path)?.teamIdentifier
        if let expectedTeam = CodeSignVerifier.validatedTeamIdentifier(expected.teamIdentifier) {
            let teamCheck = await CodeSignVerifier.verify(url.path, deep: false, teamIdentifier: expectedTeam)
            guard teamCheck.success else {
                return .failure(.teamMismatch(expected: expectedTeam, found: stagedTeam))
            }
        }

        if policy.requireGatekeeper {
            let assessment = await CodeSignVerifier.gatekeeperAssessment(url.path, kind: .execute)
            guard assessment.accepted else {
                return .failure(.gatekeeperRejected(assessment.detail))
            }
        }

        return .success(VerifiedPayload(
            url: url, kind: .app, version: declaredVersion, teamIdentifier: stagedTeam,
            bundleIdentifier: stagedIdentifier
        ))
    }

    static func verifyPackage(
        at url: URL,
        expected: ExpectedApp,
        policy: VerificationPolicy = .strict
    ) async -> Result<VerifiedPayload, VerificationFailure> {
        let fileExtension = url.pathExtension.lowercased()
        guard fileExtension == "pkg" || fileExtension == "mpkg", isRealFile(url) else {
            return .failure(.notAPackage)
        }

        // A package runs its own scripts as root and has no bundle identifier or version to
        // compare, so the developer is all that ties it to the installed application.
        guard let expectedTeam = CodeSignVerifier.validatedTeamIdentifier(expected.teamIdentifier) else {
            return .failure(.noDeveloperToCompare)
        }

        guard let signature = await CodeSignVerifier.packageSignature(of: url.path),
              signature.isDeveloperSigned else {
            return .failure(.invalidSignature("The package is not signed with a Developer ID"))
        }

        guard signature.teamIdentifier == expectedTeam else {
            return .failure(.teamMismatch(expected: expectedTeam, found: signature.teamIdentifier))
        }

        if policy.requireGatekeeper {
            let assessment = await CodeSignVerifier.gatekeeperAssessment(url.path, kind: .install)
            guard assessment.accepted else {
                return .failure(.gatekeeperRejected(assessment.detail))
            }
        }

        return .success(VerifiedPayload(url: url, kind: .pkg, version: nil, teamIdentifier: signature.teamIdentifier))
    }

    /// Whether code built for `architectures` runs on a Mac with `host` processors.
    /// Apple silicon runs Intel code through Rosetta; the reverse is impossible.
    static func runs(on host: String, architectures: [NSNumber]?) -> Bool {
        guard let architectures, !architectures.isEmpty else { return true }
        let values = Set(architectures.map(\.intValue))
        let hasIntel = values.contains(NSBundleExecutableArchitectureX86_64)
        let hasARM = values.contains(NSBundleExecutableArchitectureARM64)
        return host == "arm64" ? (hasARM || hasIntel) : hasIntel
    }

    private static func isRealDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func isRealFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }
}
