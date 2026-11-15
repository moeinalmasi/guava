import Foundation

/// Checks for the latest versions of applications using multiple sources
class VersionChecker {
    
    /// Cache: lowercased app name -> (token, latestVersion)
    private static var caskNameMap: [String: (token: String, version: String)] = [:]
    /// Cache: lowercased bundle ID -> (token, latestVersion)  
    private static var caskBundleIdMap: [String: (token: String, version: String)] = [:]
    /// Installed Homebrew cask tokens (for auto-update capability)
    private static var installedCaskTokens: Set<String> = []
    private static var cacheLoaded = false
    
    /// Manual bundle ID -> cask token mapping for apps whose names don't match
    private static let bundleIdToCask: [String: String] = [
        "com.adobe.acrobat.pro": "adobe-acrobat-pro",
        "com.adobe.reader": "adobe-acrobat-reader",
        "com.microsoft.vsode": "visual-studio-code",
        "com.microsoft.vscode": "visual-studio-code",
        "com.displaylink.displaylinkuseragent": "displaylink",
        "com.logi.ghub": "logitech-g-hub",
        "com.microsoft.wdav": "microsoft-auto-update",
        "com.microsoft.autoupdate2": "microsoft-auto-update",
        "com.google.chrome": "google-chrome",
        "com.google.chrome.canary": "google-chrome-canary",
        "org.mozilla.firefox": "firefox",
        "com.docker.docker": "docker",
        "com.spotify.client": "spotify",
        "com.tinyspeck.slackmacgap": "slack",
        "us.zoom.xos": "zoom",
        "com.microsoft.edgemac": "microsoft-edge",
        "com.microsoft.teams2": "microsoft-teams",
        "com.microsoft.word": "microsoft-word",
        "com.microsoft.excel": "microsoft-excel",
        "com.microsoft.powerpoint": "microsoft-powerpoint",
        "com.microsoft.outlook": "microsoft-outlook",
        "com.microsoft.onenote.mac": "microsoft-onenote",
        "com.postmanlabs.mac": "postman",
        "com.insomnia.app": "insomnia",
        "com.jetbrains.intellij": "intellij-idea",
        "com.jetbrains.pycharm": "pycharm",
        "com.jetbrains.webstorm": "webstorm",
        "com.sublimetext.4": "sublime-text",
        "com.obsproject.obs-studio": "obs",
        "com.1password.1password": "1password",
        "com.bitwarden.desktop": "bitwarden",
        "io.github.nickvision.application": "rectangle",
        "com.knollsoft.rectangle": "rectangle",
    ]
    
    /// Load the full Homebrew cask database from the public API
    static func loadHomebrewCaskMap() async {
        guard !cacheLoaded else { return }
        
        // 1. Load the full cask list from Homebrew's public API
        guard let url = URL(string: "https://formulae.brew.sh/api/cask.json") else {
            cacheLoaded = true
            return
        }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let casks = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                cacheLoaded = true
                return
            }
            
