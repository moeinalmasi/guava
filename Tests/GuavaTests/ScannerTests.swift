import Foundation
import Testing
@testable import Guava

/// A fake home folder with scripted stand-ins for real tools.
private struct FakeHome {
    let scratch: TemporaryDirectory
    let environment: ToolEnvironment

    init() throws {
        scratch = try TemporaryDirectory("guava-home")
        try scratch.makeDirectory("bin")
        environment = ToolEnvironment(
            home: scratch.url,
            inherited: ["PATH": scratch.url.appendingPathComponent("bin").path],
            includeSystemLocations: false
        )
    }

    /// A tool that prints the version stored next to it and bumps it when asked to update.
    func addVersionedTool(at relativePath: String, version: String, updateArgument: String, newVersion: String) throws {
        let stateFile = scratch.url.appendingPathComponent(relativePath + ".version").path
        try scratch.write(version + "\n", to: relativePath + ".version")
        try scratch.write(
            """
            #!/bin/sh
            case "$1" in
              --version) /bin/cat '\(stateFile)' ;;
              \(updateArgument)) echo '\(newVersion)' > '\(stateFile)'; echo "updated" ;;
              *) exit 2 ;;
            esac
            """,
            to: relativePath,
            executable: true
        )
    }

    /// A `git` that reads and advances a REV file inside the repository it is pointed at.
    func addFakeGit() throws {
        try scratch.write(
            """
            #!/bin/sh
            [ "$1" = "-C" ] || exit 2
            repo=$2
            case "$3" in
              rev-parse) /bin/cat "$repo/REV" ;;
              pull) echo "b2c3d4e" > "$repo/REV" ;;
              *) exit 2 ;;
            esac
            """,
            to: "bin/git",
            executable: true
        )
    }
}

@Suite("Dotfile scan")
struct DotfileScanTests {

    @Test("lists every top-level dot entry and nothing else")
    func listsDotEntries() throws {
        let home = try FakeHome()
        try home.scratch.makeDirectory(".bun")
        try home.scratch.write("", to: ".zshrc")
        try home.scratch.makeDirectory("Documents")
        try home.scratch.makeDirectory(".config/nested/.hidden")

        #expect(DevToolScanner.dotEntries(in: home.scratch.url) == [".bun", ".config", ".zshrc"])
    }

    @Test("finds tools by the folders and binaries they leave in the home folder")
    func detectsTools() throws {
        let home = try FakeHome()
        try home.addVersionedTool(at: ".bun/bin/bun", version: "1.3.14", updateArgument: "upgrade", newVersion: "1.4.0")
        try home.addVersionedTool(at: ".cargo/bin/rustup", version: "rustup 1.27.1 (54dd3d00f 2024-04-24)", updateArgument: "update", newVersion: "rustup 1.28.0")
        try home.addVersionedTool(at: ".claude-cli/currentVersion/claude", version: "2.1.22 (Claude Code)", updateArgument: "update", newVersion: "2.2.0 (Claude Code)")
        try home.addVersionedTool(at: "bin/copilot", version: "GitHub Copilot CLI 1.0.114.", updateArgument: "update", newVersion: "GitHub Copilot CLI 1.0.120.")
        try home.scratch.makeDirectory(".copilot")
        try home.scratch.makeDirectory(".vscode/extensions")
        try home.scratch.write("#!/bin/sh\n", to: "bin/code", executable: true)
        // npm's global packages are left alone, whatever npm has put in the home folder.
        try home.scratch.write("", to: ".npmrc")
        try home.scratch.write("#!/bin/sh\n", to: "bin/npm", executable: true)

        let scan = DevToolScanner.scan(environment: home.environment, includeSystemUpdaters: false)

        #expect(scan.tools.map(\.id) == ["bun", "rustup", "claude-code", "copilot-cli", "vscode-extensions"])
        #expect(scan.entries.contains(".bun"))
        #expect(scan.entries.contains(".npmrc"))
        #expect(scan.claimedEntries == [".bun", ".cargo", ".claude-cli", ".copilot", ".vscode"])

        let bun = try #require(scan.tools.first { $0.id == "bun" })
        #expect(bun.updateCommand.displayString == "bun upgrade")
        let code = try #require(scan.tools.first { $0.id == "vscode-extensions" })
        #expect(code.updateCommand.displayString == "code --update-extensions")
    }

    @Test("judges a Rust update by the compiler's version, not by rustup's own")
    func probesRustCompiler() async throws {
        let home = try FakeHome()
        let compilerVersion = home.scratch.url.appendingPathComponent(".cargo/rustc.version").path
        try home.scratch.write("rustc 1.83.0 (90b35a623 2024-11-26)\n", to: ".cargo/rustc.version")
        try home.scratch.write("#!/bin/sh\n/bin/cat '\(compilerVersion)'\n", to: ".cargo/bin/rustc", executable: true)
        // rustup itself stays at the same version while it moves the toolchain on.
        try home.scratch.write(
            """
            #!/bin/sh
            case "$1" in
              --version) echo "rustup 1.27.1 (54dd3d00f 2024-04-24)" ;;
              update) echo "rustc 1.84.0 (9fc6b4312 2025-01-07)" > '\(compilerVersion)' ;;
              *) exit 2 ;;
            esac
            """,
            to: ".cargo/bin/rustup", executable: true
        )
        let rust = try #require(DevToolScanner.scan(environment: home.environment, includeSystemUpdaters: false).tools.first)

        #expect(rust.id == "rustup")
        #expect(await DevToolUpdater.update(rust, environment: home.environment) == .updated(from: "1.83.0", to: "1.84.0"))
        #expect(await DevToolUpdater.update(rust, environment: home.environment) == .alreadyCurrent("1.84.0"))
    }

    @Test("does not report a tool whose folder exists but whose program is missing")
    func requiresTheProgram() throws {
        let home = try FakeHome()
        try home.scratch.makeDirectory(".bun")
        try home.scratch.makeDirectory(".copilot")
        try home.scratch.makeDirectory(".vscode/extensions")
        try home.scratch.makeDirectory(".local/share/uv/tools/ruff")
        try home.scratch.makeDirectory(".bun/bin/bun")

        let scan = DevToolScanner.scan(environment: home.environment, includeSystemUpdaters: false)

        #expect(scan.tools.isEmpty)
        #expect(scan.claimedEntries.isEmpty)
        #expect(scan.entries == [".bun", ".copilot", ".local", ".vscode"])
    }

