import AppKit
import Foundation

/// What a staged application was verified to be. The install step compares its own private
/// copy with this, so changing the staged bundle after it was checked achieves nothing.
struct BundleIdentity: Equatable, Sendable {
    var bundleIdentifier: String?
    /// `CFBundleShortVersionString`, or `CFBundleVersion` when the bundle has no short version.
    var version: String?
}

/// One installation step, run either as the current user or with administrator rights.
enum InstallOperation: Equatable, Sendable {
    /// Replace the application at `destination` with the bundle at `staged`.
    /// `owner` is a numeric `uid:gid` to restore on the new bundle, or nil to leave it as copied.
    case replaceApp(
        staged: String, destination: String, owner: String?, teamIdentifier: String?,
        requireGatekeeper: Bool, identity: BundleIdentity? = nil
    )
    /// Run an installer package. Always needs administrator rights.
    case installPackage(path: String, teamIdentifier: String?, requireGatekeeper: Bool)
}

enum InstallOutcome: Equatable, Sendable {
    /// `note` carries a non-fatal remark, such as a leftover copy that could not be removed.
    case installed(note: String?)
    case failed(String)
    /// The administrator prompt was dismissed or never answered.
    case notAuthorized

    var isInstalled: Bool {
        if case .installed = self { return true }
        return false
    }
}

enum InstallRoute: Equatable, Sendable {
    case user
    case administrator
}

/// Builds the shell script that performs installations.
///
/// The same functions run for both routes. Each copies the payload into a private temporary
/// folder and verifies *that copy* before using it, so when the script runs as root nothing a
/// user-level process does to the staging folder afterwards can change what gets installed.
///
/// The copy is finished, ownership included, before it is moved into place, and the installed
/// bundle is only ever renamed or deleted whole, never written into. macOS (App Management)
/// stops one developer's code from writing inside another developer's installed app unless
/// the user allows it.
///
/// A Stop or a timeout ends the script wherever it is, except during the swap itself, and the
/// private copy is deleted on the way out.
enum InstallScript {

    static let resultMarker = "GUAVA_RESULT"

    static let functions = """
    work=
    guava_interrupted() {
      if [ -n "$work" ]; then /bin/rm -rf "$work"; fi
      exit 143
    }
    trap 'guava_interrupted' HUP INT TERM
    guava_plist_value() {
      /usr/bin/plutil -extract "$2" raw -o - "$1" 2>/dev/null
    }
    guava_replace_app() {
      staged=$1; dest=$2; owner=$3; requirement=$4; gatekeeper=$5; identifier=$6; version=$7
      name=$(/usr/bin/basename "$dest")
      old="$dest.guava-old"
      work=$(/usr/bin/mktemp -d /private/tmp/guava-install.XXXXXXXX) || return 70
      copy="$work/$name"
      /usr/bin/ditto "$staged" "$copy" || { /bin/rm -rf "$work"; return 71; }
      info="$copy/Contents/Info.plist"
      if [ -n "$identifier" ] && [ "$(guava_plist_value "$info" CFBundleIdentifier)" != "$identifier" ]; then
        /bin/rm -rf "$work"; return 77
      fi
      if [ -n "$version" ]; then
        found=$(guava_plist_value "$info" CFBundleShortVersionString) || found=$(guava_plist_value "$info" CFBundleVersion)
        if [ "$found" != "$version" ]; then /bin/rm -rf "$work"; return 77; fi
      fi
      if [ -n "$requirement" ]; then
        /usr/bin/codesign --verify --deep --strict -R "$requirement" "$copy" || { /bin/rm -rf "$work"; return 72; }
      else
        /usr/bin/codesign --verify --deep --strict "$copy" || { /bin/rm -rf "$work"; return 72; }
      fi
      if [ "$gatekeeper" = 1 ]; then
        /usr/sbin/spctl --assess --type execute "$copy" || { /bin/rm -rf "$work"; return 73; }
      fi
      if [ -n "$owner" ]; then /usr/sbin/chown -hR "$owner" "$copy" 2>/dev/null; fi
      /bin/rm -rf "$old"
      if [ -e "$old" ] || [ -L "$old" ]; then /bin/rm -rf "$work"; return 74; fi
      # From the first move until the previous copy is gone, a Stop or a timeout must not end
      # the script: in between, the app exists only under its temporary name.
      trap '' HUP INT TERM PIPE
      swap=0
      if [ -e "$dest" ] || [ -L "$dest" ]; then
        /bin/mv "$dest" "$old" || swap=74
      fi
      if [ "$swap" = 0 ]; then
        if [ -e "$dest" ] || [ -L "$dest" ]; then
          swap=75
        elif ! /bin/mv "$copy" "$dest"; then
          /bin/rm -rf "$dest"
          if [ -e "$old" ]; then /bin/mv "$old" "$dest"; fi
          swap=75
        fi
      fi
      if [ "$swap" = 0 ]; then /bin/rm -rf "$old"; fi
      /bin/rm -rf "$work"
      work=
      trap 'guava_interrupted' HUP INT TERM
      trap - PIPE
      if [ "$swap" != 0 ]; then return "$swap"; fi
      if [ -e "$old" ]; then return 76; fi
      return 0
    }
    guava_install_pkg() {
      pkg=$1; team=$2; gatekeeper=$3
      # A package runs its own scripts as root; without a developer to hold it to, it does not run.
      [ -n "$team" ] || return 72
      work=$(/usr/bin/mktemp -d /private/tmp/guava-install.XXXXXXXX) || return 70
      copy="$work/installer.pkg"
      /bin/cp "$pkg" "$copy" || { /bin/rm -rf "$work"; return 71; }
      signature=$(/usr/sbin/pkgutil --check-signature "$copy" 2>&1) || { /bin/rm -rf "$work"; return 72; }
      case "$signature" in
        *"($team)"*) ;;
        *) /bin/rm -rf "$work"; return 72 ;;
      esac
      if [ "$gatekeeper" = 1 ]; then
        /usr/sbin/spctl --assess --type install "$copy" || { /bin/rm -rf "$work"; return 73; }
      fi
      /usr/sbin/installer -pkg "$copy" -target /
      status=$?
      /bin/rm -rf "$work"
      work=
      if [ "$status" -ne 0 ]; then return 78; fi
      return 0
    }
    """

