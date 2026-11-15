import SwiftUI
import Combine

/// Main view model that coordinates scanning, checking, and updating
@MainActor
class GuavaViewModel: ObservableObject {
    @Published var allApps: [AppInfo] = []
    @Published var isScanning: Bool = false
    @Published var isCheckingAll: Bool = false
    @Published var isUpdatingAll: Bool = false
    @Published var brewUpdates: [BrewUpdateInfo] = []
    @Published var isScanningBrew: Bool = false
    @Published var isUpdatingAllBrew: Bool = false
    @Published var brewAuthenticationRequest: BrewAuthenticationRequest?
    @Published var searchText: String = ""
    @Published var filterMode: FilterMode = .all
    @Published var hiddenFilterMode: HiddenFilterMode = .all
    @Published var progress: Double = 0
    @Published var statusMessage: String = "Ready"
    @Published var selectedTab: Tab = .apps
    @Published var tempFiles: [TempFileInfo] = []
    @Published var isScanningTempFiles: Bool = false
    @Published var isDeletingAllTempFiles: Bool = false
    @Published var tempFileFilterMode: TempFileCategory? = nil
    @Published var lastScanTime: Date? = {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".guava_last_scan")
        guard let data = try? Data(contentsOf: path),
              let str = String(data: data, encoding: .utf8),
              let ti = Double(str) else { return nil }
        return Date(timeIntervalSince1970: ti)
    }()
    
    let hiddenManager = HiddenAppsManager.shared
    private var cancellables = Set<AnyCancellable>()
    
    enum Tab: String, CaseIterable {
        case apps = "Applications"
        case hidden = "Hidden Apps"
        case tempFiles = "Temporary Files"
    }
    
    enum FilterMode: String, CaseIterable {
        case all = "All"
        case updatesAvailable = "Updates Available"
        case upToDate = "Up to Date"
        case appStore = "App Store"
        case brew = "Brew"
    }
    
    enum HiddenFilterMode: String, CaseIterable {
        case all = "All"
        case hidden = "Hidden"
        case macOSNative = "macOS Native"
        case edgeApps = "Edge Apps"
    }
    
    init() {
        // Re-publish when hidden list changes
        hiddenManager.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }
    
    /// Visible apps: not hidden by user AND not OS-update-only system apps
    var apps: [AppInfo] {
        allApps.filter {
            !$0.isSystemOSUpdate &&
            !$0.isEdgeApp &&
            !hiddenManager.isHidden($0.name)
        }
    }

    /// Hidden apps: user-hidden, OS-update-only system apps, or Edge-installed web apps.
    var hiddenApps: [AppInfo] {
        allApps.filter {
            $0.isSystemOSUpdate ||
            $0.isEdgeApp ||
            hiddenManager.isHidden($0.name)
        }
    }
    
    var filteredApps: [AppInfo] {
        var result = apps
        
        if !searchText.isEmpty {
            result = result.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
        
        switch filterMode {
        case .all:
            break
        case .updatesAvailable:
            result = result.filter { $0.updateStatus == .updateAvailable }
        case .upToDate:
            result = result.filter { $0.updateStatus == .upToDate }
        case .appStore:
            result = result.filter { $0.isAppleAppStoreApp }
        case .brew:
            result = []
        }
        
        return result
    }
    
    var filteredHiddenApps: [AppInfo] {
        var result = hiddenApps
        
        if !searchText.isEmpty {
            result = result.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
        
        switch hiddenFilterMode {
        case .all:
            break
        case .hidden:
            result = result.filter {
                hiddenManager.isHidden($0.name) &&
                !$0.isSystemOSUpdate &&
                !$0.isEdgeApp
            }
        case .macOSNative:
            result = result.filter { $0.isSystemOSUpdate }
        case .edgeApps:
            result = result.filter { $0.isEdgeApp }
        }
        
        return result
    }
    
    var updateCount: Int {
        apps.filter { $0.hasUpdate }.count
    }
    
    /// Combined scan + check: re-scans installed apps then checks all for updates
    func checkForUpdates(persistTimestamp: Bool = true) {
        isScanning = true
        isCheckingAll = true
        progress = 0
        statusMessage = "Scanning applications..."
        
        Task {
            // Step 1: Fresh scan to pick up any version changes
            let scannedApps = await Task.detached {
                AppScanner.scanApplications()
            }.value
            
            self.allApps = scannedApps
            self.subscribeToAppChanges()
            self.isScanning = false
            
            // Step 2: Check for updates
            statusMessage = "Loading Homebrew data..."
            await VersionChecker.loadHomebrewCaskMap()
            
            let visibleApps = apps
            let total = Double(visibleApps.count)
            statusMessage = "Checking for updates..."
            
            let batchSize = 5
            for batchStart in stride(from: 0, to: visibleApps.count, by: batchSize) {
                let batchEnd = min(batchStart + batchSize, visibleApps.count)
                let batch = Array(visibleApps[batchStart..<batchEnd])
                
                await withTaskGroup(of: Void.self) { group in
                    for app in batch {
                        group.addTask {
                            await VersionChecker.checkForUpdate(app)
                        }
                    }
                }
                
                progress = Double(batchEnd) / total
            }

            statusMessage = "Loading installed Homebrew packages..."
            await loadBrewUpdates()
            
            isCheckingAll = false
            progress = 1.0
            
            if persistTimestamp {
                lastScanTime = Date()
                let filePath = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".guava_last_scan")
                try? lastScanTime!.timeIntervalSince1970.description
                    .data(using: .utf8)?.write(to: filePath)
            }
            
            let updatable = updateCount
            statusMessage = updatable > 0
                ? "\(updatable) update(s) available"
                : "All applications are up to date"
        }
    }
    
    func updateApp(_ app: AppInfo) {
        Task { _ = await UpdateEngine.updateApp(app) }
    }

    var filteredBrewUpdates: [BrewUpdateInfo] {
        guard !searchText.isEmpty else { return brewUpdates }
        return brewUpdates.filter {
            $0.token.localizedCaseInsensitiveContains(searchText)
        }
    }

    func refreshBrewUpdates() {
        Task {
            await loadBrewUpdates()
        }
    }

    func updateBrewCask(_ cask: BrewUpdateInfo) {
        guard cask.canUpdate else { return }

        Task {
            cask.isUpdating = true
            cask.updateError = nil
            statusMessage = "Updating \(cask.token)..."

            let result = await BrewHelper.runWithStatus(updateArguments(for: cask))
            cask.isUpdating = false

            if result.success {
                statusMessage = "Updated \(cask.token)"
                await loadBrewUpdates()
            } else {
                let message = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
                cask.updateError = message.isEmpty ? "Homebrew upgrade failed" : message
                statusMessage = "Failed to update \(cask.token)"
                requestAuthenticationIfNeeded(
                    tokens: [cask.token],
                    error: message,
                    requiresReinstall: cask.needsRepair
                )
            }
        }
    }

    func updateAllBrewCasks() {
        let casks = brewUpdates.filter(\.canUpdate)
        guard !casks.isEmpty else { return }

        Task {
            isUpdatingAllBrew = true
            statusMessage = "Updating \(casks.count) Homebrew casks..."

            var updatedCount = 0
            var failedCount = 0
            for cask in casks {
                cask.isUpdating = true
                cask.updateError = nil
                let result = await BrewHelper.runWithStatus(updateArguments(for: cask))
                cask.isUpdating = false

                if result.success {
                    updatedCount += 1
                } else {
                    failedCount += 1
                    let message = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
                    cask.updateError = message.isEmpty ? "Homebrew update failed" : message
                    requestAuthenticationIfNeeded(
                        tokens: [cask.token],
                        error: message,
                        requiresReinstall: cask.needsRepair
                    )
                }
            }

            isUpdatingAllBrew = false
            statusMessage = failedCount == 0
                ? "Updated \(updatedCount) Homebrew casks"
                : "Updated \(updatedCount); \(failedCount) failed"

            await loadBrewUpdates()
        }
    }
    
    func checkSingleApp(_ app: AppInfo) {
        Task {
            // Re-read installed version from disk in case it was updated
            app.currentVersion = AppScanner.readCurrentVersion(for: app.path) ?? app.currentVersion
            await VersionChecker.loadHomebrewCaskMap()
            await VersionChecker.checkForUpdate(app)
        }
    }
    
    func openUpdate(for app: AppInfo) {
        switch app.updateMethod {
        case .appStore: UpdateEngine.openAppStoreUpdate(app)
        case .manual, .unknown: UpdateEngine.openWebSearch(app)
        default: break
        }
    }
    
    func hideApp(_ app: AppInfo) {
        hiddenManager.hide(app.name)
    }
    
    func unhideApp(_ app: AppInfo) {
        hiddenManager.unhide(app.name)
    }

    func openInteractiveBrewUpgrade(_ request: BrewAuthenticationRequest) {
        BrewHelper.openInteractiveUpgrade(
            tokens: request.caskTokens,
            kind: request.packageKind,
            includeAzureLogin: request.requiresAzureLogin,
            reinstall: request.requiresReinstall
        )
        statusMessage = "Continue the Homebrew update in Terminal, then refresh Brew updates"
    }

    private func requestAuthenticationIfNeeded(tokens: [String], error: String, requiresReinstall: Bool) {
        guard BrewHelper.requiresInteractiveAuthentication(error) else { return }
        brewAuthenticationRequest = BrewAuthenticationRequest(
            caskTokens: tokens,
            errorMessage: error,
            requiresAzureLogin: BrewHelper.requiresAzureLogin(error),
            requiresReinstall: requiresReinstall,
            packageKind: brewUpdates.first { tokens.contains($0.token) }?.kind ?? .cask
        )
    }

    private func updateArguments(for package: BrewUpdateInfo) -> [String] {
        var arguments = [package.needsRepair ? "reinstall" : "upgrade"]
        if package.kind == .cask {
            arguments.append("--cask")
        }
        arguments.append(package.token)
        return arguments
    }

    private func loadBrewUpdates() async {
        isScanningBrew = true
        let result = await BrewHelper.installedPackages()
        brewUpdates = result.packages.map {
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
        isScanningBrew = false

        if let error = result.error {
            statusMessage = error
        }
    }
    
    // MARK: - Temporary Files
    
    var filteredTempFiles: [TempFileInfo] {
        var result = tempFiles
        if !searchText.isEmpty {
            result = result.filter {
                $0.fileName.localizedCaseInsensitiveContains(searchText) ||
                $0.appName.localizedCaseInsensitiveContains(searchText)
            }
        }
        if let category = tempFileFilterMode {
            result = result.filter { $0.category == category }
        }
        return result
    }
    
    var totalTempFileSize: String {
        let total = tempFiles.reduce(Int64(0)) { $0 + $1.size }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }
    
    var filteredTempFileSize: String {
        let total = filteredTempFiles.reduce(Int64(0)) { $0 + $1.size }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }
    
    func scanTempFiles() {
        isScanningTempFiles = true
        statusMessage = "Scanning temporary files..."
        
        Task {
            let files = await Task.detached {
                TempFileScanner.scan()
            }.value
            
            self.tempFiles = files
            self.subscribeToTempFileChanges()
            self.isScanningTempFiles = false
            self.statusMessage = "Found \(files.count) items (\(totalTempFileSize))"
        }
    }
    
    func deleteTempFile(_ file: TempFileInfo) {
        guard !file.isCritical else { return }
        file.isDeleting = true
        Task.detached {
            let success = TempFileScanner.deleteItem(at: file.path)
            await MainActor.run {
                if success {
                    self.tempFiles.removeAll { $0.id == file.id }
                    self.statusMessage = "Deleted \(file.fileName)"
                } else {
                    file.isDeleting = false
                    self.statusMessage = "Failed to delete \(file.fileName)"
                }
            }
        }
    }
    
    func deleteAllTempFiles() {
        isDeletingAllTempFiles = true
        statusMessage = "Deleting all temporary files..."
        let filesToDelete = filteredTempFiles.filter { !$0.isCritical }
        let totalCount = filesToDelete.count
        
        Task.detached {
            var deleted = 0
            for file in filesToDelete {
                await MainActor.run { file.isDeleting = true }
                if TempFileScanner.deleteItem(at: file.path) {
                    deleted += 1
                    await MainActor.run {
                        self.tempFiles.removeAll { $0.id == file.id }
                    }
                } else {
                    await MainActor.run { file.isDeleting = false }
                }
            }
            let finalCount = deleted
            await MainActor.run {
                self.isDeletingAllTempFiles = false
                self.statusMessage = "Deleted \(finalCount) of \(totalCount) items"
            }
        }
    }
    
    private func subscribeToTempFileChanges() {
        for file in tempFiles {
            file.objectWillChange
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }
    }
    
    private func subscribeToAppChanges() {
        cancellables.removeAll()
        // Re-subscribe to hidden manager
        hiddenManager.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        
        for app in allApps {
            app.objectWillChange
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }
    }
}