    @Test("finds Oh My Zsh and the plugins and themes cloned into it")
    func detectsOhMyZsh() throws {
        let home = try FakeHome()
        try home.addFakeGit()
        try home.scratch.write("echo upgraded\n", to: ".oh-my-zsh/tools/upgrade.sh")
        try home.scratch.write("a1b2c3d\n", to: ".oh-my-zsh/REV")
        try home.scratch.makeDirectory(".oh-my-zsh/custom/plugins/sample-plugin/.git")
        try home.scratch.makeDirectory(".oh-my-zsh/custom/plugins/example")
        try home.scratch.makeDirectory(".oh-my-zsh/custom/themes/sample-theme/.git")

        let scan = DevToolScanner.scan(environment: home.environment, includeSystemUpdaters: false)

        #expect(scan.tools.map(\.id) == [
            "oh-my-zsh",
            "omz-custom:plugins/sample-plugin",
            "omz-custom:themes/sample-theme",
        ])
        #expect(scan.tools.map(\.name) == ["Oh My Zsh", "sample-plugin", "sample-theme"])
        #expect(scan.tools[1].updateCommand.arguments.suffix(3) == ["pull", "--ff-only", "--quiet"])
        #expect(scan.tools[0].updateCommand.environment["ZSH"] == home.scratch.url.appendingPathComponent(".oh-my-zsh").path)
    }
}

@Suite("Tool updates")
struct DevToolUpdaterTests {

    @Test("pulls the version number out of whatever a tool prints", arguments: [
        ("1.3.14\n", "1.3.14"),
        ("GitHub Copilot CLI 1.0.114.\nRun 'copilot update' to check for updates.", "1.0.114"),
        ("rustup 1.27.1 (54dd3d00f 2024-04-24)", "1.27.1"),
        ("deno 2.1.4 (stable, release, aarch64-apple-darwin)\nv8 13.0", "2.1.4"),
        ("2.1.22 (Claude Code)", "2.1.22"),
        ("\n  a1b2c3d\n", "a1b2c3d"),
        ("node v24.1.0-rc.1 (arm64)", "24.1.0-rc.1"),
    ])
    func extractsVersions(output: String, version: String) {
        #expect(DevToolUpdater.extractVersion(from: output) == version)
    }

    @Test("has no version when a tool prints nothing")
    func handlesEmptyOutput() {
        #expect(DevToolUpdater.extractVersion(from: "") == nil)
        #expect(DevToolUpdater.extractVersion(from: "\n  \n") == nil)
    }

    @Test("runs a tool's updater and reports the version change")
    func reportsVersionChange() async throws {
        let home = try FakeHome()
        try home.addVersionedTool(at: ".bun/bin/bun", version: "1.3.14", updateArgument: "upgrade", newVersion: "1.4.0")
        let bun = try #require(DevToolScanner.scan(environment: home.environment, includeSystemUpdaters: false).tools.first)

        #expect(await DevToolUpdater.version(of: bun, environment: home.environment)?.display == "1.3.14")

        let lines = Collector<String>()
        let outcome = await DevToolUpdater.update(bun, environment: home.environment) { line, _ in lines.append(line) }

        #expect(outcome == .updated(from: "1.3.14", to: "1.4.0"))
        #expect(outcome.summary == "Updated 1.3.14 → 1.4.0")
        #expect(lines.values == ["updated"])
    }

    @Test("says so when the updater ran but nothing changed")
    func reportsNoChange() async throws {
        let home = try FakeHome()
        try home.addVersionedTool(at: ".bun/bin/bun", version: "1.4.0", updateArgument: "upgrade", newVersion: "1.4.0")
        let bun = try #require(DevToolScanner.scan(environment: home.environment, includeSystemUpdaters: false).tools.first)

        let outcome = await DevToolUpdater.update(bun, environment: home.environment)

        #expect(outcome == .alreadyCurrent("1.4.0"))
        #expect(!outcome.isFailure)
    }

    /// A stand-in for an updater like Microsoft's: `--list` says whether anything is pending and
    /// `--install` takes its time. It leaves one file when it starts and another when it ends.
    private func slowUpdater(
        in home: FakeHome, listOutput: String, listStatus: Int = 0
    ) throws -> (tool: DevTool, started: URL, finished: URL) {
        let started = home.scratch.url.appendingPathComponent("install.started")
        let finished = home.scratch.url.appendingPathComponent("install.finished")
        let script = try home.scratch.write(
            """
            #!/bin/sh
            case "$1" in
              --list) printf '\(listOutput)'; exit \(listStatus) ;;
              --install) echo x > '\(started.path)'; /bin/sleep 3; echo x > '\(finished.path)' ;;
              *) exit 2 ;;
            esac
            """,
            to: "bin/slow-updater", executable: true
        )
        let tool = DevTool(
            id: "slow", name: "Slow updater", dotEntries: [],
            versionProbe: .none,
            updateCommand: ToolCommand(executable: script.path, arguments: ["--install"]),
            updateTimeout: 30,
            pendingCheck: PendingCheck(
                command: ToolCommand(executable: script.path, arguments: ["--list"]),
                nothingPendingMarker: "No updates available"
            ),
            finishesInBackground: true
        )
        return (tool, started, finished)
    }

    private func waitForFile(_ url: URL, seconds: Double = 20) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    @Test("starts a background updater and moves on without waiting for it to finish")
    func startsBackgroundUpdater() async throws {
        let home = try FakeHome()
        // As msupdate does it: one status line redrawn in place, then what it found.
        let (tool, started, finished) = try slowUpdater(
            in: home, listOutput: "\\r\\033[2K\\rChecking for updates...\\r\\033[2K\\rUpdates available: 2"
        )

        let begun = Date()
        let lines = Collector<String>()
        let outcome = await DevToolUpdater.update(tool, environment: home.environment) { line, _ in lines.append(line) }
        let waited = Date().timeIntervalSince(begun)

        #expect(outcome == .runningInBackground)
        #expect(waited < 2, "The run waited \(waited) s for an updater it should only have started")
        #expect(!FileManager.default.fileExists(atPath: finished.path))
        // The redrawn status line is kept out of the log.
        #expect(lines.values.isEmpty)
        // Left alone, the updater starts, carries on and finishes by itself.
        #expect(await waitForFile(started))
        #expect(await waitForFile(finished))
    }

    @Test("does not start the updater at all when it says nothing is pending")
    func skipsWhenNothingIsPending() async throws {
        let home = try FakeHome()
        let (tool, started, _) = try slowUpdater(
            in: home, listOutput: "Checking for updates...Update Assistant: IdleNo updates available"
        )

        let outcome = await DevToolUpdater.update(tool, environment: home.environment)

        #expect(outcome == .alreadyCurrent(nil))
        #expect(outcome.summary == "Already up to date")
        #expect(await waitForFile(started, seconds: 1) == false)
    }

    @Test("reports a failed check instead of starting the updater blind")
    func reportsFailedCheck() async throws {
        let home = try FakeHome()
        let (tool, started, _) = try slowUpdater(
            in: home, listOutput: "\\r\\033[2K\\rError: the update service is not reachable", listStatus: 1
        )

        let outcome = await DevToolUpdater.update(tool, environment: home.environment)

        #expect(outcome == .failed("Error: the update service is not reachable"))
        #expect(await waitForFile(started, seconds: 1) == false)
    }