            for cask in casks {
                guard let token = cask["token"] as? String,
                      let version = cask["version"] as? String else { continue }
                
                let entry = (token: token, version: cleanVersion(version))
                
                // Map by cask token
                caskNameMap[token.lowercased()] = entry
                
                // Map by display names
                if let names = cask["name"] as? [String] {
                    for name in names {
                        caskNameMap[name.lowercased()] = entry
                    }
                }
                
                // Map by artifacts (app file names)
                if let artifacts = cask["artifacts"] as? [Any] {
                    for artifact in artifacts {
                        if let dict = artifact as? [String: Any],
                           let apps = dict["app"] as? [String] {
                            for app in apps {
                                let appName = app.replacingOccurrences(of: ".app", with: "").lowercased()
                                caskNameMap[appName] = entry
                            }
                        }
                    }
                }
            }
        } catch {
            // API unavailable, continue without it
        }
        
        // 2. Load locally installed cask tokens (for auto-update via brew)
        let brewOutput = await runBrewCommand(["list", "--cask"])
        if !brewOutput.isEmpty {
            let tokens = brewOutput.components(separatedBy: .newlines).filter { !$0.isEmpty }
            installedCaskTokens = Set(tokens)
        }
        
        cacheLoaded = true
    }
    
    /// Check for updates for a single app
    static func checkForUpdate(_ app: AppInfo) async {
        await MainActor.run {
            app.updateStatus = .checking
            app.latestVersion = nil
            app.updateError = nil
        }
        
        let currentVersion = app.currentVersion
        let bundleId = app.bundleIdentifier
        let appName = app.name
        let isAppStore = app.isAppleAppStoreApp
        
        // For Apple App Store apps, go straight to iTunes API
        if isAppStore, let bundleId = bundleId {
            let found = await checkAppStore(app, bundleId: bundleId, currentVersion: currentVersion)
            if found { return }
            await MainActor.run {
                app.updateMethod = .appStore
                app.updateStatus = .unknown
            }
            return
        }
        
        // 0. Try manual bundle ID -> cask token mapping first (most reliable)
        if let bundleId = bundleId,
           let caskToken = bundleIdToCask[bundleId.lowercased()] {
            let found = await checkHomebrewAPI(app, token: caskToken, currentVersion: currentVersion)
            if found { return }
        }
        
        // 1. Try Homebrew cask database (covers ~7500 apps)
        if let result = findInCaskDB(for: appName) {
            let isInstalledViaBrew = installedCaskTokens.contains(result.token)
            let cleanLatest = result.version
            let cleanCurrent = cleanVersion(currentVersion)
            let hasUpdate = compareVersions(cleanCurrent, cleanLatest) == .orderedAscending
            
            await MainActor.run {
                app.latestVersion = cleanLatest
                app.updateMethod = isInstalledViaBrew ? .homebrew : .manual
                app.updateStatus = hasUpdate ? .updateAvailable : .upToDate
            }
            return
        }
        
        // 2. Try Mac App Store lookup by bundle ID
        if let bundleId = bundleId {
            let found = await checkAppStore(app, bundleId: bundleId, currentVersion: currentVersion)
            if found { return }
        }
        
        // 3. Try Homebrew API by guessing token names
        let guessedTokens = generateCaskTokenGuesses(for: appName)
        for token in guessedTokens {
            let found = await checkHomebrewAPI(app, token: token, currentVersion: currentVersion)
            if found { return }
        }
        
        // Nothing found
        await MainActor.run {
            app.updateStatus = .unknown
            app.updateMethod = .manual
        }
    }
    
    /// Look up app in the cached Homebrew cask database
    private static func findInCaskDB(for appName: String) -> (token: String, version: String)? {
        if let entry = caskNameMap[appName.lowercased()] {
            return entry
        }
        let hyphenated = appName.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        if let entry = caskNameMap[hyphenated] {
            return entry
        }
        return nil
    }
    
    /// Generate possible Homebrew cask token names from an app name
    private static func generateCaskTokenGuesses(for name: String) -> [String] {
        let lower = name.lowercased()
        let hyphenated = lower.replacingOccurrences(of: " ", with: "-")
        let collapsed = lower.replacingOccurrences(of: " ", with: "")
        var guesses = [hyphenated, collapsed, lower]
        
        // Remove common suffixes
        for suffix in ["-app", "-for-mac", "-mac", "-desktop"] {
            if hyphenated.hasSuffix(suffix) {
                guesses.append(String(hyphenated.dropLast(suffix.count)))
            }
        }
        
        return guesses
    }
    
    /// Check a specific Homebrew cask token via the public API
    private static func checkHomebrewAPI(_ app: AppInfo, token: String, currentVersion: String) async -> Bool {
        let urlString = "https://formulae.brew.sh/api/cask/\(token).json"
        guard let url = URL(string: urlString) else { return false }
        
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return false }
            
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let version = json["version"] as? String else { return false }
            
            let cleanLatest = cleanVersion(version)
            let cleanCurrent = cleanVersion(currentVersion)
            let hasUpdate = compareVersions(cleanCurrent, cleanLatest) == .orderedAscending
            let isInstalledViaBrew = installedCaskTokens.contains(token)
            
            await MainActor.run {
                app.latestVersion = cleanLatest
                app.updateMethod = isInstalledViaBrew ? .homebrew : .manual
                app.updateStatus = hasUpdate ? .updateAvailable : .upToDate
            }
            return true
        } catch {
            return false
        }
    }
    
    /// Check for updates via Mac App Store
    private static func checkAppStore(_ app: AppInfo, bundleId: String, currentVersion: String) async -> Bool {
        let urlString = "https://itunes.apple.com/lookup?bundleId=\(bundleId)&country=us&entity=macSoftware"
        guard let url = URL(string: urlString) else { return false }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]],
                  let result = results.first,
                  let latestVersion = result["version"] as? String else {
                return false
            }
            
            let cleanLatest = cleanVersion(latestVersion)
            let cleanCurrent = cleanVersion(currentVersion)
            let hasUpdate = compareVersions(cleanCurrent, cleanLatest) == .orderedAscending
            
            await MainActor.run {
                app.latestVersion = cleanLatest
                app.updateMethod = .appStore
                app.updateStatus = hasUpdate ? .updateAvailable : .upToDate
            }
            return true
        } catch {
            return false
        }
    }
    
    /// Remove extra metadata from version strings
    /// Handles: "1.2.3,456" -> "1.2.3", "0.4.2+2" -> "0.4.2", "16.105.26020123" unchanged
    static func cleanVersion(_ version: String) -> String {
        var v = version
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
    
    /// Run a Homebrew command and return output
    private static func runBrewCommand(_ arguments: [String]) async -> String {
        await BrewHelper.run(arguments)
    }
}
