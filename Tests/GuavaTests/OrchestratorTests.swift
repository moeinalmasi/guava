import Foundation
import Testing
@testable import Guava

/// A scripted Mac. Records everything the orchestrator asks it to do.
@MainActor
final class FakeEnvironment: UpdateEnvironment {
    var settings = UpdateSettings()
    var hasHomebrew = true

    // The scripted world.
    var apps: [AppInfo] = []
    var brewPackages: [BrewUpdateInfo] = []
    var tools: [DevToolInfo] = []
    var managedPaths: Set<String> = []
    var agent: CopilotCLI? = CopilotCLI(
        executablePath: "/fake/copilot",
        environment: ToolEnvironment(home: URL(fileURLWithPath: "/fake/home"), inherited: [:], includeSystemLocations: false)
    )
    var installedVersions: [String: String] = [:]
    var rootOwned: Set<String> = []
    var running: Set<String> = []
    var quitResults: [String: RunningApps.QuitResult] = [:]
    var agentOutcomes: [String: AgentUpdateOutcome] = [:]
    var appStoreOutcome: AgentUpdateOutcome = .updateTriggered(notes: nil)
    var toolOutcomes: [String: ToolUpdateOutcome] = [:]
    var failingCasks: Set<String> = []
    /// Casks Homebrew reports as upgraded while the app on disk stays as it was.
    var casksLeftUnchanged: Set<String> = []
    var brewRemaining: [String] = []
    var brewNeedsAuthentication = false
    /// As when the run is stopped mid-way: Homebrew can no longer be asked what is installed.
    var brewListingFailsWhenStopped = false
    /// `brew upgrade` ran, but the installed packages could not be listed afterwards.
    var brewListingFailsAfterUpgrade = false
    var installOutcomes: [String: InstallOutcome] = [:]
    /// Staged payloads whose installer reports success without changing the app.
    var installsThatChangeNothing: Set<String> = []
    /// Installed copies whose signature cannot be read.
    var unreadableSignatures: Set<String> = []
    var administratorApproves = true
    var cleanupReport = CleanupReport()
    /// Versions that appear only when the Mac is scanned again, as if another updater finished.
    var versionsAfterRescan: [String: String] = [:]
    /// Called with each step as it is recorded, so a test can interfere mid-run.
    var onStep: ((String) -> Void)?
    /// Awaited while a tool is being updated, so a test can look at the run while it is paused there.
    var whileUpdatingTool: (@MainActor (DevToolInfo) async -> Void)?

    // What happened.
    private(set) var steps: [String] = []
    private(set) var installBatches: [(operations: [InstallOperation], asAdministrator: Bool, prompt: String?)] = []
    private(set) var cleanedRunDirectory: URL??
    /// How often the Downloads folder was looked at, and what cleanup was told had been there.
    private(set) var downloadsSnapshotCount = 0
    private(set) var cleanedDownloadsSnapshot: Set<String>?
    private(set) var appStoreTasks: [[AppStoreUpdateTask]] = []
    /// Whether each scan was allowed to record the time it ran.
    private(set) var scansPersisted: [Bool] = []
    private var stagedVersions: [String: (appPath: String, version: String)] = [:]
    private var scanCount = 0

    private func record(_ step: String) {
        steps.append(step)
        onStep?(step)
    }

    func scan(_ model: GuavaViewModel, persistTimestamp: Bool) async {
        scanCount += 1
        scansPersisted.append(persistTimestamp)
        record("scan")
        if scanCount > 1 {
            installedVersions.merge(versionsAfterRescan) { _, new in new }
        }
        for app in apps {
            if let version = installedVersions[app.path] {
                app.currentVersion = version
            }
            app.heldBack = nil
            if let latest = app.latestVersion {
                app.updateStatus = app.currentVersion == latest ? .upToDate : .updateAvailable
            }
        }
        model.apps = apps
        // As the real check does once every app has been looked at.
        model.settleCheck()
        model.brewUpdates = brewPackages
        model.devTools = tools
        model.dotEntryCount = 7
    }

    func microsoftManagedPaths() async -> Set<String> { managedPaths }
    func locateAgent() -> CopilotCLI? { agent }
    func mcpServers(for cli: CopilotCLI) async -> [String] { ["computer-use", "github-mcp-server"] }
    func installedVersion(of app: AppInfo) -> String? { installedVersions[app.path] }

    func refreshHomebrew(onLine: ProcessRunner.LineHandler?) async -> ProcessResult {
        record("brew update")
        return ProcessResult(exitCode: 0, stdout: "", stderr: "", timedOut: false, wasCancelled: false, launchError: nil)
    }

    func reloadHomebrew(_ model: GuavaViewModel) async {
        model.brewUpdates = brewListingFailsWhenStopped && Task.isCancelled ? [] : brewPackages
    }

    func upgradeHomebrew(_ model: GuavaViewModel, onLine: ProcessRunner.LineHandler?) async -> BrewUpgradeResult {
        record("brew upgrade")
        onLine?("==> Upgrading packages", .stdout)
        let pending = brewPackages.filter(\.canUpdate).map(\.token)
        if brewListingFailsAfterUpgrade {
            return BrewUpgradeResult(upgraded: [], remaining: pending, isVerified: false)
        }
        brewPackages = brewPackages.map { package in
            let stillOutdated = brewRemaining.contains(package.token)
            return BrewUpdateInfo(
                token: package.token, kind: package.kind,
                installedVersion: stillOutdated ? package.installedVersion : package.latestVersion,
                latestVersion: package.latestVersion, isPinned: package.isPinned,
                hasUpdate: stillOutdated, needsRepair: false
            )
        }
        model.brewUpdates = brewPackages
        return BrewUpgradeResult(
            upgraded: pending.filter { !brewRemaining.contains($0) },
            remaining: brewRemaining,
            errorOutput: brewNeedsAuthentication ? "sudo: a terminal is required" : "",
            needsAuthentication: brewNeedsAuthentication
        )
    }

    func updateTool(_ info: DevToolInfo, onLine: ProcessRunner.LineHandler?) async -> ToolUpdateOutcome {
        record("tool:\(info.id)")
        await whileUpdatingTool?(info)
        return toolOutcomes[info.id] ?? .alreadyCurrent("1.0")
    }

    func upgradeCask(_ app: AppInfo) async -> Bool {
        record("cask:\(app.name)")
        guard !failingCasks.contains(app.name) else {
            app.updateError = "Error: download failed"
            return false
        }
        if !casksLeftUnchanged.contains(app.name) {
            installedVersions[app.path] = app.latestVersion
        }
        return true
    }

