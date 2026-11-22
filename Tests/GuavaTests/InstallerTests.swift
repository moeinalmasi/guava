import Foundation
import Testing
@testable import Guava

@Suite("Install script")
struct InstallScriptTests {

    @Test("quotes paths so that spaces and quotes cannot break out of an argument")
    func quotesArguments() {
        #expect(InstallScript.shellQuoted("/Applications/Bob's App.app") == "'/Applications/Bob'\\''s App.app'")
        #expect(InstallScript.shellQuoted("$(touch /tmp/x)") == "'$(touch /tmp/x)'")
        #expect(InstallScript.appleScriptEscaped("say \"hi\" \\ bye") == "say \\\"hi\\\" \\\\ bye")
    }

    @Test("accepts only numeric owners", arguments: [
        ("0:0", true), ("501:20", true), ("root:wheel", false), ("0", false), ("0:0; rm -rf /", false), (":", false),
    ])
    func validatesOwners(owner: String, isValid: Bool) {
        #expect((InstallScript.validatedOwner(owner) != nil) == isValid)
    }

    @Test("drops a malformed team identifier instead of placing it in the script")
    func ignoresMalformedTeam() {
        let script = InstallScript.script(for: [.replaceApp(
            staged: "/tmp/a.app", destination: "/tmp/b.app", owner: nil,
            teamIdentifier: "BAD\"; rm -rf /; \"", requireGatekeeper: false
        )])

        #expect(!script.contains("rm -rf /;"))
        #expect(script.contains("guava_replace_app '/tmp/a.app' '/tmp/b.app' '' '' 0 '' ''; echo \"GUAVA_RESULT 0 $?\""))
    }

    @Test("pins the developer team, the application and its version in the script")
    func embedsTeamRequirement() {
        let script = InstallScript.script(for: [.replaceApp(
            staged: "/tmp/a.app", destination: "/tmp/b.app", owner: "0:0",
            teamIdentifier: "A1B2C3D4E5", requireGatekeeper: true,
            identity: BundleIdentity(bundleIdentifier: "com.example.app", version: "7.2.5 (90525)")
        )])

        #expect(script.contains(
            "'=anchor apple generic and certificate leaf[subject.OU] = \"A1B2C3D4E5\"' 1 "
                + "'com.example.app' '7.2.5 (90525)'; echo"
        ))
        #expect(script.contains("'0:0'"))
    }

    @Test("maps reported statuses back to operations by index")
    func parsesResults() {
        let output = "noise\nGUAVA_RESULT 1 72\nGUAVA_RESULT 0 0\nGUAVA_RESULT 9 0\nGUAVA_RESULT x 0\n"

        #expect(InstallScript.parseResults(output, count: 3) == [0, 72, nil])
        #expect(InstallScript.outcome(forStatus: 0) == .installed(note: nil))
        #expect(InstallScript.outcome(forStatus: 76).isInstalled)
        #expect(!InstallScript.outcome(forStatus: 72).isInstalled)
        #expect(!InstallScript.outcome(forStatus: nil).isInstalled)
    }

    @Test("survives the round trip through AppleScript with its line endings intact")
    func runsThroughAppleScript() async {
        let script = "printf 'first line\\n'\necho \"it's \\\"quoted\\\"\"\necho \"GUAVA_RESULT 0 $?\""
        let source = InstallScript.appleScript(running: script, prompt: nil, asAdministrator: false)

        let result = await ProcessRunner.run("/usr/bin/osascript", ["-e", source], timeout: 60)

        #expect(result.success)
        #expect(result.stdout.contains("first line\nit's \"quoted\"\n"))
        #expect(InstallScript.parseResults(result.stdout, count: 1) == [0])
    }

    @Test("asks for administrator rights with a prompt naming what will be installed")
    func buildsAdministratorRequest() {
        let source = InstallScript.appleScript(
            running: "true", prompt: "Guava wants to update \"Sample\"", asAdministrator: true
        )

        #expect(source == "do shell script \"true\" with prompt \"Guava wants to update \\\"Sample\\\"\" "
            + "with administrator privileges without altering line endings")
    }
}

