import Foundation

/// A request to run Guava without its window.
enum HeadlessCommand: Equatable {
    case help
    /// Print what was found and what could be updated.
    case scan
    /// Run Update Everything, or only show its plan.
    case updateAll(dryRun: Bool)

    static let usage = """
    Usage: Guava [option]

      (no option)            Open the Guava window.
      --scan                 List applications, Homebrew packages and tools, and what is outdated.
      --update-all           Update everything, then delete the downloaded packages.
      --update-all --dry-run Show what --update-all would do without changing anything.
      --help                 Show this text.

    --update-all exits with status 0 when nothing failed and nothing needs your attention.
    """

    /// Nil when the arguments do not ask for a headless run, so the window opens as usual.
    /// Unknown arguments are ignored because macOS passes its own to launched apps.
    init?(arguments: [String]) {
        if arguments.contains("--help") || arguments.contains("-h") {
            self = .help
        } else if arguments.contains("--update-all") {
            self = .updateAll(dryRun: arguments.contains("--dry-run"))
        } else if arguments.contains("--scan") {
            self = .scan
        } else {
            return nil
        }
    }
}

/// Runs Guava's scan and update pipeline from a terminal.
enum HeadlessRunner {

    static func run(_ command: HeadlessCommand) -> Never {
        // Show progress as it happens even when the output is piped.
        setvbuf(stdout, nil, _IOLBF, 0)
        Task { @MainActor in
            exit(await execute(command))
        }
        // The main run loop rather than dispatchMain(): AppKit keeps its picture of which
        // applications are running up to date only while that loop turns.
        while true {
            RunLoop.main.run()
        }
    }

    @MainActor
    private static func execute(_ command: HeadlessCommand) async -> Int32 {
        switch command {
        case .help:
            print(HeadlessCommand.usage)
            return 0

        case .scan:
            // A report leaves nothing behind, the record of this Mac included.
            let model = GuavaViewModel(store: LocalStore.home.readOnly)
            print("Scanning…")
            await model.performCheckForUpdates(persistTimestamp: false)
            let managed = await MicrosoftAutoUpdate.managedApplicationPaths()
            let settings = UpdateSettings.load()
            let context = AppRoutingContext(
                agentEnabled: settings.agentEnabled,
                agentAvailable: CopilotCLI.locate() != nil,
                microsoftManagedPaths: managed
            )
            print(scanReport(model, context: context))
            return 0

        case .updateAll(let dryRun):
            let model = GuavaViewModel(store: dryRun ? LocalStore.home.readOnly : .home)
            model.updater.onLog = { print(format($0)) }
            let summary = await model.updater.run(dryRun: dryRun)
            if !model.updater.items.isEmpty {
                print("\nResults")
                for item in model.updater.items {
                    print("  \(marker(for: item.state)) \(item.name): \(item.state.detail)")
                }
            }
            return summary.isClean ? 0 : 1
        }
    }

    @MainActor
    static func scanReport(_ model: GuavaViewModel, context: AppRoutingContext) -> String {
        var lines: [String] = []

        let listed = model.listedApps
        let outdatedApps = listed.filter(\.hasUpdate)
        lines.append("Applications: \(listed.count) listed, \(outdatedApps.count) outdated")
        for app in outdatedApps {
            let route = UpdatePlanner.route(for: app, context: context)
            lines.append("  \(app.name) \(app.currentVersion) → \(app.latestVersion ?? "?")  [\(route.label)]")
        }
        for app in listed where app.heldBack != nil {
            let reason = app.heldBack == .organisation
                ? "licensed to your organisation, which installs its updates"
                : "its own updater has not installed it"
            lines.append("  \(app.name) \(app.currentVersion) stays as it is: \(app.latestVersion ?? "a newer version") exists, \(reason)")
        }
        // Named here rather than by pointing at the record, which a report does not write.
        let unlisted = model.record.hidden.map(\.name)
        if !unlisted.isEmpty {
            lines.append("  Not listed, as nothing can update them: \(unlisted.joined(separator: ", "))")
        }

        let outdatedPackages = model.brewUpdates.filter(\.canUpdate)
        lines.append("")
        lines.append("Homebrew: \(model.brewUpdates.count) listed, \(outdatedPackages.count) outdated")
        for package in outdatedPackages {
            lines.append("  \(package.token) \(package.installedVersion) → \(package.latestVersion)  [\(package.kind.rawValue)]")
        }

        lines.append("")
        lines.append("Tools: \(model.devTools.count) can update themselves (\(model.dotEntryCount) dot entries scanned in the home folder)")
        for info in model.devTools {
            lines.append("  \(info.tool.name) \(info.version ?? "?")  [\(info.tool.updateCommand.displayString)]")
        }

        return lines.joined(separator: "\n")
    }

    static func format(_ entry: UpdateLogEntry) -> String {
        switch entry.level {
        case .phase: return "\n==> \(entry.text)"
        case .info: return "  \(entry.text)"
        case .detail: return "  \(entry.text)"
        case .success: return "  ✓ \(entry.text)"
        case .warning: return "  ! \(entry.text)"
        case .error: return "  ✗ \(entry.text)"
        }
    }

    static func marker(for state: UpdateItemState) -> String {
        switch state {
        case .updated: return "✓"
        case .started: return "↻"
        case .unchanged: return "="
        case .needsAttention: return "!"
        case .failed: return "✗"
        case .skipped, .pending, .running: return "-"
        }
    }
}
