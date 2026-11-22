import Foundation

/// Checks for the latest versions of applications using multiple sources
class VersionChecker {

    /// Homebrew's cask catalogue, the casks Homebrew has installed on this Mac, and the
    /// download Homebrew publishes for each cask. Read from concurrent checks.
    private static var catalog = CaskCatalog()
    private static var installedCaskTokens: Set<String> = []
    private static var caskDownloads: [String: CaskDownload] = [:]
    private static var catalogLoadedAt: Date?
    private static let lock = NSLock()

    /// How long a downloaded catalogue is used before a check downloads it again.
    private static let catalogLifetime: TimeInterval = 5 * 60

    /// The download Homebrew publishes for a cask on this Mac, if the cask is known.
    static func download(forCask token: String) -> CaskDownload? {
        lock.withLock { caskDownloads[token] }
    }

    /// Load Homebrew's cask catalogue from its public API. A catalogue that is a few minutes
    /// old is downloaded again, so that a check made long after the app was opened still sees
    /// the latest releases.
    static func loadCaskCatalog() async {
        let isFresh = lock.withLock {
            catalogLoadedAt.map { Date().timeIntervalSince($0) < catalogLifetime } ?? false
        }
        guard !isFresh else { return }

        var loaded: (catalog: CaskCatalog, downloads: [String: CaskDownload])?
        if let url = URL(string: "https://formulae.brew.sh/api/cask.json"),
           let (data, _) = try? await URLSession.shared.data(from: url),
           let records = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            var downloads: [String: CaskDownload] = [:]
            for record in records {
                if let download = CaskDownloadResolver.resolve(cask: record) {
                    downloads[download.token] = download
                }
            }
            loaded = (CaskCatalog(records: records), downloads)
        }

        // Locally installed cask tokens (for auto-update via brew)
        let tokens = await BrewHelper.run(["list", "--cask"])
            .components(separatedBy: .newlines)
            .filter { !$0.isEmpty }

