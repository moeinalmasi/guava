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

/// Why an app is shown as up to date although a newer version of it exists.
enum HeldBack: Equatable {
    /// Its App Store licence belongs to an organisation, which installs its updates itself.
    case organisation
    /// An update was handed to the app's own updater, which did not install it.
    case notInstalled
}

/// Model for an installed application
class AppInfo: Identifiable, ObservableObject {
    let id = UUID()
    let name: String
    let bundleIdentifier: String?
    @Published var currentVersion: String
    let path: String
    let icon: NSImage?
    /// True when the bundle carries a Mac App Store receipt, whoever published it.
    /// Such apps must only ever be updated through the App Store.
    let hasAppStoreReceipt: Bool
    /// True when that receipt is a licence held by an organisation for this Mac. The
    /// organisation's device management installs the updates of such a copy, and the App
    /// Store offers its user none.
    let isOrganisationLicensed: Bool
    
    @Published var latestVersion: String?
    @Published var updateStatus: UpdateStatus = .unknown
    @Published var updateMethod: UpdateMethod = .unknown
    @Published var updateError: String?
    /// Set when the app is shown as up to date although `latestVersion` is newer.
    @Published var heldBack: HeldBack?
    /// Homebrew cask describing this app, when the version check matched one.
    var caskToken: String?
    /// True when the last check could ask every source and none of them offers versions of
    /// this app, so that nothing can tell whether it is out of date, let alone update it.
    var hasNoUpdateSource = false
    
    var hasUpdate: Bool {
        updateStatus == .updateAvailable
    }

    /// True while a newer version is waiting, also after an attempt to install it has failed.
    var isOutdated: Bool {
        updateStatus == .updateAvailable || updateStatus == .error
    }
    
    init(
        name: String, bundleIdentifier: String?, currentVersion: String, path: String, icon: NSImage?,
        hasAppStoreReceipt: Bool = false, isOrganisationLicensed: Bool = false
    ) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.currentVersion = currentVersion
        self.path = path
        self.icon = icon
        self.hasAppStoreReceipt = hasAppStoreReceipt
        self.isOrganisationLicensed = isOrganisationLicensed
    }
}

enum BrewPackageKind: String {
    case homebrew = "Homebrew"
    case cask = "Cask"
    case formula = "Formula"
}

/// An installed Homebrew package and its current upgrade state.
final class BrewUpdateInfo: Identifiable {
    let id: String
    let token: String
    let kind: BrewPackageKind
    let installedVersion: String
    let latestVersion: String
    let isPinned: Bool
    let hasUpdate: Bool
    let needsRepair: Bool

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

/// What became of the formulae Homebrew had installed without linking them.
struct BrewLinkRepair: Equatable {
    /// Linked again.
    var relinked: [String] = []
    /// Left unlinked by the upgrade just made, and still unlinked: files that are not theirs
    /// to remove are in the way.
    var unlinked: [String] = []
}

/// What a single `brew upgrade` pass achieved.
struct BrewUpgradeResult: Equatable {
    var upgraded: [String] = []
    /// Packages that were outdated before the pass and still are.
    var remaining: [String] = []
    var errorOutput: String = ""
    /// True when Homebrew stopped because it could not ask for a password.
    var needsAuthentication: Bool = false
    /// False when the installed packages could not be listed afterwards, so that what the
    /// pass achieved is unknown. `remaining` then holds everything that was outdated before.
    var isVerified: Bool = true
    /// What `brew upgrade` said when it ended with an error. It can do so with every package
    /// at its latest version, for instance when one of them could not be linked.
    var failure: String? = nil
    var links = BrewLinkRepair()
}

/// A self-updating tool found on this Mac.
final class DevToolInfo: Identifiable {
    let tool: DevTool
    var id: String { tool.id }
    /// What the tool reported as installed when it was last looked at.
    let version: String?

    init(tool: DevTool, version: String? = nil) {
        self.tool = tool
        self.version = version
    }
}
