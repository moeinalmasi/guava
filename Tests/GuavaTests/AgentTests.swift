import Foundation
import Testing
@testable import Guava

@Suite("Copilot agent invocation")
struct CopilotAgentArgumentTests {

    private func configuration(
        allowComputerUse: Bool = true,
        model: String? = nil,
        maxAICredits: Int? = 60,
        servers: [String] = ["issues", "Team-Chat-Server", "computer-use", "browser-use", "github-mcp-server"]
    ) -> AgentRunConfiguration {
        AgentRunConfiguration(
            workingDirectory: URL(fileURLWithPath: "/stage/run/app"),
            prompt: "Update one app",
            sessionName: "Guava: update App",
            allowComputerUse: allowComputerUse,
            model: model,
            maxAICredits: maxAICredits,
            timeout: 600,
            configuredMCPServers: servers
        )
    }

    /// The values that follow a variadic option, up to the next option.
    private func values(after option: String, in arguments: [String]) -> [String] {
        guard let start = arguments.firstIndex(of: option) else { return [] }
        return Array(arguments[(start + 1)...].prefix { !$0.hasPrefix("--") })
    }

    @Test("confines the session to the staging folder and the Guava agent")
    func confinesSession() {
        let arguments = CopilotAgent.arguments(for: configuration())

        #expect(Array(arguments.prefix(7)) == [
            "-C", "/stage/run/app", "--trust-folder", "--agent", "guava-updater", "-p", "Update one app",
        ])
        #expect(arguments.contains("--no-custom-instructions"))
        #expect(arguments.contains("--no-ask-user"))
        #expect(arguments.contains("--sync-session=off"))
        #expect(Array(arguments.suffix(4)) == ["--output-format", "json", "-n", "Guava: update App"])
    }

    @Test("grants no path beyond the staging folder except read-only system tool folders")
    func confinesPaths() {
        for allowComputerUse in [true, false] {
            let arguments = CopilotAgent.arguments(for: configuration(allowComputerUse: allowComputerUse))
            let added = arguments.indices
                .filter { arguments[$0] == "--add-dir" }
                .map { arguments[$0 + 1] }

            #expect(!arguments.contains("--allow-all-paths"))
            #expect(!arguments.contains("--allow-all"))
            #expect(!arguments.contains("--yolo"))
            #expect(added == ["/usr/bin", "/usr/sbin", "/usr/libexec", "/bin", "/sbin"])
            for directory in added {
                #expect(!FileManager.default.isWritableFile(atPath: directory), "\(directory) must be read-only")
            }
        }
    }

    @Test("exposes only the tools an updater needs")
    func restrictsTools() {
        let withComputerUse = values(after: "--available-tools", in: CopilotAgent.arguments(for: configuration()))
        let without = values(
            after: "--available-tools",
            in: CopilotAgent.arguments(for: configuration(allowComputerUse: false))
        )

        #expect(withComputerUse == CopilotAgent.baseTools + CopilotAgent.computerUseTools)
        #expect(without == CopilotAgent.baseTools)
        #expect(!without.contains { $0.hasPrefix("computer-use") })
    }

    @Test("switches off every MCP server except web search and, when allowed, computer use")
    func disablesOtherServers() {
        func disabled(_ arguments: [String]) -> [String] {
            arguments.indices
                .filter { arguments[$0] == "--disable-mcp-server" }
                .map { arguments[$0 + 1] }
        }

        #expect(disabled(CopilotAgent.arguments(for: configuration()))
            == ["issues", "Team-Chat-Server", "browser-use"])
        #expect(disabled(CopilotAgent.arguments(for: configuration(allowComputerUse: false)))
            == ["issues", "Team-Chat-Server", "computer-use", "browser-use"])
        // Computer use is switched off even when the server list could not be read.
        #expect(disabled(CopilotAgent.arguments(for: configuration(allowComputerUse: false, servers: [])))
            == ["computer-use"])
    }

    @Test("denies commands that install software or change privileges and security settings")
    func deniesPrivilegedCommands() {
        let denied = values(after: "--deny-tool", in: CopilotAgent.arguments(for: configuration()))

        for command in ["sudo", "osascript", "installer", "brew", "spctl", "xattr", "security"] {
            #expect(denied.contains("shell(\(command):*)"))
        }
        #expect(denied.count == CopilotAgent.deniedShellCommands.count)
    }

    @Test("passes the model and credit limit only when set, never below the CLI's minimum")
    func passesOptionalLimits() {
        let defaults = CopilotAgent.arguments(for: configuration(model: "  ", maxAICredits: nil))
        #expect(!defaults.contains("--model"))
        #expect(!defaults.contains("--max-ai-credits"))

        let custom = CopilotAgent.arguments(for: configuration(model: "example-model", maxAICredits: 5))
        #expect(values(after: "--model", in: custom) == ["example-model"])
        #expect(values(after: "--max-ai-credits", in: custom) == ["30"])
    }

    @Test("reads server names from the CLI's grouped listing")
    func parsesServerListing() {
        let output = """
        User servers:
          notes (local)
          docs (http)

        Plugin servers:
          cloud (local)
          Mail-Server (http, disabled)

        Builtin servers:
          computer-use (local)
          github-mcp-server (http)
        """

        #expect(CopilotCLI.parseMCPServerNames(output) == [
            "notes", "docs", "cloud", "Mail-Server", "computer-use", "github-mcp-server",
        ])
        #expect(CopilotCLI.parseMCPServerNames("No servers configured.\n").isEmpty)
    }
}

