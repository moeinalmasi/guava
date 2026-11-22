import AppKit
import SwiftUI
import Testing
@testable import Guava

/// Renders the real SwiftUI views offscreen to PNG files, so the layout can be looked at
/// without opening a window or capturing the screen:
///
///     GUAVA_UI_SNAPSHOTS=/tmp/guava-snapshots swift test --filter UISnapshotTests
///
/// The main-window snapshot scans this Mac (read-only) and so shows its real applications.
@Suite(
    "UI snapshots",
    .enabled(if: ProcessInfo.processInfo.environment["GUAVA_UI_SNAPSHOTS"] != nil),
    .serialized
)
@MainActor
struct UISnapshotTests {

    private var directory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["GUAVA_UI_SNAPSHOTS"] ?? NSTemporaryDirectory())
    }

    /// Lays `view` out in a window that is never shown and writes what it draws to a PNG.
    @discardableResult
    private func render<Content: View>(
        _ view: Content,
        width: CGFloat,
        height: CGFloat,
        name: String,
        until isReady: () -> Bool = { true }
    ) async throws -> URL {
        _ = NSApplication.shared
        let frame = NSRect(x: 0, y: 0, width: width, height: height)
        // A real window paints its background behind the content; an offscreen bitmap does not.
        let hosting = NSHostingView(rootView: view
            .frame(width: width, height: height)
            .background(Color(nsColor: .windowBackgroundColor)))
        hosting.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()

        // Give SwiftUI time to settle, and any work the view starts time to finish.
        var waited = 0.0
        repeat {
            try await Task.sleep(nanoseconds: 300_000_000)
            waited += 0.3
        } while !isReady() && waited < 90
        try await Task.sleep(nanoseconds: 400_000_000)
        hosting.layoutSubtreeIfNeeded()

        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(name).png")
        try data.write(to: file)
        window.contentView = nil
        return file
    }

    private func app(_ name: String, receipt: Bool = false, method: UpdateMethod = .manual) -> AppInfo {
        let app = AppInfo(
            name: name, bundleIdentifier: "com.example.\(name.lowercased())", currentVersion: "1.0",
            path: "/Applications/\(name).app", icon: nil, hasAppStoreReceipt: receipt
        )
        app.latestVersion = "2.0"
        app.updateMethod = method
        app.updateStatus = .updateAvailable
        return app
    }

    private func tool(_ id: String, _ name: String) -> DevToolInfo {
        DevToolInfo(tool: DevTool(
            id: id, name: name, dotEntries: [],
            versionProbe: .none, updateCommand: ToolCommand(executable: "/usr/bin/true", arguments: [])
        ))
    }

    @Test("main window: the applications on this Mac")
    func mainWindow() async throws {
        let model = GuavaViewModel()
        let ready = { !model.isScanning && !model.isCheckingAll && !model.apps.isEmpty }

        try await render(ContentView(viewModel: model), width: 620, height: 720, name: "main", until: ready)
        // In a wide window the list stays a narrow column in the middle.
        try await render(ContentView(viewModel: model), width: 1280, height: 720, name: "main-wide", until: ready)

        #expect(!model.apps.isEmpty)
        #expect(model.apps.allSatisfy { !$0.path.hasPrefix("/System/") })
    }

    @Test("main window: every state a row can be in, at the narrowest width the window allows")
    func rowStates() async throws {
        func row(_ name: String, _ version: String, _ status: UpdateStatus, latest: String? = nil) -> AppInfo {
            let app = AppInfo(
                name: name, bundleIdentifier: nil, currentVersion: version,
                path: "/Applications/\(name).app", icon: NSWorkspace.shared.icon(forFile: "/System/Applications/Calculator.app")
            )
            app.latestVersion = latest
            app.updateStatus = status
            return app
        }
        let failed = row("Notes", "11.2.0", .error)
        failed.updateError = "Signed by a different developer"
        let rows = [
            row("Browser", "120.0.6099.71", .updateAvailable, latest: "120.0.6099.109"),
            row("An Application With a Name Far Too Long to Fit", "2026.11.21.1048", .updateAvailable, latest: "2026.11.28.2210"),
            row("PDF Tools", "6.0.10", .updating, latest: "6.0.11"),
            row("Tiler", "0.98", .checking),
            failed,
            row("Editor", "151.0.1", .upToDate, latest: "151.0.1"),
            row("Homemade Tool", "3.1", .unknown),
        ]

        try await render(
            VStack(spacing: 0) {
                ForEach(rows) { app in
                    AppRow(app: app)
                    Divider()
                }
                Spacer(minLength: 0)
            },
            width: 520, height: 320, name: "main-rows"
        )
    }

    @Test("main window: the first scan, and a check under way")
    func checking() async throws {
        let scanning = GuavaViewModel()
        scanning.isScanning = true
        scanning.isCheckingAll = true
        scanning.statusMessage = "Looking at your applications…"
        try await render(ContentView(viewModel: scanning), width: 520, height: 420, name: "main-scanning")

        let checking = GuavaViewModel()
        checking.apps = [app("Tiler"), app("Browser"), app("Notes"), app("Editor")]
        checking.apps[1].updateStatus = .upToDate
        checking.apps[2].updateStatus = .checking
        checking.apps[3].updateStatus = .unknown
        checking.isCheckingAll = true
        checking.progress = 0.5
        checking.statusMessage = "Checking for updates…"
        try await render(ContentView(viewModel: checking), width: 520, height: 420, name: "main-checking")

        // A check that is already under way is not started a second time by the window.
        #expect(checking.apps.count == 4)
    }

    @Test("progress sheet: a finished run with every kind of result")
    func finishedRun() async throws {
        let environment = FakeEnvironment()
        environment.brewPackages = (1...41).map {
            BrewUpdateInfo(
                token: "pkg\($0)", kind: .formula, installedVersion: "1", latestVersion: "2",
                isPinned: false, hasUpdate: true, needsRepair: false
            )
        }
        environment.tools = [tool("omz", "Oh My Zsh"), tool("bun", "Bun"), tool("uv", "uv tools")]
        environment.toolOutcomes = [
            "omz": .updated(from: "6010fb6", to: "a91c2de"),
            "uv": .failed("error: Failed to upgrade 1 tool"),
        ]
        environment.apps = [
            app("Tiler"), app("Browser"), app("Notes"), app("Storyboard", receipt: true),
            app("Containers", method: .homebrew), app("Mystery"),
        ]
        environment.rootOwned = ["/Applications/Browser.app"]
        environment.running = ["/Applications/Notes.app"]
        environment.quitResults = ["/Applications/Notes.app": .refused]
        environment.agentOutcomes = [
            "Tiler": .staged(VerifiedPayload(
                url: URL(fileURLWithPath: "/stage/run-1/tiler/payload/Tiler.app"),
                kind: .app, version: "2.0", teamIdentifier: "A1B2C3D4E5"
            )),
            "Browser": .staged(VerifiedPayload(
                url: URL(fileURLWithPath: "/stage/run-1/browser/payload/Browser.app"),
                kind: .app, version: "2.0", teamIdentifier: "F6G7H8J9K0"
            )),
            "Notes": .staged(VerifiedPayload(
                url: URL(fileURLWithPath: "/stage/run-1/notes/payload/Notes.app"),
                kind: .app, version: "2.0", teamIdentifier: "L1M2N3P4Q5"
            )),
            "Mystery": .failed("Signed by a different developer: expected team ABCDE12345, found ZYXWV98765"),
        ]
        environment.cleanupReport = CleanupReport(bytesFreed: 984_822_579, removed: ["/stage/run-1"])

        let model = GuavaViewModel()
        let orchestrator = UpdateOrchestrator(model: model) { environment }
        let summary = await orchestrator.run()

        try await render(
            UpdateEverythingView(updater: orchestrator, isPresented: .constant(true)),
            width: 700, height: 600, name: "sheet-finished"
        )
        // The smallest the sheet can be made.
        try await render(
            UpdateEverythingView(updater: orchestrator, isPresented: .constant(true)),
            width: 560, height: 480, name: "sheet-finished-narrow"
        )
        #expect(summary.updated >= 3)
    }

    @Test("progress sheet: a run in progress, waiting on a tool that says nothing")
    func runInProgress() async throws {
        let environment = FakeEnvironment()
        environment.brewPackages = (1...3).map {
            BrewUpdateInfo(
                token: "pkg\($0)", kind: .formula, installedVersion: "1", latestVersion: "2",
                isPinned: false, hasUpdate: true, needsRepair: false
            )
        }
        environment.tools = [tool("omz", "Oh My Zsh"), tool("uv", "uv tools"), tool("slow", "Slow updater")]
        environment.toolOutcomes = [
            "omz": .updated(from: "6010fb6", to: "a91c2de"),
            "uv": .failed(
                "error: Failed to upgrade example-tool\n  Caused by: No solution found when resolving dependencies:\n"
                    + "  Because example-tool was not found in the package registry, the requirements are unsatisfiable."
            ),
        ]
        environment.apps = [app("Tiler")]

        let model = GuavaViewModel()
        let orchestrator = UpdateOrchestrator(model: model) { environment }
        var snapshot: URL?
        environment.whileUpdatingTool = { info in
            guard info.id == "slow" else { return }
            // As if the tool had been silent for a while.
            orchestrator.noteIfQuiet(now: Date().addingTimeInterval(130))
            snapshot = try? await render(
                UpdateEverythingView(updater: orchestrator, isPresented: .constant(true)),
                width: 700, height: 600, name: "sheet-running"
            )
        }
        await orchestrator.run()

        #expect(snapshot != nil)
    }

    @Test("settings")
    func settings() async throws {
        try await render(UpdateSettingsView(), width: 520, height: 620, name: "settings")
    }
}