    func agentTask(for app: AppInfo) async -> AgentTaskContext {
        let isRootOwned = rootOwned.contains(app.path)
        return AgentTaskContext(
            task: AppUpdateTask(
                name: app.name, bundleIdentifier: app.bundleIdentifier, installedPath: app.path,
                installedVersion: app.currentVersion, latestKnownVersion: app.latestVersion,
                expectedTeamIdentifier: "ABCDE12345", download: nil, sparkleFeedURL: nil,
                ownedByRoot: isRootOwned, isRunning: running.contains(app.path),
                computerUseAllowed: settings.allowComputerUse
            ),
            teamIdentifier: "ABCDE12345",
            route: isRootOwned ? .administrator : .user,
            owner: isRootOwned ? "0:0" : "501:80",
            signatureProblem: unreadableSignatures.contains(app.path) ? "codesign timed out" : nil
        )
    }

    func prepareUpdate(
        for task: AppUpdateTask, cli: CopilotCLI, runDirectory: URL, mcpServers: [String],
        onEvent: @escaping @Sendable (AgentEvent) -> Void
    ) async -> AgentUpdateReport {
        record("agent:\(task.name)")
        onEvent(.toolStarted(tool: "bash", summary: "curl -fL -o downloads/app.dmg"))
        let outcome = agentOutcomes[task.name] ?? .failed("No download found")
        if case .staged(let payload) = outcome {
            stagedVersions[payload.url.path] = (task.installedPath, payload.version ?? task.latestKnownVersion ?? "?")
        }
        return AgentUpdateReport(outcome: outcome, workspace: runDirectory, premiumRequests: 1)
    }

    func updateAppStore(
        _ apps: [AppStoreUpdateTask], cli: CopilotCLI, runDirectory: URL, mcpServers: [String],
        onEvent: @escaping @Sendable (AgentEvent) -> Void
    ) async -> AgentUpdateReport {
        record("agent:app-store")
        appStoreTasks.append(apps)
        return AgentUpdateReport(outcome: appStoreOutcome, workspace: runDirectory, premiumRequests: 2)
    }

    func openAppStoreUpdates() {
        record("open app store")
    }

    func isRunning(_ app: AppInfo) -> Bool { running.contains(app.path) }

    func quit(_ app: AppInfo) async -> RunningApps.QuitResult {
        record("quit:\(app.name)")
        let result = quitResults[app.path] ?? .quit
        if result == .quit {
            running.remove(app.path)
        }
        return result
    }

    func relaunch(_ app: AppInfo) {
        record("relaunch:\(app.name)")
    }

    func install(_ operations: [InstallOperation], asAdministrator: Bool, prompt: String?) async -> [InstallOutcome] {
        record(asAdministrator ? "install as administrator" : "install")
        installBatches.append((operations, asAdministrator, prompt))
        guard !asAdministrator || administratorApproves else {
            return operations.map { _ in .notAuthorized }
        }
        return operations.map { operation in
            let staged: String
            switch operation {
            case .replaceApp(let path, _, _, _, _, _): staged = path
            case .installPackage(let path, _, _): staged = path
            }
            let outcome = installOutcomes[staged] ?? .installed(note: nil)
            if outcome.isInstalled, !installsThatChangeNothing.contains(staged), let target = stagedVersions[staged] {
                installedVersions[target.appPath] = target.version
            }
            return outcome
        }
    }

    func makeRunDirectory() throws -> URL {
        record("make staging folder")
        return URL(fileURLWithPath: "/stage/run-1")
    }

    func removeAbandonedRuns() async {
        record("remove abandoned runs")
    }

    func downloadsSnapshot() -> Set<String> {
        downloadsSnapshotCount += 1
        return ["existing.dmg"]
    }

    func cleanUp(
        runDirectory: URL?, since start: Date, downloadsSnapshot: Set<String>, onLine: ProcessRunner.LineHandler?
    ) async -> CleanupReport {
        record("cleanup")
        cleanedRunDirectory = .some(runDirectory)
        cleanedDownloadsSnapshot = downloadsSnapshot
        return cleanupReport
    }
}

@Suite("Update Everything")
@MainActor
struct UpdateOrchestratorTests {

    private func makeApp(
        _ name: String,
        installed: String = "1.0",
        latest: String? = "2.0",
        method: UpdateMethod = .manual,
        receipt: Bool = false
    ) -> AppInfo {
        let app = AppInfo(
            name: name, bundleIdentifier: "com.example.\(name.lowercased())", currentVersion: installed,
            path: "/Applications/\(name).app", icon: nil, hasAppStoreReceipt: receipt
        )
        app.latestVersion = latest
        app.updateMethod = method
        app.updateStatus = latest != nil && latest != installed ? .updateAvailable : .upToDate
        return app
    }

    private func staged(_ name: String, kind: PayloadKind = .app, version: String = "2.0") -> AgentUpdateOutcome {
        let file = kind == .app ? "\(name).app" : "\(name).pkg"
        return .staged(VerifiedPayload(
            url: URL(fileURLWithPath: "/stage/run-1/\(name.lowercased())/payload/\(file)"),
            kind: kind, version: kind == .app ? version : nil, teamIdentifier: "ABCDE12345",
            bundleIdentifier: kind == .app ? "com.example.\(name.lowercased())" : nil
        ))
    }

    private func makeTool(_ id: String, name: String) -> DevToolInfo {
        DevToolInfo(tool: DevTool(
            id: id, name: name, dotEntries: [".\(id)"],
            versionProbe: .none, updateCommand: ToolCommand(executable: "/usr/bin/true", arguments: ["update"])
        ))
    }

    private func outdatedPackage(_ token: String) -> BrewUpdateInfo {
        BrewUpdateInfo(
            token: token, kind: .formula, installedVersion: "1.0", latestVersion: "2.0",
            isPinned: false, hasUpdate: true, needsRepair: false
        )
    }

    /// Runs the orchestrator to completion and returns it with its environment.
    private func run(
        _ environment: FakeEnvironment,
        dryRun: Bool = false
    ) async -> (orchestrator: UpdateOrchestrator, summary: UpdateSummary, model: GuavaViewModel) {
        let model = GuavaViewModel()
        let orchestrator = UpdateOrchestrator(model: model) { environment }
        let summary = await orchestrator.run(dryRun: dryRun)
        return (orchestrator, summary, model)
    }

    private func state(of name: String, in orchestrator: UpdateOrchestrator) -> UpdateItemState? {
        orchestrator.items.first { $0.name == name }?.state
    }