@Suite("Copilot agent events")
struct CopilotAgentEventTests {

    @Test("describes a shell command the agent starts")
    func parsesToolStart() {
        let line = #"{"type":"tool.execution_start","data":{"toolCallId":"c1","toolName":"bash","arguments":{"command":"curl -fL -o downloads/app.dmg https://example.com/app.dmg\necho done","description":"Download"},"turnId":"0"},"id":"1","timestamp":"2026-11-20T19:11:26.000Z"}"#

        #expect(CopilotAgent.parseEvent(line) == .toolStarted(
            tool: "bash", summary: "curl -fL -o downloads/app.dmg https://example.com/app.dmg"
        ))
    }

    @Test("summarises other tools by their most telling argument")
    func summarisesTools() {
        #expect(CopilotAgent.summarize(tool: "web_fetch", arguments: ["url": "https://example.com/feed.xml"])
            == "https://example.com/feed.xml")
        #expect(CopilotAgent.summarize(tool: "web_search", arguments: ["query": "Example app mac download"])
            == "Example app mac download")
        #expect(CopilotAgent.summarize(tool: "computer-use-exec_js", arguments: ["code": "var apps = cua.listApps();"])
            == "var apps = cua.listApps();")
        #expect(CopilotAgent.summarize(tool: "bash", arguments: ["command": String(repeating: "a", count: 400)]).count == 161)
        #expect(CopilotAgent.summarize(tool: "unknown", arguments: [:]).isEmpty)
    }

    @Test("reports tool results, replies, and the final usage")
    func parsesOtherEvents() {
        #expect(CopilotAgent.parseEvent(
            #"{"type":"tool.execution_complete","data":{"toolCallId":"c1","success":true,"result":{"content":"ok"}}}"#
        ) == .toolFinished(success: true))
        #expect(CopilotAgent.parseEvent(
            #"{"type":"tool.execution_complete","data":{"toolCallId":"c1","success":false}}"#
        ) == .toolFinished(success: false))
        #expect(CopilotAgent.parseEvent(
            #"{"type":"assistant.message","data":{"content":"Staged Example 2.0.\n","toolRequests":[]}}"#
        ) == .message("Staged Example 2.0."))
        #expect(CopilotAgent.parseEvent(
            #"{"type":"result","timestamp":"t","sessionId":"s","exitCode":0,"usage":{"premiumRequests":2}}"#
        ) == .finished(exitCode: 0, premiumRequests: 2))
    }

    @Test("ignores streaming deltas, empty replies and anything that is not an event")
    func ignoresNoise() {
        #expect(CopilotAgent.parseEvent(#"{"type":"assistant.message_delta","data":{"deltaContent":"St"}}"#) == nil)
        #expect(CopilotAgent.parseEvent(#"{"type":"assistant.message","data":{"content":"","toolRequests":[{}]}}"#) == nil)
        #expect(CopilotAgent.parseEvent(#"{"type":"session.info","data":{"infoType":"configuration","message":"Disabled tools: x"}}"#) == nil)
        #expect(CopilotAgent.parseEvent("not json") == nil)
        #expect(CopilotAgent.parseEvent("{broken") == nil)
        #expect(CopilotAgent.parseEvent("") == nil)
    }
}

