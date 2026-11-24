import Foundation
import Testing
@testable import Guava

@Suite("Code signature parsing")
struct CodeSignatureParsingTests {

    @Test("reads the team, identifier and authorities of a Developer ID signature")
    func parsesDeveloperSignature() {
        let output = """
        Executable=/Applications/Sample Editor.app/Contents/MacOS/Editor
        Identifier=com.example.editor
        Format=app bundle with Mach-O thin (arm64)
        Authority=Developer ID Application: Example Corporation (A1B2C3D4E5)
        Authority=Developer ID Certification Authority
        Authority=Apple Root CA
        Timestamp=Nov 17, 2026 at 3:05:11 AM
        TeamIdentifier=A1B2C3D4E5
        """

        let signature = CodeSignVerifier.parseSignature(output)

        #expect(signature.identifier == "com.example.editor")
        #expect(signature.teamIdentifier == "A1B2C3D4E5")
        #expect(signature.authorities.first == "Developer ID Application: Example Corporation (A1B2C3D4E5)")
        #expect(!signature.isAdHoc)
    }

    @Test("treats ad-hoc and Apple platform signatures as having no team")
    func parsesTeamlessSignatures() {
        let adHoc = CodeSignVerifier.parseSignature("Identifier=Guava\nSignature=adhoc\nTeamIdentifier=not set\n")
        #expect(adHoc.isAdHoc)
        #expect(adHoc.teamIdentifier == nil)

        let platform = CodeSignVerifier.parseSignature(
            "Identifier=com.apple.calculator\nAuthority=macOS Software Signing\nAuthority=Apple Root CA\n"
        )
        #expect(platform.teamIdentifier == nil)
        #expect(!platform.isAdHoc)
    }

    @Test(
        "accepts only well-formed team identifiers",
        arguments: [
            ("A1B2C3D4E5", true),
            ("a1b2c3d4e5", false),
            ("A1B2C3D4E", false),
            ("A1B2C3D4E5X", false),
            ("A1B2C\"D4E5", false),
            ("A1B2C3D4E'", false),
            ("not set", false),
            ("", false),
        ]
    )
    func validatesTeamIdentifiers(value: String, isValid: Bool) {
        #expect((CodeSignVerifier.validatedTeamIdentifier(value) != nil) == isValid)
    }

    @Test("reads the signer of a notarized installer package")
    func parsesPackageSignature() {
        let output = """
        Package "sample-installer-2.0.pkg":
           Status: signed by a developer certificate issued by Apple for distribution
           Notarization: trusted by the Apple notary service
           Signed with a trusted timestamp on: 2026-10-26 11:10:28 +0000
           Certificate Chain:
            1. Developer ID Installer: Example Corporation (A1B2C3D4E5)
               Expires: 2027-02-01 22:12:15 +0000
               ------------------------------------------------------------------------
            2. Developer ID Certification Authority
        """

        let signature = CodeSignVerifier.parsePackageSignature(output)

        #expect(signature.isDeveloperSigned)
        #expect(signature.isNotarized)
        #expect(signature.teamIdentifier == "A1B2C3D4E5")
    }

    @Test("reports an unsigned package as not developer-signed")
    func parsesUnsignedPackage() {
        let signature = CodeSignVerifier.parsePackageSignature("Package \"x.pkg\":\n   Status: no signature\n")

        #expect(!signature.isDeveloperSigned)
        #expect(!signature.isNotarized)
        #expect(signature.teamIdentifier == nil)
    }
}

@Suite("Payload verification")
struct PayloadVerifierTests {

    private let relaxed = VerificationPolicy(requireGatekeeper: false, requireNewerVersion: true)
    private let expected = ExpectedApp(
        name: "Fixture",
        bundleIdentifier: "com.example.fixture",
        teamIdentifier: nil,
        installedVersion: "1.0"
    )

    @Test("accepts an intact, newer build of the same application")
    func acceptsNewerBuild() async throws {
        let scratch = try TemporaryDirectory()
        let app = try await Fixture.makeApp(at: scratch.url.appendingPathComponent("Fixture.app"), version: "2.0")

        let result = await PayloadVerifier.verifyApp(at: app, expected: expected, policy: relaxed)

        let payload = try result.get()
        #expect(payload.kind == .app)
        #expect(payload.version == "2.0")
    }

