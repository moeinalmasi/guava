import SwiftUI
import Combine

/// What Guava knows about this Mac: its applications, its Homebrew packages and the tools that
/// update themselves. The window lists the applications; Update Everything works on all three.
@MainActor
class GuavaViewModel: ObservableObject {
    @Published var apps: [AppInfo] = []
    @Published var isScanning: Bool = false
    @Published var isCheckingAll: Bool = false
    @Published var brewUpdates: [BrewUpdateInfo] = []
    @Published var devTools: [DevToolInfo] = []
    /// Number of top-level dot entries found in the home folder by the last scan.
    @Published var dotEntryCount: Int = 0
    /// Whether the Update Everything progress sheet is on screen.
    @Published var isShowingUpdateProgress: Bool = false
    @Published var progress: Double = 0
    /// What the check is doing, shown at the top of the window while it runs.
    @Published var statusMessage: String = ""
    @Published var lastScanTime: Date? = {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".guava_last_scan")
        guard let data = try? Data(contentsOf: path),
              let str = String(data: data, encoding: .utf8),
              let ti = Double(str) else { return nil }
        return Date(timeIntervalSince1970: ti)
    }()

    private var cancellables = Set<AnyCancellable>()
    private var activeCheck: Task<Void, Never>?

    /// The formulae whose files are linked into Homebrew's prefix, and those that are meant
    /// to be and are not, as of the last listing.
    private var linkedFormulae: Set<String> = []
    private var formulaeMissingLinks: Set<String> = []

    /// The apps left out of the list and the updates that were not on offer on this Mac.
    @Published private(set) var record: LocalRecord
    private let store: LocalStore

    /// - Parameter store: where the record of hidden apps and held updates is kept. The app
    ///   uses `.home`; anything that must leave the home folder alone uses `.none`.
    init(store: LocalStore) {
        self.store = store
        record = store.load()
    }

    /// Runs Update Everything. Created on first use so it can refer back to this model.
    private(set) lazy var updater: UpdateOrchestrator = {
        let orchestrator = UpdateOrchestrator(model: self)
        // The window disables its buttons during a run.
        updaterCancellable = orchestrator.$isRunning
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
        return orchestrator
    }()
    private var updaterCancellable: AnyCancellable?

    var isUpdatingEverything: Bool {
        updater.isRunning
    }

    /// The applications in the order the window lists them: those with an update waiting
    /// first, then the rest, each group by name. Apps that nothing can update are left out.
    var listedApps: [AppInfo] {
        let hidden = Set(record.hidden.map(\.path))
        return apps
            .filter { !hidden.contains($0.path) }
            .sorted { first, second in
                if first.isOutdated != second.isOutdated { return first.isOutdated }
                return first.name.localizedCaseInsensitiveCompare(second.name) == .orderedAscending
            }
    }

    var updateCount: Int {
        listedApps.filter(\.isOutdated).count
    }

    /// How many of the scanned apps are left out of the list.
    var hiddenCount: Int {
        apps.count - listedApps.count
    }

    /// One line about the list, for the top of the window.
    var summaryLine: String {
        if isScanning || isCheckingAll { return statusMessage }
        let listed = listedApps.count
        guard listed > 0 else {
            return apps.isEmpty ? "No applications found" : "No applications that can be updated"
        }
        let count = listed == 1 ? "1 app" : "\(listed) apps"
        switch updateCount {
        case 0: return "\(count), no updates found"
        case 1: return "\(count), 1 update available"
        default: return "\(count), \(updateCount) updates available"
        }
    }

    /// What the list leaves out, for anyone who wonders where an app went.
    var listNote: String {
        switch hiddenCount {
        case 0: return "The applications in /Applications and ~/Applications"
        case 1: return "1 app that nothing can update is not listed. It is named in ~/.guava"
        default: return "\(hiddenCount) apps that nothing can update are not listed. They are named in ~/.guava"
        }
    }

    // MARK: - What is remembered

    /// Brings a finished check and the record together. An update that is not on offer on
    /// this Mac shows as up to date, an app that nothing can update leaves the list, and the
    /// record is brought up to date with what the check found.
    func settleCheck() {
        var updated = record

        // An entry lasts while the app is still there at the same version and no version
        // newer than the one that did not arrive has appeared.
        updated.held = record.held.filter { entry in
            guard let app = apps.first(where: { $0.path == entry.path }),
                  app.currentVersion == entry.installedVersion else { return false }
            return app.latestVersion == nil || app.latestVersion == entry.latestVersion
        }
        for app in apps where app.updateStatus == .updateAvailable {
            if app.isOrganisationLicensed {
                app.heldBack = .organisation
                app.updateStatus = .upToDate
            } else if updated.held.contains(where: { $0.path == app.path }) {
                app.heldBack = .notInstalled
                app.updateStatus = .upToDate
            }
        }

        // An app the check could not find out about stays as it was: without an answer,
        // nothing has been learned about it.
        let wasHidden = Set(record.hidden.map(\.path))
        updated.hidden = apps
            .filter { $0.hasNoUpdateSource || ($0.updateStatus == .unknown && wasHidden.contains($0.path)) }
            .map { LocalRecord.HiddenApp(name: $0.name, path: $0.path) }
            .sorted { $0.path < $1.path }

        remember(updated)
    }

    /// Remembers that an update was handed to the app's own updater and did not arrive, and
    /// shows the app as up to date until a newer version than that one appears.
    func holdBack(_ app: AppInfo) {
        guard let latest = app.latestVersion, latest != app.currentVersion else { return }
        var updated = record
        updated.held.removeAll { $0.path == app.path }
        updated.held.append(LocalRecord.HeldUpdate(
            name: app.name, path: app.path, installedVersion: app.currentVersion, latestVersion: latest
        ))
        updated.held.sort { $0.path < $1.path }
        app.heldBack = .notInstalled
        app.updateStatus = .upToDate
        remember(updated)
    }

    private func remember(_ updated: LocalRecord) {
        guard updated != record else { return }
        record = updated
        store.save(updated)
    }

    // MARK: - Checking

    /// Combined scan + check: re-scans installed apps then checks all for updates
    func checkForUpdates(persistTimestamp: Bool = true) {
        startCheck(persistTimestamp: persistTimestamp)
    }

    /// The same scan and check, for callers that need its results before continuing.
    func performCheckForUpdates(persistTimestamp: Bool = true) async {
        // A scan that is already under way is as fresh as a new one would be.
        if let running = activeCheck, isCheckingAll {
            await running.value
            return
        }
        await startCheck(persistTimestamp: persistTimestamp).value
    }

    @discardableResult
    private func startCheck(persistTimestamp: Bool) -> Task<Void, Never> {
        isScanning = true
        isCheckingAll = true
        progress = 0
        statusMessage = "Looking at your applications…"

        let task = Task { await runCheck(persistTimestamp: persistTimestamp) }
        activeCheck = task
        return task
    }

    private func runCheck(persistTimestamp: Bool) async {
        // Step 1: Fresh scan to pick up any version changes
        let scannedApps = await Task.detached {
            AppScanner.scanApplications()
        }.value

        apps = scannedApps
        subscribeToAppChanges()
        isScanning = false

        // Step 2: Check for updates
        statusMessage = "Checking for updates…"
        await VersionChecker.loadCaskCatalog()

        let total = Double(scannedApps.count)
        let batchSize = 5
        for batchStart in stride(from: 0, to: scannedApps.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, scannedApps.count)
            let batch = Array(scannedApps[batchStart..<batchEnd])

            await withTaskGroup(of: Void.self) { group in
                for app in batch {
                    group.addTask {
                        await VersionChecker.checkForUpdate(app)
                    }
                }
            }

            progress = Double(batchEnd) / total
        }
        settleCheck()

        statusMessage = "Checking Homebrew…"
        await loadBrewUpdates()

        statusMessage = "Checking developer tools…"
        await loadDevTools()

        isCheckingAll = false
        progress = 1.0

        let now = Date()
        lastScanTime = now
        if persistTimestamp {
            let filePath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".guava_last_scan")
            try? now.timeIntervalSince1970.description
                .data(using: .utf8)?.write(to: filePath)
        }
    }

    // MARK: - Homebrew

    /// Upgrade everything Homebrew reports as outdated in one pass, then reload the list.
    @discardableResult
    func performBrewUpgradeAll(onLine: ProcessRunner.LineHandler? = nil) async -> BrewUpgradeResult {
        let pending = brewUpdates.filter(\.canUpdate)
        guard !pending.isEmpty else { return BrewUpgradeResult() }
        let linkedBefore = linkedFormulae

        let upgrade = await BrewHelper.upgradeAll(onLine: onLine)
        var errorOutput = upgrade.launchError ?? upgrade.stderr

        // A cask whose install record is missing cannot be upgraded, only reinstalled.
        for package in pending where package.needsRepair {
            let repair = await BrewHelper.runProcess(
                ["reinstall", "--cask", package.token], timeout: 30 * 60, onLine: onLine
            )
            if !repair.success {
                errorOutput += "\n" + repair.stderr
            }
        }

        // Listed in a task of its own: when the caller was stopped part-way, what Homebrew
        // managed to upgrade before that still has to be read back to be reported truthfully.
        let listed = await Task { await self.loadBrewUpdates() }.value
        let message = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)

        guard listed else {
            // The packages known are those from before the pass; nothing is known beyond it.
            return BrewUpgradeResult(
                upgraded: [],
                remaining: pending.map(\.token),
                errorOutput: message,
                needsAuthentication: BrewHelper.requiresInteractiveAuthentication(message),
                isVerified: false
            )
        }

        // An upgrade can leave a formula installed and unlinked. Nothing more is started once
        // the run has been stopped.
        var links = BrewLinkRepair()
        if !Task.isCancelled {
            links = await repairBrewLinks(
                lostInUpgrade: linkedBefore.intersection(formulaeMissingLinks), onLine: onLine
            )
        }

        let stillPending = Set(brewUpdates.filter(\.canUpdate).map(\.id))
        return BrewUpgradeResult(
            upgraded: pending.filter { !stillPending.contains($0.id) }.map(\.token),
            remaining: pending.filter { stillPending.contains($0.id) }.map(\.token),
            errorOutput: message,
            needsAuthentication: BrewHelper.requiresInteractiveAuthentication(message),
            failure: upgrade.success || upgrade.wasCancelled ? nil : upgrade.failureMessage,
            links: links
        )
    }

    /// Links the formulae that Homebrew has installed without linking them, wherever that
    /// loses nothing. Until then their commands are missing from the PATH, and whatever needs
    /// them fails, Guava's own agent included. See `BrewHelper.relink`.
    ///
    /// - Parameter lostInUpgrade: the formulae that were linked until the upgrade just made.
    func repairBrewLinks(
        lostInUpgrade: Set<String> = [],
        onLine: ProcessRunner.LineHandler? = nil
    ) async -> BrewLinkRepair {
        var repair = BrewLinkRepair()
        for formula in formulaeMissingLinks.sorted() {
            // Nothing more is started once the run has been stopped.
            if Task.isCancelled { break }
            let wasLinked = lostInUpgrade.contains(formula)
            switch await BrewHelper.relink(formula, wasLinked: wasLinked, onLine: onLine) {
            case .linked:
                repair.relinked.append(formula)
            case .blocked:
                // A formula that was already unlinked before this run may be so on purpose,
                // and a run that was stopped did not find out what is in the way.
                if wasLinked, !Task.isCancelled { repair.unlinked.append(formula) }
            case .leftAlone:
                break
            }
        }
        if !repair.relinked.isEmpty {
            // In a task of its own, so that it is read back even when the run was stopped.
            await Task { await self.loadBrewUpdates() }.value
        }
        return repair
    }

    /// Reload the Homebrew packages. Returns false when Homebrew could not be asked; what was
    /// known before then stays, since an empty answer says nothing about what is installed.
    @discardableResult
    func loadBrewUpdates() async -> Bool {
        let result = await BrewHelper.installedPackages()

        if result.error != nil, !brewUpdates.isEmpty { return false }

        let formulae = result.packages.filter { $0.kind == .formula }
        linkedFormulae = Set(formulae.filter(\.isLinked).map(\.token))
        formulaeMissingLinks = Set(formulae.filter(\.isMissingLinks).map(\.token))

        // Dependencies count only when they are outdated.
        let listed = result.packages.filter {
            $0.kind != .formula || $0.installedOnRequest || $0.hasUpdate
        }
        brewUpdates = listed.map {
            BrewUpdateInfo(
                token: $0.token,
                kind: $0.kind,
                installedVersion: $0.installedVersion,
                latestVersion: $0.latestVersion,
                isPinned: $0.isPinned,
                hasUpdate: $0.hasUpdate,
                needsRepair: $0.needsRepair
            )
        }
        return result.error == nil
    }

    // MARK: - Developer tools

    /// Scan the home folder's dot entries for self-updating tools and read their versions.
    func loadDevTools() async {
        let scan = await Task.detached { DevToolScanner.scan() }.value

        let versions = await withTaskGroup(of: (String, String?).self) { group -> [String: String] in
            for tool in scan.tools {
                group.addTask { (tool.id, await DevToolUpdater.version(of: tool)?.display) }
            }
            var found: [String: String] = [:]
            for await (id, version) in group {
                found[id] = version
            }
            return found
        }

        devTools = scan.tools.map { DevToolInfo(tool: $0, version: versions[$0.id]) }
        dotEntryCount = scan.entries.count
    }

    // MARK: - Helpers

    /// The list is ordered by whether an app has an update, so it has to be drawn again
    /// whenever an app's state changes.
    private func subscribeToAppChanges() {
        cancellables.removeAll()
        for app in apps {
            app.objectWillChange
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }
    }
}
