import Foundation
import AppKit

/// Represents how an app can be updated
enum UpdateMethod: String, Codable {
    case homebrew       // Can be updated via `brew upgrade --cask`
    case appStore       // Needs to be updated via Mac App Store
    case manual         // Requires manual download from website
    case unknown        // Update method not determined
}

/// Represents the update status of an application
enum UpdateStatus: String {
    case upToDate       = "Up to Date"
    case updateAvailable = "Update Available"
    case checking       = "Checking..."
    case error          = "Error"
    case updating       = "Updating..."
    case unknown        = "Unknown"
}

/// Model for an installed application
class AppInfo: Identifiable, ObservableObject {
    let id = UUID()
    let name: String
    let bundleIdentifier: String?
    @Published var currentVersion: String
    let path: String
    let icon: NSImage?
    let isAppleAppStoreApp: Bool
    let isSystemOSUpdate: Bool
    let isEdgeApp: Bool
    
    @Published var latestVersion: String?
    @Published var updateStatus: UpdateStatus = .unknown
    @Published var updateMethod: UpdateMethod = .unknown
    @Published var isUpdating: Bool = false
    @Published var updateError: String?
    
    var canAutoUpdate: Bool {
        updateMethod == .homebrew && updateStatus == .updateAvailable
    }
    
    var hasUpdate: Bool {
        updateStatus == .updateAvailable
    }
    
    var storeURL: URL? {
        guard let bundleId = bundleIdentifier else { return nil }
        return URL(string: "macappstore://apps.apple.com/app/id\(bundleId)")
    }
    
    init(name: String, bundleIdentifier: String?, currentVersion: String, path: String, icon: NSImage?, isAppleAppStoreApp: Bool = false, isSystemOSUpdate: Bool = false, isEdgeApp: Bool = false) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.currentVersion = currentVersion
        self.path = path
        self.icon = icon
        self.isAppleAppStoreApp = isAppleAppStoreApp
        self.isSystemOSUpdate = isSystemOSUpdate
        self.isEdgeApp = isEdgeApp
    }
}

enum BrewPackageKind: String {
    case homebrew = "Homebrew"
    case cask = "Cask"
}

/// An installed Homebrew package and its current upgrade state.
class BrewUpdateInfo: Identifiable, ObservableObject {
    let id: String
    let token: String
    let kind: BrewPackageKind
    let installedVersion: String
    let latestVersion: String
    let isPinned: Bool
    let hasUpdate: Bool
    let needsRepair: Bool

    @Published var isUpdating: Bool = false
    @Published var updateError: String?

    var canUpdate: Bool {
        !isPinned && (hasUpdate || needsRepair)
    }

    init(token: String, kind: BrewPackageKind, installedVersion: String, latestVersion: String, isPinned: Bool, hasUpdate: Bool, needsRepair: Bool) {
        self.id = "\(kind.rawValue):\(token)"
        self.token = token
        self.kind = kind
        self.installedVersion = installedVersion
        self.latestVersion = latestVersion
        self.isPinned = isPinned
        self.hasUpdate = hasUpdate
        self.needsRepair = needsRepair
    }
}

struct BrewAuthenticationRequest: Identifiable {
    let id = UUID()
    let caskTokens: [String]
    let errorMessage: String
    let requiresAzureLogin: Bool
    let requiresReinstall: Bool
    let packageKind: BrewPackageKind
}

/// Category of temporary file
enum TempFileCategory: String, CaseIterable {
    case cache = "Cache"
    case logs = "Logs"
    case crashReports = "Crash Reports"
    case tempFiles = "Temp Files"
}

/// Model for a temporary/cache file entry
class TempFileInfo: Identifiable, ObservableObject {
    let id = UUID()
    let fileName: String
    let appName: String
    let path: String
    let size: Int64
    let category: TempFileCategory
    let isCritical: Bool
    @Published var isDeleting: Bool = false
    
    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
    
    init(fileName: String, appName: String, path: String, size: Int64, category: TempFileCategory, isCritical: Bool = false) {
        self.fileName = fileName
        self.appName = appName
        self.path = path
        self.size = size
        self.category = category
        self.isCritical = isCritical
    }
}