    @Test("says so when a background updater cannot be started")
    func reportsMissingBackgroundUpdater() async throws {
        let home = try FakeHome()
        let tool = DevTool(
            id: "gone", name: "Gone", dotEntries: [], versionProbe: .none,
            updateCommand: ToolCommand(executable: home.scratch.url.appendingPathComponent("bin/missing").path, arguments: []),
            finishesInBackground: true
        )

        guard case .failed(let message) = await DevToolUpdater.update(tool, environment: home.environment) else {
            Issue.record("A missing updater was reported as started")
            return
        }
        #expect(message.contains("bin/missing"))
    }

    @Test("asks Microsoft AutoUpdate what is pending before installing, and never waits on the install")
    func describesMicrosoftAutoUpdate() {
        let tool = DevToolScanner.microsoftAutoUpdate(
            msupdate: "/Library/X/Microsoft AutoUpdate.app/Contents/MacOS/msupdate"
        )

        #expect(tool.firstCommand.displayString == "msupdate --list")
        #expect(tool.pendingCheck?.nothingPendingMarker == "No updates available")
        #expect(tool.updateCommand.displayString == "msupdate --install")
        #expect(tool.finishesInBackground)
        #expect(tool.backgroundNote?.contains("background") == true)
        #expect(tool.versionProbe == .command(ToolCommand(
            executable: "/usr/bin/defaults",
            arguments: ["read", "/Library/X/Microsoft AutoUpdate.app/Contents/Info", "CFBundleShortVersionString"]
        )))
    }

    @Test("reports why an updater failed")
    func reportsFailure() async throws {
        let home = try FakeHome()
        try home.scratch.write(
            "#!/bin/sh\n[ \"$1\" = --version ] && { echo 1.0.0; exit 0; }\necho 'error: no network' >&2\nexit 1\n",
            to: ".bun/bin/bun", executable: true
        )
        let bun = try #require(DevToolScanner.scan(environment: home.environment, includeSystemUpdaters: false).tools.first)

        let outcome = await DevToolUpdater.update(bun, environment: home.environment)

        #expect(outcome == .failed("error: no network"))
        #expect(outcome.isFailure)
    }

    @Test("reports a tool that no longer runs once its own updater has finished")
    func reportsToolBrokenByItsUpdate() async throws {
        let home = try FakeHome()
        let marker = home.scratch.url.appendingPathComponent(".bun/half-updated").path
        try home.scratch.write(
            """
            #!/bin/sh
            [ -e '\(marker)' ] && { echo 'no build for this platform' >&2; exit 1; }
            case "$1" in
              --version) echo 1.3.0 ;;
              upgrade) echo x > '\(marker)' ;;
              *) exit 2 ;;
            esac
            """,
            to: ".bun/bin/bun", executable: true
        )
        let bun = try #require(DevToolScanner.scan(environment: home.environment, includeSystemUpdaters: false).tools.first)

        let outcome = await DevToolUpdater.update(bun, environment: home.environment)

        // "Its updater ran" would be true, and would hide that the tool is now unusable.
        #expect(outcome == .failed("Its updater finished, but the tool no longer runs when asked for its version"))
    }

    @Test("updates a git-based plugin and shows its new revision")
    func updatesGitPlugin() async throws {
        let home = try FakeHome()
        try home.addFakeGit()
        try home.scratch.makeDirectory(".oh-my-zsh/custom/plugins/sample-plugin/.git")
        try home.scratch.write("a1b2c3d\n", to: ".oh-my-zsh/custom/plugins/sample-plugin/REV")
        let plugin = try #require(DevToolScanner.scan(environment: home.environment, includeSystemUpdaters: false).tools.first)

        let outcome = await DevToolUpdater.update(plugin, environment: home.environment)

        #expect(outcome == .updated(from: "a1b2c3d", to: "b2c3d4e"))
    }

    @Test("notices a change inside a list even when the number of items is the same")
    func detectsChangesWithinListing() async throws {
        let home = try FakeHome()
        let listing = home.scratch.url.appendingPathComponent("extensions.list").path
        try home.scratch.write("Listing extensions:\nexample.alpha@1.0.0\nexample.beta@2.0.0\n", to: "extensions.list")
        try home.scratch.makeDirectory(".vscode/extensions")
        try home.scratch.write(
            """
            #!/bin/sh
            case "$1" in
              --list-extensions) /bin/cat '\(listing)' ;;
              --update-extensions) /usr/bin/sed -i '' 's/alpha@1.0.0/alpha@1.1.0/' '\(listing)' ;;
            esac
            """,
            to: "bin/code", executable: true
        )
        let code = try #require(DevToolScanner.scan(environment: home.environment, includeSystemUpdaters: false).tools.first)

        // The line that is not an extension is not counted.
        #expect(await DevToolUpdater.version(of: code, environment: home.environment)?.display == "2 extensions")
        #expect(await DevToolUpdater.update(code, environment: home.environment) == .updated(from: nil, to: "2 extensions"))
        #expect(await DevToolUpdater.update(code, environment: home.environment) == .alreadyCurrent("2 extensions"))
    }

    @Test("describes outcomes in plain words")
    func summarisesOutcomes() {
        #expect(ToolUpdateOutcome.updated(from: nil, to: "3 packages").summary == "Updated to 3 packages")
        #expect(ToolUpdateOutcome.updated(from: nil, to: nil).summary == "Updated")
        #expect(ToolUpdateOutcome.alreadyCurrent(nil).summary == "Already up to date")
        #expect(ToolUpdateOutcome.triggered.summary == "Updater ran")
        #expect(ToolUpdateOutcome.runningInBackground.summary == "Started; it finishes in the background")
        #expect(!ToolUpdateOutcome.runningInBackground.isFailure)
        #expect(ToolUpdateOutcome.failed("boom").summary == "Failed: boom")
    }
}

@Suite("Microsoft AutoUpdate")
struct MicrosoftAutoUpdateTests {

    @Test("reads the managed applications out of msupdate's noisy output")
    func parsesRegisteredApplications() {
        let output = """
        \r\n\r\u{1B}[2K\rChecking configuration...\r\u{1B}[2K\r<?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>AutoUpdateVersion</key>
            <string>4.0</string>
            <key>RegisteredApplications</key>
            <dict>
                <key>/Applications/Second.app</key>
                <dict><key>Application ID</key><string>SECOND</string></dict>
                <key>/Applications/First.app</key>
                <dict><key>Application ID</key><string>FIRST</string></dict>
            </dict>
        </dict>
        </plist>
        trailing chatter
        """

        #expect(MicrosoftAutoUpdate.parseRegisteredApplications(from: output) == [
            "/Applications/First.app",
            "/Applications/Second.app",
        ])
    }

    @Test("finds nothing in output without a property list")
    func handlesUnexpectedOutput() {
        #expect(MicrosoftAutoUpdate.parseRegisteredApplications(from: "Checking configuration...").isEmpty)
        #expect(MicrosoftAutoUpdate.parseRegisteredApplications(from: "<?xml </plist>").isEmpty)
        #expect(MicrosoftAutoUpdate.parseRegisteredApplications(from: "").isEmpty)
    }
}

@Suite("Homebrew packages")
struct BrewPackageTests {