    @Test("rejects a different application even when it is validly signed")
    func rejectsWrongBundleIdentifier() async throws {
        let scratch = try TemporaryDirectory()
        let app = try await Fixture.makeApp(
            at: scratch.url.appendingPathComponent("Fixture.app"),
            bundleIdentifier: "com.example.impostor",
            version: "2.0"
        )

        let result = await PayloadVerifier.verifyApp(at: app, expected: expected, policy: relaxed)

        #expect(result == .failure(.bundleIdentifierMismatch(
            expected: "com.example.fixture", found: "com.example.impostor"
        )))
    }

    @Test("rejects a build that is not newer than the installed one", arguments: ["1.0", "0.9"])
    func rejectsOldBuild(version: String) async throws {
        let scratch = try TemporaryDirectory()
        let app = try await Fixture.makeApp(at: scratch.url.appendingPathComponent("Fixture.app"), version: version)

        let result = await PayloadVerifier.verifyApp(at: app, expected: expected, policy: relaxed)

        #expect(result == .failure(.notNewer(installed: "1.0", staged: version)))
    }

    @Test("rejects a bundle modified after it was signed")
    func rejectsTamperedBundle() async throws {
        let scratch = try TemporaryDirectory()
        let app = try await Fixture.makeApp(at: scratch.url.appendingPathComponent("Fixture.app"), version: "2.0")
        try "#!/bin/sh\necho tampered\n".write(
            to: app.appendingPathComponent("Contents/MacOS/Fixture"), atomically: true, encoding: .utf8
        )

        let result = await PayloadVerifier.verifyApp(at: app, expected: expected, policy: relaxed)

        guard case .failure(.invalidSignature) = result else {
            Issue.record("Expected an invalid signature, got \(result)")
            return
        }
    }

    @Test("rejects an unsigned bundle")
    func rejectsUnsignedBundle() async throws {
        let scratch = try TemporaryDirectory()
        let app = try await Fixture.makeApp(
            at: scratch.url.appendingPathComponent("Fixture.app"), version: "2.0", sign: false
        )

        let result = await PayloadVerifier.verifyApp(at: app, expected: expected, policy: relaxed)

        guard case .failure(.invalidSignature) = result else {
            Issue.record("Expected an invalid signature, got \(result)")
            return
        }
    }

    @Test("rejects a build signed by a different developer than the installed app")
    func rejectsTeamMismatch() async throws {
        let scratch = try TemporaryDirectory()
        let app = try await Fixture.makeApp(at: scratch.url.appendingPathComponent("Fixture.app"), version: "2.0")
        let signedExpectation = ExpectedApp(
            name: "Fixture",
            bundleIdentifier: "com.example.fixture",
            teamIdentifier: "A1B2C3D4E5",
            installedVersion: "1.0"
        )

        let result = await PayloadVerifier.verifyApp(at: app, expected: signedExpectation, policy: relaxed)

        #expect(result == .failure(.teamMismatch(expected: "A1B2C3D4E5", found: nil)))
    }

    @Test("rejects a build Gatekeeper would not open under the default policy", .enabled(if: gatekeeperEnabled))
    func strictPolicyRequiresGatekeeper() async throws {
        let scratch = try TemporaryDirectory()
        let app = try await Fixture.makeApp(at: scratch.url.appendingPathComponent("Fixture.app"), version: "2.0")

        let result = await PayloadVerifier.verifyApp(at: app, expected: expected, policy: .strict)

        guard case .failure(.gatekeeperRejected) = result else {
            Issue.record("Expected a Gatekeeper rejection, got \(result)")
            return
        }
    }

    @Test("takes off what no signature covers, which strict verification would refuse")
    func removesSidebandData() async throws {
        let scratch = try TemporaryDirectory()
        let app = try await Fixture.makeApp(at: scratch.url.appendingPathComponent("Fixture.app"), version: "2.0")
        let executable = app.appendingPathComponent("Contents/MacOS/Fixture").path
        let readOnly = try scratch.write("data", to: "Fixture.app/Contents/Resources/data.bin").path
        // Signed with the resource in place; then comes what a vendor's disk image can add.
        let signed = await ProcessRunner.run("/usr/bin/codesign", ["--force", "--sign", "-", app.path], timeout: 60)
        try #require(signed.success)
        for path in [app.path, executable, readOnly] {
            try Fixture.setFinderInfo(on: path)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: readOnly)

        // Intact, signed, and refused all the same.
        let before = await CodeSignVerifier.verify(app.path)
        #expect(!before.success)

        #expect(SidebandData.remove(from: app) == 3)

        #expect(await CodeSignVerifier.verify(app.path).success)
        #expect(![app.path, executable, readOnly].contains(where: Fixture.hasFinderInfo))
        // A file is as unwritable as it was, and a clean bundle is left as it is.
        #expect(try FileManager.default.attributesOfItem(atPath: readOnly)[.posixPermissions] as? Int == 0o444)
        #expect(SidebandData.remove(from: app) == 0)
    }

    @Test("does not follow a link out of the bundle it is cleaning")
    func leavesLinkTargetsAlone() throws {
        let scratch = try TemporaryDirectory()
        let contents = try scratch.makeDirectory("Fixture.app/Contents")
        let outside = try scratch.write("not part of the app", to: "outside.txt").path
        try FileManager.default.createSymbolicLink(
            atPath: contents.appendingPathComponent("link").path, withDestinationPath: outside
        )
        try Fixture.setFinderInfo(on: contents.path)
        try Fixture.setFinderInfo(on: outside)

        #expect(SidebandData.remove(from: scratch.url.appendingPathComponent("Fixture.app")) == 1)

        #expect(!Fixture.hasFinderInfo(contents.path))
        #expect(Fixture.hasFinderInfo(outside))
    }

    @Test("rejects things that are not real application bundles")
    func rejectsNonBundles() async throws {
        let scratch = try TemporaryDirectory()
        let app = try await Fixture.makeApp(at: scratch.url.appendingPathComponent("Real.app"), version: "2.0")
        let link = scratch.url.appendingPathComponent("Link.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: app)
        let file = try scratch.write("not a bundle", to: "File.app")
        let folder = try scratch.makeDirectory("Folder")

        for candidate in [link, file, folder] {
            let result = await PayloadVerifier.verifyApp(at: candidate, expected: expected, policy: relaxed)
            #expect(result == .failure(.notAnAppBundle))
        }
    }

    @Test("rejects a file that is not an installer package")
    func rejectsNonPackages() async throws {
        let scratch = try TemporaryDirectory()
        let file = try scratch.write("plain", to: "notes.txt")
        let unsigned = try scratch.write("not really a package", to: "Fake.pkg")
        let fromKnownDeveloper = ExpectedApp(
            name: "Fixture", bundleIdentifier: "com.example.fixture",
            teamIdentifier: "A1B2C3D4E5", installedVersion: "1.0"
        )

        #expect(await PayloadVerifier.verifyPackage(at: file, expected: fromKnownDeveloper) == .failure(.notAPackage))
        guard case .failure(.invalidSignature) = await PayloadVerifier.verifyPackage(
            at: unsigned, expected: fromKnownDeveloper
        ) else {
            Issue.record("Expected an unsigned package to be rejected")
            return
        }
    }

    @Test("never accepts an installer package when the installed copy has no developer to compare with")
    func refusesPackageWithoutDeveloper() async throws {
        let scratch = try TemporaryDirectory()
        let package = try scratch.write("whatever it contains", to: "Update.pkg")

        // `expected` describes an installed copy that is unsigned or ad-hoc signed.
        #expect(await PayloadVerifier.verifyPackage(at: package, expected: expected) == .failure(.noDeveloperToCompare))
        #expect(await PayloadVerifier.verifyPackage(
            at: package, expected: expected, policy: relaxed
        ) == .failure(.noDeveloperToCompare))
    }

    @Test("rejects a build that needs a newer macOS than this Mac runs")
    func rejectsBuildForNewerSystem() async throws {
        let scratch = try TemporaryDirectory()
        let app = try await Fixture.makeApp(
            at: scratch.url.appendingPathComponent("Fixture.app"), version: "2.0", minimumSystemVersion: "14.0"
        )

        let onVentura = await PayloadVerifier.verifyApp(
            at: app, expected: expected, policy: relaxed, hostSystemVersion: "13.6.1"
        )
        #expect(onVentura == .failure(.requiresNewerSystem(required: "14.0", host: "13.6.1")))

        for host in ["14.0.0", "14.2", "26.1.0"] {
            let result = await PayloadVerifier.verifyApp(
                at: app, expected: expected, policy: relaxed, hostSystemVersion: host
            )
            #expect((try? result.get()) != nil, "macOS \(host) should be accepted")
        }
    }

    @Test("tells an installed copy without a developer from one whose signature could not be read")
    func interpretsInstalledSignatures() {
        func result(exit: Int32, stderr: String, timedOut: Bool = false, launchError: String? = nil) -> ProcessResult {
            ProcessResult(
                exitCode: exit, stdout: "", stderr: stderr, timedOut: timedOut, wasCancelled: false,
                launchError: launchError
            )
        }
        let signed = "Identifier=com.example.sample\nAuthority=Developer ID Application: X (A1B2C3D4E5)\nTeamIdentifier=A1B2C3D4E5\n"
        let adHoc = "Identifier=Guava\nSignature=adhoc\nTeamIdentifier=not set\n"

        #expect(CodeSignVerifier.interpretInstalledSignature(result(exit: 0, stderr: signed)) == .developer("A1B2C3D4E5"))
        #expect(CodeSignVerifier.interpretInstalledSignature(result(exit: 0, stderr: adHoc)) == .noDeveloper)
        #expect(CodeSignVerifier.interpretInstalledSignature(
            result(exit: 1, stderr: "/Applications/Plain.app: code object is not signed at all\n")
        ) == .noDeveloper)

        // Anything else means it is not known who signed it, which must not pass for "nobody".
        let unreadable: [ProcessResult] = [
            result(exit: 1, stderr: "/Applications/Gone.app: No such file or directory\n"),
            result(exit: 15, stderr: "", timedOut: true),
            result(exit: -1, stderr: "", launchError: "Could not run /usr/bin/codesign"),
            // A timeout must not be read as "unsigned" just because of what was printed first.
            result(exit: 15, stderr: "code object is not signed at all", timedOut: true),
        ]
        for outcome in unreadable {
            guard case .unreadable = CodeSignVerifier.interpretInstalledSignature(outcome) else {
                Issue.record("Expected an unreadable signature for \(outcome)")
                continue
            }
        }
    }

    @Test("reads who signed real bundles on disk")
    func readsInstalledSignatures() async throws {
        let scratch = try TemporaryDirectory()
        let adHoc = try await Fixture.makeApp(at: scratch.url.appendingPathComponent("AdHoc.app"), version: "1.0")
        let unsigned = try await Fixture.makeApp(
            at: scratch.url.appendingPathComponent("Unsigned.app"), version: "1.0", sign: false
        )

        #expect(await CodeSignVerifier.installedSignature(of: adHoc.path) == .noDeveloper)
        #expect(await CodeSignVerifier.installedSignature(of: unsigned.path) == .noDeveloper)
        guard case .unreadable = await CodeSignVerifier.installedSignature(
            of: scratch.url.appendingPathComponent("Missing.app").path
        ) else {
            Issue.record("A bundle that does not exist has no readable signature")
            return
        }
    }

    @Test("knows which processors can run which builds")
    func checksArchitectures() {
        let arm = NSNumber(value: NSBundleExecutableArchitectureARM64)
        let intel = NSNumber(value: NSBundleExecutableArchitectureX86_64)
        let ppc = NSNumber(value: NSBundleExecutableArchitecturePPC)

        #expect(PayloadVerifier.runs(on: "arm64", architectures: [arm]))
        #expect(PayloadVerifier.runs(on: "arm64", architectures: [intel]))
        #expect(PayloadVerifier.runs(on: "x86_64", architectures: [intel, arm]))
        #expect(!PayloadVerifier.runs(on: "x86_64", architectures: [arm]))
        #expect(!PayloadVerifier.runs(on: "arm64", architectures: [ppc]))
        #expect(PayloadVerifier.runs(on: "x86_64", architectures: nil))
        #expect(PayloadVerifier.runs(on: "x86_64", architectures: []))
    }
}