@Suite("App installation")
struct AppInstallerTests {

    /// Installed v1 plus a staged v2, both ad-hoc signed.
    private func makeScenario(
        _ scratch: TemporaryDirectory,
        installedName: String = "Fixture.app"
    ) async throws -> (installed: URL, staged: URL) {
        let applications = try scratch.makeDirectory("Applications")
        let staging = try scratch.makeDirectory("staging/payload")
        let installed = try await Fixture.makeApp(at: applications.appendingPathComponent(installedName), version: "1.0")
        let staged = try await Fixture.makeApp(at: staging.appendingPathComponent("Fixture.app"), version: "2.0")
        return (installed, staged)
    }

    @Test("replaces the installed application and leaves nothing behind")
    func replacesApplication() async throws {
        let scratch = try TemporaryDirectory()
        let (installed, staged) = try await makeScenario(scratch)

        let outcomes = await AppInstaller.run(
            [.replaceApp(staged: staged.path, destination: installed.path, owner: nil,
                         teamIdentifier: nil, requireGatekeeper: false)],
            asAdministrator: false
        )

        #expect(outcomes == [.installed(note: nil)])
        #expect(Fixture.version(ofAppAt: installed) == "2.0")
        #expect(!FileManager.default.fileExists(atPath: installed.path + ".guava-old"))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: installed.deletingLastPathComponent().path)
        #expect(leftovers == ["Fixture.app"])
        #expect((await CodeSignVerifier.verify(installed.path)).success)
    }

    @Test("handles application names containing spaces and quotes")
    func handlesAwkwardNames() async throws {
        let scratch = try TemporaryDirectory()
        let (installed, staged) = try await makeScenario(scratch, installedName: "Bob's \"Great\" App.app")

        let outcomes = await AppInstaller.run(
            [.replaceApp(staged: staged.path, destination: installed.path, owner: nil,
                         teamIdentifier: nil, requireGatekeeper: false)],
            asAdministrator: false
        )

        #expect(outcomes == [.installed(note: nil)])
        #expect(Fixture.version(ofAppAt: installed) == "2.0")
    }

    @Test("keeps the installed version when the download fails its signature check")
    func keepsOldVersionOnBadSignature() async throws {
        let scratch = try TemporaryDirectory()
        let (installed, staged) = try await makeScenario(scratch)
        try "#!/bin/sh\necho tampered\n".write(
            to: staged.appendingPathComponent("Contents/MacOS/Fixture"), atomically: true, encoding: .utf8
        )

        let outcomes = await AppInstaller.run(
            [.replaceApp(staged: staged.path, destination: installed.path, owner: nil,
                         teamIdentifier: nil, requireGatekeeper: false)],
            asAdministrator: false
        )

        #expect(outcomes == [.failed("The download failed its signature check")])
        #expect(Fixture.version(ofAppAt: installed) == "1.0")
        #expect(!FileManager.default.fileExists(atPath: installed.path + ".guava-old"))
    }

    @Test("installs a copy that is still the application and version that were checked")
    func installsWhenIdentityMatches() async throws {
        let scratch = try TemporaryDirectory()
        let (installed, staged) = try await makeScenario(scratch)

        let outcomes = await AppInstaller.run(
            [.replaceApp(staged: staged.path, destination: installed.path, owner: nil,
                         teamIdentifier: nil, requireGatekeeper: false,
                         identity: BundleIdentity(bundleIdentifier: "com.example.fixture", version: "2.0"))],
            asAdministrator: false
        )

        #expect(outcomes == [.installed(note: nil)])
        #expect(Fixture.version(ofAppAt: installed) == "2.0")
    }