@Suite("Agent task")
struct AgentTaskTests {

    private let task = AppUpdateTask(
        name: "Example",
        bundleIdentifier: "com.example.app",
        installedPath: "/Applications/Example.app",
        installedVersion: "1.0",
        latestKnownVersion: "2.0",
        expectedTeamIdentifier: "ABCDE12345",
        download: CaskDownload(
            token: "example",
            version: "2.0",
            url: "https://example.com/Example-2.0.dmg",
            sha256: String(repeating: "a", count: 64),
            homepage: "https://example.com/"
        ),
        sparkleFeedURL: nil,
        ownedByRoot: false,
        isRunning: true,
        computerUseAllowed: false
    )

    private func facts(in prompt: String) throws -> [String: Any] {
        let start = try #require(prompt.firstIndex(of: "{"))
        let end = try #require(prompt.lastIndex(of: "}"))
        let object = try JSONSerialization.jsonObject(with: Data(prompt[start...end].utf8))
        return try #require(object as? [String: Any])
    }

    @Test("gives the agent the official download, checksum and identity to match")
    func buildsAppPrompt() throws {
        let prompt = AgentPrompt.appUpdate(task, architecture: "arm64", macOSVersion: "15.0")
        let facts = try facts(in: prompt)
        let download = try #require(facts["download"] as? [String: Any])

        #expect(facts["type"] as? String == "app")
        #expect(facts["bundleIdentifier"] as? String == "com.example.app")
        #expect(facts["expectedTeamIdentifier"] as? String == "ABCDE12345")
        #expect(facts["installedVersion"] as? String == "1.0")
        #expect(facts["architecture"] as? String == "arm64")
        #expect(facts["computerUseAllowed"] as? Bool == false)
        #expect(download["url"] as? String == "https://example.com/Example-2.0.dmg")
        #expect(download["sha256"] as? String == String(repeating: "a", count: 64))
        #expect(download["source"] as? String == "Homebrew cask example")
        #expect(prompt.contains("https://example.com/Example-2.0.dmg"))
        #expect(prompt.contains("guava-result.json"))
    }

    @Test("states plainly when no download or team is known")
    func marksUnknownFacts() throws {
        let unknown = AppUpdateTask(
            name: "Mystery", bundleIdentifier: nil, installedPath: "/Applications/Mystery.app",
            installedVersion: "3", latestKnownVersion: nil, expectedTeamIdentifier: nil, download: nil,
            sparkleFeedURL: "https://example.com/appcast.xml", ownedByRoot: true, isRunning: false,
            computerUseAllowed: true
        )

        let facts = try facts(in: AgentPrompt.appUpdate(unknown))

        #expect(facts["download"] is NSNull)
        #expect(facts["bundleIdentifier"] is NSNull)
        #expect(facts["expectedTeamIdentifier"] is NSNull)
        #expect(facts["sparkleFeedURL"] as? String == "https://example.com/appcast.xml")
        #expect(facts["ownedByRoot"] as? Bool == true)
    }