    @Test("reads formulae and casks from one listing")
    func parsesInstalledPackages() throws {
        let json = """
        {
          "formulae": [
            {"name": "jq", "versions": {"stable": "1.8.1"}, "outdated": true, "pinned": false,
             "linked_keg": "1.7.1", "keg_only": false,
             "installed": [{"version": "1.7.1", "installed_on_request": true}]},
            {"name": "oniguruma", "versions": {"stable": "6.9.10"}, "revision": 1, "outdated": true, "pinned": false,
             "linked_keg": null, "keg_only": false,
             "installed": [{"version": "6.9.10", "installed_on_request": false}]},
            {"name": "node@24", "versions": {"stable": "24.22.1"}, "outdated": true, "pinned": true,
             "linked_keg": null, "keg_only": true,
             "installed": [{"version": "24.1.0", "installed_on_request": false},
                           {"version": "24.20.0", "installed_on_request": true}]}
          ],
          "casks": [
            {"token": "dotnet-sdk", "version": "11.0.100", "installed": "10.0.100", "outdated": true, "pinned": false},
            {"token": "broken", "version": "2.0", "installed": null, "outdated": false}
          ]
        }
        """

        let packages = try BrewHelper.parseInstalled(json: Data(json.utf8))

        #expect(packages.map(\.token) == ["jq", "oniguruma", "node@24", "dotnet-sdk", "broken"])
        #expect(packages[0] == BrewHelper.InstalledPackage(
            token: "jq", kind: .formula, installedVersion: "1.7.1", latestVersion: "1.8.1",
            isPinned: false, hasUpdate: true, needsRepair: false, installedOnRequest: true
        ))
        #expect(!packages[1].installedOnRequest)
        // A rebuilt formula shows its revision, so "installed" and "latest" visibly differ.
        #expect(packages[1].installedVersion == "6.9.10")
        #expect(packages[1].latestVersion == "6.9.10_1")
        #expect(packages[1].hasUpdate)
        #expect(packages[2].installedVersion == "24.20.0")
        #expect(packages[2].isPinned)
        #expect(packages[2].installedOnRequest)
        #expect(packages[3].kind == .cask)
        #expect(packages[3].hasUpdate)
        #expect(packages[4].needsRepair)
        #expect(packages[4].installedVersion == "Unknown")
        // Installed without its links, a formula's commands are missing. One that Homebrew
        // never links is as it should be.
        #expect(packages.map(\.isMissingLinks) == [false, true, false, false, false])
        #expect(packages.prefix(3).map(\.isLinked) == [true, false, false])
    }

    @Test("accepts a listing with only one kind of package")
    func toleratesMissingSections() throws {
        #expect(try BrewHelper.parseInstalled(json: Data(#"{"casks": []}"#.utf8)).isEmpty)
        let bare = try BrewHelper.parseInstalled(json: Data(#"{"formulae": [{"name": "bare"}]}"#.utf8))
        #expect(bare.map(\.token) == ["bare"])
        // Without Homebrew's word that it links the formula, nothing is called missing.
        #expect(bare.map(\.isMissingLinks) == [false])
        #expect(throws: (any Error).self) {
            try BrewHelper.parseInstalled(json: Data("Error: brew broke".utf8))
        }
    }

    @Test("reads what Homebrew says is in the way of a formula's links")
    func parsesLinkConflicts() {
        let output = """
        Would remove:
        /opt/homebrew/bin/npm -> /opt/homebrew/lib/node_modules/npm/bin/npm-cli.js
        /opt/homebrew/bin/npx -> /opt/homebrew/lib/node_modules/npm/bin/npx-cli.js
        /opt/homebrew/share/man/man1/tool.1
        """

        #expect(BrewHelper.parseLinkConflicts(output) == [
            "/opt/homebrew/bin/npm", "/opt/homebrew/bin/npx", "/opt/homebrew/share/man/man1/tool.1",
        ])
        // What Homebrew would link is in nothing's way.
        #expect(BrewHelper.parseLinkConflicts("Would link:\n/opt/homebrew/bin/node\n").isEmpty)
        #expect(BrewHelper.parseLinkConflicts("Would remove:\n").isEmpty)
        #expect(BrewHelper.parseLinkConflicts("Error: No such keg: /opt/homebrew/Cellar/tool").isEmpty)
    }

    @Test("calls a link in the way stale only when nothing would be lost with it")
    func findsStaleLinks() throws {
        let prefix = try TemporaryDirectory("guava-brew")
        func path(_ relative: String) -> String { prefix.url.appendingPathComponent(relative).path }
        func link(_ relative: String, to destination: String) throws {
            try FileManager.default.createSymbolicLink(atPath: path(relative), withDestinationPath: destination)
        }
        // A formula whose command lives outside its keg, the way npm does.
        try prefix.write("#!/bin/sh\n", to: "lib/node_modules/tool/cli.js")
        try prefix.write("binary", to: "Cellar/tool/2.0/bin/tool")
        try prefix.write("binary", to: "Cellar/tool/2.0/bin/extra")
        try link("Cellar/tool/2.0/bin/helper", to: path("lib/node_modules/tool/cli.js"))
        try prefix.makeDirectory("opt")
        try link("opt/tool", to: "../Cellar/tool/2.0")
        try prefix.makeDirectory("bin")
        // Leads to the very file the formula's own link leads to.
        try link("bin/helper", to: "../lib/node_modules/tool/cli.js")
        // Leads nowhere.
        try link("bin/tool", to: "../lib/gone/tool")
        // Leads somewhere else, and a file that is no link at all.
        try link("bin/extra", to: "../lib/node_modules/tool/cli.js")
        try prefix.write("someone's own", to: "bin/plain")

        let stale = BrewHelper.staleLinks(
            among: [path("bin/helper"), path("bin/tool"), path("bin/extra"), path("bin/plain"), "/elsewhere/bin/helper"],
            prefix: prefix.url, formula: "tool"
        )

        #expect(stale == [path("bin/helper"), path("bin/tool")])
    }

    @Test("reads which old versions brew cleanup could not delete")
    func parsesUnremovableKegs() {
        let output = """
        Warning: Permission denied @ apply2files - /opt/homebrew/Cellar/tool/1.0/lib/__pycache__/tool.pyc
        Error: Could not cleanup old kegs! Fix your permissions on:
          /opt/homebrew/Cellar/tool/1.0
          /opt/homebrew/Cellar/other@3/3.1.4
        """

        #expect(BrewHelper.parseUnremovableKegs(output) == [
            "/opt/homebrew/Cellar/tool/1.0", "/opt/homebrew/Cellar/other@3/3.1.4",
        ])
        #expect(BrewHelper.parseUnremovableKegs("Error: Permission denied @ rb_sysopen - /opt/homebrew/x").isEmpty)
    }

    @Test("moves aside only an old version of a formula whose version in use is another")
    func recognisesSupersededKegs() throws {
        let prefix = try TemporaryDirectory("guava-brew")
        func path(_ relative: String) -> String { prefix.url.appendingPathComponent(relative).path }
        try prefix.write("old", to: "Cellar/tool/1.0/bin/tool")
        try prefix.write("new", to: "Cellar/tool/2.0/bin/tool")
        try prefix.write("only", to: "Cellar/lonely/1.0/bin/lonely")
        try prefix.makeDirectory("opt")
        try FileManager.default.createSymbolicLink(atPath: path("opt/tool"), withDestinationPath: "../Cellar/tool/2.0")
        try FileManager.default.createSymbolicLink(atPath: path("Cellar/tool/alias"), withDestinationPath: "1.0")

        #expect(BrewHelper.isSupersededKeg(path("Cellar/tool/1.0"), prefix: prefix.url))
        // The version in use, a formula with nothing in use, and anything that is not a
        // version folder of the Cellar's stay where they are.
        #expect(!BrewHelper.isSupersededKeg(path("Cellar/tool/2.0"), prefix: prefix.url))
        #expect(!BrewHelper.isSupersededKeg(path("Cellar/lonely/1.0"), prefix: prefix.url))
        #expect(!BrewHelper.isSupersededKeg(path("Cellar/tool/alias"), prefix: prefix.url))
        #expect(!BrewHelper.isSupersededKeg(path("Cellar/tool"), prefix: prefix.url))
        #expect(!BrewHelper.isSupersededKeg(path("Cellar/tool/1.0/bin"), prefix: prefix.url))
        #expect(!BrewHelper.isSupersededKeg(path("lib"), prefix: prefix.url))
        #expect(!BrewHelper.isSupersededKeg(path("Cellar/tool/3.0"), prefix: prefix.url))
        // Nor does a path that only looks like a version folder: this one is the Cellar itself.
        #expect(!BrewHelper.isSupersededKeg(path("Cellar/tool/.."), prefix: prefix.url))
        #expect(prefix.exists("Cellar/tool/1.0/bin/tool"))
    }
}

