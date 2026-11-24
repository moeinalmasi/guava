import Foundation

/// Runs Update Everything: scan, Homebrew, tools, applications, cleanup and verification.
///
/// Deterministic updaters go first. The Copilot agent is used only for applications nothing
/// else can update, and it only ever *stages* a download: Guava verifies it, installs it, and
/// deletes every package afterwards.
@MainActor
final class UpdateOrchestrator: ObservableObject {

    enum Phase: String, CaseIterable, Sendable {
        case idle = "Ready"
        case scanning = "Scanning"
        case homebrew = "Homebrew"
        case tools = "Tools"
        case apps = "Applications"
        case installing = "Installing"
        case cleanup = "Cleaning up"
        case verifying = "Verifying"
        case finished = "Finished"
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var isRunning = false
    @Published private(set) var activity = "" {
        didSet { activityStarted = Date() }
    }
    /// When the run in progress began, for the clock in the progress sheet.
    @Published private(set) var runStarted: Date?
    @Published private(set) var items: [UpdateItem] = []
    @Published private(set) var log: [UpdateLogEntry] = []
    @Published private(set) var plan: UpdatePlan?
    @Published private(set) var summary: UpdateSummary?

    /// Receives every log entry as it is recorded. Used by the headless mode.
    var onLog: ((UpdateLogEntry) -> Void)?

    /// How long a step may log nothing before the log says that it is still running.
    static let quietInterval: TimeInterval = 60

    private unowned let model: GuavaViewModel
    private let makeEnvironment: @MainActor () -> UpdateEnvironment
    private var task: Task<Void, Never>?
    private var nextLogID = 0
    private var activityStarted = Date()
    private lazy var relay = OutputRelay { [weak self] lines in
        self?.appendDetail(lines)
    }

    private static let maximumLogEntries = 4000

    /// - Parameter makeEnvironment: builds the side-effect layer for each run, so that
    ///   settings changed between runs take effect.
    init(
        model: GuavaViewModel,
        makeEnvironment: @escaping @MainActor () -> UpdateEnvironment = { LiveUpdateEnvironment() }
    ) {
        self.model = model
        self.makeEnvironment = makeEnvironment
    }

    // MARK: - Control

    func start(dryRun: Bool = false) {
        // `isRunning` only turns true once the task begins, so `task` is checked as well:
        // a second call in the same turn must not replace the task that Stop has to reach.
        guard !isRunning, task == nil else { return }
        task = Task { [weak self] in
            _ = await self?.run(dryRun: dryRun)
        }
    }

    /// Stop after the step in progress. Cleanup still runs.
    func cancel() {
        guard isRunning, let task, !task.isCancelled else { return }
        record(.warning, "Stopping…")
        task.cancel()
    }

    @discardableResult
    func run(dryRun: Bool = false) async -> UpdateSummary {
        guard !isRunning else { return summary ?? UpdateSummary() }
        // The model owns this object, so the reference held to it is unowned. A run keeps the
        // model alive for as long as it lasts, in case its window is closed in the meantime.
        let model = self.model
        defer { withExtendedLifetime(model) {} }

        isRunning = true
        runStarted = Date()
        items = []
        log = []
        plan = nil
        summary = nil

        // A tool that works in silence must not look like a run that has stopped.
        let heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if Task.isCancelled { return }
                self?.noteIfQuiet()
            }
        }
        defer { heartbeat.cancel() }

        let state = RunState(environment: makeEnvironment())
        // A preview sweeps nothing afterwards, so it does not look at the Downloads folder at
        // all: the first look makes macOS ask the user for permission.
        let downloadsSnapshot: Set<String> = dryRun ? [] : state.environment.downloadsSnapshot()

        record(.phase, dryRun ? "Update Everything (dry run)" : "Update Everything")
        if !dryRun {
            // A preview changes nothing, the leftovers of an earlier run included.
            await state.environment.removeAbandonedRuns()
        }

        await scan(state, persistTimestamp: !dryRun)

        if !dryRun {
            if !Task.isCancelled { await updateHomebrew(state) }
            if !Task.isCancelled { await updateTools(state) }
            if !Task.isCancelled { await updateApplications(state) }
            if !Task.isCancelled { await updateAppStore(state) }
            if !Task.isCancelled { await installWithAdministrator(state) }

            let wasCancelled = Task.isCancelled
            state.wasCancelled = wasCancelled

            // Cleanup must happen even when the run was stopped, so it gets a task of its own
            // that does not inherit this one's cancellation.
            await Task { [weak self] in
                await self?.cleanUp(state, snapshot: downloadsSnapshot)
                if wasCancelled {
                    self?.refreshInstalledVersions(state)
                } else {
                    await self?.verify(state)
                }
                self?.reconcileWithInstalledVersions(state)
                self?.holdBackWhatDidNotArrive(state)
                self?.markFailedUpdates()
                self?.reopenAppsThatClosedLate(state)
            }.value
        }