    static func script(for operations: [InstallOperation]) -> String {
        var lines = [functions]
        for (index, operation) in operations.enumerated() {
            let call: String
            switch operation {
            case .replaceApp(let staged, let destination, let owner, let team, let requireGatekeeper, let identity):
                let requirement = CodeSignVerifier.validatedTeamIdentifier(team)
                    .map(CodeSignVerifier.teamRequirement) ?? ""
                call = [
                    "guava_replace_app",
                    shellQuoted(staged),
                    shellQuoted(destination),
                    shellQuoted(validatedOwner(owner) ?? ""),
                    shellQuoted(requirement),
                    requireGatekeeper ? "1" : "0",
                    shellQuoted(identity?.bundleIdentifier ?? ""),
                    shellQuoted(identity?.version ?? ""),
                ].joined(separator: " ")
            case .installPackage(let path, let team, let requireGatekeeper):
                call = [
                    "guava_install_pkg",
                    shellQuoted(path),
                    shellQuoted(CodeSignVerifier.validatedTeamIdentifier(team) ?? ""),
                    requireGatekeeper ? "1" : "0",
                ].joined(separator: " ")
            }
            lines.append("\(call); echo \"\(resultMarker) \(index) $?\"")
        }
        return lines.joined(separator: "\n")
    }

    /// Exit status of each operation, by index. Nil when the script never reported one.
    static func parseResults(_ output: String, count: Int) -> [Int32?] {
        var statuses = [Int32?](repeating: nil, count: count)
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let fields = rawLine.split(separator: " ")
            guard fields.count == 3, fields[0] == resultMarker,
                  let index = Int(fields[1]), let status = Int32(fields[2]),
                  statuses.indices.contains(index) else { continue }
            statuses[index] = status
        }
        return statuses
    }

    static func outcome(forStatus status: Int32?) -> InstallOutcome {
        switch status {
        case 0: return .installed(note: nil)
        case 76: return .installed(note: "The previous copy could not be removed; it is next to the app, ending in .guava-old")
        case 70: return .failed("Could not create a temporary folder")
        case 71: return .failed("Could not copy the download")
        case 72: return .failed("The download failed its signature check")
        case 73: return .failed("Gatekeeper rejected the download")
        case 74: return .failed(
            "Could not move the installed version aside. If macOS blocked it, allow Guava under "
                + "System Settings → Privacy & Security → App Management and try again"
        )
        case 75: return .failed("Could not put the new version in place; the previous version was kept")
        case 77: return .failed("The download is no longer the application and version that were checked")
        case 78: return .failed("The installer package reported an error")
        case .some(let other): return .failed("Installation failed (status \(other))")
        case .none: return .failed("Installation did not run")
        }
    }

    static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    static func appleScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// AppleScript that runs `script` through `/bin/sh` and returns its output unchanged.
    static func appleScript(running script: String, prompt: String?, asAdministrator: Bool) -> String {
        var source = "do shell script \"\(appleScriptEscaped(script))\""
        if asAdministrator {
            if let prompt {
                source += " with prompt \"\(appleScriptEscaped(prompt))\""
            }
            source += " with administrator privileges"
        }
        return source + " without altering line endings"
    }

    /// Accepts only a numeric `uid:gid` pair.
    static func validatedOwner(_ owner: String?) -> String? {
        guard let owner else { return nil }
        let parts = owner.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) && $0.allSatisfy(\.isASCII) }) else {
            return nil
        }
        return owner
    }
}

