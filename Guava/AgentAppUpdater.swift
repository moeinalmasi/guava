import Foundation

/// How Guava may use the Copilot agent.
struct AgentSettings: Equatable, Sendable {
    var allowComputerUse = true
    var model: String?
    var maxAICredits: Int? = 60
    var timeout: TimeInterval = 20 * 60
}

/// What came of asking the agent to prepare one update.
enum AgentUpdateOutcome: Equatable, Sendable {
    /// A download passed every check and is ready for Guava to install.
    case staged(VerifiedPayload)
    /// The vendor's own updater or the App Store was set in motion.
    case updateTriggered(notes: String?)
    case upToDate(notes: String?)
    case failed(String)
}

struct AgentUpdateReport: Equatable, Sendable {
    let outcome: AgentUpdateOutcome
    /// The task's staging folder. Holds the payload when the outcome is `staged`.
    let workspace: URL
    let premiumRequests: Int?
}

/// Runs the update agent for one task and vets what it produced.
enum AgentAppUpdater {

    static func prepareUpdate(
        for task: AppUpdateTask,
        cli: CopilotCLI,
        runDirectory: URL,
        settings: AgentSettings,
        configuredMCPServers: [String],
        policy: VerificationPolicy = .strict,
        onEvent: (@Sendable (AgentEvent) -> Void)? = nil
    ) async -> AgentUpdateReport {
        let workspace: URL
        do {
            workspace = try AgentWorkspace.prepare(named: task.name, in: runDirectory)
        } catch {
            return AgentUpdateReport(
                outcome: .failed("Could not create a staging folder: \(error.localizedDescription)"),
                workspace: runDirectory,
                premiumRequests: nil
            )
        }

        let session = await CopilotAgent.run(
            cli: cli,
            configuration: AgentRunConfiguration(
                workingDirectory: workspace,
                prompt: AgentPrompt.appUpdate(task),
                sessionName: "Guava: update \(task.name)",
                allowComputerUse: settings.allowComputerUse && task.computerUseAllowed,
                model: settings.model,
                maxAICredits: settings.maxAICredits,
                timeout: settings.timeout,
                configuredMCPServers: configuredMCPServers
            ),
            onEvent: onEvent
        )

        let expected = ExpectedApp(
            name: task.name,
            bundleIdentifier: task.bundleIdentifier,
            teamIdentifier: task.expectedTeamIdentifier,
            installedVersion: task.installedVersion
        )
        let outcome = await evaluate(session: session, workspace: workspace, expected: expected, policy: policy)

        var payload: URL?
        if case .staged(let verified) = outcome { payload = verified.url }
        await AgentWorkspace.discardScratch(in: workspace, keeping: payload)

        return AgentUpdateReport(outcome: outcome, workspace: workspace, premiumRequests: session.premiumRequests)
    }

    /// Runs the agent on the Mac App Store's pending updates.
    static func updateAppStore(
        _ apps: [AppStoreUpdateTask],
        cli: CopilotCLI,
        runDirectory: URL,
        settings: AgentSettings,
        configuredMCPServers: [String],
        onEvent: (@Sendable (AgentEvent) -> Void)? = nil
    ) async -> AgentUpdateReport {
        let workspace: URL
        do {
            workspace = try AgentWorkspace.prepare(named: "mac-app-store", in: runDirectory)
        } catch {
            return AgentUpdateReport(
                outcome: .failed("Could not create a staging folder: \(error.localizedDescription)"),
                workspace: runDirectory,
                premiumRequests: nil
            )
        }

        let session = await CopilotAgent.run(
            cli: cli,
            configuration: AgentRunConfiguration(
                workingDirectory: workspace,
                prompt: AgentPrompt.appStoreUpdate(apps, computerUseAllowed: settings.allowComputerUse),
                sessionName: "Guava: Mac App Store updates",
                allowComputerUse: settings.allowComputerUse,
                model: settings.model,
                maxAICredits: settings.maxAICredits,
                timeout: settings.timeout,
                configuredMCPServers: configuredMCPServers
            ),
            onEvent: onEvent
        )

        var outcome = await evaluate(
            session: session,
            workspace: workspace,
            expected: ExpectedApp(name: "Mac App Store", bundleIdentifier: nil, teamIdentifier: nil, installedVersion: ""),
            policy: .strict
        )
        // The App Store installs its own updates; a staged payload here would be a mistake.
        if case .staged = outcome {
            outcome = .failed("The agent staged a download instead of using the App Store")
        }
        await AgentWorkspace.discardScratch(in: workspace, keeping: nil)

        return AgentUpdateReport(outcome: outcome, workspace: workspace, premiumRequests: session.premiumRequests)
    }