        lock.withLock {
            // Without an answer, what was known before stays, and the next check asks again.
            if let loaded {
                catalog = loaded.catalog
                caskDownloads = loaded.downloads
                catalogLoadedAt = Date()
            }
            if !tokens.isEmpty {
                installedCaskTokens = Set(tokens)
            }
        }
    }
    
    /// Check for updates for a single app
    static func checkForUpdate(_ app: AppInfo) async {
        await MainActor.run {
            app.updateStatus = .checking
            app.latestVersion = nil
            app.updateError = nil
            app.caskToken = nil
            app.heldBack = nil
            app.hasNoUpdateSource = false
        }
        
        let currentVersion = app.currentVersion
        let bundleId = app.bundleIdentifier
        let appName = app.name
        let appPath = app.path
        // Anything carrying a Mac App Store receipt is the App Store's to update, even when a
        // Homebrew cask exists for a direct-download build of the same app.
        let isAppStore = app.hasAppStoreReceipt
        
        // For App Store apps, go straight to iTunes API
        if isAppStore, let bundleId = bundleId {
            let answer = await askAppStore(about: bundleId)
            if case .listed(let version) = answer {
                await record(storeVersion: version, for: app, currentVersion: currentVersion)
                return
            }
            await MainActor.run {
                app.updateMethod = .appStore
                app.updateStatus = .unknown
                app.hasNoUpdateSource = answer == .notListed
            }
            return
        }

        let (catalog, installedTokens) = lock.withLock { (Self.catalog, installedCaskTokens) }

        // 1. The Homebrew cask that claims this app (the catalogue covers ~7500 apps)
        let claim = catalog.lookUp(
            name: appName,
            path: appPath,
            bundleIdentifier: bundleId,
            installedVersion: cleanVersion(currentVersion),
            installedTokens: installedTokens,
            isOnlyAppInFolder: { isOnlyApp(inFolderOf: appPath) }
        )
        if case .match(let cask) = claim {
            await record(cask, for: app, currentVersion: currentVersion, installedTokens: installedTokens)
            return
        }
        
        // 2. Try Mac App Store lookup by bundle ID
        var storeAnswer: StoreAnswer?
        if let bundleId = bundleId {
            let answer = await askAppStore(about: bundleId)
            if case .listed(let version) = answer {
                await record(storeVersion: version, for: app, currentVersion: currentVersion)
                return
            }
            storeAnswer = answer
        }
        
        // 3. A cask whose token can be guessed from the app's name. Not when several casks
        // claim the app already: a guess would only pick one of them.
        if claim == .unclaimed {
            for token in tokenGuesses(for: appName) {
                if let guessed = catalog.cask(withToken: token) {
                    await record(guessed, for: app, currentVersion: currentVersion, installedTokens: installedTokens)
                    return
                }
            }
        }
        
        // Nothing found. That nothing offers versions of this app is only established when
        // every source could be asked and none of them knew it.
        let isEstablished = hasNoSource(
            claim: claim, catalogIsLoaded: !catalog.isEmpty, storeAnswer: storeAnswer
        )
        await MainActor.run {
            app.updateStatus = .unknown
            app.updateMethod = .manual
            app.hasNoUpdateSource = isEstablished
        }
    }

    /// Whether the sources, taken together, say that nothing offers versions of an app.
    /// `storeAnswer` is nil for an app without a bundle identifier to ask the App Store about.
    static func hasNoSource(claim: CaskCatalog.Answer, catalogIsLoaded: Bool, storeAnswer: StoreAnswer?) -> Bool {
        claim == .unclaimed && catalogIsLoaded && storeAnswer != .unreachable
    }

    private static func record(
        _ cask: CaskCatalog.Match,
        for app: AppInfo,
        currentVersion: String,
        installedTokens: Set<String>
    ) async {
        let hasUpdate = compareVersions(cleanVersion(currentVersion), cask.version) == .orderedAscending
        await MainActor.run {
            app.latestVersion = cask.version
            app.updateMethod = installedTokens.contains(cask.token) ? .homebrew : .manual
            app.updateStatus = hasUpdate ? .updateAvailable : .upToDate
            app.caskToken = cask.token
        }
    }

    private static func record(storeVersion: String, for app: AppInfo, currentVersion: String) async {
        let latest = cleanVersion(storeVersion)
        let hasUpdate = compareVersions(cleanVersion(currentVersion), latest) == .orderedAscending
        await MainActor.run {
            app.latestVersion = latest
            app.updateMethod = .appStore
            app.updateStatus = hasUpdate ? .updateAvailable : .upToDate
        }
    }

    /// Whether a bundle is the only application in the folder that holds it.
    private static func isOnlyApp(inFolderOf path: String) -> Bool {
        let folder = (path as NSString).deletingLastPathComponent
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return entries.filter { $0.lowercased().hasSuffix(".app") }.count == 1
    }
    
    /// Cask tokens an app's name suggests. A token often leaves out a word the name ends with.
    static func tokenGuesses(for name: String) -> [String] {
        let lower = name.lowercased()
        let hyphenated = lower.replacingOccurrences(of: " ", with: "-")
        let collapsed = lower.replacingOccurrences(of: " ", with: "")
        var guesses = [hyphenated, collapsed, lower]
        
        for suffix in ["-app", "-for-mac", "-mac", "-desktop", "-manager"] {
            if hyphenated.hasSuffix(suffix) {
                guesses.append(String(hyphenated.dropLast(suffix.count)))
            }
        }
        
        return guesses
    }
    
    /// What the App Store said when asked about an app by its bundle identifier.
    enum StoreAnswer: Equatable {
        case listed(version: String)
        /// The App Store answered, and does not carry the app.
        case notListed
        /// There was no usable answer, so nothing is known either way.
        case unreachable
    }

    /// Ask the Mac App Store for the current version of an app.
    private static func askAppStore(about bundleId: String) async -> StoreAnswer {
        let urlString = "https://itunes.apple.com/lookup?bundleId=\(bundleId)&country=us&entity=macSoftware"
        guard let url = URL(string: urlString),
              let (data, response) = try? await URLSession.shared.data(from: url),
              let status = (response as? HTTPURLResponse)?.statusCode else {
            return .unreachable
        }
        return storeAnswer(statusCode: status, body: data)
    }

    /// Reads the App Store's reply to a lookup.
    static func storeAnswer(statusCode: Int, body: Data) -> StoreAnswer {
        guard statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else {
            return .unreachable
        }
        guard let first = results.first else { return .notListed }
        guard let version = first["version"] as? String else { return .unreachable }
        return .listed(version: version)
    }
    
    /// Remove extra metadata from version strings
    /// Handles: "1.2.3,456" -> "1.2.3", "0.4.2+2" -> "0.4.2", "16.105.26020123" unchanged,
    /// "7.2.5 (90525)" -> "7.2.5.90525"
    static func cleanVersion(_ version: String) -> String {
        var v = version
        // Fold a trailing parenthesized build number into a version segment
        if let match = v.range(of: #"\s*\((\d+)\)\s*$"#, options: .regularExpression) {
            let build = v[match].filter(\.isNumber)
            v = String(v[v.startIndex..<match.lowerBound]) + "." + build
        }
        if let commaIdx = v.firstIndex(of: ",") {
            v = String(v[v.startIndex..<commaIdx])
        }
        if let plusIdx = v.firstIndex(of: "+") {
            v = String(v[v.startIndex..<plusIdx])
        }
        v = v.trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? "0" : v
    }
    
    /// Compare two semantic version strings
    /// Handles cases where Homebrew uses build numbers while installed uses short versions
    static func compareVersions(_ v1: String, _ v2: String) -> ComparisonResult {
        let parts1 = v1.components(separatedBy: ".").compactMap { Int($0) }
        let parts2 = v2.components(separatedBy: ".").compactMap { Int($0) }
        
        let maxLen = max(parts1.count, parts2.count)
        
        for i in 0..<maxLen {
            let p1 = i < parts1.count ? parts1[i] : 0
            let p2 = i < parts2.count ? parts2[i] : 0
            
            // If one segment is a build number (>100000) and the other is a
            // normal version (<1000), they use different versioning schemes — skip
            if (p1 > 100000 && p2 < 1000) || (p2 > 100000 && p1 < 1000) {
                continue
            }
            
            if p1 < p2 { return .orderedAscending }
            if p1 > p2 { return .orderedDescending }
        }
        
        return .orderedSame
    }
}
