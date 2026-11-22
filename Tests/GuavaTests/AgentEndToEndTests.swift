import Foundation
import Testing
@testable import Guava

/// Runs the real GitHub Copilot agent against a throwaway application.
///
/// These spend AI credits and need a signed-in Copilot CLI, so they only run when asked:
///
///     GUAVA_E2E_AGENT=1 swift test --filter AgentEndToEndTests
///
/// Nothing outside the test's temporary folder is touched. The fixture is ad-hoc signed, so
/// the Gatekeeper requirement is relaxed here; every other check runs as it does in the app.
@Suite(
    "Agent end to end",
    .enabled(if: ProcessInfo.processInfo.environment["GUAVA_E2E_AGENT"] == "1"),
    .serialized
)
struct AgentEndToEndTests {

    private static let bundleIdentifier = "com.example.guava-fixture"
    private let policy = VerificationPolicy(requireGatekeeper: false, requireNewerVersion: true)
    private let settings = AgentSettings(allowComputerUse: false, model: nil, maxAICredits: 60, timeout: 10 * 60)

    /// An installed 1.0 and a "vendor download" of 2.0 packed as a zip archive.
    private struct Scenario {
        let scratch: TemporaryDirectory
        let installed: URL
        let archive: URL
        let checksum: String
        let stagingRoot: URL
        let runDirectory: URL
    }

    private func makeScenario() async throws -> Scenario {
        let scratch = try TemporaryDirectory("guava-e2e")
        let applications = try scratch.makeDirectory("Applications")
        let installed = try await Fixture.makeApp(
            at: applications.appendingPathComponent("Guava Fixture.app"),
            bundleIdentifier: Self.bundleIdentifier, version: "1.0", name: "GuavaFixture"
        )

        let release = try scratch.makeDirectory("release")
        let next = try await Fixture.makeApp(
            at: release.appendingPathComponent("Guava Fixture.app"),
            bundleIdentifier: Self.bundleIdentifier, version: "2.0", name: "GuavaFixture"
        )
        let archive = scratch.url.appendingPathComponent("GuavaFixture-2.0.zip")
        let packed = await ProcessRunner.run(
            "/usr/bin/ditto", ["-c", "-k", "--keepParent", next.path, archive.path], timeout: 120
        )
        try #require(packed.success, "Could not pack the fixture: \(packed.failureMessage)")
        // Leave only the archive, so the update can only come from "downloading" it.
        try FileManager.default.removeItem(at: release)

        let digest = await ProcessRunner.run("/usr/bin/shasum", ["-a", "256", archive.path], timeout: 60)
        let checksum = String(digest.stdout.prefix(64))
        try #require(checksum.count == 64)

        let stagingRoot = try scratch.makeDirectory("staging")
        return Scenario(
            scratch: scratch,
            installed: installed,
            archive: archive,
            checksum: checksum,
            stagingRoot: stagingRoot,
            runDirectory: try InstallCleanup.makeRunDirectory(in: stagingRoot)
        )
    }

    private func task(for scenario: Scenario, checksum: String) -> AppUpdateTask {
        AppUpdateTask(
            name: "Guava Fixture",
            bundleIdentifier: Self.bundleIdentifier,
            installedPath: scenario.installed.path,
            installedVersion: "1.0",
            latestKnownVersion: "2.0",
            expectedTeamIdentifier: nil,
            download: CaskDownload(
                token: "guava-fixture", version: "2.0",
                url: scenario.archive.absoluteString, sha256: checksum, homepage: nil
            ),
            sparkleFeedURL: nil,
            ownedByRoot: false,
            isRunning: false,
            computerUseAllowed: false
        )
    }