    @Test("accepts exactly what the verifier reported about the staged bundle")
    func installerAgreesWithVerifier() async throws {
        let scratch = try TemporaryDirectory()
        let (installed, staged) = try await makeScenario(scratch)
        let verified = try await PayloadVerifier.verifyApp(
            at: staged,
            expected: ExpectedApp(
                name: "Fixture", bundleIdentifier: "com.example.fixture", teamIdentifier: nil, installedVersion: "1.0"
            ),
            policy: VerificationPolicy(requireGatekeeper: false, requireNewerVersion: true)
        ).get()

        let outcomes = await AppInstaller.run(
            [.replaceApp(staged: verified.url.path, destination: installed.path, owner: nil,
                         teamIdentifier: verified.teamIdentifier, requireGatekeeper: false,
                         identity: BundleIdentity(bundleIdentifier: verified.bundleIdentifier, version: verified.version))],
            asAdministrator: false
        )

        #expect(verified.bundleIdentifier == "com.example.fixture")
        #expect(verified.version == "2.0")
        #expect(outcomes == [.installed(note: nil)])
        #expect(Fixture.version(ofAppAt: installed) == "2.0")
    }

    @Test("keeps the installed version when the staged bundle was swapped after it was checked", arguments: [
        BundleIdentity(bundleIdentifier: "com.example.other", version: "2.0"),
        BundleIdentity(bundleIdentifier: "com.example.fixture", version: "2.1"),
        BundleIdentity(bundleIdentifier: nil, version: "1.9"),
    ])
    func refusesSwappedBundle(checked: BundleIdentity) async throws {
        let scratch = try TemporaryDirectory()
        // What is in the staging folder now is a validly signed 2.0 of com.example.fixture,
        // which is not what `checked` says passed verification.
        let (installed, staged) = try await makeScenario(scratch)

        let outcomes = await AppInstaller.run(
            [.replaceApp(staged: staged.path, destination: installed.path, owner: nil,
                         teamIdentifier: nil, requireGatekeeper: false, identity: checked)],
            asAdministrator: false
        )

        #expect(outcomes == [.failed("The download is no longer the application and version that were checked")])
        #expect(Fixture.version(ofAppAt: installed) == "1.0")
        #expect(!FileManager.default.fileExists(atPath: installed.path + ".guava-old"))
    }

    @Test("keeps the installed version when the developer team does not match")
    func keepsOldVersionOnTeamMismatch() async throws {
        let scratch = try TemporaryDirectory()
        let (installed, staged) = try await makeScenario(scratch)

        let outcomes = await AppInstaller.run(
            [.replaceApp(staged: staged.path, destination: installed.path, owner: nil,
                         teamIdentifier: "A1B2C3D4E5", requireGatekeeper: false)],
            asAdministrator: false
        )

        #expect(outcomes == [.failed("The download failed its signature check")])
        #expect(Fixture.version(ofAppAt: installed) == "1.0")
    }

    @Test("keeps the installed version when Gatekeeper rejects the copy", .enabled(if: gatekeeperEnabled))
    func keepsOldVersionOnGatekeeperRejection() async throws {
        let scratch = try TemporaryDirectory()
        let (installed, staged) = try await makeScenario(scratch)

        let outcomes = await AppInstaller.run(
            [.replaceApp(staged: staged.path, destination: installed.path, owner: nil,
                         teamIdentifier: nil, requireGatekeeper: true)],
            asAdministrator: false
        )

        #expect(outcomes == [.failed("Gatekeeper rejected the download")])
        #expect(Fixture.version(ofAppAt: installed) == "1.0")
    }

    @Test("clears a leftover copy from an interrupted earlier run before installing")
    func clearsStaleBackup() async throws {
        let scratch = try TemporaryDirectory()
        let (installed, staged) = try await makeScenario(scratch)
        let stale = URL(fileURLWithPath: installed.path + ".guava-old")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try "old".write(to: stale.appendingPathComponent("marker"), atomically: true, encoding: .utf8)

        let outcomes = await AppInstaller.run(
            [.replaceApp(staged: staged.path, destination: installed.path, owner: nil,
                         teamIdentifier: nil, requireGatekeeper: false)],
            asAdministrator: false
        )

        #expect(outcomes == [.installed(note: nil)])
        #expect(Fixture.version(ofAppAt: installed) == "2.0")
        #expect(!FileManager.default.fileExists(atPath: stale.path))
    }

