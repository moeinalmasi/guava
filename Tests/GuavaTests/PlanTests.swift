import Foundation
import Testing
@testable import Guava

@Suite("Update routing")
struct UpdatePlannerTests {

    private let ready = AppRoutingContext(
        agentEnabled: true,
        agentAvailable: true,
        microsoftManagedPaths: ["/Applications/Managed.app"]
    )

    private func route(
        path: String = "/Applications/Example.app",
        receipt: Bool = false,
        method: UpdateMethod = .manual,
        context: AppRoutingContext? = nil
    ) -> AppUpdateRoute {
        UpdatePlanner.route(
            path: path, hasAppStoreReceipt: receipt, updateMethod: method, context: context ?? ready
        )
    }

    @Test("sends an App Store copy to the App Store even when Homebrew or the agent could update it")
    func prefersAppStoreForReceipts() {
        #expect(route(receipt: true, method: .manual) == .appStore)
        #expect(route(receipt: true, method: .homebrew) == .appStore)
        #expect(route(path: "/Applications/Managed.app", receipt: true) == .appStore)
    }

    @Test("uses Homebrew for apps Homebrew installed")
    func usesHomebrewForCasks() {
        #expect(route(method: .homebrew) == .homebrew)
        #expect(route(path: "/Applications/Managed.app", method: .homebrew) == .homebrew)
    }

    @Test("leaves apps registered with Microsoft AutoUpdate to it")
    func defersToMicrosoftAutoUpdate() {
        #expect(route(path: "/Applications/Managed.app") == .microsoftAutoUpdate)
        #expect(route(path: "/Applications/Other.app") == .agent)
    }

    @Test("uses the agent for everything else, including apps the App Store merely also sells")
    func usesAgentOtherwise() {
        #expect(route(method: .manual) == .agent)
        #expect(route(method: .unknown) == .agent)
        #expect(route(receipt: false, method: .appStore) == .agent)
    }

    @Test("skips with a reason when the agent is off or missing")
    func skipsWithoutAgent() {
        var off = ready
        off.agentEnabled = false
        var missing = ready
        missing.agentAvailable = false

        #expect(route(context: off) == .skipped(reason: "the Copilot agent is turned off in Settings"))
        #expect(route(context: missing) == .skipped(reason: "the GitHub Copilot CLI is not installed"))
        // Routes that do not need the agent are unaffected.
        #expect(route(method: .homebrew, context: off) == .homebrew)
        #expect(route(receipt: true, context: missing) == .appStore)
    }

    @Test("says that the update cannot be made when the Copilot CLI is installed and will not start")
    func reportsBrokenAgent() {
        var broken = ready
        broken.agentAvailable = false
        broken.agentProblem = "env: node: No such file or directory"

        let chosen = route(context: broken)

        #expect(chosen == .unavailable(
            reason: "the GitHub Copilot CLI does not start (env: node: No such file or directory)"
        ))
        #expect(chosen.label == "Not possible: the GitHub Copilot CLI does not start (env: node: No such file or directory)")
        #expect(route(method: .homebrew, context: broken) == .homebrew)
        // With the agent turned off, whether it would start is beside the point.
        broken.agentEnabled = false
        #expect(route(context: broken) == .skipped(reason: "the Copilot agent is turned off in Settings"))
    }

    @Test("routes a scanned app from its own properties")
    func routesAppInfo() {
        let storeApp = AppInfo(
            name: "Sample", bundleIdentifier: "com.example.sample", currentVersion: "4.0",
            path: "/Applications/Sample.app", icon: nil, hasAppStoreReceipt: true
        )
        storeApp.updateMethod = .manual

        #expect(UpdatePlanner.route(for: storeApp, context: ready) == .appStore)
    }
}

@Suite("Update plan and summary")
struct UpdatePlanTests {