@Suite("Cask downloads")
struct CaskDownloadTests {

    private let cask: [String: Any] = [
        "token": "visual-studio-code",
        "version": "1.147.0",
        "url": "https://update.code.visualstudio.com/1.147.0/darwin-arm64/stable",
        "sha256": String(repeating: "a", count: 64),
        "homepage": "https://code.visualstudio.com/",
        "variations": [
            "sequoia": [
                "url": "https://update.code.visualstudio.com/1.147.0/darwin/stable",
                "sha256": String(repeating: "b", count: 64),
            ],
            "arm64_big_sur": [
                "url": "https://update.code.visualstudio.com/1.97.2/darwin-arm64/stable",
                "sha256": String(repeating: "c", count: 64),
                "version": "1.97.2",
            ],
            "x86_64_linux": ["url": "https://example.com/linux"],
        ],
    ]

    @Test("uses the top-level download on current Apple silicon")
    func resolvesAppleSilicon() throws {
        let download = try #require(CaskDownloadResolver.resolve(cask: cask, architecture: "arm64", macOSMajorVersion: 27))

        #expect(download.url == "https://update.code.visualstudio.com/1.147.0/darwin-arm64/stable")
        #expect(download.sha256 == String(repeating: "a", count: 64))
        #expect(download.version == "1.147.0")
        #expect(download.homepage == "https://code.visualstudio.com/")
    }

    @Test("uses the Intel download for the running macOS release")
    func resolvesIntel() throws {
        let download = try #require(CaskDownloadResolver.resolve(cask: cask, architecture: "x86_64", macOSMajorVersion: 15))

        #expect(download.url == "https://update.code.visualstudio.com/1.147.0/darwin/stable")
        #expect(download.sha256 == String(repeating: "b", count: 64))
    }

    @Test("uses the older build Homebrew lists for an old macOS on Apple silicon")
    func resolvesOlderAppleSilicon() throws {
        let download = try #require(CaskDownloadResolver.resolve(cask: cask, architecture: "arm64", macOSMajorVersion: 11))

        #expect(download.version == "1.97.2")
        #expect(download.sha256 == String(repeating: "c", count: 64))
    }

    @Test("falls back to the top level when Homebrew lists no difference for this platform")
    func fallsBackToTopLevel() throws {
        let intel = try #require(CaskDownloadResolver.resolve(cask: cask, architecture: "x86_64", macOSMajorVersion: 14))
        #expect(intel.url.hasSuffix("darwin-arm64/stable"))

        let future = try #require(CaskDownloadResolver.resolve(cask: cask, architecture: "arm64", macOSMajorVersion: 99))
        #expect(future.url.hasSuffix("darwin-arm64/stable"))
    }

    @Test("gives no download rather than guess on an Intel Mac running an unknown macOS")
    func refusesToGuess() {
        #expect(CaskDownloadResolver.resolve(cask: cask, architecture: "x86_64", macOSMajorVersion: 99) == nil)

        var universal = cask
        universal["variations"] = ["x86_64_linux": ["url": "https://example.com/linux"]]
        #expect(CaskDownloadResolver.resolve(cask: universal, architecture: "x86_64", macOSMajorVersion: 99) != nil)
    }

    @Test("drops a checksum Homebrew does not pin and rejects unusable records")
    func handlesIncompleteRecords() throws {
        var unpinned = cask
        unpinned["sha256"] = "no_check"
        #expect(try #require(CaskDownloadResolver.resolve(cask: unpinned, architecture: "arm64", macOSMajorVersion: 27)).sha256 == nil)

        var local = cask
        local["url"] = "file:///tmp/app.dmg"
        #expect(CaskDownloadResolver.resolve(cask: local, architecture: "arm64", macOSMajorVersion: 27) == nil)

        #expect(CaskDownloadResolver.resolve(cask: ["token": "x", "version": "1"]) == nil)
        #expect(CaskDownloadResolver.codename(forMajorVersion: 26) == "tahoe")
        #expect(CaskDownloadResolver.codename(forMajorVersion: 12345) == nil)
    }
}

@Suite("Cask matching")
struct CaskCatalogTests {

    /// A record as Homebrew serves it. `pkg` stands for a cask that installs from a package.
    private func cask(
        _ token: String, version: String = "2.0", names: [String] = [],
        apps: [Any] = [], pkg: Bool = false, deletes: Any? = nil, zap: [String] = [], font: Bool = false
    ) -> [String: Any] {
        var artifacts: [[String: Any]] = []
        if !apps.isEmpty { artifacts.append(["app": apps]) }
        if pkg { artifacts.append(["pkg": ["Installer.pkg"]]) }
        if font { artifacts.append(["font": ["Sample.ttf"]]) }
        if let deletes { artifacts.append(["uninstall": [["quit": "com.example.other", "delete": deletes]]]) }
        if !zap.isEmpty { artifacts.append(["zap": [["trash": zap]]]) }
        return ["token": token, "version": version, "name": names, "artifacts": artifacts]
    }