    @Test("reports each operation separately when a batch partly fails")
    func reportsBatchPerOperation() async throws {
        let scratch = try TemporaryDirectory()
        let (installed, staged) = try await makeScenario(scratch)
        let missing = scratch.url.appendingPathComponent("staging/payload/Missing.app")
        let other = scratch.url.appendingPathComponent("Applications/Other.app")

        let outcomes = await AppInstaller.run(
            [
                .replaceApp(staged: missing.path, destination: other.path, owner: nil,
                            teamIdentifier: nil, requireGatekeeper: false),
                .replaceApp(staged: staged.path, destination: installed.path, owner: nil,
                            teamIdentifier: nil, requireGatekeeper: false),
            ],
            asAdministrator: false
        )

        #expect(outcomes == [.failed("Could not copy the download"), .installed(note: nil)])
        #expect(!FileManager.default.fileExists(atPath: other.path))
        #expect(Fixture.version(ofAppAt: installed) == "2.0")
    }

    /// Groups the current user belongs to. Changing a file's group to one of them needs no root.
    private static let userGroups: [gid_t] = {
        var groups = [gid_t](repeating: 0, count: 64)
        let count = getgroups(Int32(groups.count), &groups)
        return count > 0 ? Array(Set(groups.prefix(Int(count)))) : []
    }()

    @Test(
        "gives the new copy the ownership it was asked to restore, all the way down",
        .enabled(if: userGroups.count > 1)
    )
    func restoresOwnership() async throws {
        let scratch = try TemporaryDirectory()
        let (installed, staged) = try await makeScenario(scratch)
        let attributes = try FileManager.default.attributesOfItem(atPath: staged.path)
        let stagedGroup = try #require(attributes[.groupOwnerAccountID] as? NSNumber).uint32Value
        let group = try #require(Self.userGroups.first { $0 != stagedGroup })
        let owner = "\(getuid()):\(group)"

        let outcomes = await AppInstaller.run(
            [.replaceApp(staged: staged.path, destination: installed.path, owner: owner,
                         teamIdentifier: nil, requireGatekeeper: false)],
            asAdministrator: false
        )

        #expect(outcomes == [.installed(note: nil)])
        #expect(Fixture.version(ofAppAt: installed) == "2.0")
        #expect(AppInstaller.ownerSpecification(of: installed.path) == owner)
        #expect(AppInstaller.ownerSpecification(of: installed.appendingPathComponent("Contents/Info.plist").path) == owner)
    }

    @Test("runs the whole script through AppleScript, the way the administrator route does")
    func runsWholeScriptThroughAppleScript() async throws {
        let scratch = try TemporaryDirectory()
        let (installed, staged) = try await makeScenario(scratch, installedName: "Bob's \"Great\" App.app")
        let script = InstallScript.script(for: [
            .replaceApp(staged: staged.path, destination: installed.path,
                        owner: "\(getuid()):\(getgid())", teamIdentifier: nil, requireGatekeeper: false,
                        identity: BundleIdentity(bundleIdentifier: "com.example.fixture", version: "2.0")),
            .replaceApp(staged: staged.path, destination: installed.path, owner: nil,
                        teamIdentifier: nil, requireGatekeeper: false,
                        identity: BundleIdentity(bundleIdentifier: "com.example.fixture", version: "3.0 (it's \"new\")")),
        ])
        // Everything but the privileges: same AppleScript, same shell, same escaping.
        let source = InstallScript.appleScript(running: script, prompt: nil, asAdministrator: false)

        let result = await ProcessRunner.run("/usr/bin/osascript", ["-e", source], timeout: 120)

        #expect(result.success, "osascript failed: \(result.failureMessage)")
        #expect(InstallScript.parseResults(result.stdout, count: 2) == [0, 77])
        #expect(Fixture.version(ofAppAt: installed) == "2.0")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: installed.deletingLastPathComponent().path)
        #expect(leftovers == ["Bob's \"Great\" App.app"])
    }

