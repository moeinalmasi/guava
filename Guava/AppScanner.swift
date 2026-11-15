import Foundation
import AppKit

/// Scans standard system-wide, user, and macOS-managed application locations.
class AppScanner {

    private struct ScanLocation {
        let url: URL
        let isMacOSManaged: Bool
    }

    private struct AppIdentity: Hashable {
        let bundleIdentifier: String?
        let normalizedName: String
    }

    /// Application directories to scan and whether their apps are updated with macOS.
    private static var scanLocations: [ScanLocation] {
        [
            ScanLocation(url: URL(fileURLWithPath: "/Applications"), isMacOSManaged: false),
            ScanLocation(
                url: FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Applications", isDirectory: true),
                isMacOSManaged: false
            ),
            ScanLocation(url: URL(fileURLWithPath: "/System/Applications"), isMacOSManaged: true),
            ScanLocation(
                url: URL(fileURLWithPath: "/System/Library/CoreServices/Applications"),
                isMacOSManaged: true
            ),
        ]
    }
    
    /// Bundle identifiers to exclude from scan results entirely
    private static let excludedBundleIds: Set<String> = Set([Bundle.main.bundleIdentifier].compactMap { $0 })
    
    /// Scans application folders and returns ALL apps with proper tagging
    static func scanApplications() -> [AppInfo] {
        let fileManager = FileManager.default
        var apps: [AppInfo] = []
        var seenApps = Set<AppIdentity>()

        for location in scanLocations {
            guard let enumerator = fileManager.enumerator(
                at: location.url,
                includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                options: [.skipsPackageDescendants]
            ) else {
                continue
            }

            for case let appURL as URL in enumerator
            where appURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
                guard let app = readAppInfo(
                    at: appURL.path,
                    isMacOSManaged: location.isMacOSManaged
                ) else {
                    continue
                }

                if let bundleIdentifier = app.bundleIdentifier,
                   excludedBundleIds.contains(bundleIdentifier) {
                    continue
                }

                let identity = AppIdentity(
                    bundleIdentifier: app.bundleIdentifier,
                    normalizedName: app.name.folding(
                        options: [.caseInsensitive, .diacriticInsensitive],
                        locale: .current
                    )
                )
                if seenApps.insert(identity).inserted {
                    apps.append(app)
                }
            }
        }
        
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    
    /// Re-read the current version from disk for a given app path
    static func readCurrentVersion(for appPath: String) -> String? {
        let plistPath = (appPath as NSString).appendingPathComponent("Contents/Info.plist")
        guard let plistData = FileManager.default.contents(atPath: plistPath),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] else {
            return nil
        }
        return (plist["CFBundleShortVersionString"] as? String)
            ?? (plist["CFBundleVersion"] as? String)
    }
    
    /// Read app info from a .app bundle path
    private static func readAppInfo(at appPath: String, isMacOSManaged: Bool) -> AppInfo? {
        let fileManager = FileManager.default
        let plistPath = (appPath as NSString).appendingPathComponent("Contents/Info.plist")
        
        guard fileManager.fileExists(atPath: plistPath),
              let plistData = fileManager.contents(atPath: plistPath),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] else {
            return nil
        }
        
        let fileName = (appPath as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
        let name = (plist["CFBundleDisplayName"] as? String)
            ?? (plist["CFBundleName"] as? String)
            ?? fileName
        
        let version = (plist["CFBundleShortVersionString"] as? String)
            ?? (plist["CFBundleVersion"] as? String)
            ?? "Unknown"
        let bundleId = plist["CFBundleIdentifier"] as? String
        
        let icon = NSWorkspace.shared.icon(forFile: appPath)
        icon.size = NSSize(width: 32, height: 32)
        
        // Check if this is an Apple App Store app
        let receiptPath = (appPath as NSString).appendingPathComponent("Contents/_MASReceipt/receipt")
        let hasReceipt = fileManager.fileExists(atPath: receiptPath)
        let isAppleBundleId = bundleId?.hasPrefix("com.apple.") ?? false
        let isEdgeApp = bundleId?.hasPrefix("com.microsoft.edgemac.app.") ?? false

        let isAppStore = hasReceipt && isAppleBundleId
        let isOSUpdate = isMacOSManaged || (isAppleBundleId && !hasReceipt)
        
        return AppInfo(
            name: name,
            bundleIdentifier: bundleId,
            currentVersion: version,
            path: appPath,
            icon: icon,
            isAppleAppStoreApp: isAppStore,
            isSystemOSUpdate: isOSUpdate,
            isEdgeApp: isEdgeApp
        )
    }
}