    private var catalog: CaskCatalog {
        CaskCatalog(records: [
            cask("sample", version: "3.1,456", names: ["Sample"], apps: ["Sample.app"]),
            cask("sample@beta", version: "4.0", names: ["Sample Beta"], apps: ["Sample.app"]),
            cask("sample@lts", version: "2.9", names: ["Sample LTS"], apps: ["Sample.app"]),
            cask("sample-editor", version: "5.0", names: ["Sample Editor by Example"], apps: ["Sample Editor.app"]),
            cask("edit", version: "0.1", names: ["Edit"], pkg: true),
            cask("renamed", version: "6.0", apps: ["Renamed-arm64.app", ["target": "Renamed Tool.app"]]),
            // Installed from packages: only their uninstall says which bundle is theirs.
            cask("meeting", version: "7.0", names: ["Meeting"], pkg: true,
                 deletes: ["/Applications/meet.example.app", "/Library/Logs/meeting"],
                 zap: ["~/Library/Preferences/com.example.meeting.plist"]),
            cask("meeting-for-admins", version: "7.0", pkg: true, deletes: "/Applications/meet.example.app",
                 zap: ["~/Library/Caches/com.example.meeting"]),
            cask("studio", version: "26.1", names: ["Studio"], pkg: true, deletes: "/Applications/Studio Helper.app",
                 zap: ["~/Library/Preferences/com.example.studio.plist"]),
            cask("office-suite", version: "16.0", names: ["Office Suite"], pkg: true,
                 deletes: ["/Applications/Writer.app", "/Applications/Sheets.app"]),
            cask("writer", version: "16.2", names: ["Writer"], pkg: true),
            cask("reader-pro", version: "8.0", names: ["Reader Pro Edition"], pkg: true,
                 deletes: "/Applications/Reader Pro/",
                 zap: ["~/Library/Saved Application State/com.example.reader.savedState"]),
            cask("input-method", version: "1.0", pkg: true, deletes: "/Library/Input Methods/Typing.app",
                 zap: ["~/Library/Preferences/com.example.typing.plist"]),
            // Two products whose bundles have the same name.
            cask("notes", version: "35.0.3", names: ["Notes"], apps: ["Notes.app"]),
            cask("notes-lite", version: "4.0.8", names: ["Notes Lite"], apps: ["Notes.app"]),
            cask("suite-home", version: "8.0", names: ["Suite Home"], apps: ["Suite.app"]),
            cask("suite-work", version: "8.0", names: ["Suite Work"], apps: ["Suite.app"]),
            // Not an application at all.
            cask("font-sample", version: "9.0", names: ["Sample Sans"], font: true),
            ["token": "broken"],
        ])
    }

    private func token(_ answer: CaskCatalog.Answer) -> String? {
        if case .match(let match) = answer { return match.token }
        return nil
    }

    @Test("matches an app by its name and prefers the main release over its side channels")
    func matchesByName() {
        // Three casks install Sample.app; the one that also goes by the app's name wins.
        #expect(catalog.lookUp(name: "Sample", path: "/Applications/Sample.app")
            == .match(CaskCatalog.Match(token: "sample", version: "3.1")))
        #expect(token(catalog.lookUp(name: "Writer", path: "/Applications/Writer.app")) == "writer")
        #expect(catalog.cask(withToken: "Sample@Beta") == CaskCatalog.Match(token: "sample@beta", version: "4.0"))
        #expect(catalog.cask(withToken: "broken") == nil)
    }

    @Test("keeps an app on the release line it is on")
    func followsReleaseLine() {
        func lookUp(installed: String) -> String? {
            token(catalog.lookUp(name: "Sample", path: "/Applications/Sample.app", installedVersion: installed))
        }
        // A long-term-support copy is compared with its own line, not moved to the main release.
        #expect(lookUp(installed: "2.8") == "sample@lts")
        #expect(lookUp(installed: "2.9") == "sample@lts")
        #expect(lookUp(installed: "3.0") == "sample")
        // No line continues this version, so the main release it is.
        #expect(lookUp(installed: "1.0") == "sample")
    }

    @Test("matches an app that shows another name by the bundle the cask installs")
    func matchesByBundle() {
        // The app calls itself "Edit", which is another cask's name. Its bundle says more,
        // even when that other cask is one Homebrew has installed.
        let path = "/Applications/Sample Editor.app"
        #expect(token(catalog.lookUp(name: "Edit", path: path)) == "sample-editor")
        #expect(token(catalog.lookUp(name: "Edit", path: path, installedTokens: ["edit"])) == "sample-editor")
        // A bundle that is renamed on installation goes by its new name only.
        #expect(token(catalog.lookUp(name: "Tool", path: "/Applications/Renamed Tool.app")) == "renamed")
        #expect(catalog.lookUp(name: "Renamed-arm64", path: "/Applications/Renamed-arm64.app") == .unclaimed)
    }

    @Test("matches an app installed from a package by what the cask removes, if the cask knows the app")
    func matchesByOwnedPath() {
        let meeting = "/Applications/meet.example.app"
        #expect(token(catalog.lookUp(name: "meet.example", path: meeting, bundleIdentifier: "com.example.Meeting"))
            == "meeting")
        // Without the identifier there is nothing to tell the cask's app from a companion of it.
        #expect(catalog.lookUp(name: "meet.example", path: meeting) == .unclaimed)
        // The cask removes this helper, but everything else it names belongs to another app.
        #expect(catalog.lookUp(
            name: "Studio Helper", path: "/Applications/Studio Helper.app", bundleIdentifier: "com.example.studio.helper"
        ) == .unclaimed)
        // A bundle of the same name somewhere Guava does not look is another matter altogether.
        #expect(catalog.lookUp(
            name: "Typing", path: "/Applications/Typing.app", bundleIdentifier: "com.example.typing"
        ) == .unclaimed)

        let reader = "/Applications/Reader Pro/Reader.app"
        #expect(token(catalog.lookUp(
            name: "Reader", path: reader, bundleIdentifier: "com.example.reader", isOnlyAppInFolder: { true }
        )) == "reader-pro")
        // Among several apps in that folder there is no telling which one the version is for.
        #expect(catalog.lookUp(
            name: "Reader", path: reader, bundleIdentifier: "com.example.reader", isOnlyAppInFolder: { false }
        ) == .unclaimed)
    }

    @Test("does not take a suite's version for one of its apps, or a font's for an app of that name")
    func leavesSuitesAndFontsAlone() {
        #expect(catalog.lookUp(name: "Sheets", path: "/Applications/Sheets.app") == .unclaimed)
        #expect(token(catalog.lookUp(name: "Office Suite", path: "/Applications/Office Suite.app")) == "office-suite")
        #expect(catalog.lookUp(name: "Sample Sans", path: "/Applications/Sample Sans.app") == .unclaimed)
        #expect(catalog.cask(withToken: "font-sample") == nil)
    }

    @Test("gives no answer when two products claim the same bundle and disagree about its version")
    func refusesToGuessBetweenProducts() {
        func lookUp(installed: String?, installedTokens: Set<String> = []) -> CaskCatalog.Answer {
            catalog.lookUp(
                name: "Notes", path: "/Applications/Notes.app",
                installedVersion: installed, installedTokens: installedTokens
            )
        }
        // Whatever the installed version suggests, a wrong guess would have one product's
        // download installed over the other, so there is no guessing.
        #expect(lookUp(installed: "4.0.6") == .contested)
        #expect(lookUp(installed: "35.0.1") == .contested)
        #expect(lookUp(installed: nil) == .contested)
        // Homebrew's own record of what it installed settles it.
        #expect(token(lookUp(installed: "4.0.6", installedTokens: ["notes-lite"])) == "notes-lite")
        // Two editions at the very same version are still two products, with two downloads.
        #expect(catalog.lookUp(name: "Suite", path: "/Applications/Suite.app", installedVersion: "7.9") == .contested)
    }

    @Test("prefers the cask Homebrew installed on this Mac, and finds nothing for a stranger")
    func prefersInstalledCask() {
        let sample = "/Applications/Sample.app"
        #expect(token(catalog.lookUp(name: "Sample", path: sample, installedTokens: ["sample@beta"])) == "sample@beta")
        // Being installed does not make a cask claim an app it knows nothing about.
        #expect(catalog.lookUp(name: "Stranger", path: "/Applications/Stranger.app", installedTokens: ["sample"])
            == .unclaimed)
        #expect(CaskCatalog().lookUp(name: "Sample", path: sample) == .unclaimed)
    }

    @Test("guesses tokens from an app's name")
    func guessesTokens() {
        #expect(VersionChecker.tokenGuesses(for: "Sample Editor") == ["sample-editor", "sampleeditor", "sample editor"])
        #expect(VersionChecker.tokenGuesses(for: "Sample Desktop").last == "sample")
        #expect(VersionChecker.tokenGuesses(for: "Sample Manager").last == "sample")
    }
}