    @Test("lists the App Store apps that are waiting for an update")
    func buildsAppStorePrompt() throws {
        let prompt = AgentPrompt.appStoreUpdate(
            [AppStoreUpdateTask(name: "Storyboard", bundleIdentifier: "com.example.storyboard", installedVersion: "1.0", latestKnownVersion: "1.1")],
            computerUseAllowed: true
        )
        let facts = try facts(in: prompt)
        let apps = try #require(facts["apps"] as? [[String: Any]])

        #expect(facts["type"] as? String == "app-store")
        #expect(apps.count == 1)
        #expect(apps[0]["name"] as? String == "Storyboard")
    }

    @Test("installs the agent definition where the CLI looks for project agents")
    func preparesWorkspace() throws {
        let scratch = try TemporaryDirectory()

        let workspace = try AgentWorkspace.prepare(named: "Bob's \"Great\" App!", in: scratch.url)
        let definition = try String(
            contentsOf: workspace.appendingPathComponent(".github/agents/guava-updater.agent.md"), encoding: .utf8
        )

        #expect(workspace.lastPathComponent == "bob-s-great-app")
        #expect(definition.hasPrefix("---\nname: guava-updater\ndescription: "))
        #expect(definition.contains("guava-result.json"))
        for command in CopilotAgent.deniedShellCommands {
            #expect(definition.contains("`\(command)`"), "The agent is not told to avoid \(command)")
        }
    }

    @Test("gives every task its own folder, even when two names come out the same")
    func keepsWorkspacesApart() async throws {
        let scratch = try TemporaryDirectory()

        let first = try AgentWorkspace.prepare(named: "日本語", in: scratch.url)
        let second = try AgentWorkspace.prepare(named: "한국어", in: scratch.url)
        let third = try AgentWorkspace.prepare(named: "", in: scratch.url)

        #expect([first, second, third].map(\.lastPathComponent) == ["app", "app-2", "app-3"])

        // What one task stages survives the next task's tidying up.
        let payload = first.appendingPathComponent("payload/First.app")
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        try "download".write(to: second.appendingPathComponent("leftover.dmg"), atomically: true, encoding: .utf8)
        await AgentWorkspace.discardScratch(in: second, keeping: nil)

        #expect(FileManager.default.fileExists(atPath: payload.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: second.path).isEmpty)
    }

    @Test("makes safe folder names", arguments: [
        ("Sample Editor Pro", "sample-editor-pro"),
        ("meet.example", "meet-example"),
        ("../../etc", "etc"),
        ("日本語", "app"),
        ("", "app"),
    ])
    func makesSlugs(name: String, slug: String) {
        #expect(AgentWorkspace.slug(for: name) == slug)
    }
}

@Suite("Agent result")
struct AgentResultTests {

    private func writeResult(_ json: String, in scratch: TemporaryDirectory) throws {
        try scratch.write(json, to: AgentResultReader.fileName)
    }

    @Test("accepts a staged application inside the staging folder")
    func readsStagedApp() throws {
        let scratch = try TemporaryDirectory()
        let app = try scratch.makeDirectory("payload/Example.app")
        try writeResult(
            #"{"status":"staged","payload":"payload/Example.app","version":"2.0","sourceURL":"https://example.com/a.dmg","notes":" Staged. "}"#,
            in: scratch
        )

        let result = try AgentResultReader.read(from: scratch.url).get()

        #expect(result.status == .staged)
        #expect(result.payload?.path == app.path)
        #expect(result.payloadKind == .app)
        #expect(result.version == "2.0")
        #expect(result.notes == "Staged.")
    }