    @Test("describes each planned action on its own line")
    func describesPlan() {
        let plan = UpdatePlan(
            brewPackages: ["jq", "fd"],
            tools: ["Bun"],
            apps: [
                .init(name: "Tiler", installedVersion: "2.0.4", latestVersion: "2.0.5", route: .agent),
                .init(name: "Storyboard", installedVersion: "1.4", latestVersion: nil, route: .appStore),
                .init(name: "Mystery", installedVersion: "1", latestVersion: "2",
                      route: .skipped(reason: "the GitHub Copilot CLI is not installed")),
            ]
        )

        #expect(plan.lines == [
            "Homebrew: upgrade 2 package(s): jq, fd",
            "Tools: run 1 updater(s): Bun",
            "App: Tiler 2.0.4 → 2.0.5 via Copilot agent",
            "App: Storyboard 1.4 via Mac App Store",
            "App: Mystery 1 → 2 via Skipped: the GitHub Copilot CLI is not installed",
        ])
        #expect(!plan.isEmpty)
    }

    @Test("says so when nothing is outdated and shortens long package lists")
    func describesEmptyAndLongPlans() {
        #expect(UpdatePlan().lines == ["Homebrew: nothing outdated", "Applications: nothing outdated"])
        #expect(UpdatePlan().isEmpty)

        let many = UpdatePlan(brewPackages: (1...15).map { "pkg\($0)" })
        #expect(many.lines[0].hasSuffix("pkg12, and 3 more"))
    }

    @Test("counts outcomes and reports a run as clean only when nothing needs the user")
    func summarisesItems() {
        func item(_ id: String, _ state: UpdateItemState) -> UpdateItem {
            UpdateItem(id: id, category: .app, name: id, state: state)
        }
        let summary = UpdateSummary(items: [
            item("a", .updated("1 → 2")),
            item("b", .updated("3 → 4")),
            item("c", .started("App Store")),
            item("d", .unchanged("Current")),
            item("e", .needsAttention("Quit it")),
            item("f", .failed("Bad signature")),
            item("g", .skipped("Agent off")),
            item("h", .pending),
        ])

        #expect(summary.updated == 2)
        #expect(summary.started == 1)
        #expect(summary.unchanged == 1)
        #expect(summary.needsAttention == 1)
        #expect(summary.failed == 1)
        #expect(summary.skipped == 1)
        #expect(!summary.isClean)
        #expect(summary.headline == "2 updated, 1 in progress, 1 needs attention, 1 failed, 1 skipped")

        var several = summary
        several.needsAttention = 3
        #expect(several.headline == "2 updated, 1 in progress, 3 need attention, 1 failed, 1 skipped")
    }

    @Test("words the headline for clean, cancelled and dry runs")
    func wordsHeadlines() {
        var clean = UpdateSummary(items: [UpdateItem(id: "a", category: .tool, name: "a", state: .unchanged("ok"))])
        #expect(clean.isClean)
        #expect(clean.headline == "Everything is already up to date")

        clean.wasCancelled = true
        #expect(!clean.isClean)
        #expect(clean.headline == "Stopped: Everything is already up to date")

        var dry = UpdateSummary()
        dry.wasDryRun = true
        #expect(dry.headline == "Dry run: nothing was changed")
    }

    @Test("knows which item states are final")
    func classifiesStates() {
        #expect(!UpdateItemState.pending.isFinished)
        #expect(!UpdateItemState.running.isFinished)
        #expect(UpdateItemState.started("x").isFinished)
        #expect(UpdateItemState.failed("why").detail == "why")
        #expect(UpdateItemState.pending.detail == "Waiting")
    }
}

@Suite("Update settings")
struct UpdateSettingsTests {

    @Test("starts with the agent, computer use and cleanup all on")
    func usesDefaults() {
        let settings = UpdateSettings.load { _ in nil }

        #expect(settings == UpdateSettings())
        #expect(settings.agentEnabled && settings.allowComputerUse && settings.quitRunningApps)
        #expect(settings.sweepDownloads && settings.cleanBrewCache)
        #expect(settings.agent == AgentSettings(allowComputerUse: true, model: nil, maxAICredits: 60, timeout: 1200))
    }