    @Test("never runs an installer package that is not pinned to a developer", arguments: [nil, "", "not-a-team"])
    func refusesUnpinnedPackage(team: String?) async throws {
        let scratch = try TemporaryDirectory()
        let package = try scratch.write("not a real package", to: "Update.pkg")

        let outcomes = await AppInstaller.run(
            [.installPackage(path: package.path, teamIdentifier: team, requireGatekeeper: true)],
            asAdministrator: false
        )

        #expect(outcomes == [.failed("The download failed its signature check")])
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.url.path) == ["Update.pkg"])
    }

    @Test("deletes its private copy when it is interrupted before the swap")
    func cleansUpWhenInterrupted() async throws {
        let scratch = try TemporaryDirectory()
        let work = try scratch.makeDirectory("work")
        try scratch.write("a partial copy", to: "work/Fixture.app/Contents/file")
        // As if Stop arrived while the download was still being copied or checked.
        let script = InstallScript.functions + """

        work=\(InstallScript.shellQuoted(work.path))
        /bin/kill -TERM $$
        /bin/sleep 5
        echo "\(InstallScript.resultMarker) 0 0"
        """

        let result = await ProcessRunner.run("/bin/sh", ["-c", script], timeout: 30)

        #expect(result.exitCode == 143)
        #expect(InstallScript.parseResults(result.stdout, count: 1) == [nil])
        #expect(!FileManager.default.fileExists(atPath: work.path))
    }

    @Test("finishes the swap once it has begun, even if it is told to stop in the middle")
    func finishesSwapWhenInterrupted() async throws {
        let scratch = try TemporaryDirectory()
        let (installed, staged) = try await makeScenario(scratch)
        // A stand-in for `mv` that signals the script the first time it is used, which is
        // between moving the old version aside and putting the new one in its place.
        let marker = scratch.url.appendingPathComponent("signalled").path
        let mover = try scratch.write(
            """
            #!/bin/sh
            if [ ! -e '\(marker)' ]; then /usr/bin/touch '\(marker)'; /bin/kill -TERM $PPID; fi
            exec /bin/mv "$@"
            """,
            to: "mv", executable: true
        )
        let script = InstallScript.script(for: [.replaceApp(
            staged: staged.path, destination: installed.path, owner: nil,
            teamIdentifier: nil, requireGatekeeper: false
        )]).replacingOccurrences(of: "/bin/mv ", with: InstallScript.shellQuoted(mover.path) + " ")

        let result = await ProcessRunner.run("/bin/sh", ["-c", script], timeout: 60)

        #expect(FileManager.default.fileExists(atPath: marker), "The script was never signalled")
        #expect(InstallScript.parseResults(result.stdout, count: 1) == [0])
        #expect(Fixture.version(ofAppAt: installed) == "2.0")
        #expect(!FileManager.default.fileExists(atPath: installed.path + ".guava-old"))
    }

    @Test("installs with user rights only where the user owns the bundle")
    func choosesRoute() async throws {
        let scratch = try TemporaryDirectory()
        let (installed, _) = try await makeScenario(scratch)

        #expect(AppInstaller.route(forDestination: installed.path) == .user)
        #expect(AppInstaller.route(forDestination: scratch.url.appendingPathComponent("New.app").path) == .user)
        #expect(AppInstaller.route(forDestination: installed.path, currentUser: getuid() + 1) == .administrator)
        #expect(AppInstaller.route(forDestination: "/System/Applications/Calculator.app") == .administrator)
        #expect(AppInstaller.ownerSpecification(of: installed.path) == "\(getuid()):\(getgid())")
    }
}