    @Test("accepts an absolute payload path as long as it is inside the staging folder")
    func readsAbsolutePayload() throws {
        let scratch = try TemporaryDirectory()
        let package = try scratch.write("pkg", to: "payload/Example.pkg")
        try writeResult(#"{"status":"staged","payload":"\#(package.path)"}"#, in: scratch)

        let result = try AgentResultReader.read(from: scratch.url).get()

        #expect(result.payloadKind == .pkg)
        #expect(result.payload?.path == package.path)
    }

    @Test("rejects a payload that points outside the staging folder", arguments: [
        "../outside/Evil.app",
        "payload/../../outside/Evil.app",
        "/System/Library/CoreServices/Finder.app",
        "link/Evil.app",
        ".",
    ])
    func rejectsEscapes(reference: String) throws {
        let scratch = try TemporaryDirectory()
        let staging = try scratch.makeDirectory("staging")
        try scratch.makeDirectory("outside/Evil.app")
        try FileManager.default.createSymbolicLink(
            at: staging.appendingPathComponent("link"),
            withDestinationURL: scratch.url.appendingPathComponent("outside")
        )
        try #"{"status":"staged","payload":"\#(reference)"}"#.write(
            to: staging.appendingPathComponent(AgentResultReader.fileName), atomically: true, encoding: .utf8
        )

        #expect(AgentResultReader.read(from: staging) == .failure(.payloadOutsideStaging))
    }

