import Foundation
import AppKit

/// Handles updating applications
class UpdateEngine {
    
    /// Update a single app via Homebrew
    static func updateApp(_ app: AppInfo) async -> Bool {
        guard app.updateMethod == .homebrew else { return false }
        
        guard let caskName = await getCaskName(name: app.name) else { return false }
        
        await MainActor.run {
            app.isUpdating = true
            app.updateStatus = .updating
        }
        
        let result = await BrewHelper.runWithStatus(["upgrade", "--cask", caskName])
        
        await MainActor.run {
            app.isUpdating = false
            if result.success {
                app.updateStatus = .upToDate
                app.updateError = nil
                if let newVersion = readCurrentVersion(at: app.path) {
                    app.latestVersion = newVersion
                }
            } else {
                app.updateStatus = .error
                let errMsg = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
                app.updateError = errMsg.isEmpty ? "Failed to update via Homebrew" : errMsg
            }
        }
        
        return result.success
    }
    
    /// Open the Mac App Store Updates tab
    static func openAppStoreUpdate(_ app: AppInfo) {
        if let url = URL(string: "macappstore://showUpdatesPage") {
            NSWorkspace.shared.open(url)
        }
    }
    
    /// Search for download page of the app
    static func openWebSearch(_ app: AppInfo) {
        let query = "\(app.name) mac download latest version".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? app.name
        if let url = URL(string: "https://www.google.com/search?q=\(query)") {
            NSWorkspace.shared.open(url)
        }
    }
    
    /// Get the Homebrew cask name for an app
    private static func getCaskName(name appName: String) async -> String? {
        let output = await BrewHelper.run(["list", "--cask"])
        let casks = output.components(separatedBy: .newlines).filter { !$0.isEmpty }
        
        let appNameLower = appName.lowercased()
            .replacingOccurrences(of: " ", with: "-")
        
        if casks.contains(appNameLower) { return appNameLower }
        
        for cask in casks {
            let info = await BrewHelper.run(["info", "--cask", "--json=v2", cask])
            if let data = info.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let caskList = json["casks"] as? [[String: Any]],
               let caskInfo = caskList.first,
               let artifacts = caskInfo["artifacts"] as? [[String: Any]] {
                for artifact in artifacts {
                    if let apps = artifact["app"] as? [String] {
                        for appFile in apps {
                            let name = appFile.replacingOccurrences(of: ".app", with: "")
                            if name.localizedCaseInsensitiveCompare(appName) == .orderedSame {
                                return cask
                            }
                        }
                    }
                }
            }
        }
        
        return nil
    }
    
    /// Re-read version from an app bundle
    private static func readCurrentVersion(at path: String) -> String? {
        let plistPath = (path as NSString).appendingPathComponent("Contents/Info.plist")
        guard let data = FileManager.default.contents(atPath: plistPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }
        return plist["CFBundleShortVersionString"] as? String
    }
}