    /// Decide what an agent session achieved from its result file, never from what it said.
    static func evaluate(
        session: AgentRunOutcome,
        workspace: URL,
        expected: ExpectedApp,
        policy: VerificationPolicy
    ) async -> AgentUpdateOutcome {
        if session.wasCancelled { return .failed("Cancelled") }
        if session.timedOut { return .failed("The agent ran out of time") }
        if let failure = session.failure { return .failed(failure) }

        let result: AgentResult
        switch AgentResultReader.read(from: workspace) {
        case .success(let value):
            result = value
        case .failure(let error):
            let said = session.finalMessage.map { " Agent said: \(String($0.prefix(300)))" } ?? ""
            return .failed(error.message + "." + said)
        }

        switch result.status {
        case .failed:
            return .failed(result.notes ?? "The agent could not update this app")
        case .upToDate:
            return .upToDate(notes: result.notes)
        case .updateTriggered:
            return .updateTriggered(notes: result.notes)
        case .staged:
            guard let payload = result.payload, let kind = result.payloadKind else {
                return .failed(AgentResultError.payloadMissing.message)
            }
            let verification: Result<VerifiedPayload, VerificationFailure>
            switch kind {
            case .app:
                verification = await PayloadVerifier.verifyApp(at: payload, expected: expected, policy: policy)
            case .pkg:
                verification = await PayloadVerifier.verifyPackage(at: payload, expected: expected, policy: policy)
            }
            switch verification {
            case .success(let verified): return .staged(verified)
            case .failure(let failure): return .failed(failure.message)
            }
        }
    }
}

extension AgentWorkspace {

    /// Delete everything the agent left in its staging folder except the verified payload:
    /// downloaded disk images and archives, unpacked copies, and anything still mounted.
    static func discardScratch(in workspace: URL, keeping payload: URL?) async {
        await InstallCleanup.detachImages(under: workspace)

        let fileManager = FileManager.default
        let workspacePath = workspace.standardizedFileURL.resolvingSymlinksInPath().path
        var keptEntry: String?
        if let payload {
            let payloadPath = payload.standardizedFileURL.resolvingSymlinksInPath().path
            if payloadPath.hasPrefix(workspacePath + "/") {
                keptEntry = payloadPath.dropFirst(workspacePath.count + 1)
                    .split(separator: "/").first.map(String.init)
            }
        }

        for name in (try? fileManager.contentsOfDirectory(atPath: workspace.path)) ?? [] where name != keptEntry {
            let entry = workspace.appendingPathComponent(name)
            if (try? fileManager.removeItem(at: entry)) == nil {
                _ = await ProcessRunner.run("/bin/chmod", ["-R", "u+rwX", entry.path], timeout: 120)
                _ = await ProcessRunner.run("/bin/rm", ["-rf", entry.path], timeout: 300)
            }
        }

        // Inside the kept folder, drop everything that is not the payload itself.
        guard let payload, let keptEntry else { return }
        let keptFolder = workspace.appendingPathComponent(keptEntry)
        let payloadPath = payload.standardizedFileURL.resolvingSymlinksInPath().path
        guard keptFolder.standardizedFileURL.resolvingSymlinksInPath().path != payloadPath else { return }
        for name in (try? fileManager.contentsOfDirectory(atPath: keptFolder.path)) ?? [] {
            let entry = keptFolder.appendingPathComponent(name)
            let entryPath = entry.standardizedFileURL.resolvingSymlinksInPath().path
            if entryPath != payloadPath, !payloadPath.hasPrefix(entryPath + "/") {
                try? fileManager.removeItem(at: entry)
            }
        }
    }
}