    private func describe(_ events: [AgentEvent]) -> String {
        events.map { event -> String in
            switch event {
            case .toolStarted(let tool, let summary): return "  \(tool): \(summary)"
            case .toolFinished(let success): return success ? "" : "  (tool call failed)"
            case .message(let text): return "  agent: \(text.prefix(300))"
            case .notice(let text): return "  notice: \(text)"
            case .finished(let exitCode, let requests): return "  finished: exit \(exitCode), \(requests ?? 0) premium request(s)"
            }
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }

    @Test("the agent stages an update that Guava then verifies, installs and cleans up")
    func updatesFixtureApplication() async throws {
        let cli = try #require(CopilotCLI.locate(), "The GitHub Copilot CLI is not installed")
        let scenario = try await makeScenario()
        let events = Collector<AgentEvent>()

        let report = await AgentAppUpdater.prepareUpdate(
            for: task(for: scenario, checksum: scenario.checksum),
            cli: cli,
            runDirectory: scenario.runDirectory,
            settings: settings,
            configuredMCPServers: await cli.configuredMCPServers(),
            policy: policy
        ) { events.append($0) }
        print("Agent transcript:\n\(describe(events.values))")

        guard case .staged(let payload) = report.outcome else {
            Issue.record("The agent did not stage a verified payload: \(report.outcome)")
            return
        }
        #expect(payload.kind == .app)
        #expect(payload.version == "2.0")
        #expect(InstallCleanup.isInside(payload.url, report.workspace))

        // Guava discards the agent's downloads as soon as the payload is verified.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: report.workspace.path)
        #expect(leftovers == [payload.url.deletingLastPathComponent().lastPathComponent])

        let outcomes = await AppInstaller.run(
            [.replaceApp(
                staged: payload.url.path, destination: scenario.installed.path, owner: nil,
                teamIdentifier: nil, requireGatekeeper: false,
                identity: BundleIdentity(bundleIdentifier: payload.bundleIdentifier, version: payload.version)
            )],
            asAdministrator: false
        )
        #expect(outcomes == [.installed(note: nil)])
        #expect(Fixture.version(ofAppAt: scenario.installed) == "2.0")

        let cleanup = await InstallCleanup.removeDirectory(scenario.runDirectory, within: scenario.stagingRoot)
        #expect(cleanup.problems.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: scenario.runDirectory.path))
        #expect(InstallCleanup.images(await InstallCleanup.mountedImages(), under: scenario.scratch.url).isEmpty)
        // The agent must not have touched the installed copy itself.
        #expect(try FileManager.default.contentsOfDirectory(
            atPath: scenario.installed.deletingLastPathComponent().path
        ) == ["Guava Fixture.app"])
    }

    @Test("a download that does not match its checksum is never staged or installed")
    func refusesChecksumMismatch() async throws {
        let cli = try #require(CopilotCLI.locate(), "The GitHub Copilot CLI is not installed")
        let scenario = try await makeScenario()
        let events = Collector<AgentEvent>()

        let report = await AgentAppUpdater.prepareUpdate(
            for: task(for: scenario, checksum: String(repeating: "0", count: 64)),
            cli: cli,
            runDirectory: scenario.runDirectory,
            settings: settings,
            configuredMCPServers: await cli.configuredMCPServers(),
            policy: policy
        ) { events.append($0) }
        print("Agent transcript:\n\(describe(events.values))")

        guard case .failed(let reason) = report.outcome else {
            Issue.record("A mismatched download was not refused: \(report.outcome)")
            return
        }
        print("Refused with: \(reason)")
        #expect(Fixture.version(ofAppAt: scenario.installed) == "1.0")
        // Nothing the agent downloaded survives a refusal.
        #expect(try FileManager.default.contentsOfDirectory(atPath: report.workspace.path).isEmpty)

        _ = await InstallCleanup.removeDirectory(scenario.runDirectory, within: scenario.stagingRoot)
    }

    /// Stages a real pending update for an installed application and runs the full production
    /// checks on it (signature, developer team, notarization), then stops. Nothing is installed.
    ///
    ///     GUAVA_E2E_AGENT=1 GUAVA_E2E_REAL_APP="/Applications/Example.app" \
    ///         swift test --filter AgentEndToEndTests/stagesRealUpdateWithoutInstalling
    @Test(
        "a real pending update is staged and passes the strict checks, without being installed",
        .enabled(if: ProcessInfo.processInfo.environment["GUAVA_E2E_REAL_APP"] != nil)
    )
    @MainActor
    func stagesRealUpdateWithoutInstalling() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["GUAVA_E2E_REAL_APP"])
        let cli = try #require(CopilotCLI.locate(), "The GitHub Copilot CLI is not installed")
        let app = try #require(
            AppScanner.scanApplications().first { $0.path == path },
            "No application was found at \(path)"
        )
        await VersionChecker.loadCaskCatalog()
        await VersionChecker.checkForUpdate(app)
        try #require(app.hasUpdate, "\(app.name) \(app.currentVersion) has no pending update to stage")
        let versionBefore = app.currentVersion

        let scratch = try TemporaryDirectory("guava-e2e")
        let stagingRoot = try scratch.makeDirectory("staging")
        let runDirectory = try InstallCleanup.makeRunDirectory(in: stagingRoot)
        var settings = UpdateSettings()
        settings.allowComputerUse = false
        let environment = LiveUpdateEnvironment(settings: settings)
        let context = await environment.agentTask(for: app)
        print("Staging \(app.name) \(versionBefore) → \(app.latestVersion ?? "?"); "
            + "team \(context.teamIdentifier ?? "none"); download \(context.task.download?.url ?? "to be found by the agent")")

        let events = Collector<AgentEvent>()
        let report = await environment.prepareUpdate(
            for: context.task,
            cli: cli,
            runDirectory: runDirectory,
            mcpServers: await cli.configuredMCPServers()
        ) { events.append($0) }
        print("Agent transcript:\n\(describe(events.values))")

        guard case .staged(let payload) = report.outcome else {
            Issue.record("The update was not staged: \(report.outcome)")
            _ = await InstallCleanup.removeDirectory(runDirectory, within: stagingRoot)
            return
        }
        print("Verified payload: \(payload.url.lastPathComponent) \(payload.version ?? "") team \(payload.teamIdentifier ?? "none")")
        #expect(payload.teamIdentifier == context.teamIdentifier)
        #expect(InstallCleanup.isInside(payload.url, runDirectory))

        let cleanup = await InstallCleanup.removeDirectory(runDirectory, within: stagingRoot)
        #expect(cleanup.problems.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: runDirectory.path))
        #expect(InstallCleanup.images(await InstallCleanup.mountedImages(), under: scratch.url).isEmpty)
        // The installed copy is exactly as it was.
        #expect(AppScanner.readCurrentVersion(for: path) == versionBefore)
    }
}