    @Test("reads stored choices and keeps limits within what the CLI accepts")
    func readsStoredValues() {
        // Stored the way UserDefaults hands values back: numbers and booleans as NSNumber.
        let stored: [String: Any] = [
            UpdateSettings.Key.agentEnabled: NSNumber(value: false),
            UpdateSettings.Key.allowComputerUse: false,
            UpdateSettings.Key.agentModel: "  example-model ",
            UpdateSettings.Key.agentMaxCredits: NSNumber(value: 5),
            UpdateSettings.Key.agentTimeoutMinutes: 600,
        ]

        let settings = UpdateSettings.load { stored[$0] }

        #expect(!settings.agentEnabled)
        #expect(!settings.allowComputerUse)
        #expect(settings.quitRunningApps)
        #expect(settings.agentMaxCredits == 30)
        #expect(settings.agentTimeoutMinutes == 120)
        #expect(settings.agent.model == "example-model")
        #expect(!settings.agent.allowComputerUse)
        #expect(settings.agent.timeout == 7200)
    }

    @Test("keeps the default when a stored value has the wrong type")
    func ignoresMalformedValues() {
        let stored: [String: Any] = [
            UpdateSettings.Key.agentEnabled: "no",
            UpdateSettings.Key.agentMaxCredits: "lots",
            UpdateSettings.Key.agentModel: 42,
        ]

        #expect(UpdateSettings.load { stored[$0] } == UpdateSettings())
    }
}

@Suite("Headless commands")
struct HeadlessCommandTests {

    @Test("recognises its own options", arguments: [
        (["--scan"], HeadlessCommand.scan),
        (["--update-all"], .updateAll(dryRun: false)),
        (["--update-all", "--dry-run"], .updateAll(dryRun: true)),
        (["--dry-run", "--update-all"], .updateAll(dryRun: true)),
        (["--help"], .help),
        (["-h"], .help),
        (["--update-all", "--help"], .help),
    ])
    func parsesOptions(arguments: [String], command: HeadlessCommand) {
        #expect(HeadlessCommand(arguments: arguments) == command)
    }

    @Test("opens the window for no arguments or ones macOS adds itself", arguments: [
        [],
        ["-NSDocumentRevisionsDebugMode", "YES"],
        ["-psn_0_12345"],
        ["--dry-run"],
    ])
    func ignoresOtherArguments(arguments: [String]) {
        #expect(HeadlessCommand(arguments: arguments) == nil)
    }

    @Test("prints each kind of log entry distinctly")
    func formatsLogEntries() {
        func entry(_ level: UpdateLogEntry.Level) -> UpdateLogEntry {
            UpdateLogEntry(id: 0, date: Date(), level: level, text: "text")
        }

        #expect(HeadlessRunner.format(entry(.phase)) == "\n==> text")
        #expect(HeadlessRunner.format(entry(.success)) == "  ✓ text")
        #expect(HeadlessRunner.format(entry(.error)) == "  ✗ text")
        #expect(HeadlessRunner.marker(for: .updated("x")) == "✓")
        #expect(HeadlessRunner.marker(for: .needsAttention("x")) == "!")
    }
}

@Suite("Run log")
struct RunLogTests {

    private let utc = TimeZone(identifier: "UTC")!