    @Test("updates Homebrew, tools and apps in order, then cleans up and rescans")
    func runsPhasesInOrder() async {
        let environment = FakeEnvironment()
        environment.brewPackages = [outdatedPackage("jq")]
        environment.tools = [makeTool("bun", name: "Bun")]
        environment.apps = [makeApp("Cask", method: .homebrew), makeApp("Direct")]
        environment.agentOutcomes = ["Direct": staged("Direct")]

        let (orchestrator, summary, _) = await run(environment)

        #expect(environment.steps == [
            "remove abandoned runs",
            "scan",
            "brew update",
            "brew upgrade",
            "tool:bun",
            "make staging folder",
            "cask:Cask",
            "agent:Direct",
            "install",
            "cleanup",
            "scan",
        ])
        #expect(state(of: "Homebrew packages", in: orchestrator) == .updated("Upgraded 1 package(s)"))
        #expect(state(of: "Bun", in: orchestrator) == .unchanged("Already up to date (1.0)"))
        #expect(state(of: "Cask", in: orchestrator) == .updated("1.0 → 2.0"))
        #expect(state(of: "Direct", in: orchestrator) == .updated("1.0 → 2.0"))
        #expect(summary.updated == 3)
        #expect(summary.premiumRequests == 1)
        #expect(summary.isClean)
        #expect(environment.scansPersisted == [true, true])
        #expect(orchestrator.phase == .finished)
        #expect(!orchestrator.isRunning)
    }

    @Test("installs a verified download pinned to its developer, identity and version, with ownership kept")
    func installsStagedPayloadStrictly() async {
        let environment = FakeEnvironment()
        environment.apps = [makeApp("Direct")]
        environment.agentOutcomes = ["Direct": staged("Direct")]

        _ = await run(environment)

        #expect(environment.installBatches.count == 1)
        #expect(environment.installBatches[0].asAdministrator == false)
        #expect(environment.installBatches[0].operations == [.replaceApp(
            staged: "/stage/run-1/direct/payload/Direct.app",
            destination: "/Applications/Direct.app",
            owner: "501:80",
            teamIdentifier: "ABCDE12345",
            requireGatekeeper: true,
            identity: BundleIdentity(bundleIdentifier: "com.example.direct", version: "2.0")
        )])
    }

    @Test("asks for an administrator once, at the end, for everything that needs one")
    func batchesAdministratorInstalls() async {
        let environment = FakeEnvironment()
        environment.apps = [makeApp("RootOne"), makeApp("UserApp"), makeApp("RootTwo"), makeApp("Packaged")]
        environment.rootOwned = ["/Applications/RootOne.app", "/Applications/RootTwo.app"]
        environment.agentOutcomes = [
            "RootOne": staged("RootOne"),
            "UserApp": staged("UserApp"),
            "RootTwo": staged("RootTwo"),
            "Packaged": staged("Packaged", kind: .pkg),
        ]

        let (orchestrator, summary, _) = await run(environment)

        let administratorBatches = environment.installBatches.filter(\.asAdministrator)
        #expect(administratorBatches.count == 1)
        #expect(administratorBatches[0].operations == [
            .replaceApp(
                staged: "/stage/run-1/rootone/payload/RootOne.app", destination: "/Applications/RootOne.app",
                owner: "0:0", teamIdentifier: "ABCDE12345", requireGatekeeper: true,
                identity: BundleIdentity(bundleIdentifier: "com.example.rootone", version: "2.0")
            ),
            .replaceApp(
                staged: "/stage/run-1/roottwo/payload/RootTwo.app", destination: "/Applications/RootTwo.app",
                owner: "0:0", teamIdentifier: "ABCDE12345", requireGatekeeper: true,
                identity: BundleIdentity(bundleIdentifier: "com.example.roottwo", version: "2.0")
            ),
            .installPackage(
                path: "/stage/run-1/packaged/payload/Packaged.pkg", teamIdentifier: "ABCDE12345",
                requireGatekeeper: true
            ),
        ])
        #expect(administratorBatches[0].prompt == "Guava wants to install updates for RootOne, RootTwo, Packaged.")
        // The administrator step comes after every agent session and before cleanup.
        let adminIndex = environment.steps.firstIndex(of: "install as administrator")!
        #expect(environment.steps.lastIndex { $0.hasPrefix("agent:") }! < adminIndex)
        #expect(adminIndex < environment.steps.firstIndex(of: "cleanup")!)
        #expect(state(of: "RootOne", in: orchestrator) == .updated("1.0 → 2.0"))
        #expect(state(of: "UserApp", in: orchestrator) == .updated("1.0 → 2.0"))
        #expect(state(of: "RootTwo", in: orchestrator) == .updated("1.0 → 2.0"))
        #expect(state(of: "Packaged", in: orchestrator) == .updated("1.0 → 2.0"))
        #expect(summary.updated == 4)
        #expect(summary.failed == 0)
    }

    @Test("reports what was not installed when the administrator prompt is declined")
    func handlesDeclinedAdministratorPrompt() async {
        let environment = FakeEnvironment()
        environment.apps = [makeApp("RootOne")]
        environment.rootOwned = ["/Applications/RootOne.app"]
        environment.running = ["/Applications/RootOne.app"]
        environment.agentOutcomes = ["RootOne": staged("RootOne")]
        environment.administratorApproves = false

        let (orchestrator, summary, _) = await run(environment)

        #expect(state(of: "RootOne", in: orchestrator)
            == .needsAttention("Not installed: an administrator did not approve it"))
        #expect(environment.apps[0].currentVersion == "1.0")
        #expect(environment.apps[0].updateStatus == .updateAvailable)
        // An app that was quit for the install is reopened either way.
        #expect(environment.steps.contains("relaunch:RootOne"))
        #expect(summary.needsAttention == 1)
        #expect(!summary.isClean)
        // The staged download is still deleted.
        #expect(environment.steps.contains("cleanup"))
    }

    @Test("believes the installed version over a step that reported failure")
    func trustsWhatIsInstalled() async {
        let environment = FakeEnvironment()
        environment.apps = [makeApp("RootOne"), makeApp("RootTwo")]
        environment.rootOwned = ["/Applications/RootOne.app", "/Applications/RootTwo.app"]
        environment.agentOutcomes = ["RootOne": staged("RootOne"), "RootTwo": staged("RootTwo")]
        // The administrator step ran out of time, but had already replaced the first app.
        let timedOut = InstallOutcome.failed("Not finished in time")
        environment.installOutcomes = [
            "/stage/run-1/rootone/payload/RootOne.app": timedOut,
            "/stage/run-1/roottwo/payload/RootTwo.app": timedOut,
        ]
        environment.versionsAfterRescan = ["/Applications/RootOne.app": "2.0"]

        let (orchestrator, summary, _) = await run(environment)

        #expect(state(of: "RootOne", in: orchestrator) == .updated("1.0 → 2.0"))
        #expect(state(of: "RootTwo", in: orchestrator) == .failed("Not finished in time"))
        #expect(summary.updated == 1)
        #expect(summary.failed == 1)
    }

    @Test("changes nothing during a dry run but still reports the plan")
    func dryRunOnlyScans() async {
        let environment = FakeEnvironment()
        environment.brewPackages = [outdatedPackage("jq")]
        environment.tools = [makeTool("bun", name: "Bun")]
        environment.apps = [makeApp("Direct"), makeApp("Store", receipt: true)]

        let (orchestrator, summary, _) = await run(environment, dryRun: true)

        // Only the scan: a preview does not even clear out what an earlier run left behind.
        #expect(environment.steps == ["scan"])
        #expect(environment.installBatches.isEmpty)
        // Nor does it look at the Downloads folder, which would make macOS ask for permission.
        #expect(environment.downloadsSnapshotCount == 0)
        // A preview leaves nothing behind, not even the time of the scan.
        #expect(environment.scansPersisted == [false])
        #expect(summary.wasDryRun)
        #expect(orchestrator.items.isEmpty)
        #expect(orchestrator.plan == UpdatePlan(
            brewPackages: ["jq"],
            tools: ["Bun"],
            apps: [
                .init(name: "Direct", installedVersion: "1.0", latestVersion: "2.0", route: .agent),
                .init(name: "Store", installedVersion: "1.0", latestVersion: "2.0", route: .appStore),
            ]
        ))
    }

    @Test("still deletes downloads when the run is stopped part-way")
    func stoppingStillCleansUp() async throws {
        let environment = FakeEnvironment()
        environment.brewPackages = [outdatedPackage("jq")]
        environment.brewRemaining = ["jq"]
        environment.tools = [makeTool("bun", name: "Bun")]
        environment.apps = [makeApp("Direct")]
        environment.agentOutcomes = ["Direct": staged("Direct")]

        let model = GuavaViewModel()
        let orchestrator = UpdateOrchestrator(model: model) { environment }
        environment.onStep = { step in
            if step == "brew upgrade" {
                orchestrator.cancel()
            }
        }

        orchestrator.start()
        while orchestrator.summary == nil || orchestrator.isRunning {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let summary = try #require(orchestrator.summary)

        #expect(summary.wasCancelled)
        #expect(!summary.isClean)
        #expect(!environment.steps.contains("tool:bun"))
        #expect(!environment.steps.contains { $0.hasPrefix("agent:") })
        #expect(environment.installBatches.isEmpty)
        #expect(environment.steps.last == "cleanup")
        #expect(state(of: "Homebrew packages", in: orchestrator) == .skipped("Stopped after upgrading 0 of 1"))
        #expect(summary.headline.hasPrefix("Stopped:"))
    }

    /// Starts a run the way the button does and waits for it, so that a test can press Stop.
    /// The model is passed along because the orchestrator does not keep it alive itself.
    private func runUntilFinished(
        _ orchestrator: UpdateOrchestrator, model: GuavaViewModel
    ) async throws -> UpdateSummary {
        orchestrator.start()
        while orchestrator.summary == nil || orchestrator.isRunning {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        return try withExtendedLifetime(model) { try #require(orchestrator.summary) }
    }

    @Test("keeps Stop connected to the run when the button is pressed twice in one go")
    func startingTwiceKeepsStopWorking() async throws {
        let environment = FakeEnvironment()
        environment.brewPackages = [outdatedPackage("jq")]
        environment.brewRemaining = ["jq"]
        let model = GuavaViewModel()
        let orchestrator = UpdateOrchestrator(model: model) { environment }
        environment.onStep = { step in
            if step == "brew upgrade" {
                orchestrator.cancel()
            }
        }

        // Neither call has begun running yet when the second one arrives.
        orchestrator.start()
        orchestrator.start()
        let summary = try await runUntilFinished(orchestrator, model: model)

        #expect(summary.wasCancelled)
        #expect(environment.steps.filter { $0 == "brew upgrade" }.count == 1)
        #expect(environment.steps.last == "cleanup")
    }

    @Test("does not mistake a stopped run for having nothing to upgrade")
    func stoppingDuringBrewUpdateClaimsNothing() async throws {
        let environment = FakeEnvironment()
        environment.brewPackages = [outdatedPackage("jq")]
        environment.brewListingFailsWhenStopped = true
        let model = GuavaViewModel()
        let orchestrator = UpdateOrchestrator(model: model) { environment }
        environment.onStep = { step in
            if step == "brew update" {
                orchestrator.cancel()
            }
        }

        let summary = try await runUntilFinished(orchestrator, model: model)

        #expect(!environment.steps.contains("brew upgrade"))
        #expect(state(of: "Homebrew packages", in: orchestrator) == .skipped("Stopped before it started"))
        #expect(summary.updated == 0)
        #expect(summary.unchanged == 1)   // only the cleanup item
        #expect(summary.wasCancelled)
    }

    @Test("does not call packages upgraded when Homebrew could not be asked afterwards")
    func reportsUnverifiedBrewUpgrade() async {
        let environment = FakeEnvironment()
        environment.brewPackages = [outdatedPackage("jq"), outdatedPackage("fd")]
        environment.brewListingFailsAfterUpgrade = true

        let (orchestrator, summary, _) = await run(environment)

        #expect(state(of: "Homebrew packages", in: orchestrator) == .needsAttention(
            "brew upgrade ran, but the installed packages could not be listed to confirm what changed"
        ))
        #expect(summary.updated == 0)
        #expect(!summary.isClean)
    }

    @Test("closes nothing and installs nothing once Stop is pressed while apps are being closed")
    func stoppingWhileClosingAppsReopensThem() async throws {
        let environment = FakeEnvironment()
        environment.apps = [makeApp("RootOne"), makeApp("RootTwo")]
        environment.rootOwned = ["/Applications/RootOne.app", "/Applications/RootTwo.app"]
        environment.running = ["/Applications/RootOne.app", "/Applications/RootTwo.app"]
        environment.agentOutcomes = ["RootOne": staged("RootOne"), "RootTwo": staged("RootTwo")]
        let model = GuavaViewModel()
        let orchestrator = UpdateOrchestrator(model: model) { environment }
        environment.onStep = { step in
            if step == "quit:RootOne" {
                orchestrator.cancel()
            }
        }

        let summary = try await runUntilFinished(orchestrator, model: model)

        // The first app had already been asked to quit; the second is never touched.
        #expect(!environment.steps.contains("quit:RootTwo"))
        #expect(!environment.steps.contains("install as administrator"))
        #expect(environment.steps.contains("relaunch:RootOne"))
        #expect(!environment.steps.contains("relaunch:RootTwo"))
        #expect(state(of: "RootOne", in: orchestrator) == .skipped("Stopped"))
        #expect(state(of: "RootTwo", in: orchestrator) == .skipped("Stopped"))
        #expect(environment.steps.last == "cleanup")
        #expect(summary.wasCancelled)
    }

    @Test("reopens an app that closed only after Guava had stopped waiting for it")
    func reopensAppsThatCloseLate() async {
        let environment = FakeEnvironment()
        environment.apps = [makeApp("Slow")]
        environment.running = ["/Applications/Slow.app"]
        environment.quitResults = ["/Applications/Slow.app": .refused]
        environment.agentOutcomes = ["Slow": staged("Slow")]
        // It finishes saving and closes while the run is tidying up.
        environment.onStep = { step in
            if step == "cleanup" {
                environment.running.remove("/Applications/Slow.app")
            }
        }

        let (orchestrator, _, _) = await run(environment)

        #expect(environment.installBatches.isEmpty)
        #expect(environment.steps.last == "relaunch:Slow")
        #expect(state(of: "Slow", in: orchestrator) == .needsAttention(
            "Slow did not quit, perhaps because of unsaved changes, so it was left alone"
        ))
        #expect(orchestrator.log.contains { $0.text == "Slow closed after it was asked to quit; reopening it" })
    }

    @Test("does not report an update when the installed version did not change")
    func requiresVersionToChange() async {
        let environment = FakeEnvironment()
        environment.apps = [makeApp("Packaged"), makeApp("Cask", method: .homebrew)]
        environment.agentOutcomes = ["Packaged": staged("Packaged", kind: .pkg)]
        // The installer ran without error but put nothing new where the app is.
        environment.installsThatChangeNothing = ["/stage/run-1/packaged/payload/Packaged.pkg"]
        environment.casksLeftUnchanged = ["Cask"]

        let (orchestrator, summary, _) = await run(environment)

        #expect(state(of: "Packaged", in: orchestrator)
            == .needsAttention("The installer finished, but Packaged is still at version 1.0"))
        // By Homebrew's own record there was nothing to upgrade: that is an answer, not a fault.
        #expect(state(of: "Cask", in: orchestrator) == .unchanged("Homebrew has nothing newer than 1.0"))
        #expect(environment.apps[0].updateStatus == .updateAvailable)
        #expect(summary.updated == 0)
        #expect(summary.needsAttention == 1)
    }

    @Test("shows an app as up to date once its own updater has had the update and it did not arrive")
    func holdsBackWhatDidNotArrive() async {
        let environment = FakeEnvironment()
        environment.apps = [
            makeApp("Store", receipt: true), makeApp("Current"), makeApp("SelfUpdating"),
            makeApp("Cask", method: .homebrew), makeApp("Broken"), makeApp("Arrives"),
        ]
        environment.appStoreOutcome = .upToDate(notes: nil)
        environment.agentOutcomes = [
            "Current": .upToDate(notes: nil),
            "SelfUpdating": .updateTriggered(notes: nil),
            "Broken": .failed("Signed by a different developer"),
            "Arrives": .updateTriggered(notes: nil),
        ]
        environment.casksLeftUnchanged = ["Cask"]
        // One updater finishes its work before the run looks again.
        environment.versionsAfterRescan = ["/Applications/Arrives.app": "2.0"]

        let (orchestrator, summary, model) = await run(environment)
        func app(_ name: String) -> AppInfo? { environment.apps.first { $0.name == name } }

        #expect(state(of: "Store", in: orchestrator) == .unchanged("The App Store lists no update"))
        #expect(state(of: "Current", in: orchestrator) == .unchanged("The vendor offers nothing newer"))
        for name in ["Store", "Current", "SelfUpdating", "Cask"] {
            #expect(app(name)?.updateStatus == .upToDate, "\(name) should be shown as up to date")
            #expect(app(name)?.heldBack == .notInstalled)
        }
        #expect(model.record.held.map(\.name) == ["Cask", "Current", "SelfUpdating", "Store"])
        #expect(model.record.held.first == LocalRecord.HeldUpdate(
            name: "Cask", path: "/Applications/Cask.app", installedVersion: "1.0", latestVersion: "2.0"
        ))
        // A failure is something to try again, and an update that arrived needs no remembering.
        #expect(app("Broken")?.updateStatus == .updateAvailable)
        #expect(app("Broken")?.heldBack == nil)
        #expect(app("Arrives")?.heldBack == nil)
        #expect(state(of: "Arrives", in: orchestrator) == .updated("1.0 → 2.0"))
        #expect(orchestrator.log.contains {
            $0.text == "Store: left to its own updater, and shown as up to date until a version newer than 2.0 appears"
        })
        #expect(summary.failed == 1)
    }

    @Test("does not try again what was not on offer, until a newer version appears")
    func leavesHeldUpdatesAlone() async {
        let environment = FakeEnvironment()
        environment.apps = [makeApp("Store", receipt: true)]
        environment.appStoreOutcome = .upToDate(notes: nil)
        let model = GuavaViewModel()
        let orchestrator = UpdateOrchestrator(model: model) { environment }
        func attempts() -> Int { environment.steps.filter { $0 == "agent:app-store" }.count }

        await orchestrator.run()
        #expect(attempts() == 1)

        let second = await orchestrator.run()
        #expect(attempts() == 1)
        #expect(orchestrator.items.filter { $0.category == .app }.isEmpty)
        #expect(second.isClean)

        environment.apps[0].latestVersion = "3.0"
        await orchestrator.run()
        #expect(attempts() == 2)
        #expect(model.record.held.map(\.latestVersion) == ["3.0"])
    }

    @Test("takes Microsoft AutoUpdate at its word when it has nothing to install")
    func holdsWhatMicrosoftAutoUpdateDoesNotOffer() async {
        let environment = FakeEnvironment()
        environment.tools = [makeTool(DevToolScanner.microsoftAutoUpdateID, name: "Microsoft AutoUpdate")]
        environment.toolOutcomes = [DevToolScanner.microsoftAutoUpdateID: .alreadyCurrent(nil)]
        environment.apps = [makeApp("Alpha")]
        environment.managedPaths = ["/Applications/Alpha.app"]

        let (orchestrator, summary, model) = await run(environment)

        #expect(state(of: "Alpha", in: orchestrator) == .unchanged("Microsoft AutoUpdate offers nothing newer"))
        #expect(environment.apps[0].updateStatus == .upToDate)
        #expect(model.record.held.map(\.name) == ["Alpha"])
        #expect(summary.isClean)
    }

    @Test("does not hand an app to the agent when the installed copy's signature cannot be read")
    func refusesWhenSignatureIsUnreadable() async {
        let environment = FakeEnvironment()
        environment.apps = [makeApp("Opaque"), makeApp("Direct")]
        environment.unreadableSignatures = ["/Applications/Opaque.app"]
        environment.agentOutcomes = ["Opaque": staged("Opaque"), "Direct": staged("Direct")]

        let (orchestrator, summary, _) = await run(environment)

        #expect(!environment.steps.contains("agent:Opaque"))
        #expect(state(of: "Opaque", in: orchestrator) == .failed(
            "Not updated: the signature of the installed copy could not be read (codesign timed out)"
        ))
        #expect(environment.apps[0].updateStatus == .updateAvailable)
        // The rest of the run is unaffected.
        #expect(state(of: "Direct", in: orchestrator) == .updated("1.0 → 2.0"))
        #expect(summary.premiumRequests == 1)
    }

    @Test("hands the staging folder to cleanup and reports the space freed")
    func cleansStagingFolder() async {
        let environment = FakeEnvironment()
        environment.apps = [makeApp("Direct")]
        environment.agentOutcomes = ["Direct": .failed("Checksum mismatch")]
        environment.cleanupReport = CleanupReport(bytesFreed: 1_048_576, removed: ["/stage/run-1"], trashed: ["Stray.dmg"])

        let (orchestrator, summary, _) = await run(environment)

        #expect(environment.cleanedRunDirectory == .some(URL(fileURLWithPath: "/stage/run-1")))
        // Downloads is listed once, before anything runs, so cleanup knows what was already there.
        #expect(environment.downloadsSnapshotCount == 1)
        #expect(environment.cleanedDownloadsSnapshot == ["existing.dmg"])
        #expect(summary.bytesFreed == 1_048_576)
        #expect(state(of: "Downloaded packages", in: orchestrator) == .unchanged("Deleted, 1 MB freed"))
        #expect(orchestrator.log.contains { $0.text == "Moved Stray.dmg from Downloads to the Trash" })
        // A failed download is reported and nothing is installed.
        #expect(state(of: "Direct", in: orchestrator) == .failed("Checksum mismatch"))
        #expect(environment.installBatches.isEmpty)
        #expect(environment.apps[0].currentVersion == "1.0")
    }

    @Test("runs cleanup with no staging folder when no app needed the agent")
    func cleansUpWithoutStaging() async {
        let environment = FakeEnvironment()
        environment.brewPackages = [outdatedPackage("jq")]

        let (orchestrator, _, _) = await run(environment)

        #expect(!environment.steps.contains("make staging folder"))
        #expect(environment.cleanedRunDirectory == .some(nil))
        #expect(state(of: "Downloaded packages", in: orchestrator) == .unchanged("Nothing was left behind"))
    }

    @Test("reports cleanup problems as a failure")
    func reportsCleanupProblems() async {
        let environment = FakeEnvironment()
        environment.cleanupReport = CleanupReport(problems: ["Could not delete /stage/run-1"])

        let (orchestrator, summary, _) = await run(environment)

        #expect(state(of: "Downloaded packages", in: orchestrator) == .failed("Could not delete /stage/run-1"))
        #expect(summary.failed == 1)
    }

    @Test("quits a running app before replacing it and reopens it afterwards")
    func quitsAndRelaunchesRunningApps() async {
        let environment = FakeEnvironment()
        environment.apps = [makeApp("Direct")]
        environment.running = ["/Applications/Direct.app"]
        environment.agentOutcomes = ["Direct": staged("Direct")]

        let (orchestrator, _, _) = await run(environment)

        let steps = environment.steps
        #expect(steps.firstIndex(of: "quit:Direct")! < steps.firstIndex(of: "install")!)
        #expect(steps.firstIndex(of: "install")! < steps.firstIndex(of: "relaunch:Direct")!)
        #expect(state(of: "Direct", in: orchestrator) == .updated("1.0 → 2.0"))
    }

    @Test("leaves an app alone when it will not quit")
    func respectsAppsThatRefuseToQuit() async {
        let environment = FakeEnvironment()
        environment.apps = [makeApp("Direct")]
        environment.running = ["/Applications/Direct.app"]
        environment.quitResults = ["/Applications/Direct.app": .refused]
        environment.agentOutcomes = ["Direct": staged("Direct")]

        let (orchestrator, summary, _) = await run(environment)

        #expect(environment.installBatches.isEmpty)
        #expect(!environment.steps.contains("relaunch:Direct"))
        #expect(state(of: "Direct", in: orchestrator) == .needsAttention(
            "Direct did not quit, perhaps because of unsaved changes, so it was left alone"
        ))
        #expect(environment.apps[0].currentVersion == "1.0")
        #expect(summary.needsAttention == 1)
    }

    @Test("never quits apps when that setting is off")
    func honoursQuitSetting() async {
        let environment = FakeEnvironment()
        environment.settings.quitRunningApps = false
        environment.apps = [makeApp("Direct")]
        environment.running = ["/Applications/Direct.app"]
        environment.agentOutcomes = ["Direct": staged("Direct")]

        let (orchestrator, _, _) = await run(environment)

        #expect(!environment.steps.contains("quit:Direct"))
        #expect(environment.installBatches.isEmpty)
        #expect(state(of: "Direct", in: orchestrator)
            == .needsAttention("Direct is open. Quit it and run Update Everything again"))
    }

    @Test("skips apps that need the agent when the Copilot CLI is missing")
    func skipsWithoutCopilotCLI() async {
        let environment = FakeEnvironment()
        environment.agent = nil
        environment.apps = [makeApp("Direct"), makeApp("Cask", method: .homebrew)]

        let (orchestrator, summary, _) = await run(environment)

        #expect(!environment.steps.contains { $0.hasPrefix("agent:") })
        #expect(!environment.steps.contains("make staging folder"))
        #expect(state(of: "Direct", in: orchestrator)
            == .skipped("Not updated: the GitHub Copilot CLI is not installed"))
        #expect(state(of: "Cask", in: orchestrator) == .updated("1.0 → 2.0"))
        #expect(summary.skipped == 1)
        #expect(orchestrator.log.contains { $0.level == .warning && $0.text.contains("Copilot CLI was not found") })
    }

    @Test("does not look for the agent at all when it is turned off")
    func honoursAgentSetting() async {
        let environment = FakeEnvironment()
        environment.settings.agentEnabled = false
        environment.apps = [makeApp("Direct")]

        let (orchestrator, _, _) = await run(environment)

        #expect(!environment.steps.contains { $0.hasPrefix("agent:") })
        #expect(state(of: "Direct", in: orchestrator)
            == .skipped("Not updated: the Copilot agent is turned off in Settings"))
    }

    @Test("never sends an App Store app to the agent as a download")
    func routesAppStoreAppsToAppStore() async {
        let environment = FakeEnvironment()
        environment.apps = [makeApp("Store", receipt: true), makeApp("Other", receipt: true)]

        let (orchestrator, summary, _) = await run(environment)

        #expect(!environment.steps.contains("agent:Store"))
        #expect(environment.steps.filter { $0 == "agent:app-store" }.count == 1)
        // Guava opens the Updates page itself; the agent only has to press the button.
        #expect(environment.steps.filter { $0 == "open app store" || $0 == "agent:app-store" }
            == ["open app store", "agent:app-store"])
        #expect(environment.appStoreTasks.first?.map(\.name) == ["Store", "Other"])
        #expect(environment.installBatches.isEmpty)
        #expect(state(of: "Store", in: orchestrator) == .started("The App Store is installing it"))
        #expect(summary.started == 2)
        #expect(summary.premiumRequests == 2)
    }

    @Test("opens the App Store for the user when it cannot drive the screen")
    func opensAppStoreWithoutComputerUse() async {
        let environment = FakeEnvironment()
        environment.settings.allowComputerUse = false
        environment.apps = [makeApp("Store", receipt: true)]

        let (orchestrator, _, _) = await run(environment)

        #expect(environment.steps.contains("open app store"))
        #expect(!environment.steps.contains("agent:app-store"))
        #expect(state(of: "Store", in: orchestrator)
            == .needsAttention("Opened the App Store's Updates page: click Update All"))
    }

    @Test("hands the App Store over to the user when the agent cannot finish there")
    func handsOverAppStoreWhenAgentFails() async {
        let environment = FakeEnvironment()
        environment.apps = [makeApp("Store", receipt: true)]
        environment.appStoreOutcome = .failed("Screen Recording permission is missing")

        let (orchestrator, summary, _) = await run(environment)

        // Opened for the agent first, and brought back for the user once the agent gives up.
        #expect(environment.steps.filter { $0 == "open app store" || $0 == "agent:app-store" }
            == ["open app store", "agent:app-store", "open app store"])
        #expect(state(of: "Store", in: orchestrator) == .needsAttention(
            "The agent could not finish in the App Store. Its Updates page is open: click Update All"
        ))
        #expect(orchestrator.log.contains {
            $0.level == .warning && $0.text == "Mac App Store: Screen Recording permission is missing"
        })
        #expect(summary.failed == 0)
        #expect(summary.needsAttention == 1)
    }

    @Test("leaves App Store apps to mas when it has already upgraded them")
    func usesMasWhenInstalled() async {
        let environment = FakeEnvironment()
        environment.tools = [makeTool("mas", name: "Mac App Store")]
        environment.apps = [makeApp("Store", receipt: true)]
        environment.onStep = { step in
            if step == "tool:mas" {
                environment.installedVersions["/Applications/Store.app"] = "2.0"
            }
        }

        let (orchestrator, _, _) = await run(environment)

        #expect(environment.steps.contains("tool:mas"))
        #expect(!environment.steps.contains("agent:app-store"))
        #expect(!environment.steps.contains("open app store"))
        // It was up to date by the time the applications were looked at, so nothing was left to do.
        #expect(state(of: "Store", in: orchestrator) == nil)
        #expect(environment.apps[0].currentVersion == "2.0")
        #expect(environment.apps[0].updateStatus == .upToDate)
    }

    @Test("still goes to the App Store for what mas left as it was")
    func fallsBackWhenMasChangedNothing() async {
        let environment = FakeEnvironment()
        environment.tools = [makeTool("mas", name: "Mac App Store")]
        environment.toolOutcomes = ["mas": .failed("Error: not signed in")]
        environment.apps = [makeApp("Store", receipt: true)]

        let (orchestrator, _, _) = await run(environment)

        #expect(environment.steps.contains("tool:mas"))
        #expect(environment.steps.contains("agent:app-store"))
        #expect(state(of: "Store", in: orchestrator) == .started("The App Store is installing it"))
    }

    @Test("leaves Microsoft's apps to Microsoft AutoUpdate and confirms them on the final scan")
    func defersToMicrosoftAutoUpdate() async {
        let environment = FakeEnvironment()
        environment.apps = [makeApp("Alpha"), makeApp("Bravo")]
        environment.managedPaths = ["/Applications/Alpha.app", "/Applications/Bravo.app"]
        environment.versionsAfterRescan = ["/Applications/Alpha.app": "2.0"]

        let (orchestrator, summary, _) = await run(environment)

        #expect(!environment.steps.contains { $0.hasPrefix("agent:") })
        // Alpha finished updating while the run went on; Bravo is still waiting.
        #expect(state(of: "Alpha", in: orchestrator) == .updated("1.0 → 2.0"))
        #expect(state(of: "Bravo", in: orchestrator)
            == .started("Microsoft AutoUpdate installs it once the app is closed"))
        #expect(summary.updated == 1)
        #expect(summary.started == 1)
    }

    @Test("reports each kind of agent result")
    func mapsAgentOutcomes() async {
        let environment = FakeEnvironment()
        environment.apps = [makeApp("Current"), makeApp("SelfUpdating"), makeApp("Broken")]
        environment.agentOutcomes = [
            "Current": .upToDate(notes: "The vendor's latest is 1.0."),
            "SelfUpdating": .updateTriggered(notes: nil),
            "Broken": .failed("Signed by a different developer"),
        ]

        let (orchestrator, summary, _) = await run(environment)

        #expect(state(of: "Current", in: orchestrator) == .unchanged("The vendor's latest is 1.0."))
        #expect(state(of: "SelfUpdating", in: orchestrator) == .started("Its own updater was started"))
        #expect(state(of: "Broken", in: orchestrator) == .failed("Signed by a different developer"))
        #expect(environment.installBatches.isEmpty)
        #expect(orchestrator.log.contains { $0.level == .error && $0.text == "Broken: Signed by a different developer" })
        #expect(summary.failed == 1)
        #expect(summary.premiumRequests == 3)
    }

    @Test("reports a failed installation and keeps going")
    func continuesAfterFailedInstall() async {
        let environment = FakeEnvironment()
        environment.apps = [makeApp("Bad"), makeApp("Good")]
        environment.agentOutcomes = ["Bad": staged("Bad"), "Good": staged("Good")]
        environment.installOutcomes = ["/stage/run-1/bad/payload/Bad.app": .failed("Gatekeeper rejected the download")]

        let (orchestrator, summary, _) = await run(environment)

        #expect(state(of: "Bad", in: orchestrator) == .failed("Gatekeeper rejected the download"))
        #expect(state(of: "Good", in: orchestrator) == .updated("1.0 → 2.0"))
        #expect(environment.apps[0].currentVersion == "1.0")
        #expect(environment.apps[1].currentVersion == "2.0")
        #expect(summary.updated == 1)
        #expect(summary.failed == 1)
    }

    @Test("says when Homebrew needs a password instead of calling it a failure")
    func reportsHomebrewOutcomes() async {
        let needsPassword = FakeEnvironment()
        needsPassword.brewPackages = [outdatedPackage("jq"), outdatedPackage("privileged")]
        needsPassword.brewRemaining = ["privileged"]
        needsPassword.brewNeedsAuthentication = true
        let (first, firstSummary, _) = await run(needsPassword)
        guard case .needsAttention(let text) = state(of: "Homebrew packages", in: first) else {
            Issue.record("Expected Homebrew to need attention")
            return
        }
        #expect(text == "Upgraded 1; privileged need your password. Run brew upgrade in Terminal to finish")
        #expect(firstSummary.needsAttention == 1)

        let failing = FakeEnvironment()
        failing.brewPackages = [outdatedPackage("jq")]
        failing.brewRemaining = ["jq"]
        let (second, _, _) = await run(failing)
        #expect(state(of: "Homebrew packages", in: second) == .failed("Upgraded 0 of 1; still outdated: jq"))

        let current = FakeEnvironment()
        let (third, _, _) = await run(current)
        #expect(state(of: "Homebrew packages", in: third) == .unchanged("Nothing to upgrade"))
        #expect(!current.steps.contains("brew upgrade"))

        let absent = FakeEnvironment()
        absent.hasHomebrew = false
        let (fourth, _, _) = await run(absent)
        #expect(state(of: "Homebrew packages", in: fourth) == nil)
        #expect(!absent.steps.contains("brew update"))
    }

    @Test("reports each tool's result and a failed Homebrew cask")
    func reportsToolAndCaskOutcomes() async {
        let environment = FakeEnvironment()
        environment.tools = [makeTool("bun", name: "Bun"), makeTool("omz", name: "Oh My Zsh"), makeTool("mau", name: "AutoUpdate")]
        environment.toolOutcomes = [
            "bun": .updated(from: "1.3", to: "1.4"),
            "omz": .failed("fatal: unable to access remote"),
            "mau": .triggered,
        ]
        environment.apps = [makeApp("Cask", method: .homebrew)]
        environment.failingCasks = ["Cask"]

        let (orchestrator, summary, _) = await run(environment)

        #expect(state(of: "Bun", in: orchestrator) == .updated("Updated 1.3 → 1.4"))
        #expect(state(of: "Oh My Zsh", in: orchestrator) == .failed("fatal: unable to access remote"))
        #expect(state(of: "AutoUpdate", in: orchestrator) == .started("Its updater ran"))
        #expect(state(of: "Cask", in: orchestrator) == .failed("Error: download failed"))
        #expect(summary.updated == 1)
        #expect(summary.failed == 2)
        #expect(summary.started == 1)
    }

    @Test("counts the time on whatever is running, and stops counting when it is done")
    func tracksWhenItemsStarted() async throws {
        let environment = FakeEnvironment()
        environment.tools = [makeTool("bun", name: "Bun")]
        let model = GuavaViewModel()
        let orchestrator = UpdateOrchestrator(model: model) { environment }
        var whileRunning: UpdateItem?
        var runStarted: Date?
        environment.onStep = { step in
            if step == "tool:bun" {
                whileRunning = orchestrator.items.first { $0.name == "Bun" }
                runStarted = orchestrator.runStarted
            }
        }

        let before = Date()
        await orchestrator.run()

        #expect(whileRunning?.state == .running)
        let itemStarted = try #require(whileRunning?.startedAt)
        #expect(itemStarted >= before && itemStarted <= Date())
        #expect(try #require(runStarted) <= itemStarted)
        // Finished items have no clock left to run.
        #expect(!orchestrator.items.isEmpty && orchestrator.items.allSatisfy { $0.startedAt == nil })
        withExtendedLifetime(model) {}
    }

    @Test("says in the log that a step working in silence is still running")
    func notesQuietSteps() async {
        let environment = FakeEnvironment()
        environment.tools = [makeTool("mau", name: "Microsoft AutoUpdate")]
        let model = GuavaViewModel()
        let orchestrator = UpdateOrchestrator(model: model) { environment }
        environment.onStep = { step in
            guard step == "tool:mau" else { return }
            // Something was logged a moment ago: nothing to add.
            orchestrator.noteIfQuiet()
            // Two minutes and five seconds later, still without a word from the tool.
            orchestrator.noteIfQuiet(now: Date().addingTimeInterval(125))
        }

        await orchestrator.run()

        let notes = orchestrator.log.filter { $0.text.hasPrefix("  Still running after") }
        #expect(notes.map(\.text) == ["  Still running after 2:05: Updating Microsoft AutoUpdate"])
        #expect(notes.first?.level == .detail)
        // A run that is over is not "still running".
        orchestrator.noteIfQuiet(now: Date().addingTimeInterval(3600))
        #expect(orchestrator.log.filter { $0.text.hasPrefix("  Still running after") }.count == 1)
        withExtendedLifetime(model) {}
    }

    @Test("writes elapsed time as a clock", arguments: [
        (7.9, "0:07"), (65, "1:05"), (750, "12:30"), (3723, "1:02:03"),
        (-5, "0:00"), (Double.infinity, "0:00"), (1e12, "99:59:59"),
    ])
    func formatsElapsedTime(seconds: Double, text: String) {
        #expect(UpdateOrchestrator.formatElapsed(seconds) == text)
    }

    @Test("says when a tool's updater carries on in the background, and logs the question it asks first")
    func reportsBackgroundUpdaters() async {
        let environment = FakeEnvironment()
        let microsoft = DevTool(
            id: "mau", name: "Microsoft AutoUpdate", dotEntries: [],
            versionProbe: .none,
            updateCommand: ToolCommand(executable: "/x/msupdate", arguments: ["--install"]),
            pendingCheck: PendingCheck(
                command: ToolCommand(executable: "/x/msupdate", arguments: ["--list"]),
                nothingPendingMarker: "No updates available"
            ),
            finishesInBackground: true,
            backgroundNote: "Installing in the background"
        )
        environment.tools = [DevToolInfo(tool: microsoft), makeTool("other", name: "Other")]
        environment.toolOutcomes = ["mau": .runningInBackground, "other": .runningInBackground]

        let (orchestrator, summary, _) = await run(environment)

        #expect(state(of: "Microsoft AutoUpdate", in: orchestrator) == .started("Installing in the background"))
        #expect(state(of: "Other", in: orchestrator) == .started("Its updater is finishing in the background"))
        #expect(summary.started == 2)
        #expect(summary.isClean)
        #expect(orchestrator.log.contains { $0.text == "Microsoft AutoUpdate: msupdate --list" })
        #expect(orchestrator.log.contains { $0.text == "Other: true update" })
    }

    @Test("ignores apps that are already current and writes process output to the log in order")
    func logsInOrder() async {
        let environment = FakeEnvironment()
        environment.brewPackages = [outdatedPackage("jq")]
        environment.apps = [makeApp("Current", installed: "2.0", latest: "2.0"), makeApp("Direct")]
        environment.agentOutcomes = ["Direct": staged("Direct")]

        let (orchestrator, _, _) = await run(environment)
        let texts = orchestrator.log.map(\.text)

        #expect(!environment.steps.contains("agent:Current"))
        #expect(state(of: "Current", in: orchestrator) == nil)
        // Output from a process appears between the lines that announce and follow it.
        let announced = texts.firstIndex(of: "brew upgrade (1 package(s))")!
        let output = texts.firstIndex(of: "  ==> Upgrading packages")!
        let next = texts.firstIndex(of: "Updating applications")!
        #expect(announced < output && output < next)
        #expect(texts.contains("  $ curl -fL -o downloads/app.dmg"))
        #expect(texts.first == "Update Everything")
        #expect(orchestrator.log.map(\.id) == Array(0..<orchestrator.log.count))
    }

    @Test("refuses to start a second run while one is in progress")
    func runsOneAtATime() async throws {
        let environment = FakeEnvironment()
        environment.brewPackages = [outdatedPackage("jq")]
        let model = GuavaViewModel()
        let orchestrator = UpdateOrchestrator(model: model) { environment }
        var nested: UpdateSummary?
        environment.onStep = { step in
            if step == "brew upgrade" {
                #expect(orchestrator.isRunning)
                orchestrator.start()
                Task { nested = await orchestrator.run() }
            }
        }

        let summary = await orchestrator.run()
        try await Task.sleep(nanoseconds: 20_000_000)

        #expect(environment.steps.filter { $0 == "brew upgrade" }.count == 1)
        #expect(environment.steps.filter { $0 == "scan" }.count == 2)
        #expect(summary.updated == 1)
        #expect(nested == nil || nested == UpdateSummary())
    }
}
