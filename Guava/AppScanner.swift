import Foundation
import AppKit

/// Finds the applications Guava can keep up to date.
///
/// Only /Applications and ~/Applications are looked at. Anything macOS updates by itself is
/// left out altogether: the folders under /System are never scanned, and an Apple app without
/// a Mac App Store receipt is skipped, since it arrives with macOS.
class AppScanner {

    private struct AppIdentity: Hashable {
        let bundleIdentifier: String?
        let normalizedName: String
    }

    /// Where applications are looked for. Nothing under /System is among them.
    static var defaultLocations: [URL] {
        [
            URL(fileURLWithPath: "/Applications"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true),
        ]
    }
    
    /// Bundle identifiers to exclude from scan results entirely
    private static let excludedBundleIds: Set<String> = Set([Bundle.main.bundleIdentifier].compactMap { $0 })

    /// Whether an application belongs in the list at all, going by its Info.plist.
    static func isListed(info: [String: Any], hasAppStoreReceipt: Bool) -> Bool {
        // A web app saved from a browser is part of that browser, not an application with
        // updates of its own. Chromium-based browsers mark the launcher they create with this.
        if info["CrAppModeShortcutID"] != nil { return false }
        // Apple's own apps come with macOS and are updated with it, unless they were
        // installed from the Mac App Store.
        if let identifier = info["CFBundleIdentifier"] as? String,
           identifier.lowercased().hasPrefix("com.apple."), !hasAppStoreReceipt {
            return false
        }
        return true
    }
    
    /// Scans the application folders and returns every app Guava can update, by name.
    static func scanApplications(in locations: [URL] = defaultLocations) -> [AppInfo] {
        let fileManager = FileManager.default
        var apps: [AppInfo] = []
        var seenApps = Set<AppIdentity>()

        for location in locations {
            guard let enumerator = fileManager.enumerator(
                at: location,
                includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                options: [.skipsPackageDescendants]
            ) else {
                continue
            }

            for case let appURL as URL in enumerator
            where appURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
                guard let app = readAppInfo(at: appURL.path) else {
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

    /// A string value from an app's Info.plist, such as its Sparkle feed URL.
    static func infoValue(forKey key: String, inAppAt appPath: String) -> String? {
        let plistPath = (appPath as NSString).appendingPathComponent("Contents/Info.plist")
        guard let plistData = FileManager.default.contents(atPath: plistPath),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] else {
            return nil
        }
        return plist[key] as? String
    }
    
    /// Read app info from a .app bundle path. Nil for bundles that cannot be read and for
    /// those that do not belong in the list.
    private static func readAppInfo(at appPath: String) -> AppInfo? {
        let fileManager = FileManager.default
        let plistPath = (appPath as NSString).appendingPathComponent("Contents/Info.plist")
        
        guard fileManager.fileExists(atPath: plistPath),
              let plistData = fileManager.contents(atPath: plistPath),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] else {
            return nil
        }

        let bundleId = plist["CFBundleIdentifier"] as? String
        let receiptPath = (appPath as NSString).appendingPathComponent("Contents/_MASReceipt/receipt")
        let hasReceipt = fileManager.fileExists(atPath: receiptPath)
        guard isListed(info: plist, hasAppStoreReceipt: hasReceipt) else {
            return nil
        }
        
        let fileName = (appPath as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
        let name = (plist["CFBundleDisplayName"] as? String)
            ?? (plist["CFBundleName"] as? String)
            ?? fileName
        
        let version = (plist["CFBundleShortVersionString"] as? String)
            ?? (plist["CFBundleVersion"] as? String)
            ?? "Unknown"
        
        let icon = NSWorkspace.shared.icon(forFile: appPath)
        icon.size = NSSize(width: 32, height: 32)
        
        return AppInfo(
            name: name,
            bundleIdentifier: bundleId,
            currentVersion: version,
            path: appPath,
            icon: icon,
            hasAppStoreReceipt: hasReceipt,
            isOrganisationLicensed: hasReceipt && isOrganisationLicensed(appAt: appPath)
        )
    }

    /// Whether a Mac App Store copy is licensed to this Mac by an organisation rather than
    /// bought with an Apple ID. Spotlight records that from the receipt; when Spotlight has
    /// nothing to say about the bundle, the copy is taken to be an ordinary one.
    static func isOrganisationLicensed(appAt appPath: String) -> Bool {
        let item = NSMetadataItem(url: URL(fileURLWithPath: appPath))
        return (item?.value(forAttribute: "kMDItemAppStoreReceiptIsMachineLicensed") as? NSNumber)?.boolValue == true
    }
}