    @Test("writes a run as text, with the time of each entry and the result of each item")
    func formatsRun() {
        func entry(_ id: Int, _ level: UpdateLogEntry.Level, _ text: String) -> UpdateLogEntry {
            UpdateLogEntry(id: id, date: Date(timeIntervalSince1970: 3600 + Double(id)), level: level, text: text)
        }

        let text = RunLog.text(
            log: [
                entry(0, .phase, "Updating Homebrew"),
                entry(1, .info, "brew upgrade (1 package(s))"),
                entry(2, .detail, "  ==> Upgrading tool"),
                entry(3, .success, "tool: linked it again"),
                entry(4, .warning, "The GitHub Copilot CLI does not start"),
                entry(5, .error, "Browser: Gatekeeper rejected the download"),
            ],
            items: [
                UpdateItem(id: "homebrew", category: .homebrew, name: "Homebrew packages", state: .updated("Upgraded 1 package(s)")),
                UpdateItem(id: "app:/Applications/Browser.app", category: .app, name: "Browser",
                           state: .failed("Gatekeeper rejected the download")),
            ],
            timeZone: utc
        )

        #expect(text == """
        01:00:00 ==> Updating Homebrew
        01:00:01   brew upgrade (1 package(s))
        01:00:02     ==> Upgrading tool
        01:00:03   ✓ tool: linked it again
        01:00:04   ! The GitHub Copilot CLI does not start
        01:00:05   ✗ Browser: Gatekeeper rejected the download

        Results
          ✓ Homebrew packages: Upgraded 1 package(s)
          ✗ Browser: Gatekeeper rejected the download

        """)
    }

    @Test("keeps the logs of the most recent runs, and nothing else's files")
    func keepsRecentLogs() throws {
        let scratch = try TemporaryDirectory()
        let directory = try scratch.makeDirectory("Logs/Guava")
        try scratch.write("mine", to: "Logs/Guava/notes.txt")

        var last: URL?
        for run in 0..<(RunLog.kept + 2) {
            last = RunLog.write(
                "run \(run)\n", started: Date(timeIntervalSince1970: Double(run) * 60), in: directory, timeZone: utc
            )
        }

        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        let newest = try #require(last)
        #expect(names.count == RunLog.kept + 1)
        #expect(names.first == "notes.txt")
        // The two oldest runs have gone.
        #expect(names[1] == "update-1970-01-01-000200.log")
        #expect(newest.lastPathComponent == "update-1970-01-01-002100.log")
        #expect(try String(contentsOf: newest, encoding: .utf8) == "run 21\n")
    }
}

@Suite("Version comparison")
struct VersionComparisonTests {

    @Test("treats a bracketed build number as the last version segment", arguments: [
        ("7.2.5 (90525)", "7.2.5.90525"),
        ("3.1 (22)", "3.1.22"),
        ("12 (4)", "12.4"),
    ])
    func normalisesBracketedBuilds(raw: String, cleaned: String) {
        #expect(VersionChecker.cleanVersion(raw) == cleaned)
    }

    @Test("leaves other version formats as they were", arguments: [
        ("1.2.3,456", "1.2.3"),
        ("0.4.2+2", "0.4.2"),
        ("16.105.26020123", "16.105.26020123"),
        ("2.0 (beta)", "2.0 (beta)"),
        ("", "0"),
    ])
    func keepsOtherFormats(raw: String, cleaned: String) {
        #expect(VersionChecker.cleanVersion(raw) == cleaned)
    }

    @Test("no longer reports an update when only the way the build is written differs")
    func comparesBracketedBuilds() {
        func compare(_ installed: String, _ latest: String) -> ComparisonResult {
            VersionChecker.compareVersions(
                VersionChecker.cleanVersion(installed), VersionChecker.cleanVersion(latest)
            )
        }

        #expect(compare("7.2.5 (90525)", "7.2.5.90525") == .orderedSame)
        #expect(compare("7.2.5 (90525)", "7.2.6.91000") == .orderedAscending)
        #expect(compare("3.1 (22)", "3.1") != .orderedAscending)
        #expect(compare("3.1 (22)", "3.2") == .orderedAscending)
    }
}

@Suite("Homebrew cleanup output")
struct BrewCleanupOutputTests {

    @Test("reads how much space brew cleanup says it freed", arguments: [
        ("==> This operation has freed approximately 939.2MB of disk space.", Int64(984_822_579)),
        ("Removing: x\n==> This operation has freed approximately 12KB of disk space.\n", Int64(12_288)),
        ("==> This operation has freed approximately 1.5GB of disk space.", Int64(1_610_612_736)),
        ("==> This operation has freed approximately 512B of disk space.", Int64(512)),
    ])
    func parsesFreedSpace(output: String, bytes: Int64) {
        #expect(BrewHelper.parseFreedBytes(from: output) == bytes)
    }

    @Test("has no figure when brew cleanup removed nothing or printed something unexpected")
    func handlesMissingFigure() {
        #expect(BrewHelper.parseFreedBytes(from: "") == nil)
        #expect(BrewHelper.parseFreedBytes(from: "Warning: Skipping jq: most recent version not installed") == nil)
        #expect(BrewHelper.parseFreedBytes(from: "freed approximately lots of space") == nil)
    }
}