        for index in items.indices where !items[index].state.isFinished {
            items[index].state = .skipped("Stopped before it started")
            items[index].startedAt = nil
        }

        var result = UpdateSummary(items: items)
        result.bytesFreed = state.cleanup.bytesFreed
        result.premiumRequests = state.premiumRequests
        result.duration = Date().timeIntervalSince(state.started)
        result.wasCancelled = state.wasCancelled
        result.wasDryRun = dryRun
        summary = result

        phase = .finished
        activity = result.headline
        record(result.isClean ? .success : .warning, result.headline)
        if result.bytesFreed > 0 {
            record(.info, "Freed \(Self.formatBytes(result.bytesFreed)) of downloaded packages")
        }
        if result.premiumRequests > 0 {
            record(.info, "Copilot agent used \(result.premiumRequests) premium request(s)")
        }
        // A preview leaves nothing behind, its own log included.
        if !dryRun, let file = state.environment.keepLog(RunLog.text(log: log, items: items), started: state.started) {
            record(.info, "The log of this run is kept in \((file.path as NSString).abbreviatingWithTildeInPath)")
        }

        isRunning = false
        task = nil
        return result
    }

    // MARK: - Phases

    private func scan(_ state: RunState, persistTimestamp: Bool) async {
        enter(.scanning, "Scanning applications, Homebrew and the home folder")
        await state.environment.scan(model, persistTimestamp: persistTimestamp)
        state.microsoftManagedPaths = await state.environment.microsoftManagedPaths()
        if state.settings.agentEnabled {
            await findAgent(state)
        }
        for app in model.apps {
            state.versionsBefore[app.path] = app.currentVersion
        }

        let context = routingContext(state)
        let plan = UpdatePlan(
            brewPackages: model.brewUpdates.filter(\.canUpdate).map(\.token),
            tools: model.devTools.map(\.tool.name),
            apps: model.apps.filter(\.hasUpdate).map {
                UpdatePlan.PlannedApp(
                    name: $0.name,
                    installedVersion: $0.currentVersion,
                    latestVersion: $0.latestVersion,
                    route: UpdatePlanner.route(for: $0, context: context)
                )
            }
        )
        self.plan = plan

        record(.info, "Found \(model.listedApps.count) applications, \(model.brewUpdates.count) Homebrew packages, "
            + "and \(model.devTools.count) updatable tools behind \(model.dotEntryCount) dot entries in the home folder")
        if state.settings.agentEnabled {
            if let problem = state.agentProblem {
                record(.warning, "The GitHub Copilot CLI does not start (\(problem)). As things stand, the apps that "
                    + "need it cannot be updated")
            } else if state.cli == nil {
                record(.warning, "The GitHub Copilot CLI was not found, so apps that need it will be skipped")
            }
        }
        for line in plan.lines {
            record(.info, line)
        }
    }

    /// Looks for the Copilot CLI and makes sure that it starts. A CLI that is installed and
    /// will not start is of no more use than one that is missing, and says why.
    private func findAgent(_ state: RunState) async {
        state.cli = state.environment.locateAgent()
        state.agentProblem = nil
        if let cli = state.cli, let problem = await state.environment.agentStartupProblem(cli) {
            state.cli = nil
            state.agentProblem = problem
        }
    }

    private func updateHomebrew(_ state: RunState) async {
        let environment = state.environment
        guard environment.hasHomebrew else { return }
        enter(.homebrew, "Updating Homebrew")
        let id = "homebrew"
        let name = "Homebrew packages"
        setItem(id, .homebrew, name, .running)

        record(.info, "brew update")
        let update = await environment.refreshHomebrew(onLine: outputHandler)
        if !update.success, !update.wasCancelled {
            record(.warning, "brew update failed: \(update.failureMessage)")
        }
        await environment.reloadHomebrew(model)
        // Checked before the list is looked at: once stopped, Homebrew can no longer be asked,
        // and "nothing to upgrade" would be a guess.
        guard !Task.isCancelled else { return }

        let pending = model.brewUpdates.filter(\.canUpdate).map(\.token)
        guard !pending.isEmpty else {
            // An upgrade made before this run may have left a formula without its links.
            let links = await environment.repairHomebrewLinks(model, onLine: outputHandler)
            report(links)
            setItem(id, .homebrew, name, links.relinked.isEmpty
                ? .unchanged("Nothing to upgrade")
                : .updated("Nothing to upgrade; linked \(Self.list(links.relinked)) again"))
            return
        }

        record(.info, "brew upgrade (\(pending.count) package(s))")
        let result = await environment.upgradeHomebrew(model, onLine: outputHandler)
        report(result.links)
        let remaining = Self.list(result.remaining)
        let unlinked = result.links.unlinked

        if !result.isVerified {
            setItem(id, .homebrew, name, Task.isCancelled
                ? .skipped("Stopped; what Homebrew upgraded before that could not be read back")
                : .needsAttention(
                    "brew upgrade ran, but the installed packages could not be listed to confirm what changed"
                ))
        } else if result.remaining.isEmpty, unlinked.isEmpty {
            setItem(id, .homebrew, name, .updated("Upgraded \(result.upgraded.count) package(s)"))
            // Homebrew can end with an error and leave nothing outdated. What it said is not
            // to be lost, unless it was about links that have been put right since.
            if let failure = result.failure?.split(whereSeparator: \.isNewline).first,
               result.links.relinked.isEmpty || !failure.localizedCaseInsensitiveContains("link") {
                record(.warning, "brew upgrade ended with an error, although nothing is outdated any more: \(failure)")
            }
        } else if result.remaining.isEmpty {
            setItem(id, .homebrew, name, .needsAttention(
                "Upgraded \(result.upgraded.count), but \(Self.list(unlinked)) could not be linked, so "
                    + "\(unlinked.count == 1 ? "its" : "their") commands are missing. "
                    + "See what is in the way with brew link --overwrite --dry-run \(unlinked[0])"
            ))
        } else if Task.isCancelled {
            setItem(id, .homebrew, name, .skipped("Stopped after upgrading \(result.upgraded.count) of \(pending.count)"))
        } else if result.needsAuthentication {
            setItem(id, .homebrew, name, .needsAttention(
                "Upgraded \(result.upgraded.count); \(remaining) need your password. "
                    + "Run brew upgrade in Terminal to finish"
            ))
        } else {
            setItem(id, .homebrew, name, .failed(
                "Upgraded \(result.upgraded.count) of \(pending.count); still outdated: \(remaining)"
            ))
        }
    }

    private func updateTools(_ state: RunState) async {
        let tools = model.devTools
        guard !tools.isEmpty else { return }
        enter(.tools, "Updating developer tools")

        for info in tools {
            let id = "tool:\(info.id)"
            guard !Task.isCancelled else {
                setItem(id, .tool, info.tool.name, .pending)
                continue
            }
            setItem(id, .tool, info.tool.name, .running)
            activity = "Updating \(info.tool.name)"
            record(.info, "\(info.tool.name): \(info.tool.firstCommand.displayString)")

            let outcome = await state.environment.updateTool(info, onLine: outputHandler)
            if info.tool.id == DevToolScanner.microsoftAutoUpdateID, case .alreadyCurrent = outcome {
                state.microsoftOffersNothing = true
            }
            let itemState: UpdateItemState
            switch outcome {
            case .updated: itemState = .updated(outcome.summary)
            case .alreadyCurrent: itemState = .unchanged(outcome.summary)
            case .triggered: itemState = .started("Its updater ran")
            case .runningInBackground:
                itemState = .started(info.tool.backgroundNote ?? "Its updater is finishing in the background")
            case .failed(let message): itemState = Task.isCancelled ? .skipped("Stopped") : .failed(message)
            }
            setItem(id, .tool, info.tool.name, itemState)
        }
    }

    private func report(_ links: BrewLinkRepair) {
        for formula in links.relinked {
            record(.success, "\(formula): Homebrew had installed it without linking it, which left its commands "
                + "missing. Linked it again")
        }
        for formula in links.unlinked {
            record(.warning, "\(formula): Homebrew upgraded it but could not link it, because files that are not "
                + "its own are in the way")
        }
    }

    private func updateApplications(_ state: RunState) async {
        // Homebrew and the tool updaters may already have replaced some of these.
        refreshInstalledVersions(state)
        let targets = model.apps.filter(\.hasUpdate)
        guard !targets.isEmpty else { return }
        enter(.apps, "Updating applications")

        // They can also have changed whether the Copilot CLI starts, either way.
        if state.settings.agentEnabled {
            let problemAtScan = state.agentProblem
            await findAgent(state)
            if problemAtScan != nil, state.agentProblem == nil, state.cli != nil {
                record(.info, "The GitHub Copilot CLI starts again")
            }
        }

        let context = routingContext(state)
        let routed = targets.map { ($0, UpdatePlanner.route(for: $0, context: context)) }

        if let problem = state.agentProblem, routed.contains(where: { Self.needsAgent($0.1) }) {
            record(.warning, "The GitHub Copilot CLI does not start (\(problem)), so what needs it cannot be updated")
        }

        if let cli = state.cli, routed.contains(where: { $0.1 == .agent }) {
            state.mcpServers = await state.environment.mcpServers(for: cli)
            ensureRunDirectory(state)
        }

        for (app, route) in routed {
            let id = Self.itemID(app)
            guard !Task.isCancelled else {
                setItem(id, .app, app.name, .pending)
                continue
            }
            switch route {
            case .homebrew:
                await updateViaHomebrew(app, state)
            case .appStore:
                state.appStoreApps.append(app)
                setItem(id, .app, app.name, .pending)
            case .microsoftAutoUpdate:
                // Asked a moment ago, with the other tools, whether it had anything to install.
                setItem(id, .app, app.name, state.microsoftOffersNothing
                    ? .unchanged("Microsoft AutoUpdate offers nothing newer")
                    : .started("Microsoft AutoUpdate installs it once the app is closed"))
            case .skipped(let reason):
                setItem(id, .app, app.name, .skipped("Not updated: \(reason)"))
            case .unavailable(let reason):
                let message = "Not updated: \(reason)"
                app.updateStatus = .error
                app.updateError = message
                setItem(id, .app, app.name, .failed(message))
            case .agent:
                await updateViaAgent(app, state)
            }
        }
    }

    private func updateViaHomebrew(_ app: AppInfo, _ state: RunState) async {
        let id = Self.itemID(app)
        setItem(id, .app, app.name, .running)
        activity = "Homebrew: \(app.name)"
        record(.info, "\(app.name): brew upgrade --cask")

        let before = app.currentVersion
        let succeeded = await state.environment.upgradeCask(app)
        if succeeded {
            if let version = state.environment.installedVersion(of: app) {
                app.currentVersion = version
            }
            if app.currentVersion != before {
                setItem(id, .app, app.name, .updated("\(before) → \(app.currentVersion)"))
            } else {
                // Homebrew can finish without an error and leave the app as it was: by its own
                // record, what is installed is already the cask's latest.
                setItem(id, .app, app.name, .unchanged("Homebrew has nothing newer than \(before)"))
            }
        } else if Task.isCancelled {
            setItem(id, .app, app.name, .skipped("Stopped"))
        } else {
            let message = app.updateError ?? "Homebrew could not upgrade this app"
            let needsPassword = BrewHelper.requiresInteractiveAuthentication(message)
            // Homebrew can only ask for a password in a terminal.
            let command = "brew upgrade --cask" + (app.caskToken.map { " \($0)" } ?? "")
            setItem(id, .app, app.name, needsPassword
                ? .needsAttention("Homebrew needs your password. Run \(command) in Terminal")
                : .failed(message))
        }
    }

    private func updateViaAgent(_ app: AppInfo, _ state: RunState) async {
        let id = Self.itemID(app)
        guard let cli = state.cli, let runDirectory = state.runDirectory else {
            setItem(id, .app, app.name, .failed("Could not create a staging folder"))
            return
        }
        // An open app that may not be closed cannot be replaced, so nothing is downloaded for it.
        if !state.settings.quitRunningApps, state.environment.isRunning(app) {
            setItem(id, .app, app.name, .needsAttention("\(app.name) is open. Quit it and run Update Everything again"))
            return
        }
        setItem(id, .app, app.name, .running)
        activity = "Copilot agent: \(app.name)"

        let previousStatus = app.updateStatus
        app.updateStatus = .updating

        let context = await state.environment.agentTask(for: app)
        if let problem = context.signatureProblem {
            // With no signature to read there is no developer to hold a download to.
            app.updateStatus = previousStatus
            setItem(id, .app, app.name, .failed(
                "Not updated: the signature of the installed copy could not be read (\(problem))"
            ))
            return
        }
        record(.info, "\(app.name): Copilot agent is staging \(app.latestVersion ?? "the latest version")"
            + (context.task.download == nil ? "" : " from the download Homebrew publishes"))

        let report = await state.environment.prepareUpdate(
            for: context.task,
            cli: cli,
            runDirectory: runDirectory,
            mcpServers: state.mcpServers,
            onEvent: agentEventHandler
        )
        state.premiumRequests += report.premiumRequests ?? 0

        switch report.outcome {
        case .staged(let payload):
            record(.success, "\(app.name): download passed signature, developer and Gatekeeper checks")
            // Restoring the owner also keeps the bundle's group when the user owns it.
            let replacement = InstallOperation.replaceApp(
                staged: payload.url.path, destination: app.path, owner: context.owner,
                teamIdentifier: context.teamIdentifier, requireGatekeeper: true,
                identity: BundleIdentity(bundleIdentifier: payload.bundleIdentifier, version: payload.version)
            )
            if payload.kind == .app, context.route == .user {
                await install(app, replacement, id: id, state)
            } else {
                // Installer packages and root-owned bundles both need an administrator.
                let operation: InstallOperation = payload.kind == .pkg
                    ? .installPackage(
                        path: payload.url.path, teamIdentifier: context.teamIdentifier, requireGatekeeper: true
                    )
                    : replacement
                state.privileged.append(PendingInstall(app: app, operation: operation, itemID: id))
                app.updateStatus = previousStatus
                setItem(id, .app, app.name, .pending)
                record(.info, "\(app.name): needs an administrator to install; queued for one prompt at the end")
            }

        case .updateTriggered(let notes):
            let before = app.currentVersion
            app.updateStatus = previousStatus
            refreshInstalledVersion(app, state)
            if app.currentVersion != before {
                setItem(id, .app, app.name, .updated("\(before) → \(app.currentVersion)"))
            } else {
                setItem(id, .app, app.name, .started(notes ?? "Its own updater was started"))
            }

        case .upToDate(let notes):
            app.updateStatus = previousStatus
            setItem(id, .app, app.name, .unchanged(notes ?? "The vendor offers nothing newer"))

        case .failed(let message):
            if Task.isCancelled {
                app.updateStatus = previousStatus
                setItem(id, .app, app.name, .skipped("Stopped"))
            } else {
                app.updateStatus = .error
                app.updateError = message
                setItem(id, .app, app.name, .failed(message))
                record(.error, "\(app.name): \(message)")
            }
        }
    }

    private func updateAppStore(_ state: RunState) async {
        guard !state.appStoreApps.isEmpty else { return }
        enter(.apps, "Updating Mac App Store apps")

        // When `mas` is installed it already ran with the other tools. Whatever it upgraded
        // shows up here as a changed version; anything it left alone still needs the App Store.
        var remaining: [AppInfo] = []
        for app in state.appStoreApps {
            let before = app.currentVersion
            refreshInstalledVersion(app, state)
            if app.currentVersion != before {
                setItem(Self.itemID(app), .app, app.name, .updated("\(before) → \(app.currentVersion)"))
            } else {
                remaining.append(app)
            }
        }
        guard !remaining.isEmpty else { return }

        func mark(_ itemState: UpdateItemState) {
            for app in remaining {
                setItem(Self.itemID(app), .app, app.name, itemState)
            }
        }

        guard let cli = state.cli, state.settings.allowComputerUse else {
            state.environment.openAppStoreUpdates()
            mark(.needsAttention("Opened the App Store's Updates page: click Update All"))
            return
        }

        ensureRunDirectory(state)
        guard let runDirectory = state.runDirectory else {
            mark(.failed("Could not create a staging folder"))
            return
        }
        if state.mcpServers.isEmpty {
            state.mcpServers = await state.environment.mcpServers(for: cli)
        }
        mark(.running)
        activity = "Copilot agent: Mac App Store"
        record(.info, "Copilot agent is using the App Store to update \(Self.list(remaining.map(\.name)))")
        // Guava opens the page itself, so all that is left for the agent is to press the button.
        state.environment.openAppStoreUpdates()

        let report = await state.environment.updateAppStore(
            remaining.map {
                AppStoreUpdateTask(
                    name: $0.name, bundleIdentifier: $0.bundleIdentifier,
                    installedVersion: $0.currentVersion, latestKnownVersion: $0.latestVersion
                )
            },
            cli: cli,
            runDirectory: runDirectory,
            mcpServers: state.mcpServers,
            onEvent: agentEventHandler
        )
        state.premiumRequests += report.premiumRequests ?? 0

        /// The agent could not do it, so leave the last click to the user instead of giving up.
        func handOver(_ reason: String) {
            record(.warning, "Mac App Store: \(reason)")
            state.environment.openAppStoreUpdates()
            mark(.needsAttention(
                "The agent could not finish in the App Store. Its Updates page is open: click Update All"
            ))
        }

        switch report.outcome {
        case .updateTriggered:
            mark(.started("The App Store is installing it"))
        case .upToDate(let notes):
            mark(.unchanged(notes ?? "The App Store lists no update"))
        case .failed(let message):
            if Task.isCancelled {
                mark(.skipped("Stopped"))
            } else {
                handOver(message)
            }
        case .staged:
            handOver("The agent did not use the App Store")
        }
    }

    /// Installs everything that needs administrator rights behind a single prompt.
    private func installWithAdministrator(_ state: RunState) async {
        guard !state.privileged.isEmpty else { return }
        enter(.installing, "Installing updates that need an administrator")

        var ready: [(install: PendingInstall, wasRunning: Bool)] = []
        for pending in state.privileged {
            switch await quitIfRunning(pending.app, state) {
            case .proceed(let wasRunning):
                ready.append((pending, wasRunning))
            case .blocked(let reason):
                setItem(pending.itemID, .app, pending.app.name, .needsAttention(reason))
            case .stopped:
                setItem(pending.itemID, .app, pending.app.name, .skipped("Stopped"))
            }
        }
        // Stopped while apps were being closed: nothing is installed, and whatever was closed
        // for it is opened again.
        guard !Task.isCancelled else {
            for entry in ready {
                setItem(entry.install.itemID, .app, entry.install.app.name, .skipped("Stopped"))
                if entry.wasRunning {
                    state.environment.relaunch(entry.install.app)
                }
            }
            return
        }
        guard !ready.isEmpty else { return }

        let names = ready.map(\.install.app.name)
        for entry in ready {
            setItem(entry.install.itemID, .app, entry.install.app.name, .running)
        }
        record(.info, "Asking for an administrator to install \(Self.list(names))")

        let outcomes = await state.environment.install(
            ready.map(\.install.operation),
            asAdministrator: true,
            prompt: "Guava wants to install updates for \(Self.list(names))."
        )

        for (index, entry) in ready.enumerated() {
            let outcome = index < outcomes.count ? outcomes[index] : .failed("Installation did not run")
            finishInstall(entry.install.app, outcome, id: entry.install.itemID, state)
            if entry.wasRunning {
                state.environment.relaunch(entry.install.app)
            }
        }
    }

    private func cleanUp(_ state: RunState, snapshot: Set<String>) async {
        enter(.cleanup, "Deleting downloaded packages")
        let report = await state.environment.cleanUp(
            runDirectory: state.runDirectory,
            since: state.started,
            downloadsSnapshot: snapshot,
            onLine: outputHandler
        )
        state.cleanup = report

        for name in report.trashed {
            record(.info, "Moved \(name) from Downloads to the Trash")
        }
        for volume in report.detachedVolumes {
            record(.info, "Ejected \(volume)")
        }
        for note in report.notes {
            record(.info, note)
        }
        for problem in report.problems {
            record(.warning, problem)
        }

        let itemState: UpdateItemState
        if !report.problems.isEmpty {
            itemState = .failed(report.problems.joined(separator: "; "))
        } else if report.bytesFreed > 0 || !report.trashed.isEmpty {
            itemState = .unchanged("Deleted, \(Self.formatBytes(report.bytesFreed)) freed")
        } else {
            itemState = .unchanged("Nothing was left behind")
        }
        setItem("cleanup", .cleanup, "Downloaded packages", itemState)
    }

    private func verify(_ state: RunState) async {
        enter(.verifying, "Checking installed versions")
        await state.environment.scan(model, persistTimestamp: true)
    }

    /// What is installed has the last word. Another updater may have finished while the run
    /// went on, and an installation reported as failed or unanswered may still have gone
    /// through, for instance when the administrator step outlasted its time limit.
    private func reconcileWithInstalledVersions(_ state: RunState) {
        for app in model.apps {
            guard let index = items.firstIndex(where: { $0.id == Self.itemID(app) }),
                  let before = state.versionsBefore[app.path],
                  before != app.currentVersion else { continue }
            if case .updated = items[index].state { continue }
            items[index].state = .updated("\(before) → \(app.currentVersion)")
            items[index].startedAt = nil
        }
    }

    /// An update that was handed to the app's own channel and has not arrived by the end of
    /// the run is not attempted again. Either that channel has nothing newer for this Mac, as
    /// with a copy an organisation keeps at a version of its choosing, or it is still at
    /// work. Either way there is nothing more to do here, and the app is shown as up to date
    /// until a version newer than this one appears.
    private func holdBackWhatDidNotArrive(_ state: RunState) {
        for app in model.apps where app.hasUpdate {
            guard let item = items.first(where: { $0.id == Self.itemID(app) }),
                  state.versionsBefore[app.path] == app.currentVersion else { continue }
            switch item.state {
            case .unchanged, .started:
                model.holdBack(app)
                record(.info, "\(app.name): left to its own updater, and shown as up to date until a version "
                    + "newer than \(app.latestVersion ?? "this one") appears")
            case .pending, .running, .updated, .needsAttention, .failed, .skipped:
                break
            }
        }
    }

    /// The scan that ends a run builds the list afresh, and with it would forget which updates
    /// failed. They are marked again, so that each of those rows says what went wrong.
    private func markFailedUpdates() {
        for app in model.apps where app.hasUpdate {
            guard let item = items.first(where: { $0.id == Self.itemID(app) }),
                  case .failed(let message) = item.state else { continue }
            app.updateStatus = .error
            app.updateError = message
        }
    }

    /// An app that was asked to quit but took its time may close after Guava has given up on
    /// it. Nothing else would open it again, so that is done here.
    private func reopenAppsThatClosedLate(_ state: RunState) {
        for app in state.askedToQuit where !state.environment.isRunning(app) {
            record(.info, "\(app.name) closed after it was asked to quit; reopening it")
            state.environment.relaunch(app)
        }
    }

    // MARK: - Installing

    private enum QuitDecision {
        case proceed(wasRunning: Bool)
        case blocked(String)
        /// The run was stopped before the app was closed.
        case stopped
    }

    private func install(_ app: AppInfo, _ operation: InstallOperation, id: String, _ state: RunState) async {
        switch await quitIfRunning(app, state) {
        case .blocked(let reason):
            app.updateStatus = .updateAvailable
            setItem(id, .app, app.name, .needsAttention(reason))
        case .stopped:
            app.updateStatus = .updateAvailable
            setItem(id, .app, app.name, .skipped("Stopped"))
        case .proceed(let wasRunning):
            if Task.isCancelled {
                app.updateStatus = .updateAvailable
                setItem(id, .app, app.name, .skipped("Stopped"))
            } else {
                let outcome = await state.environment.install([operation], asAdministrator: false, prompt: nil).first
                    ?? .failed("Installation did not run")
                finishInstall(app, outcome, id: id, state)
            }
            if wasRunning {
                state.environment.relaunch(app)
            }
        }
    }

    private func quitIfRunning(_ app: AppInfo, _ state: RunState) async -> QuitDecision {
        guard state.environment.isRunning(app) else {
            return .proceed(wasRunning: false)
        }
        guard state.settings.quitRunningApps else {
            return .blocked("\(app.name) is open. Quit it and run Update Everything again")
        }
        // Nothing is installed once the run has been stopped, so nothing is closed for it.
        guard !Task.isCancelled else { return .stopped }

        record(.info, "\(app.name): asking it to quit so it can be replaced")
        switch await state.environment.quit(app) {
        case .notRunning:
            return .proceed(wasRunning: false)
        case .quit:
            return .proceed(wasRunning: true)
        case .refused:
            // It has been asked and may yet close; the end of the run checks on it.
            state.askedToQuit.append(app)
            return Task.isCancelled
                ? .stopped
                : .blocked("\(app.name) did not quit, perhaps because of unsaved changes, so it was left alone")
        }
    }

    private func finishInstall(_ app: AppInfo, _ outcome: InstallOutcome, id: String, _ state: RunState) {
        let before = state.versionsBefore[app.path] ?? app.currentVersion
        switch outcome {
        case .installed(let note):
            if let version = state.environment.installedVersion(of: app) {
                app.currentVersion = version
            }
            guard app.currentVersion != before else {
                // An installer package can succeed without touching this app, for instance by
                // installing a different product or to a different place.
                app.updateStatus = .updateAvailable
                let text = "The installer finished, but \(app.name) is still at version \(before)"
                setItem(id, .app, app.name, .needsAttention(text))
                record(.warning, text)
                return
            }
            app.updateStatus = .upToDate
            app.updateError = nil
            let text = "\(before) → \(app.currentVersion)" + (note.map { ". \($0)" } ?? "")
            setItem(id, .app, app.name, .updated(text))
            record(.success, "\(app.name): installed \(app.currentVersion)")
        case .failed(let message):
            guard !Task.isCancelled else {
                app.updateStatus = .updateAvailable
                setItem(id, .app, app.name, .skipped("Stopped"))
                return
            }
            app.updateStatus = .error
            app.updateError = message
            setItem(id, .app, app.name, .failed(message))
            record(.error, "\(app.name): \(message)")
        case .notAuthorized:
            app.updateStatus = .updateAvailable
            setItem(id, .app, app.name, Task.isCancelled
                ? .skipped("Stopped")
                : .needsAttention("Not installed: an administrator did not approve it"))
        }
    }

    // MARK: - Helpers

    private func routingContext(_ state: RunState) -> AppRoutingContext {
        AppRoutingContext(
            agentEnabled: state.settings.agentEnabled,
            agentAvailable: state.cli != nil,
            agentProblem: state.agentProblem,
            microsoftManagedPaths: state.microsoftManagedPaths
        )
    }

    private func ensureRunDirectory(_ state: RunState) {
        guard state.runDirectory == nil else { return }
        do {
            state.runDirectory = try state.environment.makeRunDirectory()
        } catch {
            record(.error, "Could not create a staging folder: \(error.localizedDescription)")
        }
    }

    private func refreshInstalledVersions(_ state: RunState) {
        for app in model.apps {
            refreshInstalledVersion(app, state)
        }
    }

    /// Re-read an app's version from disk and clear its pending update if it has caught up.
    private func refreshInstalledVersion(_ app: AppInfo, _ state: RunState) {
        guard let version = state.environment.installedVersion(of: app), version != app.currentVersion else {
            return
        }
        app.currentVersion = version
        if let latest = app.latestVersion {
            let comparison = VersionChecker.compareVersions(
                VersionChecker.cleanVersion(version), VersionChecker.cleanVersion(latest)
            )
            if comparison != .orderedAscending {
                app.updateStatus = .upToDate
            }
        }
    }

    private func enter(_ newPhase: Phase, _ text: String) {
        phase = newPhase
        activity = text
        record(.phase, text)
    }

    private func setItem(_ id: String, _ category: UpdateItem.Category, _ name: String, _ state: UpdateItemState) {
        let index: Int
        if let existing = items.firstIndex(where: { $0.id == id }) {
            index = existing
        } else {
            items.append(UpdateItem(id: id, category: category, name: name, state: state))
            index = items.count - 1
        }
        // The time an item started running is what its clock in the progress sheet counts from.
        if case .running = state {
            if items[index].startedAt == nil {
                items[index].startedAt = Date()
            }
        } else {
            items[index].startedAt = nil
        }
        items[index].state = state
    }

    /// Says in the log that the current step is still running when nothing has been logged for
    /// a while. Some tools work for minutes without a word, and in a terminal there is no
    /// spinner to show that the run is alive.
    func noteIfQuiet(now: Date = Date()) {
        guard isRunning, phase != .finished, let last = log.last,
              now.timeIntervalSince(last.date) >= Self.quietInterval else { return }
        let elapsed = Self.formatElapsed(now.timeIntervalSince(activityStarted))
        record(.detail, "  Still running after \(elapsed): \(activity)")
    }

    private func record(_ level: UpdateLogEntry.Level, _ text: String) {
        // Process output queued on other threads belongs before whatever is said next.
        relay.flush()
        append(level, text)
    }

    private func appendDetail(_ lines: [String]) {
        for line in lines {
            append(.detail, line)
        }
    }

    private func append(_ level: UpdateLogEntry.Level, _ text: String) {
        let entry = UpdateLogEntry(id: nextLogID, date: Date(), level: level, text: text)
        nextLogID += 1
        log.append(entry)
        if log.count > Self.maximumLogEntries {
            log.removeFirst(log.count - Self.maximumLogEntries + 500)
        }
        onLog?(entry)
    }

    /// Forwards a process's output lines to the log.
    private var outputHandler: ProcessRunner.LineHandler {
        let relay = self.relay
        return { line, _ in
            let text = line.strippingANSI.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty {
                relay.append("  " + text)
            }
        }
    }

    /// Describes what the agent is doing, one line per step.
    private var agentEventHandler: @Sendable (AgentEvent) -> Void {
        let relay = self.relay
        return { event in
            switch event {
            case .toolStarted(let tool, let summary):
                let label: String
                switch tool {
                case "bash": label = "$ \(summary)"
                case "web_fetch": label = "fetch \(summary)"
                case "web_search": label = "search \(summary)"
                case let name where name.hasPrefix("computer-use"): label = "computer use: \(summary)"
                default: label = "\(tool) \(summary)"
                }
                relay.append("  " + label)
            case .message(let text):
                let flattened = text.split(whereSeparator: \.isNewline).joined(separator: " ")
                relay.append("  agent: " + String(flattened.prefix(400)))
            case .notice(let text):
                relay.append("  notice: " + text)
            case .toolFinished, .finished:
                break
            }
        }
    }

    private static func itemID(_ app: AppInfo) -> String {
        "app:\(app.path)"
    }

    /// Whether updating by this route takes the Copilot agent. The App Store does, for the
    /// click on Update All.
    private static func needsAgent(_ route: AppUpdateRoute) -> Bool {
        switch route {
        case .agent, .unavailable, .appStore: return true
        case .homebrew, .microsoftAutoUpdate, .skipped: return false
        }
    }

    private static func list(_ names: [String], limit: Int = 6) -> String {
        let shown = names.prefix(limit).joined(separator: ", ")
        return names.count > limit ? "\(shown) and \(names.count - limit) more" : shown
    }

    static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Elapsed time as a clock: 0:07, 12:30, 1:02:03.
    static func formatElapsed(_ interval: TimeInterval) -> String {
        let total = interval.isFinite ? Int(min(max(interval, 0), 359_999)) : 0
        let (hours, minutes, seconds) = (total / 3600, (total % 3600) / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }

    // MARK: - Run state

    private struct PendingInstall {
        let app: AppInfo
        let operation: InstallOperation
        let itemID: String
    }

    private final class RunState {
        let environment: UpdateEnvironment
        let settings: UpdateSettings
        let started = Date()
        var cli: CopilotCLI?
        /// What the Copilot CLI said when it was found but would not start.
        var agentProblem: String?
        var mcpServers: [String] = []
        var runDirectory: URL?
        var microsoftManagedPaths: Set<String> = []
        /// True once Microsoft AutoUpdate has said, in this run, that it has nothing to install.
        var microsoftOffersNothing = false
        var versionsBefore: [String: String] = [:]
        var appStoreApps: [AppInfo] = []
        var privileged: [PendingInstall] = []
        /// Apps that were asked to quit and had not closed when Guava stopped waiting.
        var askedToQuit: [AppInfo] = []
        var premiumRequests = 0
        var cleanup = CleanupReport()
        var wasCancelled = false

        @MainActor
        init(environment: UpdateEnvironment) {
            self.environment = environment
            self.settings = environment.settings
        }
    }
}

/// Carries output from background threads to the main actor, in order and in batches.
private final class OutputRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [String] = []
    private var scheduled = false
    private let deliver: @MainActor ([String]) -> Void

    init(deliver: @escaping @MainActor ([String]) -> Void) {
        self.deliver = deliver
    }

    func append(_ line: String) {
        let shouldSchedule: Bool = lock.withLock {
            pending.append(line)
            guard !scheduled else { return false }
            scheduled = true
            return true
        }
        guard shouldSchedule else { return }
        Task { @MainActor in
            self.flush()
        }
    }

    /// Deliver everything queued so far.
    @MainActor
    func flush() {
        let lines: [String] = lock.withLock {
            defer {
                pending = []
                scheduled = false
            }
            return pending
        }
        if !lines.isEmpty {
            deliver(lines)
        }
    }
}
