import AppKit
import Foundation

/// What the orchestrator needs to know to hand one application to the agent and install the
/// result.
struct AgentTaskContext: Equatable, Sendable {
    let task: AppUpdateTask
    /// Developer team of the installed copy; a replacement must be signed by the same team.
    let teamIdentifier: String?
    let route: InstallRoute
    /// Numeric `uid:gid` of the installed copy, restored when an administrator replaces it.
    let owner: String?
    /// Set when the installed copy's signature could not be read at all. Such an app is not
    /// handed to the agent: "no developer" must never be mistaken for "could not find out".
    var signatureProblem: String? = nil
}

/// Everything Update Everything does to the outside world.
///
/// The orchestrator decides *what* happens and in which order; this performs it. Tests
/// substitute a recording fake so that a whole run can be exercised without touching the Mac.
@MainActor
protocol UpdateEnvironment {
    var settings: UpdateSettings { get }
    var hasHomebrew: Bool { get }

    // Scanning
    /// - Parameter persistTimestamp: false for a preview, which must leave nothing behind.
    func scan(_ model: GuavaViewModel, persistTimestamp: Bool) async
    func microsoftManagedPaths() async -> Set<String>
    func locateAgent() -> CopilotCLI?
    /// Why the CLI cannot be used although it is installed, in its own words, or nil when it
    /// starts.
    func agentStartupProblem(_ cli: CopilotCLI) async -> String?
    func mcpServers(for cli: CopilotCLI) async -> [String]
    func installedVersion(of app: AppInfo) -> String?

    // Homebrew and tools
    func refreshHomebrew(onLine: ProcessRunner.LineHandler?) async -> ProcessResult
    func reloadHomebrew(_ model: GuavaViewModel) async
    func upgradeHomebrew(_ model: GuavaViewModel, onLine: ProcessRunner.LineHandler?) async -> BrewUpgradeResult
    /// Links the formulae Homebrew has installed without linking them. An upgrade does this
    /// itself for what it upgraded; this is for a run that has nothing to upgrade.
    func repairHomebrewLinks(_ model: GuavaViewModel, onLine: ProcessRunner.LineHandler?) async -> BrewLinkRepair
    func updateTool(_ info: DevToolInfo, onLine: ProcessRunner.LineHandler?) async -> ToolUpdateOutcome
    func upgradeCask(_ app: AppInfo) async -> Bool

    // Agent
    func agentTask(for app: AppInfo) async -> AgentTaskContext
    func prepareUpdate(
        for task: AppUpdateTask,
        cli: CopilotCLI,
        runDirectory: URL,
        mcpServers: [String],
        onEvent: @escaping @Sendable (AgentEvent) -> Void
    ) async -> AgentUpdateReport
    func updateAppStore(
        _ apps: [AppStoreUpdateTask],
        cli: CopilotCLI,
        runDirectory: URL,
        mcpServers: [String],
        onEvent: @escaping @Sendable (AgentEvent) -> Void
    ) async -> AgentUpdateReport
    func openAppStoreUpdates()

    // Installing
    func isRunning(_ app: AppInfo) -> Bool
    func quit(_ app: AppInfo) async -> RunningApps.QuitResult
    func relaunch(_ app: AppInfo)
    func install(_ operations: [InstallOperation], asAdministrator: Bool, prompt: String?) async -> [InstallOutcome]

    // Staging and cleanup
    func makeRunDirectory() throws -> URL
    func removeAbandonedRuns() async
    func downloadsSnapshot() -> Set<String>
    func cleanUp(
        runDirectory: URL?,
        since start: Date,
        downloadsSnapshot: Set<String>,
        onLine: ProcessRunner.LineHandler?
    ) async -> CleanupReport
    /// Keeps the log of a finished run. Returns where, or nil when it could not be kept.
    func keepLog(_ text: String, started: Date) -> URL?
}

/// The real thing: Homebrew, the Copilot CLI, the file system and running applications.
@MainActor
struct LiveUpdateEnvironment: UpdateEnvironment {
    let settings: UpdateSettings

    init(settings: UpdateSettings = .load()) {
        self.settings = settings
    }