/// Installs verified payloads.
enum AppInstaller {

    /// Whether the current user can replace the bundle at `path` without administrator rights.
    static func route(forDestination path: String, currentUser: uid_t = getuid()) -> InstallRoute {
        let fileManager = FileManager.default
        let parent = (path as NSString).deletingLastPathComponent
        guard fileManager.isWritableFile(atPath: parent) else { return .administrator }
        guard let attributes = try? fileManager.attributesOfItem(atPath: path),
              let owner = attributes[.ownerAccountID] as? NSNumber else {
            return .user
        }
        return owner.uint32Value == currentUser ? .user : .administrator
    }

    /// The numeric `uid:gid` that owns `path`.
    static func ownerSpecification(of path: String) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let owner = attributes[.ownerAccountID] as? NSNumber,
              let group = attributes[.groupOwnerAccountID] as? NSNumber else {
            return nil
        }
        return "\(owner.uint32Value):\(group.uint32Value)"
    }

    /// Run the operations in order and report one outcome per operation.
    ///
    /// With `asAdministrator`, macOS shows a single authentication prompt for the whole batch.
    static func run(
        _ operations: [InstallOperation],
        asAdministrator: Bool,
        prompt: String? = nil,
        timeout: TimeInterval = 30 * 60
    ) async -> [InstallOutcome] {
        guard !operations.isEmpty else { return [] }
        let script = InstallScript.script(for: operations)

        let result: ProcessResult
        if asAdministrator {
            let source = InstallScript.appleScript(running: script, prompt: prompt, asAdministrator: true)
            result = await ProcessRunner.run("/usr/bin/osascript", ["-e", source], timeout: timeout)
            if !result.success {
                // AppleScript hands back the script's output only when it succeeds, so there is
                // nothing to tell the operations apart by.
                let outcome: InstallOutcome
                if result.timedOut {
                    outcome = .failed(
                        "Not finished in time: the administrator prompt went unanswered, or installing took too long"
                    )
                } else if result.wasCancelled || result.stderr.contains("-128") {
                    outcome = .notAuthorized
                } else {
                    outcome = .failed(result.failureMessage)
                }
                return [InstallOutcome](repeating: outcome, count: operations.count)
            }
        } else {
            result = await ProcessRunner.run("/bin/sh", ["-c", script], timeout: timeout)
        }

        return InstallScript.parseResults(result.stdout, count: operations.count).map { status in
            if status == nil, result.timedOut {
                return .failed("The installation did not finish in time")
            }
            return InstallScript.outcome(forStatus: status)
        }
    }
}

/// Finds, quits and relaunches running copies of an application.
enum RunningApps {

    enum QuitResult: Equatable, Sendable {
        case notRunning
        case quit
        /// The app is still running, for example because it is waiting on unsaved changes.
        case refused
    }

    /// Running instances whose bundle is at `path`.
    static func instances(bundleIdentifier: String?, path: String) -> [NSRunningApplication] {
        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let candidates = bundleIdentifier.map(NSRunningApplication.runningApplications(withBundleIdentifier:))
            ?? NSWorkspace.shared.runningApplications
        return candidates.filter {
            !$0.isTerminated && $0.bundleURL?.resolvingSymlinksInPath().path == target
        }
    }

    static func isRunning(bundleIdentifier: String?, path: String) -> Bool {
        !instances(bundleIdentifier: bundleIdentifier, path: path).isEmpty
    }

    /// Ask the app to quit the normal way and wait for it. Never force-quits.
    static func quit(bundleIdentifier: String?, path: String, timeout: TimeInterval = 20) async -> QuitResult {
        let running = instances(bundleIdentifier: bundleIdentifier, path: path)
        guard !running.isEmpty else { return .notRunning }

        let processIdentifiers = running.map(\.processIdentifier)
        for app in running {
            app.terminate()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if processIdentifiers.allSatisfy({ !processExists($0) }) {
                return .quit
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { break }
        }
        return processIdentifiers.allSatisfy { !processExists($0) } ? .quit : .refused
    }

    /// Open the app again without bringing it to the front.
    static func launch(path: String) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: path), configuration: configuration, completionHandler: nil
        )
    }

    private static func processExists(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
