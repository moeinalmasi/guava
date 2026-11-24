import Foundation

/// User preferences for Update Everything.
struct UpdateSettings: Equatable, Sendable {
    /// Use the GitHub Copilot agent for apps that Homebrew and vendor updaters cannot handle.
    var agentEnabled = true
    /// Let the agent drive the screen (CUA) for updaters that only have a window.
    var allowComputerUse = true
    /// Ask running apps to quit so they can be replaced, then reopen them.
    var quitRunningApps = true
    /// Move installers that appear in Downloads during a run to the Trash.
    var sweepDownloads = true
    /// Empty Homebrew's download cache after upgrading.
    var cleanBrewCache = true
    /// Model for the agent; empty uses the Copilot CLI's default.
    var agentModel = ""
    var agentMaxCredits = 60
    var agentTimeoutMinutes = 20

    enum Key {
        static let agentEnabled = "updateAll.agentEnabled"
        static let allowComputerUse = "updateAll.allowComputerUse"
        static let quitRunningApps = "updateAll.quitRunningApps"
        static let sweepDownloads = "updateAll.sweepDownloads"
        static let cleanBrewCache = "updateAll.cleanBrewCache"
        static let agentModel = "updateAll.agentModel"
        static let agentMaxCredits = "updateAll.agentMaxCredits"
        static let agentTimeoutMinutes = "updateAll.agentTimeoutMinutes"
    }

    static func load(from defaults: UserDefaults = .standard) -> UpdateSettings {
        load { defaults.object(forKey: $0) }
    }

    /// Build settings from stored values. Anything missing, or of the wrong type, keeps its default.
    static func load(lookup: (String) -> Any?) -> UpdateSettings {
        var settings = UpdateSettings()
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            lookup(key) as? Bool ?? fallback
        }
        func integer(_ key: String, _ fallback: Int) -> Int {
            lookup(key) as? Int ?? fallback
        }
        settings.agentEnabled = bool(Key.agentEnabled, settings.agentEnabled)
        settings.allowComputerUse = bool(Key.allowComputerUse, settings.allowComputerUse)
        settings.quitRunningApps = bool(Key.quitRunningApps, settings.quitRunningApps)
        settings.sweepDownloads = bool(Key.sweepDownloads, settings.sweepDownloads)
        settings.cleanBrewCache = bool(Key.cleanBrewCache, settings.cleanBrewCache)
        settings.agentModel = lookup(Key.agentModel) as? String ?? settings.agentModel
        settings.agentMaxCredits = min(max(integer(Key.agentMaxCredits, settings.agentMaxCredits), 30), 1000)
        settings.agentTimeoutMinutes = min(max(integer(Key.agentTimeoutMinutes, settings.agentTimeoutMinutes), 5), 120)
        return settings
    }

    var agent: AgentSettings {
        let model = agentModel.trimmingCharacters(in: .whitespaces)
        return AgentSettings(
            allowComputerUse: allowComputerUse,
            model: model.isEmpty ? nil : model,
            maxAICredits: agentMaxCredits,
            timeout: TimeInterval(agentTimeoutMinutes * 60)
        )
    }
}

/// How one application will be updated.
enum AppUpdateRoute: Equatable, Sendable {
    /// `brew upgrade --cask`: the app was installed through Homebrew.
    case homebrew
    /// The Mac App Store owns this app.
    case appStore
    /// Microsoft AutoUpdate keeps this app current.
    case microsoftAutoUpdate
    /// The Copilot agent stages a download that Guava verifies and installs.
    case agent
    /// Left for the user to decide: the reason is a setting, or something not installed.
    case skipped(reason: String)
    /// What would update it is broken, so the update cannot be made.
    case unavailable(reason: String)

    var label: String {
        switch self {
        case .homebrew: return "Homebrew"
        case .appStore: return "Mac App Store"
        case .microsoftAutoUpdate: return "Microsoft AutoUpdate"
        case .agent: return "Copilot agent"
        case .skipped(let reason): return "Skipped: \(reason)"
        case .unavailable(let reason): return "Not possible: \(reason)"
        }
    }
}

struct AppRoutingContext: Equatable, Sendable {
    var agentEnabled: Bool
    var agentAvailable: Bool
    /// What the Copilot CLI said when it was installed but would not start. Nil when it starts.
    var agentProblem: String? = nil
    /// Paths of the applications registered with Microsoft AutoUpdate.
    var microsoftManagedPaths: Set<String>
}

/// Decides which updater is responsible for each application.
enum UpdatePlanner {

    /// The order matters: an app's own distribution channel always wins over a direct download,
    /// so an App Store copy is never replaced with the vendor's build of the same app.
    static func route(
        path: String,
        hasAppStoreReceipt: Bool,
        updateMethod: UpdateMethod,
        context: AppRoutingContext
    ) -> AppUpdateRoute {
        if hasAppStoreReceipt { return .appStore }
        if updateMethod == .homebrew { return .homebrew }
        if context.microsoftManagedPaths.contains(path) { return .microsoftAutoUpdate }
        guard context.agentEnabled else {
            return .skipped(reason: "the Copilot agent is turned off in Settings")
        }
        if let problem = context.agentProblem {
            return .unavailable(reason: "the GitHub Copilot CLI does not start (\(problem))")
        }
        guard context.agentAvailable else {
            return .skipped(reason: "the GitHub Copilot CLI is not installed")
        }
        return .agent
    }