    var hasHomebrew: Bool {
        BrewHelper.brewPath != nil
    }

    private var downloadsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
    }

    // MARK: Scanning

    func scan(_ model: GuavaViewModel, persistTimestamp: Bool) async {
        await model.performCheckForUpdates(persistTimestamp: persistTimestamp)
    }

    func microsoftManagedPaths() async -> Set<String> {
        await MicrosoftAutoUpdate.managedApplicationPaths()
    }

    func locateAgent() -> CopilotCLI? {
        CopilotCLI.locate()
    }

    func agentStartupProblem(_ cli: CopilotCLI) async -> String? {
        await cli.startupProblem()
    }

    func mcpServers(for cli: CopilotCLI) async -> [String] {
        await cli.configuredMCPServers()
    }

    func installedVersion(of app: AppInfo) -> String? {
        AppScanner.readCurrentVersion(for: app.path)
    }

    // MARK: Homebrew and tools

    func refreshHomebrew(onLine: ProcessRunner.LineHandler?) async -> ProcessResult {
        await BrewHelper.update(onLine: onLine)
    }

    func reloadHomebrew(_ model: GuavaViewModel) async {
        await model.loadBrewUpdates()
    }

    func upgradeHomebrew(_ model: GuavaViewModel, onLine: ProcessRunner.LineHandler?) async -> BrewUpgradeResult {
        await model.performBrewUpgradeAll(onLine: onLine)
    }

    func repairHomebrewLinks(_ model: GuavaViewModel, onLine: ProcessRunner.LineHandler?) async -> BrewLinkRepair {
        await model.repairBrewLinks(onLine: onLine)
    }

    func updateTool(_ info: DevToolInfo, onLine: ProcessRunner.LineHandler?) async -> ToolUpdateOutcome {
        await DevToolUpdater.update(info.tool, onLine: onLine)
    }

    func upgradeCask(_ app: AppInfo) async -> Bool {
        await UpdateEngine.updateApp(app)
    }

    // MARK: Agent

    func agentTask(for app: AppInfo) async -> AgentTaskContext {
        var teamIdentifier: String?
        var signatureProblem: String?
        switch await CodeSignVerifier.installedSignature(of: app.path) {
        case .developer(let team): teamIdentifier = team
        case .noDeveloper: break
        case .unreadable(let reason): signatureProblem = reason
        }

        let route = AppInstaller.route(forDestination: app.path)
        let task = AppUpdateTask(
            name: app.name,
            bundleIdentifier: app.bundleIdentifier,
            installedPath: app.path,
            installedVersion: app.currentVersion,
            latestKnownVersion: app.latestVersion,
            expectedTeamIdentifier: teamIdentifier,
            download: app.caskToken.flatMap(VersionChecker.download(forCask:)),
            sparkleFeedURL: AppScanner.infoValue(forKey: "SUFeedURL", inAppAt: app.path),
            ownedByRoot: route == .administrator,
            isRunning: isRunning(app),
            computerUseAllowed: settings.allowComputerUse
        )
        return AgentTaskContext(
            task: task,
            teamIdentifier: teamIdentifier,
            route: route,
            owner: AppInstaller.ownerSpecification(of: app.path),
            signatureProblem: signatureProblem
        )
    }

    func prepareUpdate(
        for task: AppUpdateTask,
        cli: CopilotCLI,
        runDirectory: URL,
        mcpServers: [String],
        onEvent: @escaping @Sendable (AgentEvent) -> Void
    ) async -> AgentUpdateReport {
        await AgentAppUpdater.prepareUpdate(
            for: task,
            cli: cli,
            runDirectory: runDirectory,
            settings: settings.agent,
            configuredMCPServers: mcpServers,
            onEvent: onEvent
        )
    }

    func updateAppStore(
        _ apps: [AppStoreUpdateTask],
        cli: CopilotCLI,
        runDirectory: URL,
        mcpServers: [String],
        onEvent: @escaping @Sendable (AgentEvent) -> Void
    ) async -> AgentUpdateReport {
        await AgentAppUpdater.updateAppStore(
            apps,
            cli: cli,
            runDirectory: runDirectory,
            settings: settings.agent,
            configuredMCPServers: mcpServers,
            onEvent: onEvent
        )
    }

    func openAppStoreUpdates() {
        UpdateEngine.openAppStoreUpdatesPage()
    }

    // MARK: Installing

    func isRunning(_ app: AppInfo) -> Bool {
        RunningApps.isRunning(bundleIdentifier: app.bundleIdentifier, path: app.path)
    }

    func quit(_ app: AppInfo) async -> RunningApps.QuitResult {
        await RunningApps.quit(bundleIdentifier: app.bundleIdentifier, path: app.path)
    }

    func relaunch(_ app: AppInfo) {
        RunningApps.launch(path: app.path)
    }

    func install(_ operations: [InstallOperation], asAdministrator: Bool, prompt: String?) async -> [InstallOutcome] {
        // The administrator batch also has to wait for someone to answer the prompt.
        let perOperation: TimeInterval = 10 * 60
        let timeout = asAdministrator
            ? 10 * 60 + perOperation * TimeInterval(operations.count)
            : 30 * 60
        return await AppInstaller.run(operations, asAdministrator: asAdministrator, prompt: prompt, timeout: timeout)
    }

    // MARK: Staging and cleanup

    func makeRunDirectory() throws -> URL {
        try InstallCleanup.makeRunDirectory()
    }

    func removeAbandonedRuns() async {
        _ = await InstallCleanup.removeAbandonedRuns()
    }

    func downloadsSnapshot() -> Set<String> {
        // Read only when it is going to be swept; macOS asks before letting an app in there.
        settings.sweepDownloads ? InstallCleanup.snapshot(of: downloadsDirectory) : []
    }

    func cleanUp(
        runDirectory: URL?,
        since start: Date,
        downloadsSnapshot: Set<String>,
        onLine: ProcessRunner.LineHandler?
    ) async -> CleanupReport {
        var report = CleanupReport()

        if let runDirectory {
            report.merge(await InstallCleanup.removeDirectory(runDirectory))
        }

        if settings.cleanBrewCache, hasHomebrew, let cache = await BrewHelper.cacheDirectory() {
            let cacheDownloads = cache.appendingPathComponent("downloads", isDirectory: true)
            let sizeBefore = InstallCleanup.directorySize(cacheDownloads)

            var result = await BrewHelper.cleanup(onLine: onLine)
            var brew = CleanupReport()
            // An old version Homebrew cannot delete fails every cleanup from then on. Moved to
            // the Trash, it is out of the way, and Homebrew is asked again.
            if !result.success, let prefix = await BrewHelper.prefix() {
                let moved = BrewHelper.trashUnremovableKegs(
                    BrewHelper.parseUnremovableKegs(result.stderr), prefix: prefix
                )
                brew.notes += moved.map { path in
                    let version = (path as NSString).lastPathComponent
                    let formula = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
                    return "Moved the old \(formula) \(version) to the Trash: Homebrew could not delete it, "
                        + "because some of its files belong to another user"
                }
                if !moved.isEmpty {
                    result = await BrewHelper.cleanup(onLine: onLine)
                }
            }
            if !result.success {
                brew.problems.append("brew cleanup failed: \(result.failureMessage)")
            }
            brew.problems += InstallCleanup.removeBrewCacheLeftovers(cache: cache).problems

            let measured = max(sizeBefore - InstallCleanup.directorySize(cacheDownloads), 0)
            // Homebrew's own figure also counts the old versions it removed.
            brew.bytesFreed = max(BrewHelper.parseFreedBytes(from: result.stdout) ?? 0, measured)
            if brew.bytesFreed > 0 {
                brew.removed = ["Homebrew downloads and old versions"]
            }
            report.merge(brew)
        }

        if settings.sweepDownloads {
            report.merge(InstallCleanup.sweepInstallers(
                in: downloadsDirectory, createdAfter: start, excluding: downloadsSnapshot
            ))
        }
        return report
    }

    func keepLog(_ text: String, started: Date) -> URL? {
        RunLog.write(text, started: started)
    }
}