    @Test("rejects incomplete or malformed results")
    func rejectsBadResults() throws {
        let scratch = try TemporaryDirectory()
        #expect(AgentResultReader.read(from: scratch.url) == .failure(.missing))

        try writeResult("not json", in: scratch)
        #expect(AgentResultReader.read(from: scratch.url) == .failure(.unreadable))

        try writeResult(#"{"payload":"payload/Example.app"}"#, in: scratch)
        #expect(AgentResultReader.read(from: scratch.url) == .failure(.unreadable))

        try writeResult(#"{"status":"installed"}"#, in: scratch)
        #expect(AgentResultReader.read(from: scratch.url) == .failure(.unknownStatus("installed")))

        try writeResult(#"{"status":"staged"}"#, in: scratch)
        #expect(AgentResultReader.read(from: scratch.url) == .failure(.payloadMissing))

        try writeResult(#"{"status":"staged","payload":"payload/Missing.app"}"#, in: scratch)
        #expect(AgentResultReader.read(from: scratch.url) == .failure(.payloadNotFound))

        try scratch.write("#!/bin/sh", to: "payload/install.sh")
        try writeResult(#"{"status":"staged","payload":"payload/install.sh"}"#, in: scratch)
        #expect(AgentResultReader.read(from: scratch.url) == .failure(.payloadUnsupported))
    }

    @Test("does not follow a result file that is a symbolic link")
    func rejectsLinkedResultFile() throws {
        let scratch = try TemporaryDirectory()
        let staging = try scratch.makeDirectory("staging")
        let elsewhere = try scratch.write(#"{"status":"up_to_date"}"#, to: "elsewhere.json")
        try FileManager.default.createSymbolicLink(
            at: staging.appendingPathComponent(AgentResultReader.fileName), withDestinationURL: elsewhere
        )

        #expect(AgentResultReader.read(from: staging) == .failure(.missing))
    }

    @Test("reads outcomes that need no payload", arguments: [
        ("update_triggered", AgentResult.Status.updateTriggered),
        ("up_to_date", .upToDate),
        ("failed", .failed),
    ])
    func readsOtherStatuses(raw: String, status: AgentResult.Status) throws {
        let scratch = try TemporaryDirectory()
        try writeResult(#"{"status":"\#(raw)","notes":"Because."}"#, in: scratch)

        let result = try AgentResultReader.read(from: scratch.url).get()

        #expect(result.status == status)
        #expect(result.payload == nil)
        #expect(result.notes == "Because.")
    }
}

@Suite("Agent outcome evaluation")
struct AgentOutcomeTests {

    private let relaxed = VerificationPolicy(requireGatekeeper: false, requireNewerVersion: true)
    private let expected = ExpectedApp(
        name: "Fixture", bundleIdentifier: "com.example.fixture", teamIdentifier: nil, installedVersion: "1.0"
    )

    private func session(
        exitCode: Int32 = 0, timedOut: Bool = false, cancelled: Bool = false,
        message: String? = nil, failure: String? = nil
    ) -> AgentRunOutcome {
        AgentRunOutcome(
            exitCode: exitCode, timedOut: timedOut, wasCancelled: cancelled,
            finalMessage: message, premiumRequests: 1, failure: failure
        )
    }

    @Test("accepts a staged download only after verifying it")
    func verifiesStagedPayload() async throws {
        let scratch = try TemporaryDirectory()
        try await Fixture.makeApp(at: scratch.url.appendingPathComponent("payload/Fixture.app"), version: "2.0")
        try scratch.write(#"{"status":"staged","payload":"payload/Fixture.app"}"#, to: AgentResultReader.fileName)

        let outcome = await AgentAppUpdater.evaluate(
            session: session(), workspace: scratch.url, expected: expected, policy: relaxed
        )

        guard case .staged(let payload) = outcome else {
            Issue.record("Expected a staged payload, got \(outcome)")
            return
        }
        #expect(payload.version == "2.0")
    }

    @Test("accepts a vendor's build that carries Finder metadata, as some disk images do")
    func acceptsPayloadWithFinderMetadata() async throws {
        let scratch = try TemporaryDirectory()
        let app = try await Fixture.makeApp(at: scratch.url.appendingPathComponent("payload/Fixture.app"), version: "2.0")
        try Fixture.setFinderInfo(on: app.appendingPathComponent("Contents/MacOS/Fixture").path)
        try scratch.write(#"{"status":"staged","payload":"payload/Fixture.app"}"#, to: AgentResultReader.fileName)

        let outcome = await AgentAppUpdater.evaluate(
            session: session(), workspace: scratch.url, expected: expected, policy: relaxed
        )

        guard case .staged = outcome else {
            Issue.record("Expected a staged payload, got \(outcome)")
            return
        }
        // What is installed carries nothing that its signature does not cover.
        #expect(!Fixture.hasFinderInfo(app.appendingPathComponent("Contents/MacOS/Fixture").path))
    }

    @Test("calls it up to date, not a failure, when the vendor's download is what is installed")
    func treatsSameVersionAsUpToDate() async throws {
        let scratch = try TemporaryDirectory()
        try await Fixture.makeApp(at: scratch.url.appendingPathComponent("payload/Fixture.app"), version: "1.0")
        try scratch.write(#"{"status":"staged","payload":"payload/Fixture.app"}"#, to: AgentResultReader.fileName)

        let outcome = await AgentAppUpdater.evaluate(
            session: session(), workspace: scratch.url, expected: expected, policy: relaxed
        )

        #expect(outcome == .upToDate(notes: "The vendor's download is version 1.0, and 1.0 is installed"))

        // A download that fails any other check says nothing about what the vendor offers.
        let unsigned = try TemporaryDirectory()
        try await Fixture.makeApp(
            at: unsigned.url.appendingPathComponent("payload/Fixture.app"), version: "1.0", sign: false
        )
        try unsigned.write(#"{"status":"staged","payload":"payload/Fixture.app"}"#, to: AgentResultReader.fileName)
        let refused = await AgentAppUpdater.evaluate(
            session: session(), workspace: unsigned.url, expected: expected, policy: relaxed
        )
        guard case .failed(let reason) = refused else {
            Issue.record("Expected a failure, got \(refused)")
            return
        }
        #expect(reason.hasPrefix("The code signature is not valid"))
    }

    @Test("does not trust the agent's claim when the staged download is the wrong app")
    func rejectsUnverifiedPayload() async throws {
        let scratch = try TemporaryDirectory()
        try await Fixture.makeApp(
            at: scratch.url.appendingPathComponent("payload/Fixture.app"),
            bundleIdentifier: "com.example.impostor", version: "2.0"
        )
        try scratch.write(
            #"{"status":"staged","payload":"payload/Fixture.app","notes":"Verified and ready."}"#,
            to: AgentResultReader.fileName
        )

        let outcome = await AgentAppUpdater.evaluate(
            session: session(message: "All checks passed."), workspace: scratch.url, expected: expected, policy: relaxed
        )

        #expect(outcome == .failed("Wrong application: expected com.example.fixture, found com.example.impostor"))
    }

    @Test("reports a session that was cut short before looking for a result")
    func reportsInterruptedSessions() async throws {
        let scratch = try TemporaryDirectory()
        try scratch.write(#"{"status":"up_to_date"}"#, to: AgentResultReader.fileName)

        #expect(await AgentAppUpdater.evaluate(
            session: session(timedOut: true), workspace: scratch.url, expected: expected, policy: relaxed
        ) == .failed("The agent ran out of time"))
        #expect(await AgentAppUpdater.evaluate(
            session: session(cancelled: true), workspace: scratch.url, expected: expected, policy: relaxed
        ) == .failed("Cancelled"))
        #expect(await AgentAppUpdater.evaluate(
            session: session(exitCode: 1, failure: "Not signed in"), workspace: scratch.url, expected: expected, policy: relaxed
        ) == .failed("Not signed in"))
    }

    @Test("quotes what the agent said when it left no result file")
    func explainsMissingResult() async throws {
        let scratch = try TemporaryDirectory()

        let outcome = await AgentAppUpdater.evaluate(
            session: session(message: "I could not find a download."),
            workspace: scratch.url, expected: expected, policy: relaxed
        )

        #expect(outcome == .failed(
            "The agent finished without reporting a result. Agent said: I could not find a download."
        ))
    }

    @Test("passes through outcomes that involve no download")
    func passesThroughOtherOutcomes() async throws {
        let scratch = try TemporaryDirectory()

        try scratch.write(#"{"status":"up_to_date","notes":"Already current."}"#, to: AgentResultReader.fileName)
        #expect(await AgentAppUpdater.evaluate(
            session: session(), workspace: scratch.url, expected: expected, policy: relaxed
        ) == .upToDate(notes: "Already current."))

        try scratch.write(#"{"status":"update_triggered"}"#, to: AgentResultReader.fileName)
        #expect(await AgentAppUpdater.evaluate(
            session: session(), workspace: scratch.url, expected: expected, policy: relaxed
        ) == .updateTriggered(notes: nil))

        try scratch.write(#"{"status":"failed","notes":"Checksum mismatch."}"#, to: AgentResultReader.fileName)
        #expect(await AgentAppUpdater.evaluate(
            session: session(), workspace: scratch.url, expected: expected, policy: relaxed
        ) == .failed("Checksum mismatch."))
    }

    @Test("discards the agent's downloads and keeps only the verified payload")
    func discardsScratch() async throws {
        let scratch = try TemporaryDirectory()
        let payload = try scratch.makeDirectory("payload/Fixture.app")
        try scratch.write("dmg", to: "downloads/Fixture.dmg")
        try scratch.write("zip", to: "unpack/Fixture.zip")
        try scratch.write("stray", to: "payload/README.txt")
        try scratch.write("agent", to: ".github/agents/guava-updater.agent.md")
        try scratch.write("{}", to: AgentResultReader.fileName)

        await AgentWorkspace.discardScratch(in: scratch.url, keeping: payload)

        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.url.path) == ["payload"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.url.appendingPathComponent("payload").path)
            == ["Fixture.app"])
    }

    @Test("discards everything when nothing was staged")
    func discardsEverythingWithoutPayload() async throws {
        let scratch = try TemporaryDirectory()
        try scratch.write("dmg", to: "downloads/Fixture.dmg")
        try scratch.makeDirectory("payload/Rejected.app")

        await AgentWorkspace.discardScratch(in: scratch.url, keeping: nil)

        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.url.path).isEmpty)
    }
}