    static func route(for app: AppInfo, context: AppRoutingContext) -> AppUpdateRoute {
        route(
            path: app.path,
            hasAppStoreReceipt: app.hasAppStoreReceipt,
            updateMethod: app.updateMethod,
            context: context
        )
    }
}

/// What Update Everything is about to do.
struct UpdatePlan: Equatable, Sendable {
    struct PlannedApp: Equatable, Sendable {
        let name: String
        let installedVersion: String
        let latestVersion: String?
        let route: AppUpdateRoute
    }

    var brewPackages: [String] = []
    var tools: [String] = []
    var apps: [PlannedApp] = []

    var isEmpty: Bool {
        brewPackages.isEmpty && tools.isEmpty && apps.isEmpty
    }

    /// One line per planned action, for logs and dry runs.
    var lines: [String] {
        var lines: [String] = []
        if brewPackages.isEmpty {
            lines.append("Homebrew: nothing outdated")
        } else {
            lines.append("Homebrew: upgrade \(brewPackages.count) package(s): \(Self.abbreviated(brewPackages))")
        }
        if !tools.isEmpty {
            lines.append("Tools: run \(tools.count) updater(s): \(Self.abbreviated(tools))")
        }
        if apps.isEmpty {
            lines.append("Applications: nothing outdated")
        }
        for app in apps {
            let target = app.latestVersion.map { " → \($0)" } ?? ""
            lines.append("App: \(app.name) \(app.installedVersion)\(target) via \(app.route.label)")
        }
        return lines
    }

    private static func abbreviated(_ names: [String], limit: Int = 12) -> String {
        let shown = names.prefix(limit).joined(separator: ", ")
        return names.count > limit ? "\(shown), and \(names.count - limit) more" : shown
    }
}

/// The state of one thing being updated.
enum UpdateItemState: Equatable, Sendable {
    case pending
    case running
    /// Confirmed: the installed version changed.
    case updated(String)
    /// Another updater (the App Store, a vendor's own) was started and finishes on its own.
    case started(String)
    case unchanged(String)
    /// Nothing went wrong, but the user has to do something.
    case needsAttention(String)
    case failed(String)
    case skipped(String)

    var detail: String {
        switch self {
        case .pending: return "Waiting"
        case .running: return "Working…"
        case .updated(let text), .started(let text), .unchanged(let text),
             .needsAttention(let text), .failed(let text), .skipped(let text):
            return text
        }
    }

    var isFinished: Bool {
        switch self {
        case .pending, .running: return false
        default: return true
        }
    }
}

struct UpdateItem: Identifiable, Equatable, Sendable {
    enum Category: String, Sendable {
        case homebrew = "Homebrew"
        case tool = "Tool"
        case app = "App"
        case cleanup = "Cleanup"
    }

    let id: String
    let category: Category
    let name: String
    var state: UpdateItemState
    /// When the item began running. Nil unless it is running now.
    var startedAt: Date? = nil
}

struct UpdateLogEntry: Identifiable, Equatable, Sendable {
    enum Level: Sendable {
        case phase
        case info
        case detail
        case success
        case warning
        case error
    }

    let id: Int
    let date: Date
    let level: Level
    let text: String
}

/// The outcome of a whole run.
struct UpdateSummary: Equatable, Sendable {
    var updated = 0
    var started = 0
    var unchanged = 0
    var needsAttention = 0
    var failed = 0
    var skipped = 0
    var bytesFreed: Int64 = 0
    var premiumRequests = 0
    var duration: TimeInterval = 0
    var wasCancelled = false
    var wasDryRun = false

    init() {}

    init(items: [UpdateItem]) {
        for item in items {
            switch item.state {
            case .updated: updated += 1
            case .started: started += 1
            case .unchanged: unchanged += 1
            case .needsAttention: needsAttention += 1
            case .failed: failed += 1
            case .skipped: skipped += 1
            case .pending, .running: break
            }
        }
    }

    /// True when nothing failed and nothing is left for the user to do.
    var isClean: Bool {
        failed == 0 && needsAttention == 0 && !wasCancelled
    }

    var headline: String {
        if wasDryRun { return "Dry run: nothing was changed" }
        var parts: [String] = []
        if updated > 0 { parts.append("\(updated) updated") }
        if started > 0 { parts.append("\(started) in progress") }
        if needsAttention > 0 {
            parts.append(needsAttention == 1 ? "1 needs attention" : "\(needsAttention) need attention")
        }
        if failed > 0 { parts.append("\(failed) failed") }
        if skipped > 0 { parts.append("\(skipped) skipped") }
        let body = parts.isEmpty ? "Everything is already up to date" : parts.joined(separator: ", ")
        return wasCancelled ? "Stopped: \(body)" : body
    }
}