@Suite("Update sources")
struct UpdateSourceTests {

    @Test("reads what the App Store says about an app")
    func readsStoreAnswer() {
        func answer(_ status: Int, _ body: String) -> VersionChecker.StoreAnswer {
            VersionChecker.storeAnswer(statusCode: status, body: Data(body.utf8))
        }

        #expect(answer(200, #"{"resultCount":1,"results":[{"version":"10.4.6","trackName":"Sample"}]}"#)
            == .listed(version: "10.4.6"))
        #expect(answer(200, #"{"resultCount":0,"results":[]}"#) == .notListed)
        // No answer is not the same as "not there".
        #expect(answer(503, #"{"resultCount":0,"results":[]}"#) == .unreachable)
        #expect(answer(200, "<html>Sign in to continue</html>") == .unreachable)
        #expect(answer(200, #"{"results":[{"trackName":"No version"}]}"#) == .unreachable)
    }

    @Test("calls an app unupdatable only when every source could be asked and none knew it")
    func establishesMissingSource() {
        #expect(VersionChecker.hasNoSource(claim: .unclaimed, catalogIsLoaded: true, storeAnswer: .notListed))
        // An app without a bundle identifier cannot be asked about at the App Store.
        #expect(VersionChecker.hasNoSource(claim: .unclaimed, catalogIsLoaded: true, storeAnswer: nil))
        #expect(!VersionChecker.hasNoSource(claim: .unclaimed, catalogIsLoaded: false, storeAnswer: .notListed))
        #expect(!VersionChecker.hasNoSource(claim: .unclaimed, catalogIsLoaded: true, storeAnswer: .unreachable))
        #expect(!VersionChecker.hasNoSource(claim: .contested, catalogIsLoaded: true, storeAnswer: .notListed))
    }
}

@Suite("Local record")
@MainActor
struct LocalRecordTests {

    private func app(
        _ name: String, _ status: UpdateStatus, installed: String = "1.0", latest: String? = nil,
        unsourced: Bool = false, organisation: Bool = false
    ) -> AppInfo {
        let app = AppInfo(
            name: name, bundleIdentifier: "com.example.\(name.lowercased())", currentVersion: installed,
            path: "/Applications/\(name).app", icon: nil,
            hasAppStoreReceipt: organisation, isOrganisationLicensed: organisation
        )
        app.latestVersion = latest
        app.updateStatus = status
        app.hasNoUpdateSource = unsourced
        return app
    }

    @Test("leaves apps that nothing can update out of the list and names them in the file")
    func hidesUnupdatableApps() throws {
        let scratch = try TemporaryDirectory()
        let store = LocalStore(url: scratch.url.appendingPathComponent(".guava"))
        let model = GuavaViewModel(store: store)
        model.apps = [
            app("Alpha", .upToDate, latest: "1.0"), app("Homemade", .unknown, unsourced: true), app("Offline", .unknown),
        ]

        model.settleCheck()

        // Only what was established counts: an app the check could not ask about stays.
        #expect(model.listedApps.map(\.name) == ["Alpha", "Offline"])
        #expect(model.hiddenCount == 1)
        #expect(model.summaryLine == "2 apps, no updates found")
        #expect(model.listNote == "1 app that nothing can update is not listed. It is named in ~/.guava")
        #expect(store.load().hidden == [LocalRecord.HiddenApp(name: "Homemade", path: "/Applications/Homemade.app")])

        // The next launch leaves it out from the start, before anything has been checked.
        let relaunched = GuavaViewModel(store: store)
        relaunched.apps = [app("Alpha", .checking), app("Homemade", .checking)]
        #expect(relaunched.listedApps.map(\.name) == ["Alpha"])
    }

    @Test("keeps an app hidden through a check that learned nothing, and lists it once a source appears")
    func hiddenAppsFollowWhatIsKnown() {
        let model = GuavaViewModel()
        model.apps = [app("Homemade", .unknown, unsourced: true)]
        model.settleCheck()
        #expect(model.listedApps.isEmpty)
        #expect(model.summaryLine == "No applications that can be updated")

        // Offline: nothing was learned, so nothing changes.
        model.apps = [app("Homemade", .unknown)]
        model.settleCheck()
        #expect(model.listedApps.isEmpty)

        model.apps = [app("Homemade", .updateAvailable, latest: "2.0")]
        model.settleCheck()
        #expect(model.listedApps.map(\.name) == ["Homemade"])
        #expect(model.record.hidden.isEmpty)
    }

    @Test("shows a copy licensed to an organisation as up to date, with nothing to remember")
    func holdsOrganisationCopies() {
        let model = GuavaViewModel()
        let managed = app("Managed", .updateAvailable, latest: "2.0", organisation: true)
        let own = app("Own", .updateAvailable, latest: "2.0")
        model.apps = [managed, own]

        model.settleCheck()

        #expect(managed.updateStatus == .upToDate)
        #expect(managed.heldBack == .organisation)
        #expect(own.updateStatus == .updateAvailable)
        #expect(model.updateCount == 1)
        #expect(model.record.held.isEmpty)
    }

    @Test("keeps a held update green until the installed or the latest version changes")
    func remembersHeldUpdates() throws {
        let scratch = try TemporaryDirectory()
        let store = LocalStore(url: scratch.url.appendingPathComponent(".guava"))
        /// A later check that finds the app with these versions.
        func check(installed: String = "1.0", latest: String?, status: UpdateStatus = .updateAvailable) -> AppInfo {
            let found = app("Held", status, installed: installed, latest: latest)
            let model = GuavaViewModel(store: store)
            model.apps = [found]
            model.settleCheck()
            return found
        }
        func hold() {
            let model = GuavaViewModel(store: store)
            let held = app("Held", .updateAvailable, latest: "2.0")
            model.apps = [held]
            model.holdBack(held)
            #expect(held.updateStatus == .upToDate)
            #expect(held.heldBack == .notInstalled)
        }

        hold()
        let same = check(latest: "2.0")
        #expect(same.updateStatus == .upToDate)
        #expect(same.heldBack == .notInstalled)
        // A check that learned nothing leaves the record as it is.
        #expect(check(latest: nil, status: .unknown).updateStatus == .unknown)
        #expect(store.load().held.count == 1)
        // A newer version is a new update to try.
        #expect(check(latest: "3.0").updateStatus == .updateAvailable)
        #expect(store.load().held.isEmpty)

        // So is the same version once the app itself has moved.
        hold()
        #expect(check(installed: "1.5", latest: "2.0").updateStatus == .updateAvailable)
        #expect(store.load().held.isEmpty)
    }

    @Test("reads a record with a list missing, and starts afresh from a file it cannot read")
    func toleratesOddFiles() throws {
        let scratch = try TemporaryDirectory()
        let url = try scratch.write(
            #"{"hidden":[{"name":"Homemade","path":"/Applications/Homemade.app"}]}"#, to: ".guava"
        )
        #expect(LocalStore(url: url).load().hidden.map(\.name) == ["Homemade"])
        #expect(LocalStore(url: url).load().held.isEmpty)

        try scratch.write("not a record", to: ".guava")
        #expect(LocalStore(url: url).load() == LocalRecord())
    }

    @Test("writes nothing when it may only read")
    func readOnlyStoreWritesNothing() throws {
        let scratch = try TemporaryDirectory()
        let store = LocalStore(url: scratch.url.appendingPathComponent(".guava"))
        let model = GuavaViewModel(store: store.readOnly)
        model.apps = [app("Homemade", .unknown, unsourced: true)]

        model.settleCheck()

        // The list reflects what was found; the file is another matter.
        #expect(model.listedApps.isEmpty)
        #expect(!scratch.exists(".guava"))
    }

    @Test("says in the scan report what is held back and what is left out")
    func reportsHeldAndUnlistedApps() {
        let model = GuavaViewModel()
        model.apps = [
            app("Alpha", .upToDate, latest: "1.0"),
            app("Homemade", .unknown, unsourced: true),
            app("Managed", .updateAvailable, latest: "2.0", organisation: true),
        ]
        model.settleCheck()

        let report = HeadlessRunner.scanReport(
            model, context: AppRoutingContext(agentEnabled: true, agentAvailable: true, microsoftManagedPaths: [])
        )

        #expect(report.contains("Applications: 2 listed, 0 outdated"))
        #expect(report.contains("Managed 1.0 stays as it is: 2.0 exists, licensed to your organisation"))
        #expect(report.contains("Not listed, as nothing can update them: Homemade"))
    }
}

@Suite("Application list")
struct ApplicationListTests {

    @Test("lists what Guava can update, and nothing that macOS or a browser looks after")
    func scansOnlyUpdatableApps() async throws {
        let applications = try TemporaryDirectory("guava-apps")
        let userApplications = try TemporaryDirectory("guava-apps")
        func install(
            _ file: String, _ identifier: String, version: String = "1.0",
            receipt: Bool = false, extraInfo: [String: Any] = [:], in folder: TemporaryDirectory
        ) async throws {
            let name = ((file as NSString).lastPathComponent as NSString).deletingPathExtension
            try await Fixture.makeApp(
                at: folder.url.appendingPathComponent(file),
                bundleIdentifier: identifier, version: version, name: name, extraInfo: extraInfo, sign: false
            )
            if receipt {
                try folder.write("receipt", to: "\(file)/Contents/_MASReceipt/receipt")
            }
        }
        // Comes with macOS, and the same vendor's app from the App Store.
        try await install("Built In.app", "com.apple.BuiltIn", in: applications)
        try await install("From the Store.app", "com.apple.FromTheStore", receipt: true, in: applications)
        try await install("Sample.app", "com.example.sample", in: applications)
        try await install("Utilities/Nested.app", "com.example.nested", in: applications)
        // A web app saved from a browser, and the browser itself, which is an ordinary app.
        try await install(
            "Web Apps/Mail.app", "com.example.browser.app.abcdef",
            extraInfo: ["CrAppModeShortcutID": "abcdef"], in: userApplications
        )
        try await install("Browser.app", "com.example.browser", in: userApplications)
        // A second copy of an app is not listed.
        try await install("Sample.app", "com.example.sample", version: "0.9", in: userApplications)

        let apps = AppScanner.scanApplications(in: [applications.url, userApplications.url])

        #expect(apps.map(\.name) == ["Browser", "From the Store", "Nested", "Sample"])
        #expect(apps.map(\.hasAppStoreReceipt) == [false, true, false, false])
        #expect(apps.last?.currentVersion == "1.0")
        #expect(AppScanner.isListed(info: [:], hasAppStoreReceipt: false))
    }

    @MainActor
    @Test("puts the apps with an update first and says how many there are")
    func ordersAndSummarises() {
        func app(_ name: String, _ status: UpdateStatus) -> AppInfo {
            let app = AppInfo(
                name: name, bundleIdentifier: nil, currentVersion: "1.0",
                path: "/Applications/\(name).app", icon: nil
            )
            app.updateStatus = status
            return app
        }
        let model = GuavaViewModel()
        #expect(model.summaryLine == "No applications found")

        model.apps = [
            app("Delta", .upToDate), app("alpha", .updateAvailable), app("Bravo", .unknown), app("Charlie", .updateAvailable),
        ]
        #expect(model.listedApps.map(\.name) == ["alpha", "Charlie", "Bravo", "Delta"])
        #expect(model.summaryLine == "4 apps, 2 updates available")

        model.apps[1].updateStatus = .upToDate
        #expect(model.listedApps.map(\.name) == ["Charlie", "alpha", "Bravo", "Delta"])
        #expect(model.summaryLine == "4 apps, 1 update available")

        // An update that failed is still an update that is waiting.
        model.apps[3].updateStatus = .error
        #expect(model.listedApps.map(\.name) == ["Charlie", "alpha", "Bravo", "Delta"])
        #expect(model.summaryLine == "4 apps, 1 update available")
        model.apps[0].updateStatus = .error
        #expect(model.listedApps.map(\.name) == ["Charlie", "Delta", "alpha", "Bravo"])
        #expect(model.summaryLine == "4 apps, 2 updates available")

        model.apps = [app("Delta", .upToDate)]
        #expect(model.summaryLine == "1 app, no updates found")

        // While a check runs, the line says what the check is doing.
        model.isCheckingAll = true
        model.statusMessage = "Checking Homebrew…"
        #expect(model.summaryLine == "Checking Homebrew…")
    }
}
